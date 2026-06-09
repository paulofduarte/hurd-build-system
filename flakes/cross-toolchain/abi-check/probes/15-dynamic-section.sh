#!/usr/bin/env bash
# abi-level: auto
# Probe 15 - dynamic section tags.  DT_NEEDED set (what libc.so.0.3 itself
# pulls in), DT_FLAGS/DT_FLAGS_1 (BIND_NOW, NODELETE, ...), RELR/GNU_HASH
# presence, RUNPATH.  A change here shifts load/relocation semantics for
# everything linked against libc, invisibly to the symbol set.
set -u
ref_so="$REF/lib/libc.so.0.3"; wrk_so="$WORK/lib/libc.so.0.3"
[ -f "$ref_so" ] && [ -f "$wrk_so" ] || { echo "SKIP 15-dynamic-section - libc.so.0.3 not found"; exit 0; }
td="$PROBE_TMP/15"; mkdir -p "$td"

# Keep the ABI-relevant tags; drop address/size-valued ones (DT_HASH
# address, DT_STRSZ, etc.) that legitimately wobble with rebuilds.
dynsec() {
  "$CROSS_READELF" -d "$1" 2>/dev/null \
    | awk '/\(NEEDED\)/      {print "NEEDED", $NF}
           /\(SONAME\)/      {print "SONAME", $NF}
           /\(FLAGS\)/       {sub(/.*\(FLAGS\)[^A-Z]*/,""); print "FLAGS", $0}
           /\(FLAGS_1\)/     {sub(/.*\(FLAGS_1\)[^A-Za-z]*/,""); print "FLAGS_1", $0}
           /\(RUNPATH\)/     {print "RUNPATH", $NF}
           /\(RPATH\)/       {print "RPATH", $NF}
           /\(RELR\)/        {print "HAS_RELR"}
           /\(GNU_HASH\)/    {print "HAS_GNU_HASH"}
           /\(TEXTREL\)/     {print "HAS_TEXTREL"}' \
    | LC_ALL=C sort -u
}
dynsec "$ref_so" > "$td/ref"
dynsec "$wrk_so" > "$td/wrk"

delta="$(diff "$td/ref" "$td/wrk")"
if [ -n "$delta" ]; then
  echo "FAIL 15-dynamic-section - dynamic tags changed (< ref, > working):"
  printf '%s\n' "$delta" | grep -E '^[<>]' | sed 's/^/       /' | head -20
  exit 1
fi
echo "PASS 15-dynamic-section - DT_NEEDED/FLAGS/RELR/GNU_HASH/RUNPATH unchanged"
