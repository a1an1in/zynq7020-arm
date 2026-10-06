/*
 * xlnx_s2mm_test.c - Xilinx AXI DMA S2MM dmaengine test driver
 *
 * Bind to a device-tree node that requests the AXI-DMA S2MM channel
 * (dmas = <&axi_dma_0 1>; dma-names = "s2mm_channel"), then exposes a
 * misc char device /dev/xlnx-s2mm so that:
 *
 *   - ioctl(S2MM_TRIGGER, len)  : issue one DEV_TO_MEM (S2MM) DMA of `len`
 *                                 bytes from the PL stream into a coherent
 *                                 buffer (kernel-side dmaengine call).
 *   - ioctl(S2MM_INFO, &info)   : query buf_size / last_len.
 *   - read()                    : copy back the received bytes from the buffer.
 *
 * This is NOT "pure userspace dmaengine" -- dmaengine is a kernel API and the
 * transfer must be submitted in kernel space.  Userspace drives it and reads
 * the captured data through the char device.
 *
 * The DT client node for this driver looks like (in system-user.dtsi):
 *   amba_pl {
 *       axi_dma_0: dma@50000000 { ... };
 *       s2mm-test {
 *           compatible = "xlnx,s2mm-test";
 *           dmas = <&axi_dma_0 1>;      // args[0]=1 -> S2MM (chan[1], tdest=0)
 *           dma-names = "s2mm_channel";
 *       };
 *   };
 */

#include <linux/module.h>
#include <linux/platform_device.h>
#include <linux/of.h>
#include <linux/dma-mapping.h>
#include <linux/dmaengine.h>
#include <linux/miscdevice.h>
#include <linux/mutex.h>
#include <linux/completion.h>
#include <linux/slab.h>
#include <linux/uaccess.h>
#include <linux/fs.h>
#include <linux/io.h>

#define DRV_NAME		"xlnx-s2mm"

/* Default capture buffer.  CMA on Zynq is 16 MiB, so 4 MiB is comfortable. */
#define DEFAULT_BUF_SIZE	(4 * 1024 * 1024)
#define DEFAULT_TIMEOUT_MS	5000

/* Fake source (aurora_dma_src) control block, exposed on AXI GP0. */
#define FAKE_SRC_BASE		0x40000000
#define FAKE_LEN_OFF		0x34	/* len_r: words (32-bit) per frame */
#define FAKE_CTRL_OFF		0x30	/* bit0: RUN edge (self-clearing, one frame) */
#define FAKE_SRC_LEN		0x100

/* Capture bytes when ioctl TRIGGER len == 0.  Keep this equal to ONE fake-source
 * frame (LEN*4) so the DMA BTT matches what the source actually emits.  A 4 MiB
 * request vs a short single frame never fills -> no IOC -> no interrupt, so default
 * to a small aligned capture; override via module param if the frame is bigger. */
static unsigned int default_len = 256;
module_param(default_len, uint, 0444);
MODULE_PARM_DESC(default_len,
	"S2MM capture bytes when TRIGGER len==0 (should equal fake-source frame LEN*4)");

/* ---- userspace interface (module-local, driven through ioctl) ---- */
#define S2MM_IOCTL_MAGIC	'S'
#define IOCTL_S2MM_TRIGGER	_IOW(S2MM_IOCTL_MAGIC, 0, unsigned int)
#define IOCTL_S2MM_INFO		_IOR(S2MM_IOCTL_MAGIC, 1, struct s2mm_info)

struct s2mm_info {
	unsigned int buf_size;
	unsigned int last_len;
};

struct xlnx_s2mm_dev {
	struct platform_device *pdev;
	struct device		*dev;
	unsigned int		buf_size;
	void			*buf;
	dma_addr_t		dma_addr;
	struct dma_chan		*chan;
	struct mutex		lock;
	struct completion	cmpl;
	unsigned int		last_len;
	bool			chan_bad;	/* DMA channel unrecoverably errored */
	void __iomem		*srcregs;	/* mapped fake-source control block */
	struct miscdevice	misc;
};

static struct xlnx_s2mm_dev *s2mm_global;

/* DMA completion callback (runs in IRQ/tasklet context). */
static void s2mm_cb(void *param)
{
	complete(param);
}

static int do_s2mm_transfer(struct xlnx_s2mm_dev *st, unsigned int len)
{
	struct dma_async_tx_descriptor *desc;
	struct dma_slave_config cfg = { 0 };
	dma_cookie_t cookie;
	int ret;

	if (st->chan_bad || !st->chan || !st->chan->device) {
		dev_err(st->dev,
			"DMA channel dead (chan_bad=%d chan=%p device=%p), "
			"refusing further transfers; reinsert the module or reboot.\n",
			st->chan_bad, st->chan,
			st->chan ? st->chan->device : NULL);
		return -ENODEV;
	}

	if (len == 0)
		len = default_len;
	if (len > st->buf_size) {
		dev_err(st->dev, "length %u > buf_size %u\n", len, st->buf_size);
		return -EINVAL;
	}
	if (!st->chan) {
		dev_err(st->dev, "no DMA channel\n");
		return -ENODEV;
	}

	memset(st->buf, 0, len);

	/* AXI-DMA S2MM needs direction; width is optional for DRE. */
	cfg.direction = DMA_DEV_TO_MEM;
	dmaengine_slave_config(st->chan, &cfg);

	desc = dmaengine_prep_slave_single(st->chan, st->dma_addr, len,
					   DMA_DEV_TO_MEM,
					   DMA_PREP_INTERRUPT | DMA_CTRL_ACK);
	if (!desc) {
		dev_err(st->dev, "device_prep_slave_single failed\n");
		return -EIO;
	}

	desc->callback = s2mm_cb;
	desc->callback_param = st;

	reinit_completion(&st->cmpl);
	cookie = dmaengine_submit(desc);
	ret = dma_submit_error(cookie);
	if (ret)
		return ret;

	dma_async_issue_pending(st->chan);

	/* Fake source is a single-frame, self-clearing trigger (NOT free-run), so
	 * without an explicit RUN it emits nothing -> S2MM never fills -> no IOC
	 * -> no interrupt.  Issue one frame sized == BTT so DMA has data and will
	 * complete with an IOC interrupt.  len must be a multiple of 4 (32-bit). */
	if (st->srcregs && (len % 4 == 0)) {
		iowrite32(len / 4, st->srcregs + FAKE_LEN_OFF);
		iowrite32(1,  st->srcregs + FAKE_CTRL_OFF);
	}

	if (!wait_for_completion_timeout(&st->cmpl,
					 msecs_to_jiffies(DEFAULT_TIMEOUT_MS))) {
		st->chan_bad = true; /* level-IRQ sticky / stream starvation: wedge dead */
		dmaengine_terminate_all(st->chan);
		dev_err(st->dev,
			"S2MM timeout: PL stream never delivered %u bytes; "
			"channel marked bad, further transfers disabled\n",
			len);
		return -ETIMEDOUT;
	}

	dmaengine_synchronize(st->chan);
	st->last_len = len;

	dev_info(st->dev,
		 "S2MM: received %u bytes (dev addr 0x%pad)\nfirst: %02x %02x %02x %02x\n",
		 len, &st->dma_addr,
		 ((unsigned char *)st->buf)[0],
		 ((unsigned char *)st->buf)[1],
		 ((unsigned char *)st->buf)[2],
		 ((unsigned char *)st->buf)[3]);
	return 0;
}

/* ---- char device file operations ---- */
static long s2mm_ioctl(struct file *f, unsigned int cmd, unsigned long arg)
{
	struct xlnx_s2mm_dev *st = s2mm_global;
	unsigned int len;
	int ret;

	if (!st)
		return -ENODEV;

	switch (cmd) {
	case IOCTL_S2MM_TRIGGER:
		if (copy_from_user(&len, (void __user *)arg, sizeof(len)))
			return -EFAULT;
		mutex_lock(&st->lock);
		ret = do_s2mm_transfer(st, len);
		mutex_unlock(&st->lock);
		return ret;
	case IOCTL_S2MM_INFO:
	{
		struct s2mm_info info = {
			.buf_size = st->buf_size,
			.last_len = st->last_len,
		};
		if (copy_to_user((void __user *)arg, &info, sizeof(info)))
			return -EFAULT;
		return 0;
	}
	default:
		return -ENOTTY;
	}
}

static ssize_t s2mm_read(struct file *f, char __user *ubuf, size_t count,
			 loff_t *ppos)
{
	struct xlnx_s2mm_dev *st = s2mm_global;
	size_t n;

	if (!st || !st->last_len)
		return 0;
	if (*ppos >= st->last_len)
		return 0;

	n = min(count, (size_t)(st->last_len - *ppos));
	if (copy_to_user(ubuf, (char *)st->buf + *ppos, n))
		return -EFAULT;
	*ppos += n;
	return n;
}

static const struct file_operations s2mm_fops = {
	.owner		= THIS_MODULE,
	.read		= s2mm_read,
	.unlocked_ioctl	= s2mm_ioctl,
	.compat_ioctl	= s2mm_ioctl,
};

/* ---- platform driver ---- */
static int s2mm_probe(struct platform_device *pdev)
{
	struct device *dev = &pdev->dev;
	struct xlnx_s2mm_dev *st;
	int ret;

	st = devm_kzalloc(dev, sizeof(*st), GFP_KERNEL);
	if (!st)
		return -ENOMEM;

	st->pdev = pdev;
	st->dev = dev;
	mutex_init(&st->lock);
	init_completion(&st->cmpl);

	st->buf_size = DEFAULT_BUF_SIZE;
	st->buf = dma_alloc_coherent(dev, st->buf_size, &st->dma_addr, GFP_KERNEL);
	if (!st->buf) {
		dev_err(dev, "dma_alloc_coherent(%u) failed\n", st->buf_size);
		return -ENOMEM;
	}

	st->srcregs = ioremap(FAKE_SRC_BASE, FAKE_SRC_LEN);
	if (!st->srcregs)
		dev_warn(dev, "ioremap fake-source %#x failed; source driven out-of-band\n",
			 FAKE_SRC_BASE);

	/* Request the AXI-DMA S2MM channel via dma-names. */
	st->chan = dma_request_chan(dev, "s2mm_channel");
	if (IS_ERR(st->chan)) {
		ret = PTR_ERR(st->chan);
		dev_warn(dev, "dma_request_chan(\"s2mm_channel\") failed: %d\n",
			 ret);
		dma_free_coherent(dev, st->buf_size, st->buf, st->dma_addr);
		/*
		 * If the DMA controller is not up yet, defer and retry.
		 * Propagate the real errno so a bad dmas/dma-names binding
		 * surfaces in dmesg instead of looping silently.
		 */
		return -EPROBE_DEFER;
	}

	st->misc.minor = MISC_DYNAMIC_MINOR;
	st->misc.name = "xlnx-s2mm";
	st->misc.fops = &s2mm_fops;
	st->misc.parent = dev;
	ret = misc_register(&st->misc);
	if (ret) {
		dma_release_channel(st->chan);
		dma_free_coherent(dev, st->buf_size, st->buf, st->dma_addr);
		return ret;
	}

	platform_set_drvdata(pdev, st);
	s2mm_global = st;

	dev_info(dev, "Xilinx S2MM test driver: buf %u bytes, chan=%s\n",
		 st->buf_size, dma_chan_name(st->chan));
	return 0;
}

static int s2mm_remove(struct platform_device *pdev)
{
	struct xlnx_s2mm_dev *st = platform_get_drvdata(pdev);

	if (!st)
		return 0;

	if (st->misc.minor != 0)
		misc_deregister(&st->misc);

	if (st->srcregs)
		iounmap(st->srcregs);

	if (st->chan)
		dma_release_channel(st->chan);
	dma_free_coherent(&pdev->dev, st->buf_size, st->buf, st->dma_addr);
	s2mm_global = NULL;
	return 0;
}

static const struct of_device_id s2mm_of_match[] = {
	{ .compatible = "xlnx,s2mm-test" },
	{ /* sentinel */ }
};
MODULE_DEVICE_TABLE(of, s2mm_of_match);

static struct platform_driver s2mm_driver = {
	.probe  = s2mm_probe,
	.remove = s2mm_remove,
	.driver = {
		.name		= DRV_NAME,
		.of_match_table = s2mm_of_match,
	},
};

module_platform_driver(s2mm_driver);

MODULE_AUTHOR("zynq dev");
MODULE_DESCRIPTION("Xilinx AXI DMA S2MM dmaengine test driver");
MODULE_LICENSE("GPL v2");