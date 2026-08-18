#!/bin/bash
# run.sh — boot the DeNOVA kernel in QEMU, run the dedup test, capture serial.
# Uses KVM if /dev/kvm is writable, otherwise falls back to TCG (slower, no
# sudo needed). Emulated pmem via memmap=8G!4G -> /dev/pmem0.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEST_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
WORK="${DENOVA_WORK:-$TEST_DIR/work}"
BZ="$WORK/build/arch/x86/boot/bzImage"
INITRD="$WORK/initramfs.cpio.gz"
[ -f "$BZ" ]     || { echo "missing kernel: $BZ (run build_kernel.sh)"; exit 1; }
[ -f "$INITRD" ] || { echo "missing initramfs: $INITRD (run build_initramfs.sh)"; exit 1; }

TS=$(date +%Y%m%d-%H%M%S); OUT="$WORK/results/run-$TS"
mkdir -p "$OUT"; ln -sfn "run-$TS" "$WORK/results/latest"

ACCEL=(-enable-kvm -cpu host)
if [ ! -w /dev/kvm ]; then
  echo "note: /dev/kvm not user-writable -> TCG software emulation (slower)"
  ACCEL=(-cpu max)
fi

echo "=== booting (serial -> $OUT/serial.log) ==="
timeout 1200 qemu-system-x86_64 "${ACCEL[@]}" -smp 4 -m 16G \
  -kernel "$BZ" -initrd "$INITRD" \
  -append 'console=ttyS0 memmap=8G!4G rdinit=/init panic=1 loglevel=7' \
  -nographic -no-reboot \
  -virtfs local,path="$OUT",mount_tag=results,security_model=none,id=results \
  2>&1 | tee "$OUT/serial.log" || true

echo
echo "=== summary ==="
grep -nE "CONSISTENCY (PASS|FAIL)|after dedup|delete path|IAA loop|unmount OK|BUG:|Oops" "$OUT/serial.log" || true
echo "full log: $OUT/serial.log"
