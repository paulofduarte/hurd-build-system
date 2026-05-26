# Hurd-specific helpers — fetch, overlay, vanilla-vs-inject branch, exec.
#
# Reads $WORK, $TARGET, $GNUMACH_KERNEL, $QEMU*, $RUN_* from env.

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

# hurd_exec_with_our_kernel and _hurd_exec_via_iso were removed
# 2026-05-25 along with the module-injection-via-host approach.  All
# three Hurd scenarios now overlay our kernel into the distro's
# qcow2 via the sidekick (sidekick_overlay_kernel in lib/sidekick.sh)
# and let the disk's own GRUB drive multiboot — no need for the
# host-side -kernel/-initrd plumbing or GRUB-on-ISO assembly.
