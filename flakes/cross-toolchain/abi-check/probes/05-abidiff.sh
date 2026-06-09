#!/usr/bin/env bash
# abi-level: deep
# Tier-2 - type/struct compatibility via libabigail's `abidiff`.  Catches
# the silent-UB class Tier-1 can't: struct size / member-offset changes,
# function-signature changes, enum/variable-type changes *behind an
# unchanged symbol name+version*.  Needs DWARF, so this only runs in the
# deep/full report (mkAbiReport builds unstripped ref+working variants);
# the automatic gate skips it (it's above the `auto` level).
set -u
ref_so="$REF/lib/libc.so.0.3"; wrk_so="$WORK/lib/libc.so.0.3"
[ -f "$ref_so" ] && [ -f "$wrk_so" ] || { echo "SKIP 05-abidiff - libc.so.0.3 not found"; exit 0; }
command -v abidiff >/dev/null 2>&1 || { echo "SKIP 05-abidiff - abidiff (libabigail) not on PATH"; exit 0; }

td="$PROBE_TMP/05"; mkdir -p "$td"
supp=()
[ -n "${ABIGNORE:-}" ] && [ -f "$ABIGNORE" ] && supp=(--suppressions "$ABIGNORE")

# --fail-no-debug-info: error rather than silently downgrade if the
# variants turned out stripped (guards the deep contract).  --no-added-*
# keeps additions (new symbols/types) from counting as changes - only
# incompatible changes to the existing surface matter.
abidiff "${supp[@]}" \
  --fail-no-debug-info \
  --no-added-syms \
  "$ref_so" "$wrk_so" > "$td/abidiff.out" 2>&1
rc=$?

# libabigail exit bits: 1=error, 2=usage, 4=ABI change, 8=ABI INCOMPATIBLE.
# Fail only on the incompatible bit (8) or a hard tool error (1).
if [ $((rc & 1)) -ne 0 ]; then
  echo "FAIL 05-abidiff - abidiff tool error:"
  sed 's/^/       /' "$td/abidiff.out" | head -20
  exit 1
fi
if [ $((rc & 8)) -ne 0 ]; then
  echo "FAIL 05-abidiff - INCOMPATIBLE ABI change (struct/signature/enum behind a stable symbol):"
  sed 's/^/       /' "$td/abidiff.out" | head -40
  exit 1
fi
if [ $((rc & 4)) -ne 0 ]; then
  echo "PASS 05-abidiff - compatible ABI changes only (additions/benign; see report)"
else
  echo "PASS 05-abidiff - no type/struct/signature changes"
fi
