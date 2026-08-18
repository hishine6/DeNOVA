#!/bin/bash
# build_kernel.sh — build the DeNOVA (Linux 5.1) kernel for QEMU testing.
#
# Linux 5.1 predates gcc-10's -fno-common default, so it must be built with an
# older compiler (gcc-9). Host tools (objtool) also use HOSTCC; RETPOLINE and
# the ORC unwinder both select STACK_VALIDATION which pulls in objtool, whose
# tools/include string.h clashes with glibc-2.38+ strlcpy -- so we disable both
# and use the frame-pointer unwinder to skip objtool entirely.
#
# Out-of-tree build (O=$BUILD) keeps the source tree clean.
# Output: $BUILD/arch/x86/boot/bzImage
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEST_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"                 # denova-qemu-test/
SRC="${DENOVA_SRC:-$(cd "$TEST_DIR/.." && pwd)}"         # DeNOVA repo root
WORK="${DENOVA_WORK:-$TEST_DIR/work}"
BUILD="${DENOVA_BUILD:-$WORK/build}"
CC="${CC:-gcc-9}"
HOSTCC="${HOSTCC:-gcc-9}"
JOBS="${JOBS:-$(nproc)}"
export HOSTCFLAGS="${HOSTCFLAGS:--Wno-redundant-decls -Wno-use-after-free}"
MK=(make -C "$SRC" O="$BUILD" CC="$CC" HOSTCC="$HOSTCC")

echo "=== DeNOVA kernel build (src=$SRC build=$BUILD CC=$CC) ==="
"$CC" --version | head -1
mkdir -p "$BUILD"

if [ ! -f "$BUILD/.config" ] || [ "${RECONFIG:-0}" = "1" ]; then
    echo "=== generate .config (x86_64_defconfig + DeNOVA/pmem/virtio) ==="
    "${MK[@]}" x86_64_defconfig
    cfg="$SRC/scripts/config --file $BUILD/.config"
    $cfg -e FS_DAX -e DAX -e DEV_DAX
    $cfg -e LIBNVDIMM -e BLK_DEV_PMEM -e BTT -e NVDIMM_PFN -e NVDIMM_DAX
    $cfg -e X86_PMEM_LEGACY                       # memmap= -> /dev/pmem0
    $cfg -e NOVA_FS
    $cfg -e CRYPTO -e CRYPTO_HASH -e CRYPTO_SHA1 -e CRYPTO_MANAGER
    $cfg -e CRC32 -e CRC32C -e LIBCRC32C -e CRC16
    $cfg -e VIRTIO -e VIRTIO_PCI -e VIRTIO_BLK -e VIRTIO_NET -e VIRTIO_MMIO
    $cfg -e NET_9P -e NET_9P_VIRTIO -e 9P_FS
    $cfg -e EXT4_FS
    $cfg -e BLK_DEV_INITRD -e RD_GZIP -e DEVTMPFS -e DEVTMPFS_MOUNT
    $cfg -e SERIAL_8250 -e SERIAL_8250_CONSOLE -e TMPFS -e PROC_FS -e SYSFS
    # skip objtool (see header): drop ORC + RETPOLINE, use frame pointer
    $cfg -d UNWINDER_ORC -e UNWINDER_FRAME_POINTER -e FRAME_POINTER
    $cfg -d RETPOLINE -d STACK_VALIDATION
    $cfg -d DEBUG_INFO -d MODULE_SIG
    $cfg --set-str SYSTEM_TRUSTED_KEYS ""
    $cfg --set-str SYSTEM_REVOCATION_KEYS "" 2>/dev/null || true
    "${MK[@]}" olddefconfig
fi

echo "=== build bzImage ==="
"${MK[@]}" -j"$JOBS" bzImage
echo "=== DONE: $BUILD/arch/x86/boot/bzImage ==="
ls -la "$BUILD/arch/x86/boot/bzImage"
