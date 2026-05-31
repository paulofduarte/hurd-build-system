#!/usr/bin/env bash
# abi-level: full
# Probe 23 — confirmatory cross-check via abi-compliance-checker (ACC): an
# independent second opinion on probes 10-11 (constant/inline drift) plus
# inline-function *signature* drift, using a different engine than
# abidiff.  ACC compares two library dumps built from the unstripped libc
# + its headers; a non-zero "binary compatibility < 100%" is the signal.
set -u
ref_so="$REF/lib/libc.so.0.3"; wrk_so="$WORK/lib/libc.so.0.3"
[ -f "$ref_so" ] && [ -f "$wrk_so" ] || { echo "SKIP 23-acc-constants — libc.so.0.3 not found"; exit 0; }
command -v abi-compliance-checker >/dev/null 2>&1 || { echo "SKIP 23-acc-constants — abi-compliance-checker not on PATH"; exit 0; }
command -v abi-dumper >/dev/null 2>&1 || { echo "SKIP 23-acc-constants — abi-dumper not on PATH"; exit 0; }
td="$PROBE_TMP/23"; mkdir -p "$td"

# abi-dumper needs DWARF (the deep/full report provides unstripped libc).
abi-dumper "$ref_so" -o "$td/ref.dump" -lver ref >/dev/null 2>&1 || { echo "SKIP 23-acc-constants — abi-dumper could not read DWARF"; exit 0; }
abi-dumper "$wrk_so" -o "$td/wrk.dump" -lver wrk >/dev/null 2>&1 || { echo "SKIP 23-acc-constants — abi-dumper could not read DWARF"; exit 0; }

abi-compliance-checker -l libc \
  -old "$td/ref.dump" -new "$td/wrk.dump" \
  -report-path "$td/acc-report.html" >"$td/acc.log" 2>&1
rc=$?

# ACC exit: 0 = compatible, 1 = incompatible.  Surface the headline.
hl="$(grep -iE 'binary compatibility|incompatible|problems' "$td/acc.log" | head -3 | tr '\n' ' ')"
if [ $rc -ne 0 ]; then
  echo "FAIL 23-acc-constants — abi-compliance-checker reports incompatibility: ${hl:-see $td/acc-report.html}"
  exit 1
fi
echo "PASS 23-acc-constants — abi-compliance-checker: compatible (${hl:-100%})"
