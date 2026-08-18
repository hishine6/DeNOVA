/* dedup_trigger.c — invoke DeNOVA's custom `dedup` syscall (nr 335).
 *
 * The syscall (dedup/dedup.c: SYSCALL_DEFINE0(dedup)) opens
 * /mnt/nova/deduptable itself and calls file->f_op->dedup ->
 * nova_dedup_test(), which drains the global dedup queue populated by the
 * NOVA write path. So this just fires syscall 335 and reports the result.
 *
 * Build: gcc -static -O2 -o dedup_trigger dedup_trigger.c
 */
#include <stdio.h>
#include <unistd.h>
#include <sys/syscall.h>
#include <errno.h>
#include <string.h>

#ifndef SYS_dedup
#define SYS_dedup 335
#endif

int main(void)
{
	fprintf(stderr, "[dedup_trigger] calling syscall(%d) ...\n", SYS_dedup);
	long r = syscall(SYS_dedup);
	if (r < 0)
		fprintf(stderr, "[dedup_trigger] syscall returned %ld errno=%d (%s)\n",
			r, errno, strerror(errno));
	else
		fprintf(stderr, "[dedup_trigger] syscall returned %ld (ok)\n", r);
	return r < 0 ? 1 : 0;
}
