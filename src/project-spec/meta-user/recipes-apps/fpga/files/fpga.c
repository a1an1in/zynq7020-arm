/*
 * fpga.c — aurora PL 寄存器读写工具（同时兼容任意物理地址 /dev/mem）。
 *
 *  用法:
 *    fpga read  [opts] ADDR [WIDTH]
 *    fpga write [opts] ADDR VALUE [WIDTH]
 *   opts:
 *    -b BASE   偏移地址时的基址        (默认 0x50000000)
 *    -a        ADDR 视为绝对物理地址
 *    -o        ADDR 视为相对 BASE 的偏移 (默认)
 *    -w WIDTH  访问宽度 8/16/32       (默认 32)
 *    -d DEV    强制 mmap 设备(/dev/uio0 或 /dev/mem)
 *    -h        帮助
 *
 *  设备选择: 未用 -d 时——若目标落在 aurora 窗口 [BASE, BASE+0x10000) 且
 *  存在 /dev/uio0，则走 UIO(内核已经 generic-uio 认领, 见 system-user.dtsi);
 *  否则回退 /dev/mem(可访问任意物理地址)。宽度默认小端、对齐访问。
 */
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <sys/mman.h>
#include <sys/stat.h>

#define DEF_BASE  0x50000000ULL /* aurora 窗内基址 */
#define WINDOW    0x10000ULL    /* 窗口尺寸 */
#define UIO_DEV   "/dev/uio0"
#define MEM_DEV   "/dev/mem"

static void usage(const char *p)
{
	fprintf(stderr,
		"用法: %s CMD [opts] ADDR [VALUE] [WIDTH]\n"
		"  CMD         read | write\n"
		"  -d DEV      强制设备(/dev/uio0 或 /dev/mem)\n"
		"  -b BASE     偏移寻址时的基址 (默认 0x%08llx)\n"
		"  -a          地址=绝对物理地址\n"
		"  -o          地址=相对 BASE 的偏移 (默认)\n"
		"  -w WIDTH    8/16/32 (默认 32)\n"
		"  -h          帮助\n"
		"例:  %s read 0x10           -> 读 0x50000010\n"
		"     %s read -a 0x50000010  -> 同上(绝对)\n"
		"     %s write 0x10 0x0A     -> 写 LED_VALUE\n"
		"     %s write 0x14 0x1      -> 使能 LED\n",
		p, (unsigned long long)DEF_BASE, p, p, p, p);
}

int main(int argc, char **argv)
{
	int c;
	int mode = 'o';          /* 'o' offset, 'a' absolute */
	int width = 32;
	char devbuf[64];
	const char *forced = NULL;
	unsigned long long base = DEF_BASE;
	unsigned long long addr, value = 0;
	int want_write, want_read;
	int fd;
	void *map;
	long psz;
	unsigned long long mm_off, inoff;
	size_t map_len;
	int prot;
	const char *cmd;

	while ((c = getopt(argc, argv, "aob:d:w:h")) != -1) {
		switch (c) {
		case 'a': mode = 'a'; break;
		case 'o': mode = 'o'; break;
		case 'b': base = strtoull(optarg, NULL, 0); break;
		case 'w': width = atoi(optarg); break;
		case 'd': forced = optarg; break;
		case 'h': usage(argv[0]); return 0;
		default:  usage(argv[0]); return 2;
		}
	}
	if (optind + 1 >= argc) { usage(argv[0]); return 2; }

	cmd = argv[optind];
	want_read  = (strcmp(cmd, "read")  == 0);
	want_write = (strcmp(cmd, "write") == 0);
	if (!want_read && !want_write) { usage(argv[0]); return 2; }

	addr = strtoull(argv[optind + 1], NULL, 0);
	if (want_write) {
		if (optind + 2 >= argc) { usage(argv[0]); return 2; }
		value = strtoull(argv[optind + 2], NULL, 0);
		if (optind + 3 < argc) width = atoi(argv[optind + 3]);
	} else {
		if (optind + 2 < argc) width = atoi(argv[optind + 2]);
	}
	if (width != 8 && width != 16 && width != 32) {
		fprintf(stderr, "宽度仅支持 8/16/32\n");
		return 2;
	}

	/* 绝对地址 or 相对基址偏移 */
	if (mode != 'a')
		addr = base + addr;

	/* 设备选择 */
	if (forced) {
		snprintf(devbuf, sizeof(devbuf), "%s", forced);
	} else if (addr >= DEF_BASE && addr < DEF_BASE + WINDOW &&
		   access(UIO_DEV, F_OK) == 0) {
		snprintf(devbuf, sizeof(devbuf), "%s", UIO_DEV);
	} else {
		snprintf(devbuf, sizeof(devbuf), "%s", MEM_DEV);
	}

	fd = open(devbuf, want_write ? O_RDWR : O_RDONLY);
	if (fd < 0) { perror(devbuf); return 1; }

	psz = sysconf(_SC_PAGESIZE);
	if (strcmp(devbuf, UIO_DEV) == 0) {
		mm_off  = 0;                    /* UIO 从窗首 0 起映射 */
		inoff   = addr - DEF_BASE;
		map_len = WINDOW;               /* 已是页对齐的窗口 */
	} else {
		mm_off  = addr - (addr % (unsigned long long)psz);
		inoff   = addr - mm_off;
		if ((size_t)inoff + width <= (size_t)psz)
			map_len = (size_t)psz;
		else
			map_len = (((size_t)inoff + width - 1) / (size_t)psz + 1)
				  * (size_t)psz;
	}

	prot = want_write ? (PROT_READ | PROT_WRITE) : PROT_READ;

	/* 对普通文件 -d 时, 别映射到 EOF 之后(否则访问即 SIGBUS) */
	{
		struct stat st;
		if (fstat(fd, &st) == 0 && S_ISREG(st.st_mode)) {
			size_t len = map_len;
			if (mm_off >= (unsigned long long)st.st_size) {
				fprintf(stderr, "%s: mmap 偏移超出文件size\n", devbuf);
				close(fd);
				return 1;
			}
			if (len > (size_t)((unsigned long long)st.st_size - mm_off))
				len = (size_t)((unsigned long long)st.st_size - mm_off);
			map_len = len;
		}
	}

	map = mmap(NULL, map_len, prot, MAP_SHARED, fd, (off_t)mm_off);
	if (map == MAP_FAILED) { perror("mmap"); close(fd); return 1; }

	/* 对齐访问 */
	{
		volatile unsigned char *b = (volatile unsigned char *)map + inoff;
		if (inoff % ((width + 7) / 8) != 0) {
			/* 非自然对齐，行为未定义 — 报错退出 */
			fprintf(stderr, "地址未对齐到 %d 位\n", width);
			munmap(map, map_len); close(fd); return 2;
		}
		if (want_write) {
			if (width == 8)      *(volatile uint8_t  *)b = (uint8_t) value;
			else if (width == 16)*(volatile uint16_t *)b = (uint16_t)value;
			else                 *(volatile uint32_t *)b = (uint32_t)value;
		} else {
			unsigned long long r;
			if (width == 8)      r = *(volatile uint8_t  *)b;
			else if (width == 16)r = *(volatile uint16_t *)b;
			else                 r = *(volatile uint32_t *)b;
			if (width == 32)  printf("0x%08llx\n", r);
			else if (width == 16) printf("0x%04llx\n", r);
			else              printf("0x%02llx\n", r);
		}
	}

	munmap(map, map_len);
	close(fd);
	return 0;
}