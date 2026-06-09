#!/usr/bin/env bash
# abi-level: auto
# Probe 17 - ELF notes, chiefly .note.ABI-tag (the minimum OS/ABI version
# the binary declares).  A bump there raises the floor for everything
# linked against libc; check the .so and the startup crt objects.
set -u
td="$PROBE_TMP/17"; mkdir -p "$td"

notes() {
  local root="$1"
  for f in lib/libc.so.0.3 lib/crt1.o lib/Scrt1.o lib/crti.o; do
    [ -f "$root/$f" ] || continue
    echo "== $f =="
    "$CROSS_READELF" -n "$root/$f" 2>/dev/null \
      | grep -iE 'ABI|OS:|NT_|Version:' | sed 's/[[:space:]]\+/ /g'
  done
}
notes "$REF"  > "$td/ref"
notes "$WORK" > "$td/wrk"
[ -s "$td/ref" ] || { echo "SKIP 17-notes - no notes found"; exit 0; }

delta="$(diff "$td/ref" "$td/wrk")"
if [ -n "$delta" ]; then
  echo "FAIL 17-notes - ELF note/ABI-tag changed (< ref, > working):"
  printf '%s\n' "$delta" | grep -E '^[<>]' | sed 's/^/       /' | head -20
  exit 1
fi
echo "PASS 17-notes - .note.ABI-tag and OS/ABI version unchanged"
