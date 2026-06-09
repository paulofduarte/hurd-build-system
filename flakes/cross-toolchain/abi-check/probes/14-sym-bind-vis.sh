#!/usr/bin/env bash
# abi-level: auto
# Probe 14 - binding + visibility of exported symbols.  A global->weak
# demotion, or default->protected/hidden, changes how callers resolve a
# symbol while its name+version (Tier-1) stay put.
set -u
ref_so="$REF/lib/libc.so.0.3"; wrk_so="$WORK/lib/libc.so.0.3"
[ -f "$ref_so" ] && [ -f "$wrk_so" ] || { echo "SKIP 14-sym-bind-vis - libc.so.0.3 not found"; exit 0; }
td="$PROBE_TMP/14"; mkdir -p "$td"

# "NAME BIND VIS" for every defined dynamic symbol (readelf cols:
# Num Value Size Type Bind Vis Ndx Name).
bv() {
  "$CROSS_READELF" -W --dyn-syms "$1" 2>/dev/null \
    | awk '$1 ~ /^[0-9]+:$/ && $7 != "UND" && $8 != "" {
             n = $8; sub(/@.*/, "", n); if (n != "") print n, $5, $6 }' \
    | LC_ALL=C sort -u
}
bv "$ref_so" > "$td/ref"
bv "$wrk_so" > "$td/wrk"

# Changed bind/vis on a symbol present in both.
changed="$(awk 'NR==FNR { m[$1] = $2" "$3; next }
                ($1 in m) && m[$1] != ($2" "$3) { print $1": "m[$1]" -> "$2" "$3 }' \
           "$td/ref" "$td/wrk" | LC_ALL=C sort -u)"

if [ -n "$changed" ]; then
  echo "FAIL 14-sym-bind-vis - binding/visibility changed:"
  printf '       - %s\n' $(printf '%s\n' "$changed" | head -20)
  exit 1
fi
echo "PASS 14-sym-bind-vis - no binding/visibility changes on shared symbols"
