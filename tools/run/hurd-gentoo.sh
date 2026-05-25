#!/usr/bin/env bash
# SCENARIO=hurd-gentoo — Gentoo Hurd userland on our gnumach via
# kernel overlay (see hurd-debian.sh for the architectural notes).
# Kernel path /boot/gnumach.gz verified against the cached
# hurd-x86_64-preview.qcow2 (orb-mounted ext2, 2026-05-25).  The
# distro's grub.cfg references modules via `configfile entry_hurd.cfg`;
# the sidekick's grub.cfg regenerator flattens that indirection
# before extracting the boot recipe.
#
# Known image issue (TARGET=x86_64 only — i686 boots cleanly):
# the amd64 preview image's openrc hangs in the boot runlevel after
# the `servers` service errors out.  Root cause: rumpdisk's bundled
# NetBSD rump kernel probes the entire PCI bus and tries to attach
# the e1000 NIC (wm0), which fails on rumpdisk's tight memory budget;
# openrc's network scripts then loop on siocgifflags forever.  Image
# bug, not a harness bug — same userland hits the same wall under
# both inject and vanilla, and Gentoo's own wiki flags amd64 as
# "less stable so far than x86" (wiki.gentoo.org/wiki/Project:Hurd).
set -euo pipefail
. "$(dirname "$0")/lib/common.sh"
. "$(dirname "$0")/lib/arch-flags.sh"
. "$(dirname "$0")/lib/hurd-common.sh"
. "$(dirname "$0")/lib/sidekick.sh"

scenario_check_target "hurd-gentoo" "x86_64 i686"
arch_qemu_for_target "$TARGET"
arch_apply_accel_if_requested

extra_qemu_args=("$@")

case "$TARGET" in
  x86_64) url="$HURD_GENTOO_X86_64_URL" ;;
  i686)   url="$HURD_GENTOO_I686_URL" ;;
esac

cache="$(hurd_cache_dir gentoo "$TARGET")"
qcow2="$cache/$(basename "$url")"
hurd_fetch_once_verified "$url" "$qcow2" "$url.sha512"

overlay="$cache/overlay.qcow2"
hurd_make_overlay "$qcow2" "$overlay" qcow2

# Vanilla path: qcow2's internal GRUB boots Gentoo's bundled kernel.
# Regenerate grub.cfg via sidekick first so GRUB renders on serial.
if [ "${RUN_VANILLA:-}" = "1" ]; then
  sidekick_prepare_grub "$overlay"
fi
hurd_maybe_vanilla_exec "$QEMU" -nographic -m "$QEMU_MEM" $QEMU_MACHINE -cpu "$QEMU_CPU" \
  -drive file="$overlay",format=qcow2 \
  -no-reboot \
  "${extra_qemu_args[@]}"

# Our-kernel path: overlay our gnumach at Gentoo's kernel path,
# auto-discovered by sidekick from the disk's grub.cfg multiboot
# line.
sidekick_overlay_kernel "$overlay" "$GNUMACH_BOOT_IMAGE"

print_qemu_hint
exec "$QEMU" -nographic -m "$QEMU_MEM" $QEMU_MACHINE -cpu "$QEMU_CPU" \
  -drive file="$overlay",format=qcow2 \
  -no-reboot \
  "${extra_qemu_args[@]}"
