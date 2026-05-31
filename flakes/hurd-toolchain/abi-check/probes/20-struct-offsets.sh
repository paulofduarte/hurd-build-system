#!/usr/bin/env bash
# abi-level: full
# Probe 20 — the no-DWARF complement to Tier-2.  Capture the REFERENCE
# struct sizes + member offsets from its DWARF (via pahole), emit
# `_Static_assert(sizeof/offsetof …)` for them, then compile those asserts
# `-fsyntax-only` against the WORKING *headers*.  If a working header
# changed a public struct's layout, the assert fails — proving the drift
# with no DWARF needed on the working side (the case pahole-on-binary
# alone, probe 24, can't express against headers).
set -u
ref_so="$REF/lib/libc.so.0.3"
[ -f "$ref_so" ] || { echo "SKIP 20-struct-offsets — reference libc.so.0.3 not found"; exit 0; }
command -v pahole >/dev/null 2>&1 || { echo "SKIP 20-struct-offsets — pahole not on PATH"; exit 0; }
[ -n "${CROSS_CC:-}" ] && [ -x "$CROSS_CC" ] || { echo "SKIP 20-struct-offsets — no cross cc"; exit 0; }
td="$PROBE_TMP/20"; mkdir -p "$td"

# struct → public header that defines it.
declare -A hdr=(
  [timespec]=time.h [tm]=time.h [timeval]=sys/time.h
  [stat]=sys/stat.h [sigaction]=signal.h
  [dirent]=dirent.h [iovec]=sys/uio.h
  [rlimit]=sys/resource.h [rusage]=sys/resource.h
  [flock]=fcntl.h [pollfd]=poll.h [termios]=termios.h
)

emit_asserts() { # $1 struct  $2 header → static_asserts on stdout, or nothing
  # Don't gate on pahole's exit code: in a nix/CI sandbox (no
  # /sys/kernel/btf) pahole prints the struct from DWARF but still exits
  # non-zero, so we judge on the OUTPUT, not the status (matches probe 24).
  local s="$1" p; p="$(pahole -C "$s" "$ref_so" 2>/dev/null)"
  [ -n "$p" ] || return 1
  local size; size="$(printf '%s\n' "$p" | sed -n 's/.*\/\* size: \([0-9]\+\).*/\1/p' | tail -1)"
  [ -n "$size" ] || return 1
  echo "#include <$2>"
  echo "_Static_assert(sizeof(struct $s) == $size, \"sizeof struct $s changed\");"
  # member offsets: pahole prints "  type name;  /* OFF SZ */"
  printf '%s\n' "$p" | sed -n 's/^[[:space:]]*[A-Za-z_].*[[:space:]]\([A-Za-z_][A-Za-z0-9_]*\);[[:space:]]*\/\* *\([0-9]\+\).*/\1 \2/p' \
    | while read -r mem off; do
        echo "_Static_assert(__builtin_offsetof(struct $s, $mem) == $off, \"offset of $s.$mem changed\");"
      done
}

n=0
: > "$td/asserts.c"
for s in "${!hdr[@]}"; do
  if a="$(emit_asserts "$s" "${hdr[$s]}")" && [ -n "$a" ]; then
    printf '%s\n' "$a" >> "$td/asserts.c"; n=$((n+1))
  fi
done
[ "$n" -gt 0 ] || { echo "SKIP 20-struct-offsets — no curated structs carry DWARF in the reference"; exit 0; }

if err="$("$CROSS_CC" -fsyntax-only -D_ISOMAC -isystem "$WORK/include" -x c "$td/asserts.c" 2>&1)"; then
  echo "PASS 20-struct-offsets — $n reference struct layouts match the working headers"
else
  echo "FAIL 20-struct-offsets — working headers disagree with reference struct layout:"
  printf '%s\n' "$err" | grep -iE 'static_assert|changed|error:' | sed 's/^/       /' | head -25
  exit 1
fi
