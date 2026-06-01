#!/usr/bin/env bash
# abi-level: auto
# Tier-1 — exported symbol + version set, SONAME, abilist cross-check.
#
# The cheapest, highest-value gate: a removed or renumbered versioned
# symbol breaks every binary that imported it.  Cross-objdump output is
# target-agnostic text, so this runs host-side on the Hurd libc.so.0.3.
#
#   - REMOVED / renumbered versioned symbols  → FATAL
#   - ADDED symbols                           → review-only (printed, not fatal)
#   - SONAME bump (libc.so.0.3 → …)           → FATAL
#   - working symlist ⊄ checked-in abilist    → review-only (free cross-check)
set -u

ref_so="$REF/lib/libc.so.0.3"
wrk_so="$WORK/lib/libc.so.0.3"
[ -f "$ref_so" ] && [ -f "$wrk_so" ] || { echo "SKIP 00-symbols — libc.so.0.3 not found"; exit 0; }

td="$PROBE_TMP/00-symbols"; mkdir -p "$td"

# "VERSION symbol" for every defined, versioned dynamic symbol, sorted.
# Mirrors abilist.awk's normalized output without needing glibc's source:
# keep GLIBC_/HURD_/GCC_ version nodes, drop UND, strip the @@/@ marker
# (probe 12 covers the default-vs-non-default distinction separately).
#
# GLIBC_PRIVATE is excluded: it is glibc's explicitly-internal version node
# (intra-glibc linkage between libc.so / ld.so / libpthread), NOT public
# ABI, and it churns freely between glibc versions.  Upstream's own abilist
# checks drop it; counting its symbols as "removed" is a false positive
# (e.g. __gai_sigqueue@GLIBC_PRIVATE across 2.43 ↔ master).
symlist() {
  "$CROSS_OBJDUMP" -T "$1" 2>/dev/null | awk '
    $2 == "*UND*" { next }
    {
      for (i = 1; i <= NF; i++)
        if ($i ~ /^\(?(GLIBC_|HURD_|GCC_)/) {
          v = $i; gsub(/[()]/, "", v);
          if (v == "GLIBC_PRIVATE") break;
          print v, $NF; break
        }
    }' | LC_ALL=C sort -u
}

symlist "$ref_so" > "$td/ref.symlist"
symlist "$wrk_so" > "$td/wrk.symlist"

removed="$(comm -23 "$td/ref.symlist" "$td/wrk.symlist")"
added="$(comm -13 "$td/ref.symlist" "$td/wrk.symlist")"

soname() { "$CROSS_READELF" -d "$1" 2>/dev/null | sed -n 's/.*SONAME.*\[\(.*\)\].*/\1/p'; }
ref_soname="$(soname "$ref_so")"
wrk_soname="$(soname "$wrk_so")"

rc=0
if [ -n "$removed" ]; then
  echo "FAIL 00-symbols — $(printf '%s\n' "$removed" | grep -c .) versioned symbol(s) REMOVED/renumbered:"
  printf '       - %s\n' $(printf '%s\n' "$removed" | awk '{print $2"@"$1}' | head -30)
  rc=1
fi
if [ "$ref_soname" != "$wrk_soname" ]; then
  echo "FAIL 00-symbols — SONAME changed: $ref_soname → $wrk_soname"
  rc=1
fi

if [ "$rc" -eq 0 ]; then
  n_add="$(printf '%s' "$added" | grep -c . || true)"
  echo "PASS 00-symbols — no symbols removed, SONAME $wrk_soname (additions: ${n_add:-0}, review-only)"
fi

# Free cross-check: working symlist vs glibc's own checked-in abilist
# (the upstream-declared ABI).  Review-only — a mismatch flags drift to
# look at, never fails the gate (the working-vs-reference diff above is
# the authority).  Skipped when the abilist isn't reachable.
if [ -n "${ABILIST:-}" ] && [ -f "$ABILIST" ]; then
  awk '{print $1}' "$td/wrk.symlist" | sort -u > "$td/wrk.versions"
  missing="$(awk '{print $2, $1}' "$td/wrk.symlist" | LC_ALL=C sort -u \
            | comm -23 - <(awk 'NF>=2 {print $NF, $1}' "$ABILIST" | LC_ALL=C sort -u) | head -5)"
  [ -n "$missing" ] && echo "       note: working has symbols not in checked-in abilist (review): $(printf '%s ' $(printf '%s\n' "$missing" | awk '{print $1}'))"
fi

exit "$rc"
