# SPDX-FileCopyrightText: 2026 Paulo Duarte <paulofernandobd@gmail.com>
# SPDX-License-Identifier: GPL-3.0-or-later
# shellcheck shell=bash
# Host-side orchestrator for the sidekick helper VM.
#
# Reads $SIDEKICK_KERNEL, $SIDEKICK_INITRD from env (exported by the parent
# Makefile / the nix-run app).  Drives the generic Debian sidekick via the
# dispatcher (sidekick-dispatch.sh): each op stages a small run.sh + its
# inputs into a work dir (which is the VM's 9p /shared) and runs it once
# via sk_oneshot.  The op logic lives in lib/sidekick-{overlay,mkiso}.sh -
# moved out of the VM image so the VM stays a generic dispatcher.  See
# .claude/docs/build/SIDEKICK-DISPATCHER.md.
#
# Operations (unchanged signatures):
#   sidekick_overlay_kernel <overlay> <kernel>  overlay our kernel into a
#                            qcow2 + regenerate the disk's grub.cfg
#   sidekick_prepare_grub   <overlay>           regenerate grub.cfg only
#   sidekick_make_iso       <out_iso> <staging> <grub_cfg> [cache_key]
#                            wrap kernel+modules in a GRUB-bootable ISO

# The dispatch lib: nix-run app exports $SIDEKICK_DISPATCH (a store path);
# in-tree `make run` falls back to the sibling flakes/sidekick copy.
: "${SIDEKICK_DISPATCH:=$(dirname "$0")/../sidekick/sidekick-dispatch.sh}"
# shellcheck source=../../sidekick/sidekick-dispatch.sh
. "$SIDEKICK_DISPATCH"

# Directory holding the op run-scripts (alongside this lib).
_SK_OPLIB="$(dirname "$0")/lib"

_sidekick_check_artefacts() {
  [ -f "${SIDEKICK_KERNEL:-}" ] || die "sidekick kernel missing: ${SIDEKICK_KERNEL:-<unset>}
  -> build it: 'make sidekick' (normally automatic for hurd-* scenarios)"
  [ -f "${SIDEKICK_INITRD:-}" ] || die "sidekick initramfs missing: ${SIDEKICK_INITRD:-<unset>}
  -> build it: 'make sidekick'"
}

# _sidekick_op <work> <op-script> [extra qemu args...]
#   Stage <op-script> as the work dir's run.sh (the work dir is the VM's
#   9p /shared) and run it once.  Dumps the VM log on failure.
_sidekick_op() {
  local work="$1" op="$2"
  shift 2
  cp "$op" "$work/run.sh"
  local rc
  rc=$(sk_oneshot "$work" "$@")
  if [ "${rc:-1}" -ne 0 ]; then
    echo "sidekick: op $(basename "$op") failed (rc=$rc)" >&2
    [ -f "$work/run.out" ] && {
      echo "--- run.out ---" >&2
      cat "$work/run.out" >&2
    }
    [ -f "$work/.qemu.log" ] && {
      echo "--- qemu.log (tail) ---" >&2
      tail -20 "$work/.qemu.log" >&2
    }
  fi
  return "${rc:-1}"
}

# sidekick_overlay_kernel <overlay> <kernel>
#   Overlay <kernel> at the disk's grub-discovered kernel path + regenerate
#   grub.cfg.  Idempotent on the per-overlay stamp.
sidekick_overlay_kernel() {
  local overlay="$1" kernel="$2"
  local stamp="$overlay.kernel-stamp"
  if [ -f "$stamp" ] && [ ! "$kernel" -nt "$stamp" ] && [ ! "$overlay" -nt "$stamp" ]; then
    return 0
  fi
  _sidekick_check_artefacts
  local work
  work="$(dirname "$overlay")/sidekick-work"
  rm -rf "$work"
  mkdir -p "$work"
  cp -L "$kernel" "$work/kernel.bin"
  echo "sidekick: overlaying kernel into $(basename "$overlay") ..." >&2
  _sidekick_op "$work" "$_SK_OPLIB/sidekick-overlay.sh" -drive "file=$overlay,if=virtio" || {
    rm -rf "$work"
    return 1
  }
  rm -rf "$work"
  touch "$stamp"
}

# sidekick_prepare_grub <overlay>
#   Same op without a kernel (grub.cfg regen only - the overlay script
#   skips the kernel write when /shared/kernel.bin is absent).
sidekick_prepare_grub() {
  local overlay="$1"
  local stamp="$overlay.grub-stamp"
  if [ -f "$stamp" ] && [ ! "$overlay" -nt "$stamp" ]; then return 0; fi
  _sidekick_check_artefacts
  local work
  work="$(dirname "$overlay")/sidekick-work"
  rm -rf "$work"
  mkdir -p "$work"
  echo "sidekick: regenerating grub.cfg in $(basename "$overlay") for serial boot ..." >&2
  _sidekick_op "$work" "$_SK_OPLIB/sidekick-overlay.sh" -drive "file=$overlay,if=virtio" || {
    rm -rf "$work"
    return 1
  }
  rm -rf "$work"
  touch "$stamp"
}

# sidekick_make_iso <out_iso> <staging_dir> <grub_cfg_text> [cache_key]
#   Wrap <staging_dir> + <grub_cfg_text> in a GRUB-bootable ISO via
#   grub-mkrescue in the VM.  Content-addressed cache on (cache_key, cfg).
sidekick_make_iso() {
  local out_iso="$1" staging="$2" grub_cfg="$3" cache_key="${4:-}"
  local work
  work="$(dirname "$out_iso")/iso-build"
  local stamp="$out_iso.stamp"
  local cache_hash
  cache_hash=$(printf '%s\n%s' "$cache_key" "$grub_cfg" | sha256_stdin)
  if [ -f "$out_iso" ] && [ -f "$stamp" ] && [ "$(cat "$stamp" 2>/dev/null)" = "$cache_hash" ]; then
    return 0
  fi
  _sidekick_check_artefacts
  echo "sidekick: assembling GRUB ISO from $(basename "$staging") ..." >&2
  rm -rf "$work"
  mkdir -p "$work/iso-staging"
  cp -a "$staging/." "$work/iso-staging/"
  printf '%s\n' "$grub_cfg" >"$work/iso-grub.cfg"
  _sidekick_op "$work" "$_SK_OPLIB/sidekick-mkiso.sh" || {
    rm -rf "$work"
    return 1
  }
  [ -s "$work/out.iso" ] || die "sidekick mkiso failed: $work/out.iso missing/empty"
  mv "$work/out.iso" "$out_iso"
  rm -rf "$work"
  printf '%s' "$cache_hash" >"$stamp"
}
