#!/bin/bash
# build_initramfs.sh — HARSH end-to-end DeNOVA dedup test: many files, heavy
# read/write + rewrite churn, repeated unmount/remount (exercises FACT
# recovery), automatic (background daemon) dedup, and delete churn (exercises
# nova_dedup_is_duplicate) -- all with per-block content verification. Prints
# ">>> HARSH TEST PASS" iff every check passes with no oops and no
# "IAA Infinite loop". Needs the busybox-static package on the host.
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

cat > "$ID/init" <<'IEOF'
#!/bin/busybox sh
export PATH=/bin:/sbin
/bin/busybox --install -s /bin 2>/dev/null
mount -t proc proc /proc; mount -t sysfs sysfs /sys; mount -t devtmpfs devtmpfs /dev 2>/dev/null
blk() { stat -c '%b' "$1" 2>/dev/null; }
nd()  { echo $(( $1 * 8 )); }
FAIL=0; NF=4; NB=2500
S() { /bin/dedup_stress "$@"; }
echo
echo "================= DeNOVA HARSH dedup test ================="
[ -e /dev/pmem0 ] || { echo "pmem MISSING"; dmesg|tail; poweroff -f; }
mkdir -p /mnt/nova
mount -t NOVA -o init /dev/pmem0 /mnt/nova || { echo "init mount FAIL"; dmesg|tail -30; poweroff -f; }

echo "--- Phase 1: write $NF files + manual dedup + verify ---"
i=1; while [ $i -le $NF ]; do S /mnt/nova/f$i.dat write $NB $(nd $i); i=$((i+1)); done
sync; /bin/dedup_trigger; sync
i=1; while [ $i -le $NF ]; do S /mnt/nova/f$i.dat verify $NB $(nd $i) || { echo "P1 f$i BAD"; FAIL=1; }; i=$((i+1)); done

echo "--- Phase 2: rewrite churn (heavy R/W) + dedup + verify ---"
i=1; while [ $i -le $NF ]; do S /mnt/nova/f$i.dat write $NB $(nd $i); i=$((i+1)); done
sync; /bin/dedup_trigger; sync
i=1; while [ $i -le $NF ]; do S /mnt/nova/f$i.dat verify $NB $(nd $i) || { echo "P2 f$i BAD"; FAIL=1; }; i=$((i+1)); done

echo "--- Phase 3: unmount/remount x2 + recovery + AUTO(daemon) dedup ---"
c=1; while [ $c -le 2 ]; do
  umount /mnt/nova && echo "umount c$c OK"
  mount -t NOVA /dev/pmem0 /mnt/nova || { echo "REMOUNT c$c FAIL"; dmesg|tail -20; FAIL=1; break; }
  echo "remount c$c OK"; dmesg | grep -i "FACT recovery" | tail -1
  i=1; while [ $i -le $NF ]; do S /mnt/nova/f$i.dat verify $NB $(nd $i) || { echo "c$c f$i CORRUPT"; FAIL=1; }; i=$((i+1)); done
  S /mnt/nova/a$c.dat write $NB 16          # no trigger: the daemon dedups it
  sync; sleep 12; sync
  AB=$(blk /mnt/nova/a$c.dat)
  if [ "$AB" -lt 2000 ]; then echo "auto-dedup c$c OK ($AB sectors)"; else echo "auto-dedup c$c FAIL ($AB)"; FAIL=1; fi
  S /mnt/nova/a$c.dat verify $NB 16 || { echo "a$c CORRUPT"; FAIL=1; }
  c=$((c+1))
done

echo "--- Phase 4: delete churn (is_duplicate block-free) ---"
rm -f /mnt/nova/f1.dat /mnt/nova/f3.dat /mnt/nova/a1.dat; sync; echo "deleted 3 files"

echo "--- Phase 5: final remount + verify survivors ---"
umount /mnt/nova && echo "final umount OK"
mount -t NOVA /dev/pmem0 /mnt/nova || { echo "final remount FAIL"; FAIL=1; }
for i in 2 4; do S /mnt/nova/f$i.dat verify $NB $(nd $i) || { echo "final f$i CORRUPT"; FAIL=1; }; done
S /mnt/nova/a2.dat verify $NB 16 || { echo "final a2 CORRUPT"; FAIL=1; }
umount /mnt/nova && echo "final umount2 OK"

OOPS=$(dmesg | grep -icE "BUG:|Oops|Call Trace|general protection|kernel NULL")
IAA=$(dmesg | grep -c "IAA Infinite")
echo "================= RESULT: FAIL=$FAIL oops=$OOPS iaa=$IAA ================="
if [ "$FAIL" = 0 ] && [ "$OOPS" = 0 ] && [ "$IAA" = 0 ]; then echo ">>> HARSH TEST PASS"; else echo ">>> HARSH TEST FAIL"; fi
poweroff -f
IEOF
chmod +x "$ID/init" "$ID/bin/"*
( cd "$ID" && find . | cpio -o -H newc 2>/dev/null | gzip -9 ) > "$WORK/initramfs.cpio.gz"
echo "initramfs -> $WORK/initramfs.cpio.gz ($(du -h "$WORK/initramfs.cpio.gz" | cut -f1))"
