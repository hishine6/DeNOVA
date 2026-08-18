#!/bin/bash
# test_iaa_recovery.sh — validates opt#3's clean fast-path recovery WITH live
# IAA (indirect/chain) entries. Writes many distinct blocks so birthday
# collisions in the 23-bit direct hash spill into IAA slots, deduplicates,
# unmounts cleanly (checkpoint records hwm > IAA_START), remounts via the fast
# path (rebuilds the IAA free-list from [IAA_START, hwm)), verifies old data,
# then writes MORE distinct blocks that ALLOCATE from the rebuilt free-list +
# dedup + verify. A missed live entry in the rebuild would reuse a live slot ->
# corruption or "IAA Infinite loop". Prints ">>> IAA RECOVERY PASS" iff clean.
# Daemon-agnostic. Run:  bash scripts/test_iaa_recovery.sh && bash scripts/run.sh
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEST_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
WORK="${DENOVA_WORK:-$TEST_DIR/work}"
TOOLS="$TEST_DIR/guest/tools"
ID="$WORK/initramfs"
rm -rf "$ID"; mkdir -p "$ID"/{bin,sbin,proc,sys,dev,mnt,results}

BB=""
for c in /bin/busybox /usr/bin/busybox /sbin/busybox; do
  [ -x "$c" ] || continue
  o=$(ldd "$c" 2>&1 || true)
  case "$o" in *"not a dynamic"*|*"statically linked"*) BB="$c"; break ;; esac
done
[ -n "$BB" ] || { echo "no static busybox (try: sudo apt install busybox-static)"; exit 1; }
cp "$BB" "$ID/bin/busybox"
gcc -static -O2 -o "$ID/bin/dedup_trigger" "$TOOLS/dedup_trigger.c"
gcc -static -O2 -o "$ID/bin/dedup_stress"  "$TOOLS/dedup_stress.c"

NB="${NB:-80000}"
cat > "$ID/init" <<IEOF
#!/bin/busybox sh
export PATH=/bin:/sbin
/bin/busybox --install -s /bin 2>/dev/null
mount -t proc proc /proc; mount -t sysfs sysfs /sys; mount -t devtmpfs devtmpfs /dev 2>/dev/null
FAIL=0
echo
echo "======== DeNOVA opt#3 IAA fast-path recovery test ($NB distinct blocks) ========"
[ -e /dev/pmem0 ] || { echo "pmem MISSING"; dmesg|tail; poweroff -f; }
mkdir -p /mnt/nova
mount -t NOVA -o init /dev/pmem0 /mnt/nova || { echo "init mount FAIL"; dmesg|tail -20; poweroff -f; }

echo "--- write \$NB distinct blocks + dedup (forces IAA chains) ---"
/bin/dedup_stress /mnt/nova/a.dat write $NB 100000
sync; /bin/dedup_trigger; sync
/bin/dedup_stress /mnt/nova/a.dat verify $NB 100000 || { echo "pre-remount verify BAD"; FAIL=1; }

echo "--- clean unmount (checkpoint) + fast-path remount ---"
umount /mnt/nova && echo "umount OK"
mount -t NOVA /dev/pmem0 /mnt/nova || { echo "remount FAIL"; dmesg|tail -20; FAIL=1; }
dmesg | grep -i "fast path" | tail -1
IAALIVE=\$(dmesg | grep -i "fast path" | tail -1 | sed -n 's/.*: \([0-9]*\) live IAA.*/\1/p')
[ "\${IAALIVE:-0}" -gt 0 ] 2>/dev/null && echo "IAA entries present (\$IAALIVE) -> fast path exercised" || echo "WARN: 0 IAA entries (raise NB)"

echo "--- verify old data survived fast-path recovery ---"
/bin/dedup_stress /mnt/nova/a.dat verify $NB 100000 || { echo "post-remount verify BAD"; FAIL=1; }
echo "--- write MORE distinct blocks (allocate from rebuilt free-list) + dedup + verify ---"
/bin/dedup_stress /mnt/nova/b.dat write $NB 900000
sync; /bin/dedup_trigger; sync
/bin/dedup_stress /mnt/nova/b.dat verify $NB 900000 || { echo "b.dat verify BAD"; FAIL=1; }
/bin/dedup_stress /mnt/nova/a.dat verify $NB 100000 || { echo "a.dat re-verify BAD"; FAIL=1; }
umount /mnt/nova && echo "final umount OK"

OOPS=\$(dmesg | grep -icE "BUG:|Oops|Call Trace|kernel NULL|already in free list|assertion failed")
IAA=\$(dmesg | grep -c "IAA Infinite")
echo "======== RESULT: FAIL=\$FAIL oops=\$OOPS iaa_loop=\$IAA ========"
if [ "\$FAIL" = 0 ] && [ "\$OOPS" = 0 ] && [ "\$IAA" = 0 ]; then echo ">>> IAA RECOVERY PASS"; else echo ">>> IAA RECOVERY FAIL"; fi
poweroff -f
IEOF
chmod +x "$ID/init" "$ID/bin/"*
( cd "$ID" && find . | cpio -o -H newc 2>/dev/null | gzip -9 ) > "$WORK/initramfs.cpio.gz"
echo "initramfs -> $WORK/initramfs.cpio.gz ($(du -h "$WORK/initramfs.cpio.gz" | cut -f1))"
