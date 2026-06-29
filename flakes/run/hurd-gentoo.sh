#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Paulo Duarte <paulofernandobd@gmail.com>
# SPDX-License-Identifier: GPL-3.0-or-later
# SCENARIO=hurd-gentoo - Gentoo Hurd userland on our gnumach via
# kernel overlay (see hurd-debian.sh for the architectural notes).
# Kernel path /boot/gnumach.gz verified against the cached
# hurd-x86_64-preview.qcow2 (orb-mounted ext2, 2026-05-25).  The
# distro's grub.cfg references modules via `configfile entry_hurd.cfg`;
# the sidekick's grub.cfg regenerator flattens that indirection
# before extracting the boot recipe.
#
# Known image issue (ARCH=x86_64 only - i686 boots cleanly):
# the amd64 preview image's openrc hangs in the boot runlevel after
# the `servers` service errors out.  Root cause: rumpdisk's bundled
# NetBSD rump kernel probes the entire PCI bus and tries to attach
# the e1000 NIC (wm0), which fails on rumpdisk's tight memory budget;
# openrc's network scripts then loop on siocgifflags forever.  Image
# bug, not a harness bug - same userland hits the same wall under
# both inject and vanilla, and Gentoo's own wiki flags amd64 as
# "less stable so far than x86" (wiki.gentoo.org/wiki/Project:Hurd).
set -euo pipefail
# shellcheck source=lib/common.sh
. "$(dirname "$0")/lib/common.sh"
# shellcheck source=lib/arch-flags.sh
. "$(dirname "$0")/lib/arch-flags.sh"
# shellcheck source=lib/hurd-common.sh
. "$(dirname "$0")/lib/hurd-common.sh"
# shellcheck source=lib/sidekick.sh
. "$(dirname "$0")/lib/sidekick.sh"

scenario_check_target "hurd-gentoo" "x86_64 i686"
arch_qemu_for_target "$ARCH"
arch_apply_accel_if_requested

extra_qemu_args=("$@")

case "$ARCH" in
  x86_64) url="$HURD_GENTOO_X86_64_URL" ;;
  i686) url="$HURD_GENTOO_I686_URL" ;;
esac

cache="$(hurd_cache_dir gentoo "$ARCH")"
qcow2="$cache/$(basename "$url")"
hurd_fetch_once_verified "$url" "$qcow2" "$url.sha512"

overlay="$(hurd_overlay_path "$cache")" || exit 1
hurd_make_overlay "$qcow2" "$overlay" qcow2

# Build an external GRUB ISO (distro's own kernel for vanilla, else our gnumach)
# that pulls Gentoo's modules + root from the disk via search --fs-uuid. The qcow2
# is read but never modified (option 1); the overlay is just COW boot scratch.
iso="$cache/boot.iso"
if [ "${RUN_VANILLA:-}" = "1" ]; then
  sidekick_distro_iso "$iso" "$qcow2" qcow2
else
  sidekick_distro_iso "$iso" "$qcow2" qcow2 "$GNUMACH_KERNEL"
fi

print_qemu_hint
exec "$QEMU" -nographic -m "$QEMU_MEM" "${QEMU_MACHINE[@]}" -cpu "$QEMU_CPU" \
  -cdrom "$iso" \
  -drive file="$overlay",format=qcow2 \
  -boot d \
  -no-reboot \
  "${extra_qemu_args[@]}"
