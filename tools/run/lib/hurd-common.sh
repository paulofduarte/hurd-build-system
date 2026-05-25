# Hurd-specific helpers — fetch, overlay, vanilla-vs-inject branch, exec.
#
# Reads $WORK, $TARGET, $GNUMACH_BOOT_IMAGE, $QEMU*, $RUN_* from env.

# hurd_cache_dir <distro> <target>
#   Echoes $WORK/test-images/<distro>/<target>/, creating it as a side
#   effect. Idempotent. Callers use $(hurd_cache_dir …) — be aware that
#   the mkdir runs as part of the call even when the dir already exists.
hurd_cache_dir() {
  local dir="$WORK/test-images/$1/$2"
  mkdir -p "$dir"
  echo "$dir"
}

# hurd_fetch_once <url> <dest>
#   Downloads only if dest is missing. No checksum.
hurd_fetch_once() {
  local url="$1" dest="$2"
  [ -s "$dest" ] && return 0
  echo "fetching $(basename "$dest") …" >&2
  curl -fLo "$dest.tmp" "$url"
  mv "$dest.tmp" "$dest"
}

# hurd_fetch_once_verified <url> <dest> <checksum_url>
#   Downloads only if dest missing, then verifies via sha512.
hurd_fetch_once_verified() {
  local url="$1" dest="$2" sha="$3"
  hurd_fetch_once "$url" "$dest"
  hurd_fetch_once "$sha" "$dest.sha512"
  (cd "$(dirname "$dest")" && sha512sum -c "$(basename "$dest").sha512") \
    || die "checksum mismatch for $dest"
}

# hurd_resolve_latest_target <url> — Cuirass-specific
#   Echoes the current /download/<id> resolution of an auto-latest URL.
#   Cuirass quirk: HEAD returns 404; GET --max-filesize 1 follows the
#   redirect without downloading the body.
#
#   IMPORTANT: --max-filesize 1 makes curl always exit 63 once it sees
#   the response body (both for the success path — qcow2 binary >> 1
#   byte — and the 500-error path — JSON body ~50 bytes). Under set -e
#   the caller would die before checking $target. The trailing `|| :`
#   eats that exit code; the caller's case statement validates that
#   $target looks like a /download/<id> URL (success) or something
#   else (failure with hint).
hurd_resolve_latest_target() {
  curl -sL -X GET --max-filesize 1 -o /dev/null -w '%{url_effective}' "$1" || :
}

# hurd_fetch_via_resolve <url> <dest> <cache_marker> [error_hint]
#   For URLs that always serve "latest" via redirect (e.g., Guix Cuirass).
#   Re-fetches only when the resolved target changes; updates marker.
#   On fetch, also removes $(dirname dest)/extracted to force re-extract.
#   If upstream has no current build (URL resolves to anything other than
#   /download/<id>), die with the optional <error_hint> appended.
#
#   curl uses -f so HTTP errors after the redirect resolve (rare race)
#   produce a non-zero exit instead of silently writing error HTML as
#   the qcow2.
hurd_fetch_via_resolve() {
  local url="$1" dest="$2" marker="$3" hint="${4:-}"
  local target
  target=$(hurd_resolve_latest_target "$url")
  case "$target" in
    https://*/download/*) ;;
    *)
      local msg="upstream has no current build for $url"
      [ -n "$hint" ] && msg="$msg

$hint"
      die "$msg"
      ;;
  esac
  if [ "$target" != "$(cat "$marker" 2>/dev/null)" ]; then
    echo "upstream has new build, re-fetching: $target" >&2
    curl -sLf "$url" -o "$dest.tmp"
    mv "$dest.tmp" "$dest"
    echo "$target" > "$marker"
    rm -rf "$(dirname "$dest")/extracted"
  fi
}

# hurd_make_overlay <base> <overlay> <base_format>
#   qemu-img qcow2 overlay over <base>. <base_format> MUST match the
#   actual format of <base>: "raw" for Debian's extracted .img, "qcow2"
#   for Gentoo/Guix images. qemu-img requires the explicit -F to avoid
#   probing the backing file at every open (and to fail loudly if the
#   format is wrong instead of producing a broken overlay).
#
#   Default: fresh overlay every run (current overlay is overwritten).
#   Set RUN_KEEP_OVERLAY=1 to reuse the overlay across runs — recreated
#   only when missing or when <base> is newer than the existing overlay.
hurd_make_overlay() {
  local base="$1" overlay="$2" base_fmt="$3"
  if [ "${RUN_KEEP_OVERLAY:-}" = "1" ]; then
    [ -e "$overlay" ] && [ ! "$base" -nt "$overlay" ] && return 0
  fi
  qemu-img create -f qcow2 -b "$base" -F "$base_fmt" "$overlay" >/dev/null
}

# hurd_maybe_vanilla_exec <qemu> <args...>
#   If RUN_VANILLA=1, exec qemu with the given args (skips inject).
#   Otherwise returns 0 (the scenario script continues to the
#   our-kernel exec path).
hurd_maybe_vanilla_exec() {
  [ "${RUN_VANILLA:-}" = "1" ] || return 0
  echo "RUN_VANILLA=1 — booting distro's bundled kernel" >&2
  print_qemu_hint
  exec "$@"
}

# hurd_exec_with_our_kernel <overlay> <initrd_modules> <kernel_cmdline> [extra_qemu_args...]
#   The standard our-kernel exec: -kernel + -initrd + -drive.
#   Uses $QEMU, $QEMU_MACHINE, $QEMU_CPU, $QEMU_MEM from
#   arch_qemu_for_target. Scenarios can override any of these (notably
#   QEMU_MACHINE="-M q35" for Guix) by reassigning the variable AFTER
#   arch_qemu_for_target returns and BEFORE calling this function.
#
#   <initrd_modules> is the multi-module string passed verbatim to qemu's
#   -initrd flag.  Qemu's multiboot syntax: commas separate modules; a
#   space inside a chunk separates the file path from its per-module
#   arguments.  Each scenario must provide the canonical Hurd args so
#   gnumach knows to create tasks for the modules — without them gnumach
#   loads the modules into memory but never runs them, and boot hangs
#   silently after "2 multiboot modules" prints.
#
#   Static-exec model (Debian — ships exec.static):
#     "<cache>/ext2fs.static --multiboot-command-line=\${kernel-command-line}
#       --host-priv-port=\${host-port} --device-master-port=\${device-port}
#       --exec-server-task=\${exec-task} -T typed \${root} \$(task-create) \$(task-resume),
#      <cache>/exec.static \$(exec-task=task-create)"
#
#   Dynamic-exec model (Gentoo/Guix — ld.so loads /hurd/exec from the
#   mounted root after ext2fs.static comes up):
#     "<extract>/ext2fs.static <same args as above>,
#      <extract>/ld.so.1 exec /hurd/exec \$(exec-task=task-create)"
#
#   No --readonly or --writable: ext2fs.static's default is the right
#   behaviour, and Debian's init does its own fsysopts remount later.
#   The "/tmp /run failed" bootclean warnings during early boot are
#   intrinsic to Debian Hurd's init ordering (bootclean runs before
#   the fsysopts remount) and not affected by these flags — verified
#   empirically 2026-05-24, see Debian Bug #693398 for context.
#
#   The \${var} and \$(directive) tokens MUST reach gnumach literally —
#   they're parsed by gnumach's kern/bootstrap.c at module-load time.
#   In bash this means backslash-escaping the `$` inside double quotes.
#
#   <kernel_cmdline> is the full -append value (NOT a suffix).  Typically
#   "root=device:hd0s1 console=$QEMU_CONSOLE [...]".
#
#   Any further args are forwarded verbatim to qemu (this is how
#   $RUN_ARGS flows through).  Use the arithmetic shift form to
#   handle the "called with exactly 3 args" case safely.
#
#   Calls print_qemu_hint right before exec.
hurd_exec_with_our_kernel() {
  local overlay="$1" modules="$2" cmdline="$3"
  shift $(( $# < 3 ? $# : 3 ))

  # qemu's -kernel uses the multiboot1 loader, which rejects 64-bit
  # ELFs (gnumach's x86_64 build is 64-bit despite carrying a
  # multiboot1 magic + 32-bit trampoline — qemu checks ELF class
  # first).  For x86_64 we route through GRUB-on-ISO via the sidekick
  # helper VM: grub-mkrescue produces an ISO that boots gnumach via
  # multiboot2, and qemu loads the ISO with -cdrom instead of -kernel.
  if [ "$TARGET" = "x86_64" ]; then
    _hurd_exec_via_iso "$overlay" "$modules" "$cmdline" "$@"
  fi

  print_qemu_hint
  exec "$QEMU" -nographic $QEMU_MACHINE -m "$QEMU_MEM" -cpu "$QEMU_CPU" \
    -kernel "$GNUMACH_BOOT_IMAGE" \
    -initrd "$modules" \
    -append "$cmdline" \
    -drive file="$overlay",format=qcow2,if=ide \
    "$@"
}

# _hurd_exec_via_iso <overlay> <modules> <cmdline> [extra_qemu_args...]
#   Internal: x86_64 path.  Wraps gnumach + modules in a GRUB-bootable
#   ISO via sidekick_make_iso, then qemu -cdrom.  Called from
#   hurd_exec_with_our_kernel when TARGET=x86_64.  Files identified by
#   basename inside the ISO — caller must use unique basenames in the
#   modules string (which is the case for Hurd's standard set:
#   ext2fs.static, exec.static, ld.so.1).
_hurd_exec_via_iso() {
  local overlay="$1" modules="$2" cmdline="$3"
  shift $(( $# < 3 ? $# : 3 ))

  local cache iso staging
  cache="$(dirname "$overlay")"
  iso="$cache/boot.iso"
  staging="$cache/iso-staging"

  echo "sidekick: preparing ISO staging for x86_64 inject …" >&2
  rm -rf "$staging"
  mkdir -p "$staging"

  # Copy gnumach + every module file into staging (referenced by
  # basename in the GRUB config below).
  cp -L "$GNUMACH_BOOT_IMAGE" "$staging/$(basename "$GNUMACH_BOOT_IMAGE")"
  local saved_IFS="$IFS"
  IFS=','
  for chunk in $modules; do
    local file="${chunk%% *}"
    cp -L "$file" "$staging/$(basename "$file")"
  done
  IFS="$saved_IFS"

  # Build grub.cfg.  Critical: every ${var} and $(directive) in the
  # module args MUST be single-quoted before reaching GRUB.  GRUB's
  # parser otherwise:
  #   - expands ${var} (and the substitution variables gnumach uses
  #     like ${host-port}, ${device-port}, ${exec-task}, ${root}
  #     aren't GRUB variables, so they'd expand to empty strings)
  #   - executes $(...) as command substitution → fails because
  #     `task-create` isn't a GRUB command → menuentry parse error →
  #     drops to the `grub>` rescue prompt
  # Verified against Debian's own hurd-amd64 grub.cfg, which uses
  # the exact same single-quoting pattern:
  #   --host-priv-port='${host-port}' '$(task-create)' '$(task-resume)'
  # The literal text reaches gnumach's bootstrap, which has its own
  # substitution table for both ${...} (host-port etc) and $(...)
  # (task-create etc).
  local grub_cfg quoted_modules
  quoted_modules=$(printf '%s' "$modules" | sed -E "s/(\\\$\\{[^}]+\\})/'\\1'/g; s/(\\\$\\([^)]+\\))/'\\1'/g")

  grub_cfg=$(
    printf 'set timeout=0\n'
    printf 'menuentry "hurd" {\n'
    printf '  multiboot /%s %s\n' "$(basename "$GNUMACH_BOOT_IMAGE")" "$cmdline"
    # GRUB's `module FILE ARGS...` strips FILE and passes the rest
    # to gnumach verbatim, so the FIRST token of ARGS becomes argv[0].
    # The scenario script must include the desired argv[0] explicitly
    # in the modules string (after the file path).  For most modules
    # that's just the program name (`ext2fs`, `rumpdisk`, etc.); for
    # the dynamic loader Debian uses `exec` as argv[0] to drive ld.so
    # into "load and exec /hurd/exec" mode.  i686 path is unaffected
    # — qemu's `-initrd` always prepends the file path to the cmdline,
    # so any explicit argv[0] becomes harmless argv[1].
    saved_IFS="$IFS"
    IFS=','
    for chunk in $quoted_modules; do
      local file="${chunk%% *}"
      local args="${chunk#"$file"}"
      args="${args# }"
      printf '  module /%s %s\n' "$(basename "$file")" "$args"
    done
    IFS="$saved_IFS"
    printf '  boot\n'
    printf '}\n'
  )

  sidekick_make_iso "$iso" "$staging" "$grub_cfg"

  # `-boot order=d` forces CD-ROM-first boot.  Default qemu order is
  # HDD then CDROM, so without this qemu would load the disk image's
  # internal GRUB (which boots the distro's bundled kernel) and skip
  # our ISO entirely — verified empirically 2026-05-24 against
  # Debian's hurd-amd64 image: SeaBIOS reported "Booting from Hard
  # Disk..." and Debian's GRUB took over instead of ours.
  print_qemu_hint
  exec "$QEMU" -nographic $QEMU_MACHINE -m "$QEMU_MEM" -cpu "$QEMU_CPU" \
    -boot order=d \
    -cdrom "$iso" \
    -drive file="$overlay",format=qcow2,if=ide \
    "$@"
}
