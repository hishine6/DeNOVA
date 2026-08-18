#!/bin/bash
# build_initramfs.sh — BusyBox initramfs that runs the DeNOVA dedup test:
# mount NOVA on the emulated pmem, write a file of known patterns (duplicates +
# distinct), run the offline dedup pass, verify every block still reads back
# its pattern (consistency), then delete the file to exercise the block-free
# path (nova_dedup_is_duplicate). Needs the busybox-static package on the host.
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
[ -n "$BB" ] || { echo "no static busybox found (try: sudo apt install busybox-static)"; exit 1; }
cp "$BB" "$ID/bin/busybox"; echo "busybox: $BB"

gcc -static -O2 -o "$ID/bin/dedup_trigger" "$TOOLS/dedup_trigger.c"
gcc -static -O2 -o "$ID/bin/dedup_stress"  "$TOOLS/dedup_stress.c"
echo "tools compiled"

NBLOCKS="${NBLOCKS:-16000}"
NDISTINCT="${NDISTINCT:-64}"

cat > "$ID/init" <<IEOF
#!/bin/busybox sh
export PATH=/bin:/sbin
/bin/busybox --install -s /bin 2>/dev/null
busybox mount -t proc  proc  /proc
busybox mount -t sysfs sysfs /sys
busybox mount -t devtmpfs devtmpfs /dev 2>/dev/null
blocks() { stat -c '%b sectors' "\$1" 2>/dev/null; }
echo
echo "============== DeNOVA dedup consistency + delete-path test =============="
[ -e /dev/pmem0 ] || { echo "pmem MISSING"; dmesg | tail -20; poweroff -f; }
mkdir -p /mnt/nova
if ! mount -t NOVA -o init /dev/pmem0 /mnt/nova; then echo "NOVA mount FAILED"; dmesg | tail -40; poweroff -f; fi
echo "--- write stress.dat: $NBLOCKS blocks, $NDISTINCT distinct patterns ---"
/bin/dedup_stress /mnt/nova/stress.dat write $NBLOCKS $NDISTINCT
sync
/bin/dedup_trigger
sync
echo "stress.dat after dedup: \$(blocks /mnt/nova/stress.dat)"
if /bin/dedup_stress /mnt/nova/stress.dat verify $NBLOCKS $NDISTINCT; then
  echo ">>> CONSISTENCY PASS"
else
  echo ">>> CONSISTENCY FAIL"
fi
echo "=== df before delete ==="; df /mnt/nova
rm -f /mnt/nova/stress.dat; sync
echo "=== df after delete ==="; df /mnt/nova
if dmesg | grep -iE "BUG:|Oops|Call Trace|kernel NULL|general protection|Error!"; then
  echo ">>> DELETE-PATH problem detected above"
else
  echo ">>> delete path clean"
fi
echo "IAA loop count: \$(dmesg | grep -c 'IAA Infinite loop')"
umount /mnt/nova && echo "unmount OK"
echo "============== test done =============="
poweroff -f
IEOF
chmod +x "$ID/init" "$ID/bin/"*

( cd "$ID" && find . | cpio -o -H newc 2>/dev/null | gzip -9 ) > "$WORK/initramfs.cpio.gz"
echo "initramfs -> $WORK/initramfs.cpio.gz ($(du -h "$WORK/initramfs.cpio.gz" | cut -f1))"
