# DeNOVA QEMU test harness

Build the DeNOVA (Linux 5.1) kernel, boot it in QEMU with an emulated
persistent-memory device, mount the NOVA filesystem, and drive the offline
deduplication path to reproduce bugs and verify fixes. Everything here is
scripted so the dedup fixes on this branch can be re-verified later.

## Layout

```
denova-qemu-test/
  scripts/build_kernel.sh      build the kernel out-of-tree (gcc-9)
  scripts/build_initramfs.sh   build a BusyBox initramfs that runs the test
  scripts/run.sh               boot QEMU, run the test, capture serial log
  guest/tools/dedup_trigger.c  fires the custom `dedup` syscall (nr 335)
  guest/tools/dedup_stress.c   writes known patterns + verifies them after dedup
  work/                        build output, initramfs, results  (gitignored)
```

Paths are derived from the script location, so the tree can live anywhere.
Override `DENOVA_SRC` (kernel source, default = repo root), `DENOVA_WORK`
(scratch dir, default = `denova-qemu-test/work`) if needed.

## Host prerequisites

- `gcc-9` (Linux 5.1 predates gcc-10's `-fno-common` default; newer gccs fail)
- `qemu-system-x86_64`, `busybox-static`, `cpio`, `gzip`, `bc`, `flex`, `bison`,
  `libelf-dev`, `libssl-dev`
- KVM optional: if `/dev/kvm` is writable the run uses it, otherwise it falls
  back to TCG software emulation (slower, no sudo needed). For fast/large runs:
  `sudo chmod 666 /dev/kvm` once.

## Usage

```sh
bash scripts/build_kernel.sh        # -> work/build/arch/x86/boot/bzImage
bash scripts/build_initramfs.sh     # -> work/initramfs.cpio.gz
bash scripts/run.sh                 # boots, runs test, prints a summary
```

Test size is tunable at initramfs-build time:

```sh
NBLOCKS=40000 NDISTINCT=128 bash scripts/build_initramfs.sh
```

## What the default test does

1. Mounts NOVA (`-o init`) on the emulated pmem (`/dev/pmem0` from
   `memmap=8G!4G`).
2. Writes `stress.dat` = `NBLOCKS` 4KB blocks cycling through `NDISTINCT`
   distinct contents (so there are many duplicates and many distinct blocks).
3. Runs the offline dedup pass (`syscall 335`).
4. **Consistency check:** reads every block back and compares it to its
   expected pattern. `CONSISTENCY PASS` means dedup preserved all data (it did
   not merge non-identical blocks); the file should collapse to ~`NDISTINCT`
   physical blocks.
5. Deletes the file to exercise the block-free path
   (`nova_dedup_is_duplicate`) and scans dmesg for oops/BUG.

### Reproducing the headline bug (FACT hash collapse)

Write >500 *distinct* blocks and dedup: on the unfixed tree every fingerprint
hashed to FACT slot 0 and the insert loop printed `IAA Infinite loop, bug
exists` hundreds of times, breaking dedup entirely. With the fix that message
count is 0. (Set `NDISTINCT` high, e.g. `NBLOCKS=2000 NDISTINCT=2000`.)

### Exercising reorder

The chain-reorder pass only triggers when a hash bucket's collision chain
exceeds `REORDER_THRESHOLD` (150). Real fingerprints spread across 2^23
buckets, so to exercise it in a test, temporarily shrink the hash (e.g.
`index = fingerprint[0] & 0x7` in `nova_dedup_FACT_insert`) and lower the
threshold; the consistency test then runs with reorder active and must still
report 0 mismatches.

## Notes

- `fs/nova/super.c` has a test-only change (commit "allow mount on raw
  (non-devmap) pmem for QEMU testing"): QEMU `memmap=` pmem comes up in "raw"
  mode without struct-page DAX, so `bdev_dax_supported()` is false even though
  `dax_direct_access()` works. That commit downgrades the hard mount failure
  to a warning. Real fsdax/NVDIMM hardware passes the check normally and does
  not need it.
- Recovery (`nova_dedup_FACT_recovery`) is not wired into the mount path and
  the dedup daemon is triggered manually via syscall 335 — both unchanged from
  upstream DeNOVA.
