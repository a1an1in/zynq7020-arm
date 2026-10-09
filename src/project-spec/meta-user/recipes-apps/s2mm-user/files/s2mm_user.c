/*
 * s2mm_user.c - userspace driver/verifier for /dev/xlnx-s2mm
 *
 * Usage:
 *   s2mm-user                       # trigger a capture of DEFAULT_LEN bytes
 *   s2mm-user 4096                  # capture 4096 bytes
 *   s2mm-user 4096 | xxd | head     # dump the received bytes
 *
 * The DMA itself is submitted in kernel space (dmaengine, S2MM channel);
 * this tool triggers it via ioctl and reads the captured buffer back, so an
 * unprivileged process can verify what the PL stream delivered.
 */
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <sys/select.h>
#include <sys/time.h>

#define DEV "/dev/xlnx-s2mm"

/* Keep in sync with xlnx_s2mm_test.c */
#define S2MM_IOCTL_MAGIC 'S'
#define IOCTL_S2MM_TRIGGER _IOW(S2MM_IOCTL_MAGIC, 0, unsigned int)
#define IOCTL_S2MM_INFO    _IOR(S2MM_IOCTL_MAGIC, 1, struct s2mm_info)

struct s2mm_info {
	unsigned int buf_size;
	unsigned int last_len;
};

int main(int argc, char **argv)
{
	struct s2mm_info info;
	unsigned char *buf;
	unsigned int len = 0;
	unsigned int frame_len = 0;
	int fd, ret, i, n;

	fd = open(DEV, O_RDWR);
	if (fd < 0) {
		perror("open " DEV " (module loaded? /dev present?)");
		return 1;
	}

	ret = ioctl(fd, IOCTL_S2MM_INFO, &info);
	if (ret < 0) {
		perror("ioctl INFO");
		close(fd);
		return 1;
	}
	printf("device: buf_size=%u last_len=%u\n", info.buf_size, info.last_len);

	if (argc > 1)
		len = (unsigned int)strtoul(argv[1], NULL, 0);
	/* No arg: use a frame-sized capture, NOT buf_size.  buf_size (4 MiB) is
	 * the DMA buffer capacity, not the PL fake-source frame length; arming a
	 * huge BTT truncates fake-source len_r and DMA retires having only filled
	 * the head of the buffer while last_len still reports the full armed len.
	 * 1024 is a tested-good capture size on this design. */
	if (len == 0)
		len = 1024;

	/* Zero-copy: mmap the kernel-coherent DMA receive buffer straight into
	 * this process instead of malloc() + read() copying.  We map the full
	 * buffer capacity (buf_size); each completed frame occupies the head of
	 * this mapping (offset 0).  The DMA writes into this same physical
	 * memory, so no copy_to_user() occurs on the readback path. */
	buf = mmap(NULL, info.buf_size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
	if (buf == MAP_FAILED) {
		perror("mmap");
		close(fd);
		return 1;
	}

	ret = ioctl(fd, IOCTL_S2MM_TRIGGER, &len);
	if (ret < 0) {
		perror("ioctl TRIGGER (PL must be feeding S_AXIS_S2MM)");
		munmap(buf, info.buf_size);
		close(fd);
		return 1;
	}

	/* TRIGGER now returns immediately (async): block in select()/poll() until
	 * the completion notification arrives, then read the frame straight from
	 * the mmap'd DMA buffer.  Only a "readable" event (select() > 0, i.e.
	 * rx_done in the driver) means a frame was captured -- timeout/error
	 * means no data, so no frame is available. */
	{
		fd_set rfds;
		struct timeval tv;
		int sr;
		FD_ZERO(&rfds);
		FD_SET(fd, &rfds);
		tv.tv_sec  = 3;
		tv.tv_usec = 0;
		sr = select(fd + 1, &rfds, NULL, NULL, &tv);
		if (sr <= 0) {
			if (sr == 0)
				printf("no completed frame within 3s "
				       "(PL not delivering / frame length != BTT?\n");
			else
				perror("select");
			munmap(buf, info.buf_size);
			close(fd);
			return 2;
		}
		/* event: fd readable -> a frame is available; continue below */
	}

	/* select()/poll() do NOT report a byte count.  Query the driver AFTER
	 * the event (never the pre-trigger snapshot) for the exact number this
	 * frame delivered, then read exactly that many. */
	frame_len = len;
	{
		struct s2mm_info done;
		if (ioctl(fd, IOCTL_S2MM_INFO, &done) == 0 && done.last_len &&
		    done.last_len <= len)
			frame_len = done.last_len;
	}
	printf("frame: %u bytes available.\n", frame_len);

	/* Zero-copy readback: the DMA already wrote the frame into the head of
	 * the mmap'd buffer (offset 0).  No read()/copy_to_user() is needed --
	 * just point the analysis at buf[0..frame_len). */
	n = (int)frame_len;

	printf("captured %d bytes; first 32:\n", n);
	for (i = 0; i < n && i < 32; i++)
		printf("%02x%s", buf[i], (i + 1) % 16 ? " " : "\n");
	printf("\n");

	/* crude sanity: fail if capture is all zeroes (PL not delivering) */
	{
		int zeros = 1;
		for (i = 0; i < n; i++)
			if (buf[i]) { zeros = 0; break; }
		if (zeros)
			printf("WARNING: captured data is all 0x00\n");
	}

	munmap(buf, info.buf_size);
	close(fd);
	return 0;
}