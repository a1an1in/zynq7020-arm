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
	if (len == 0)
		len = info.buf_size;

	buf = malloc(len ? len : 1);
	if (!buf) {
		perror("malloc");
		close(fd);
		return 1;
	}

	ret = ioctl(fd, IOCTL_S2MM_TRIGGER, &len);
	if (ret < 0) {
		perror("ioctl TRIGGER (PL must be feeding S_AXIS_S2MM)");
		free(buf);
		close(fd);
		return 1;
	}

	memset(buf, 0, len);
	n = 0;
	{
		ssize_t rd;
		while ((size_t)n < info.last_len) {
			rd = read(fd, buf + n, info.last_len - n);
			if (rd <= 0)
				break;
			n += (int)rd;
		}
	}

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

	free(buf);
	close(fd);
	return 0;
}