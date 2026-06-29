#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Paulo Duarte <paulofernandobd@gmail.com>
# SPDX-License-Identifier: GPL-3.0-or-later
# SCENARIO=hurd-debian - boot Debian Hurd userland on our gnumach.
# Approach (option 1): build an external GRUB ISO that loads our gnumach and
# reuses Debian's own multiboot/module recipe + root (read from the disk's
# grub.cfg, pulled at boot via search --fs-uuid). The distro image is never
# modified; we just boot it (as a COW overlay) alongside the ISO. See
# lib/sidekick.sh.
set -euo pipefail
# shellcheck source=lib/common.sh
. "$(dirname "$0")/lib/common.sh"
# shellcheck source=lib/arch-flags.sh
. "$(dirname "$0")/lib/arch-flags.sh"
# shellcheck source=lib/hurd-common.sh
. "$(dirname "$0")/lib/hurd-common.sh"
# shellcheck source=lib/sidekick.sh
. "$(dirname "$0")/lib/sidekick.sh"

scenario_check_target "hurd-debian" "x86_64 i686"
arch_qemu_for_target "$ARCH"
arch_apply_accel_if_requested

extra_qemu_args=("$@") # RUN_ARGS pass-through

case "$ARCH" in
  x86_64) url="$HURD_DEBIAN_X86_64_URL" ;;
  i686) url="$HURD_DEBIAN_I686_URL" ;;
esac

cache="$(hurd_cache_dir debian "$ARCH")"
hurd_fetch_once "$url" "$cache/debian-hurd.img.tar.gz"

# Tarball contains a dated .img; discover the real name (see D12).
img_name=$(tar -tzf "$cache/debian-hurd.img.tar.gz" | grep -E '\.img$' | head -1)
[ -n "$img_name" ] || die "debian-hurd.img.tar.gz contains no *.img file (layout changed?)"
[ -f "$cache/$img_name" ] || tar -xzf "$cache/debian-hurd.img.tar.gz" -C "$cache"

overlay="$(hurd_overlay_path "$cache")" || exit 1
hurd_make_overlay "$cache/$img_name" "$overlay" raw

# Build an external GRUB ISO that boots either the distro's own kernel (vanilla)
# or OUR gnumach, pulling the Hurd modules + root from the disk via search
# --fs-uuid.  The distro image is read but NEVER modified (option 1); the
# writable per-run overlay is just qemu's COW scratch so the base stays pristine.
iso="$cache/boot.iso"
if [ "${RUN_VANILLA:-}" = "1" ]; then
  sidekick_distro_iso "$iso" "$cache/$img_name" raw
else
  sidekick_distro_iso "$iso" "$cache/$img_name" raw "$GNUMACH_KERNEL"
fi

print_qemu_hint
# Boot the ISO (-boot d), with the overlay attached as the Hurd disk.
# $QEMU_MACHINE is an array so RUN_ACCEL=1's -accel flags propagate as separate
# argv words.  -no-reboot halts qemu on guest reboot instead of cycling - lets us
# see what actually happened (panic? init reboot?) instead of GRUB re-popping.
exec "$QEMU" -nographic -m "$QEMU_MEM" "${QEMU_MACHINE[@]}" -cpu "$QEMU_CPU" \
  -cdrom "$iso" \
  -drive file="$overlay",format=qcow2,if=ide \
  -boot d \
  -no-reboot \
  "${extra_qemu_args[@]}"
