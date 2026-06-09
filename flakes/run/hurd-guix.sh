#!/usr/bin/env bash
# SCENARIO=hurd-guix - Guix childhurd, kernel-overlay approach.
# Needs -M q35 to boot (Guix qcow2 won't come up on i440fx).
#
# Kernel path inside the disk is a Guix store path like
# /gnu/store/<hash>-gnumach-<ver>/boot/gnumach - different on every
# upstream build.  The sidekick auto-discovers it from the disk's
# grub.cfg multiboot line, so no host-side path guessing.
#
# URL uses Cuirass's /search/latest/image endpoint (auto-resolves to
# the latest successful build with a fetchable artefact; never goes
# stale).  ARCH=x86_64 usually returns upstream 500 because Guix CI
# aggressively garbage-collects 64-bit qcow2 artefacts; the GC
# explanation is surfaced inline via $guix_x86_64_hint when that
# path fails.  ARCH=i686 is reliably available.
set -euo pipefail
. "$(dirname "$0")/lib/common.sh"
. "$(dirname "$0")/lib/arch-flags.sh"
. "$(dirname "$0")/lib/hurd-common.sh"
. "$(dirname "$0")/lib/sidekick.sh"

scenario_check_target "hurd-guix" "x86_64 i686"
arch_qemu_for_target "$ARCH"
QEMU_MACHINE="-M q35"            # Guix qcow2 hangs on i440fx - even with our
                                  # minimal regenerated grub.cfg (verified
                                  # 2026-05-25 on Linux).  q35 is required;
                                  # the cost is gnumach's in-kernel SATA driver
                                  # slowly probing q35's 6 ICH9-AHCI ports on
                                  # every boot.  Accept the slow probe as the
                                  # price of a bootable Guix.
arch_apply_accel_if_requested    # appends -accel to QEMU_MACHINE if RUN_ACCEL=1 + arch match

extra_qemu_args=("$@")           # capture RUN_ARGS pass-through

case "$ARCH" in
  x86_64) url="$HURD_GUIX_X86_64_URL"; qcow2_name="hurd64-barebones.qcow2" ;;
  i686)   url="$HURD_GUIX_I686_URL";   qcow2_name="hurd-barebones.qcow2"   ;;
esac

# GC-explanation hint only for x86_64 (i686 rarely fails).
guix_x86_64_hint="Guix CI x86_64 hurd64-barebones.qcow2 artefacts are
aggressively GC'd upstream.  This is upstream's fail-fast behaviour,
not a harness bug.

Options:
  - Re-try later (Guix CI rebuilds 64-bit Hurd periodically)
  - Use the 32-bit variant instead:
        make run ARCH=i686 SCENARIO=hurd-guix"
[ "$ARCH" = x86_64 ] && hint="$guix_x86_64_hint" || hint=""

cache="$(hurd_cache_dir guix "$ARCH")"
qcow2="$cache/$qcow2_name"
hurd_fetch_via_resolve "$url" "$qcow2" "$cache/last-target" "$hint"

overlay="$(hurd_overlay_path "$cache")" || exit 1
hurd_make_overlay "$qcow2" "$overlay" qcow2

# Vanilla path: regenerate grub.cfg via sidekick so the qcow2's
# internal GRUB renders on serial, then boot Guix's bundled kernel.
if [ "${RUN_VANILLA:-}" = "1" ]; then
  sidekick_prepare_grub "$overlay"
fi
hurd_maybe_vanilla_exec "$QEMU" -nographic -m "$QEMU_MEM" $QEMU_MACHINE -cpu "$QEMU_CPU" \
  -drive file="$overlay",format=qcow2 \
  -no-reboot \
  "${extra_qemu_args[@]}"

# Our-kernel path: overlay our gnumach at Guix's store-hash kernel
# path (auto-discovered by sidekick from the disk's grub.cfg).
sidekick_overlay_kernel "$overlay" "$GNUMACH_KERNEL"

print_qemu_hint
exec "$QEMU" -nographic -m "$QEMU_MEM" $QEMU_MACHINE -cpu "$QEMU_CPU" \
  -drive file="$overlay",format=qcow2 \
  -no-reboot \
  "${extra_qemu_args[@]}"
