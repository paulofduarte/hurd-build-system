#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Paulo Duarte <paulofernandobd@gmail.com>
# SPDX-License-Identifier: GPL-3.0-or-later
# SCENARIO=hurd-guix - Guix childhurd, booted from an external GRUB ISO
# (option 1) on the default i440fx machine, same as hurd-gentoo.  The old
# q35 requirement was for the in-place overlay approach (booting the disk's
# own gfxterm grub); our external serial-clean ISO + search --fs-uuid boots
# Guix to userland on i440fx, where the disk is IDE (rumpdisk's wd0) - and
# crucially avoids q35's slow ICH9-AHCI probe, where rumpdisk HANGS doing a
# disk IDENTIFY on the boot CD-ROM's ATAPI port.
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
# shellcheck source=lib/common.sh
. "$(dirname "$0")/lib/common.sh"
# shellcheck source=lib/arch-flags.sh
. "$(dirname "$0")/lib/arch-flags.sh"
# shellcheck source=lib/hurd-common.sh
. "$(dirname "$0")/lib/hurd-common.sh"
# shellcheck source=lib/sidekick.sh
. "$(dirname "$0")/lib/sidekick.sh"

scenario_check_target "hurd-guix" "x86_64 i686"
arch_qemu_for_target "$ARCH"
# Default machine (i440fx), like hurd-gentoo: the disk is then IDE (rumpdisk's
# wd0), and the boot CD-ROM is IDE/ATAPI (cd0) - both handled cleanly. The old
# q35 requirement was for the in-place overlay approach (booting the disk's own
# gfxterm grub); with our external serial-clean ISO + search --fs-uuid, i440fx
# boots Guix to userland AND avoids q35's slow ICH9-AHCI probe, where rumpdisk
# hangs doing a disk IDENTIFY on the ATAPI CD-ROM port.
arch_apply_accel_if_requested # appends -accel to QEMU_MACHINE if RUN_ACCEL=1 + arch match

extra_qemu_args=("$@") # capture RUN_ARGS pass-through

case "$ARCH" in
  x86_64)
    url="$HURD_GUIX_X86_64_URL"
    qcow2_name="hurd64-barebones.qcow2"
    ;;
  i686)
    url="$HURD_GUIX_I686_URL"
    qcow2_name="hurd-barebones.qcow2"
    ;;
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

# Build an external GRUB ISO (distro's own kernel for vanilla, else our gnumach)
# that pulls Guix's modules + root (store-hash paths) from the disk via search
# --fs-uuid. The qcow2 is read but never modified (option 1); the overlay is just
# COW boot scratch.
iso="$cache/boot.iso"
if [ "${RUN_VANILLA:-}" = "1" ]; then
  sidekick_distro_iso "$iso" "$qcow2" qcow2
else
  sidekick_distro_iso "$iso" "$qcow2" qcow2 "$GNUMACH_KERNEL"
fi

# NIC: rtl8139, per Guix upstream (their childhurd/qemu docs use exactly
# `--device rtl8139,netdev=net0 --netdev user,id=net0`) - a card Guix's netdde
# has a driver for. QEMU's default e1000 makes netdde hang at attach. `user`
# networking keeps outbound (SLIRP) connectivity. NOTE: Hurd networking wants KVM
# (RUN_ACCEL=1); under TCG netdde stalls regardless of NIC.
print_qemu_hint
exec "$QEMU" -nographic -m "$QEMU_MEM" "${QEMU_MACHINE[@]}" -cpu "$QEMU_CPU" \
  -cdrom "$iso" \
  -drive file="$overlay",format=qcow2 \
  -nic user,model=rtl8139 \
  -boot d \
  -no-reboot \
  "${extra_qemu_args[@]}"
