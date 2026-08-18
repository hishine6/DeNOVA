#!/bin/bash
# bench_mount.sh — build an initramfs that times FACT format (mount -o init)
# and recovery (clean remount), to measure optimization #3 (O(table) -> O(used)
# recovery via the persistent checkpoint). Daemon-agnostic (it times mount, not
# dedup throughput). Run:  bash scripts/bench_mount.sh && bash scripts/run.sh
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

cat > "$ID/init" <<'IEOF'
#!/bin/busybox sh
export PATH=/bin:/sbin
/bin/busybox --install -s /bin 2>/dev/null
mount -t proc proc /proc; mount -t sysfs sysfs /sys; mount -t devtmpfs devtmpfs /dev 2>/dev/null
now(){ cut -d' ' -f1 /proc/uptime; }
echo
echo "============== DeNOVA mount/recovery BENCHMARK (opt #3) =============="
[ -e /dev/pmem0 ] || { echo "pmem MISSING"; dmesg|tail; poweroff -f; }
mkdir -p /mnt/nova
T0=$(now)
mount -t NOVA -o init /dev/pmem0 /mnt/nova || { echo "init mount FAIL"; dmesg|tail -20; poweroff -f; }
T1=$(now)
awk -v a=$T0 -v b=$T1 'BEGIN{ printf ">>> FORMAT (mount -o init, FACT zero-fill): %.2f s\n", b-a }'
/bin/dedup_stress /mnt/nova/f.dat write 2000 8 >/dev/null 2>&1
sync; /bin/dedup_trigger >/dev/null 2>&1; sync
umount /mnt/nova && echo "clean umount OK"
T2=$(now)
mount -t NOVA /dev/pmem0 /mnt/nova || { echo "remount FAIL"; dmesg|tail -20; poweroff -f; }
T3=$(now)
awk -v a=$T2 -v b=$T3 'BEGIN{ printf ">>> RECOVERY (clean remount): %.2f s\n", b-a }'
dmesg | grep -i "FACT recovery" | tail -1
umount /mnt/nova && echo "final umount OK"
echo "============== mount benchmark done =============="
poweroff -f
IEOF
chmod +x "$ID/init" "$ID/bin/"*
( cd "$ID" && find . | cpio -o -H newc 2>/dev/null | gzip -9 ) > "$WORK/initramfs.cpio.gz"
echo "initramfs -> $WORK/initramfs.cpio.gz ($(du -h "$WORK/initramfs.cpio.gz" | cut -f1))"
