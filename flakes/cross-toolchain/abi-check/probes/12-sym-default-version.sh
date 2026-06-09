#!/usr/bin/env bash
# abi-level: auto
# Probe 12 - default (@@VER) vs non-default (@VER) version *flips*.
# Tier-1's abilist-style extraction normalizes both away, so a symbol
# silently switching which version is the default - which changes what a
# fresh link binds - would slip past it.  Keep the @@/@ marker and diff.
set -u
ref_so="$REF/lib/libc.so.0.3"; wrk_so="$WORK/lib/libc.so.0.3"
[ -f "$ref_so" ] && [ -f "$wrk_so" ] || { echo "SKIP 12-sym-default-version - libc.so.0.3 not found"; exit 0; }
td="$PROBE_TMP/12"; mkdir -p "$td"

# "NAME VERSION default|nondefault" for every defined, versioned symbol.
verlist() {
  "$CROSS_READELF" -W --dyn-syms "$1" 2>/dev/null \
    | awk '$7 != "UND" && $8 ~ /@/ {
        s = $8
        if (s ~ /@@/) { n = s; sub(/@@.*/, "", n); v = s; sub(/.*@@/, "", v); print n, v, "default" }
        else          { n = s; sub(/@.*/,  "", n); v = s; sub(/.*@/,  "", v); print n, v, "nondefault" }
      }' | LC_ALL=C sort -u
}
verlist "$ref_so" > "$td/ref"
verlist "$wrk_so" > "$td/wrk"

# Flip = same (name,version) present in both, marker changed.
flips="$(awk 'NR==FNR { m[$1" "$2] = $3; next }
              ($1" "$2) in m && m[$1" "$2] != $3 { print $1"@"$2": "m[$1" "$2]" -> "$3 }' \
         "$td/ref" "$td/wrk")"

if [ -n "$flips" ]; then
  echo "FAIL 12-sym-default-version - default/non-default version flip(s):"
  printf '       - %s\n' $(printf '%s\n' "$flips" | head -20)
  exit 1
fi
echo "PASS 12-sym-default-version - no @@/@ default-version flips"
