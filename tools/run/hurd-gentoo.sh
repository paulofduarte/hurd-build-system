#!/usr/bin/env bash
# SCENARIO=hurd-gentoo — Gentoo Hurd userland on our gnumach via
# kernel overlay (see hurd-debian.sh for the architectural notes).
# UNTESTED — Gentoo's kernel path is a guess based on the standard
# Hurd convention; verify and adjust if first boot fails to find it.
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

# Our-kernel path: overlay our gnumach at Gentoo's kernel path.
# Initial guess — adjust if sidekick reports "target kernel missing".
kernel_path="boot/gnumach.gz"

sidekick_overlay_kernel "$overlay" "$GNUMACH_BOOT_IMAGE" "$kernel_path"

print_qemu_hint
exec "$QEMU" -nographic -m "$QEMU_MEM" $QEMU_MACHINE -cpu "$QEMU_CPU" \
  -drive file="$overlay",format=qcow2 \
  "${extra_qemu_args[@]}"
