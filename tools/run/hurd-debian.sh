#!/usr/bin/env bash
# SCENARIO=hurd-debian — boot Debian Hurd userland on our gnumach.
# Approach: overlay our kernel onto the distro's bundled kernel path
# inside the per-run qcow2 overlay, then let the disk's own GRUB
# config handle the multiboot + module + cmdline work.  Reuses
# Debian's verified boot recipe verbatim — no per-arch module-chain
# reverse-engineering on our side.
set -euo pipefail
. "$(dirname "$0")/lib/common.sh"
. "$(dirname "$0")/lib/arch-flags.sh"
. "$(dirname "$0")/lib/hurd-common.sh"
. "$(dirname "$0")/lib/sidekick.sh"

scenario_check_target "hurd-debian" "x86_64 i686"
arch_qemu_for_target "$TARGET"
arch_apply_accel_if_requested

extra_qemu_args=("$@")   # RUN_ARGS pass-through

case "$TARGET" in
  x86_64) url="$HURD_DEBIAN_X86_64_URL" ;;
  i686)   url="$HURD_DEBIAN_I686_URL" ;;
esac

cache="$(hurd_cache_dir debian "$TARGET")"
hurd_fetch_once "$url" "$cache/debian-hurd.img.tar.gz"

# Tarball contains a dated .img; discover the real name (see D12).
img_name=$(tar -tzf "$cache/debian-hurd.img.tar.gz" | grep -E '\.img$' | head -1)
[ -n "$img_name" ] || die "debian-hurd.img.tar.gz contains no *.img file (layout changed?)"
[ -f "$cache/$img_name" ] || tar -xzf "$cache/debian-hurd.img.tar.gz" -C "$cache"

overlay="$cache/overlay.qcow2"
hurd_make_overlay "$cache/$img_name" "$overlay" raw

# Vanilla path: disk's GRUB boots the distro's bundled kernel as-is.
# Still need the sidekick grub.cfg pass so GRUB renders on serial
# under -nographic (no kernel swap; we just clean up the cfg).
if [ "${RUN_VANILLA:-}" = "1" ]; then
  sidekick_prepare_grub "$overlay"
fi
# $QEMU_MACHINE expanded unquoted so RUN_ACCEL=1's -accel propagates.
hurd_maybe_vanilla_exec "$QEMU" -nographic -m "$QEMU_MEM" $QEMU_MACHINE -cpu "$QEMU_CPU" \
  -drive file="$overlay",format=qcow2,if=ide \
  -no-reboot \
  "${extra_qemu_args[@]}"

# Our-kernel path: replace the distro's kernel inside the overlay
# with ours, then boot the disk normally — Debian's GRUB picks up
# our binary at its known path and feeds it to multiboot.  Sidekick
# auto-discovers the target path from the disk's grub.cfg (works
# uniformly across i686 / x86_64 / Guix store-hash paths).
sidekick_overlay_kernel "$overlay" "$GNUMACH_KERNEL"

print_qemu_hint
# -no-reboot halts qemu on guest reboot instead of cycling — lets us
# see what actually happened (panic? init reboot?) instead of GRUB
# popping back up with stale state.  If you genuinely want reboot
# loops (e.g., a kernel-stability test), pass RUN_ARGS="-no-shutdown".
exec "$QEMU" -nographic -m "$QEMU_MEM" $QEMU_MACHINE -cpu "$QEMU_CPU" \
  -drive file="$overlay",format=qcow2,if=ide \
  -no-reboot \
  "${extra_qemu_args[@]}"
