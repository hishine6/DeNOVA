/* dedup_stress.c — end-to-end dedup consistency check.
 *
 *   dedup_stress <path> write  <nblocks> <ndistinct>
 *   dedup_stress <path> verify <nblocks> <ndistinct>
 *
 * Block i's 4KB content is a deterministic function of its pattern id
 * (i % ndistinct), so the file contains exactly <ndistinct> unique block
 * contents, each repeated nblocks/ndistinct times. After the offline dedup
 * pass, every logical block must STILL read back its own pattern. A mismatch
 * means dedup merged two non-identical blocks (silent data corruption) or a
 * chain operation (e.g. reorder) corrupted the mapping.
 *
 * Build: gcc -static -O2 -o dedup_stress dedup_stress.c
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#include <stdint.h>

#define REC 4096

static void gen(unsigned char *b, unsigned long pat)
{
	uint32_t i;
	for (i = 0; i < REC; i += 4) {
		uint32_t v = pat * 2654435761u + i * 40503u + 0x1234u;
		memcpy(b + i, &v, 4);
	}
	memcpy(b, &pat, sizeof(pat));	/* stamp pattern id up front */
}

int main(int argc, char **argv)
{
	if (argc < 5) {
		fprintf(stderr, "usage: %s <path> write|verify <nblocks> <ndistinct>\n", argv[0]);
		return 2;
	}
	const char *path = argv[1], *mode = argv[2];
	unsigned long n = strtoul(argv[3], 0, 0);
	unsigned long d = strtoul(argv[4], 0, 0);
	if (d == 0) d = 1;

	unsigned char *b = malloc(REC), *e = malloc(REC);
	if (!b || !e) return 1;

	if (!strcmp(mode, "write")) {
		int fd = open(path, O_CREAT | O_TRUNC | O_WRONLY, 0644);
		if (fd < 0) { perror("open"); return 1; }
		for (unsigned long i = 0; i < n; i++) {
			gen(b, i % d);
			if (write(fd, b, REC) != REC) { perror("write"); return 1; }
		}
		if (fsync(fd)) { perror("fsync"); return 1; }
		close(fd);
		fprintf(stderr, "[stress] wrote %lu blocks, %lu distinct patterns (%lu KB)\n", n, d, n * 4);
		return 0;
	} else if (!strcmp(mode, "verify")) {
		int fd = open(path, O_RDONLY);
		if (fd < 0) { perror("open"); return 1; }
		unsigned long ok = 0, bad = 0;
		for (unsigned long i = 0; i < n; i++) {
			if (read(fd, b, REC) != REC) { perror("read"); return 1; }
			gen(e, i % d);
			if (memcmp(b, e, REC) != 0) {
				if (bad < 5)
					fprintf(stderr, "[stress] MISMATCH at block %lu (expected pattern %lu)\n", i, i % d);
				bad++;
			} else {
				ok++;
			}
		}
		close(fd);
		fprintf(stderr, "[stress] verify: %lu OK, %lu MISMATCH out of %lu\n", ok, bad, n);
		return bad ? 1 : 0;
	}
	fprintf(stderr, "unknown mode: %s\n", mode);
	return 2;
}
