# Host-side orchestrator for the sidekick helper VM.
#
# Reads $SIDEKICK_KERNEL, $SIDEKICK_INITRD from env (exported by the
# parent Makefile's `run` recipe).
#
# Three operations exposed:
#   sidekick_overlay_kernel  overlay our kernel into a qcow2 +
#                             regenerate the disk's grub.cfg
#                             (inject mode — every Hurd scenario)
#   sidekick_prepare_grub    regenerate the disk's grub.cfg only,
#                             no kernel overlay (vanilla mode —
#                             every Hurd scenario)
#   sidekick_make_iso        wrap kernel + modules in a GRUB-bootable
#                             ISO (used by boot scenario on x86_64
#                             where qemu's -kernel rejects 64-bit ELFs)

# _sidekick_check_artefacts
#   Internal: die early with an actionable error if the kernel/initramfs
#   aren't built yet.  The parent Makefile normally lists `sidekick` as
#   a prereq for the relevant scenarios so they exist by the time we
#   get here, but the check protects against direct script invocation.
_sidekick_check_artefacts() {
  [ -f "${SIDEKICK_KERNEL:-}" ] || die "sidekick kernel missing: ${SIDEKICK_KERNEL:-<unset>}
  → build it: 'make sidekick' (normally automatic for hurd-* scenarios)"
  [ -f "${SIDEKICK_INITRD:-}" ] || die "sidekick initramfs missing: ${SIDEKICK_INITRD:-<unset>}
  → build it: 'make sidekick'"
}

# _sidekick_run <append_extra> <shared_dir> [extra_qemu_args...]
#   Internal: launch the sidekick VM with the standard plumbing
#   (9p share, no-reboot, 256 MB).  qemu-system-x86_64 is hardcoded —
#   the helper VM is always x86_64 Linux regardless of host arch (see
#   D13 in the design doc).
#
#   All qemu output (SeaBIOS, iPXE, Alpine kernel boot, /init script)
#   is captured to a log under $shared/.  Only dumped to the user's
#   terminal if qemu exits non-zero — keeps the visible flow focused
#   on the actual Hurd boot, not the sidekick's prep work.
_sidekick_run() {
  local append_extra="$1" shared="$2"
  shift 2
  local log="$shared/.sidekick-qemu.log"
  qemu-system-x86_64 -nographic -m 256 -no-reboot \
    -kernel "$SIDEKICK_KERNEL" \
    -initrd "$SIDEKICK_INITRD" \
    -append "console=ttyS0 quiet loglevel=0 $append_extra" \
    -virtfs "local,path=$shared,mount_tag=shared,security_model=mapped-xattr,id=shared" \
    "$@" > "$log" 2>&1
  local rc=$?
  if [ $rc -ne 0 ]; then
    echo "sidekick: qemu exited $rc — full log:" >&2
    cat "$log" >&2
  fi
  return $rc
}

# sidekick_overlay_kernel <overlay> <kernel>
#   Boot the sidekick with the overlay attached read-write; replace
#   the kernel binary inside the overlay's ext fs with <kernel>'s
#   bytes, then regenerate /boot/grub/grub.cfg with our serial-clean
#   recipe.  The target kernel path is auto-discovered from the
#   disk's existing grub.cfg multiboot line — caller doesn't need
#   to know per-distro paths.  Gzipped iff the discovered path ends
#   in .gz (matching what GRUB expects to load).
#
#   Idempotent — re-runs only when <kernel> or <overlay> is newer
#   than the per-overlay stamp.  Note: a fresh overlay (the default,
#   per RUN_KEEP_OVERLAY) always triggers a re-overlay since the
#   stamp is per-overlay.
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

  echo "sidekick: overlaying kernel into $(basename "$overlay") …" >&2
  _sidekick_run "SIDEKICK_OP=overlay-kernel" "$work" \
    -drive "file=$overlay,if=virtio"

  rm -rf "$work"
  touch "$stamp"
}

# sidekick_prepare_grub <overlay>
#   Vanilla-mode helper: same sidekick op as overlay-kernel, but
#   without writing a kernel.  Just regenerates the disk's
#   /boot/grub/grub.cfg with our serial + timeout=0 + colour
#   overrides so the distro's bundled kernel boots cleanly under
#   -nographic.  Idempotent on overlay mtime.
sidekick_prepare_grub() {
  local overlay="$1"
  local stamp="$overlay.grub-stamp"

  if [ -f "$stamp" ] && [ ! "$overlay" -nt "$stamp" ]; then
    return 0
  fi

  _sidekick_check_artefacts

  local work
  work="$(dirname "$overlay")/sidekick-work"
  rm -rf "$work"
  mkdir -p "$work"
  # No kernel.bin / target file → /init skips the kernel-overlay step
  # but still regenerates grub.cfg.

  echo "sidekick: regenerating grub.cfg in $(basename "$overlay") for serial boot …" >&2
  _sidekick_run "SIDEKICK_OP=overlay-kernel" "$work" \
    -drive "file=$overlay,if=virtio"

  rm -rf "$work"
  touch "$stamp"
}

# sidekick_make_iso <out_iso> <staging_dir> <grub_cfg_text>
#   Runs the helper VM with SIDEKICK_OP=mkiso to wrap <staging_dir>
#   (kernel + multiboot modules + whatever else the grub.cfg
#   references) in a GRUB-bootable ISO.  Used for x86_64 inject mode
#   where qemu's -kernel can't load the 64-bit gnumach directly.
#
#   <grub_cfg_text> is written verbatim as /boot/grub/grub.cfg inside
#   the ISO.  Caller composes the multiboot+module commands; paths in
#   the cfg are relative to the ISO root (which mirrors staging_dir).
#
#   Idempotent — re-runs only when the staging dir or grub.cfg differ
#   from what produced the existing ISO.
sidekick_make_iso() {
  local out_iso="$1" staging="$2" grub_cfg="$3"
  local work="$(dirname "$out_iso")/iso-build"
  local stamp="$out_iso.stamp"

  # Cache check: invalidate if staging mtime or grub_cfg hash changed
  local cfg_hash
  cfg_hash=$(printf '%s' "$grub_cfg" | sha256_stdin)
  if [ -f "$out_iso" ] && [ -f "$stamp" ] \
      && [ "$stamp" -nt "$staging" ] \
      && [ "$(cat "$stamp" 2>/dev/null)" = "$cfg_hash" ]; then
    return 0
  fi

  _sidekick_check_artefacts

  echo "sidekick: assembling GRUB ISO from $(basename "$staging") …" >&2

  # Lay out the shared dir for the helper VM:
  #   iso-staging/   — kernel + modules (mirrored into ISO root)
  #   iso-grub.cfg   — becomes /boot/grub/grub.cfg in the ISO
  #   out.iso        — what the helper writes back
  rm -rf "$work"
  mkdir -p "$work/iso-staging"
  cp -a "$staging/." "$work/iso-staging/"
  printf '%s\n' "$grub_cfg" > "$work/iso-grub.cfg"

  _sidekick_run "SIDEKICK_OP=mkiso" "$work"

  [ -s "$work/out.iso" ] || die "sidekick mkiso failed: $work/out.iso missing/empty (qemu exited 0 but grub-mkrescue likely errored — re-run with RUN_ARGS=-monitor=stdio for inspection)"
  mv "$work/out.iso" "$out_iso"
  rm -rf "$work"
  printf '%s' "$cfg_hash" > "$stamp"
}
