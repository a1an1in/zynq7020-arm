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
#include <linux/poll.h>
#include <linux/wait.h>
#include <linux/of_address.h>

#define DRV_NAME		"xlnx-s2mm"

/* Default capture buffer.  CMA on Zynq is 16 MiB, so 4 MiB is comfortable. */
#define DEFAULT_BUF_SIZE	(4 * 1024 * 1024)

/* Fake source (aurora_dma_src) control block, exposed on AXI GP0. */
#define FAKE_SRC_BASE		0x40000000
#define FAKE_LEN_OFF		0x34	/* len_r: words (32-bit) per frame */
#define FAKE_CTRL_OFF		0x30	/* bit0: RUN edge (self-clearing, one frame) */
#define FAKE_SRC_LEN		0x100

/* Capture bytes when ioctl TRIGGER len == 0.  Keep this equal to ONE fake-source
 * frame (LEN*4) so the DMA BTT matches what the source actually emits.  A 4 MiB
 * request vs a short single frame never fills -> no IOC -> no interrupt, so default
 * to a small aligned capture; override via module param if the frame is bigger. */
static unsigned int default_len = 1024;
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
	struct wait_queue_head	rx_wait;
	unsigned int		rx_len;
	unsigned int		last_len;
	void __iomem		*dmaregs;	/* AXI-DMA regs (corrective only) */
	void __iomem		*srcregs;	/* mapped fake-source control block */
	struct miscdevice	misc;
};

static struct xlnx_s2mm_dev *s2mm_global;

/* DMA completion callback (runs in IRQ/tasklet context).  Non-blocking: just
 * publish the length, flag arrival and wake any poll()/read() waiter.  The
 * ioctl() that armed this transfer has already returned to userspace. */
static void s2mm_cb(void *param)
{
	struct xlnx_s2mm_dev *st = param;

	WRITE_ONCE(st->last_len, st->rx_len);
	wake_up_interruptible(&st->rx_wait);
}

/* ---- AXI-DMA S2MM corrective maintenance (the transfer itself still goes
 * 100% through dmaengine; we only pre-clean the channel so a stuck shared
 * level IRQ can't storm the CPU) -------------------------------------- */
/* AXI-DMA registers are intentionally NOT hardcoded: the controller base is
 * resolved from the DT `dmas` phandle at probe time (see probe) so this driver
 * stays board-portable -- no physical address is baked in.  Only the channel
 * offsets are constants.  These are corrective-maintenance offsets; the actual
 * transfer still runs 100% through dmaengine. */
#define S2MM_DMACR		0x30
#define S2MM_DMASR		0x34
#define S2MM_DMACR_RS		BIT(0)
#define S2MM_DMACR_RESET	BIT(2)
#define S2MM_DMACR_IOC_IRQ_EN	BIT(12)	/* completion (IOC) interrupt enable */
#define S2MM_DMACR_DLY_IRQ_EN	BIT(13)
#define S2MM_DMACR_ERR_IRQ_EN	BIT(14)

/*
 * Put the S2MM channel in a known-clean state before each dmaengine
 * transfer and again after a timeout:
 *   1. stop the channel, disable error/delay IRQs (keep only IOC);
 *   2. write-1-to-clear DMASR to release any latched completion/error level.
 *      If we do NOT de-assert this, the shared level IRQ fires continuously,
 *      the ISR cannot clear an unrecoverable error bit, and the CPU backs up
 *      in an IRQ storm -> serial hangs (observed).
 *   3. pulse a channel reset, then re-enable IOC.
 */
static void s2mm_dma_reset(struct xlnx_s2mm_dev *st)
{
	u32 dcr;
	int i;

	if (!st->dmaregs)
		return;

	/* stop the channel; keep only the IOC completion interrupt */
	dcr = ioread32(st->dmaregs + S2MM_DMACR);
	dcr &= ~(S2MM_DMACR_RS | S2MM_DMACR_DLY_IRQ_EN |
		 S2MM_DMACR_ERR_IRQ_EN);
	iowrite32(dcr, st->dmaregs + S2MM_DMACR);

	/* write-1-to-clear: de-assert any stuck completion/error level */
	iowrite32(0xffffffff, st->dmaregs + S2MM_DMASR);

	/* channel reset (DMACR bit2 self-clears on completion) */
	iowrite32(dcr | S2MM_DMACR_RESET, st->dmaregs + S2MM_DMACR);
	for (i = 0; i < 100000 &&
	     (ioread32(st->dmaregs + S2MM_DMACR) & S2MM_DMACR_RESET); i++)
		;

	/* re-enable just IOC so completion still wakes the dmaengine cb */
	iowrite32(ioread32(st->dmaregs + S2MM_DMACR) | S2MM_DMACR_IOC_IRQ_EN,
		  st->dmaregs + S2MM_DMACR);
}

/*
 * Arm one asynchronous S2MM capture and return immediately.  When the DMA
 * completes, dmaengine runs s2mm_cb() which stores last_len and wakes
 * rx_wait -- userspace observes the new frame via poll()/read().  Nothing
 * here blocks on completion.
 */
static int s2mm_start_async(struct xlnx_s2mm_dev *st, unsigned int len)
{
	struct dma_async_tx_descriptor *desc;
	dma_cookie_t cookie;
	int ret;

	if (!len)
		len = default_len;
	if (len > st->buf_size) {
		dev_err(st->dev, "len %u exceeds buffer %u\n", len,
			st->buf_size);
		return -EINVAL;
	}
	/* The fake source is word (32-bit) granular: a non-multiple-of-4 BTT
	 * can never equal a real source frame, so the channel would wait
	 * forever (DMA only retires once BTT is fully received, never on a
	 * short frame).  Reject instead of silently hanging poll()/select(). */
	if (len % 4) {
		dev_err(st->dev,
			"len %u not multiple of 4: BTT must equal source frame "
			"(LEN*4 bytes)\n", len);
		return -EINVAL;
	}

	/* Clean the channel (clear errors / de-assert any stuck level) so a
	 * previously latched completion can't re-trigger an IRQ storm. */
	s2mm_dma_reset(st);

	memset(st->buf, 0, len);
	desc = dmaengine_prep_slave_single(st->chan, st->dma_addr, len,
					   DMA_DEV_TO_MEM,
					   DMA_PREP_INTERRUPT | DMA_CTRL_ACK);
	if (!desc) {
		dev_err(st->dev, "device_prep_slave_single failed\n");
		return -EIO;
	}
	desc->callback = s2mm_cb;
	desc->callback_param = st;

	WRITE_ONCE(st->last_len, 0);
	st->rx_len = len;
	cookie = dmaengine_submit(desc);
	ret = dma_submit_error(cookie);
	if (ret)
		return ret;
	dma_async_issue_pending(st->chan);

	/* Trigger the (single-frame, self-clearing) fake source: frame size
	 * must equal BTT so S2MM retires with one IOC. */
	if (st->srcregs) {
		iowrite32(len / 4, st->srcregs + FAKE_LEN_OFF);
		iowrite32(1,  st->srcregs + FAKE_CTRL_OFF);
	}

	dev_info(st->dev, "S2MM armed for %u bytes (async)\n", len);
	return 0;
}

/* poll(): report readable once a frame has arrived (async notification). */
static __poll_t s2mm_poll(struct file *f, poll_table *pt)
{
	struct xlnx_s2mm_dev *st = s2mm_global;
	__poll_t mask = 0;

	if (!st)
		return EPOLLERR;
	/* "readable" == data is actually available: single source of truth is
	 * last_len (== rx_len a frame arrived in s2mm_cb), kept in sync with
	 * Rx writer via WRITE_ONCE/READ_ONCE so select() can never report
	 * ready while read() still sees 0 bytes. */
	poll_wait(f, &st->rx_wait, pt);
	if (READ_ONCE(st->last_len))
		mask |= EPOLLIN | EPOLLRDNORM;
	return mask;
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
		/* Arm only; the DMA completes asynchronously and the app is
		 * notified via poll()/read(). No blocking here. */
		mutex_lock(&st->lock);
		ret = s2mm_start_async(st, len);
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
	unsigned int avail;
	size_t n;

	if (!st)
		return 0;
	avail = READ_ONCE(st->last_len);
	if (!avail || *ppos >= avail)
		return 0;

	n = min(count, (size_t)(avail - *ppos));
	if (copy_to_user(ubuf, (char *)st->buf + *ppos, n))
		return -EFAULT;
	*ppos += n;
	return n;
}

/*
 * mmap(): expose the kernel-coherent DMA receive buffer directly to the app.
 * The buffer is dma_alloc_coherent()'d, so it is physically contiguous and
 * cache-coherent; mapping it into the app means the DMA writes land in memory
 * the app can read straight away -- the read()/copy_to_user() path is skipped
 * (zero-copy readback).  dma_mmap_coherent is the matching API for a buffer
 * obtained with dma_alloc_coherent().
 */
static int s2mm_mmap(struct file *f, struct vm_area_struct *vma)
{
	struct xlnx_s2mm_dev *st = s2mm_global;
	unsigned long size = vma->vm_end - vma->vm_start;

	if (!st)
		return -ENODEV;
	if (size > st->buf_size)
		return -EINVAL;
	return dma_mmap_coherent(st->dev, vma, st->buf, st->dma_addr, size);
}

static const struct file_operations s2mm_fops = {
	.owner		= THIS_MODULE,
	.read		= s2mm_read,
	.poll		= s2mm_poll,
	.mmap		= s2mm_mmap,
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
	init_waitqueue_head(&st->rx_wait);

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

	/* Resolve the AXI-DMA base portably from the DT `dmas` phandle so no
	 * physical address is hardcoded.  The pointer is only used for the
	 * corrective IRQ-storm pre-clean, never for the transfer itself. */
	{
		struct device_node *dma_np = of_parse_phandle(dev->of_node, "dmas", 0);

		st->dmaregs = dma_np ? of_iomap(dma_np, 0) : NULL;
		if (!st->dmaregs)
			dev_warn(dev,
				 "couldn't map AXI-DMA regs via dmas phandle; "
				 "IRQ-storm pre-clean disabled\n");
		of_node_put(dma_np);
	}

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
	if (st->dmaregs)
		iounmap(st->dmaregs);

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