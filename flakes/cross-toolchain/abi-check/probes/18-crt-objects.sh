#!/usr/bin/env bash
# abi-level: auto
# Probe 18 — C-runtime startup objects (crt1/crti/crtn/Scrt1).  Their
# symbols and section set are the startup ABI every executable links;
# drift here (a renamed _start helper, a dropped .init_array handling)
# breaks binaries without touching libc.so's symbol table.
set -u
td="$PROBE_TMP/18"; mkdir -p "$td"

crts="crt1.o crti.o crtn.o Scrt1.o gcrt1.o"
fingerprint() {
  local root="$1" f
  for f in $crts; do
    [ -f "$root/lib/$f" ] || continue
    echo "== $f symbols =="
    "$CROSS_NM" "$root/lib/$f" 2>/dev/null | awk '{print $2, $3}' | LC_ALL=C sort -u
    echo "== $f sections =="
    "$CROSS_READELF" -S "$root/lib/$f" 2>/dev/null \
      | awk 'match($0, /\] [.][A-Za-z._]+/) {s=substr($0,RSTART+2); sub(/ .*/,"",s); print s}' \
      | LC_ALL=C sort -u
  done
}
fingerprint "$REF"  > "$td/ref"
fingerprint "$WORK" > "$td/wrk"
[ -s "$td/ref" ] || { echo "SKIP 18-crt-objects — no crt objects found"; exit 0; }

delta="$(diff "$td/ref" "$td/wrk")"
if [ -n "$delta" ]; then
  echo "FAIL 18-crt-objects — startup object symbols/sections changed (< ref, > working):"
  printf '%s\n' "$delta" | grep -E '^[<>]' | sed 's/^/       /' | head -25
  exit 1
fi
echo "PASS 18-crt-objects — crt startup objects unchanged"
