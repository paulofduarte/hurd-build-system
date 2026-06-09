#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Paulo Duarte <paulofernandobd@gmail.com>
# SPDX-License-Identifier: GPL-3.0-or-later
# ABI-gate runner - globs probes/*.sh in numeric order and aggregates.
#
# Answers one question (see TOOLCHAIN-LIBC-DECOUPLING.md "ABI gate"): did
# the WORKING glibc break the exported ABI that gcc's prebuilt
# libgcc_s/libstdc++ + all userland bind to, relative to the REFERENCE?
# Every check is static (the Nix sandbox can't run Hurd binaries) -
# "stress test" means a link/compile probe, never execution.
#
# Each probe is a self-contained probes/<NN-name>.sh.  Coverage grows by
# dropping in another numbered file - no rewiring here.  A probe:
#   - reads the exported env below (REF/WORK/TP/ARCH/CROSS_* + tool paths);
#   - declares its set via a `# abi-level: auto|deep|full` header line;
#   - prints exactly one `PASS|FAIL|SKIP <name> - <detail>` line;
#   - exits 0 on PASS/SKIP, non-zero on FAIL.
# The number ranges mirror the doc: 00 Tier-1, 05 Tier-2, 10-19 cheap/Hurd
# Tier-3 (auto), 20-24 heavy Tier-3 (full).
#
# Levels are cumulative: auto <= deep <= full.  ABI_LEVEL selects the set -
# `auto` is the automatic nix gate (DWARF-free, stripped glibc); `deep` is
# `make check-glibc` (+ Tier-2 abidiff on unstripped variants); `full` is
# `make check-glibc-full` (+ the heavy probes).
#
# Exported to every probe:
#   REF WORK          the two glibc sysroot roots ($out of glibc.nix)
#   TP                target prefix, e.g. i686-gnu  (tools are $TP-objdump ...)
#   ARCH              glibc abilist arch dir: i386 (i686) | x86_64
#   CROSS_CC          cross gcc driver (raw, no libc) for -E / link probes
#   CROSS_OBJDUMP CROSS_READELF CROSS_NM   cross binutils
#   ABILIST           working glibc's checked-in libc.abilist (may be empty)
#   ABIGNORE          libabigail suppression file (Tier-2)
#   PROBE_TMP         a writable scratch dir, unique per run
set -u

PROBES_DIR="${PROBES_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/probes" && pwd)}"
ABI_LEVEL="${ABI_LEVEL:-auto}"

# auto=0 deep=1 full=2 - a probe runs when its level <= the requested one.
_level_rank() { case "$1" in auto) echo 0;; deep) echo 1;; full) echo 2;; *) echo 0;; esac; }
WANT_RANK=$(_level_rank "$ABI_LEVEL")

export PROBE_TMP="${PROBE_TMP:-$(mktemp -d)}"

n_pass=0 n_fail=0 n_skip=0
fails=()

echo "=== glibc ABI gate (level: $ABI_LEVEL) ==="
echo "    reference: ${REF##*/}"
echo "    working:   ${WORK##*/}"
echo "    target:    $TP  (abilist arch: $ARCH)"
echo

shopt -s nullglob
for probe in "$PROBES_DIR"/[0-9]*.sh; do
  pname="$(basename "$probe" .sh)"
  plevel="$(sed -n 's/^# *abi-level: *\([a-z]*\).*/\1/p' "$probe" | head -1)"
  plevel="${plevel:-auto}"
  if [ "$(_level_rank "$plevel")" -gt "$WANT_RANK" ]; then
    continue   # probe is above the requested set
  fi
  out="$(bash "$probe" 2>&1)"; rc=$?
  # A probe prints its own PASS/FAIL/SKIP line(s); echo them verbatim.
  printf '%s\n' "$out"
  if [ $rc -ne 0 ]; then
    n_fail=$((n_fail+1)); fails+=("$pname")
  elif printf '%s' "$out" | grep -q '^SKIP '; then
    n_skip=$((n_skip+1))
  else
    n_pass=$((n_pass+1))
  fi
done

echo
echo "=== ABI gate summary: $n_pass passed, $n_fail failed, $n_skip skipped ==="
if [ $n_fail -ne 0 ]; then
  echo "    FAILED probes: ${fails[*]}"
  echo "    The working glibc diverges from the reference gcc binds against."
  echo "    Either the change is ABI-safe (adjust the probe / abignore) or it"
  echo "    is a real break - rebaseline the reference (make rebaseline-ref)."
  exit 1
fi
echo "    working glibc is ABI-compatible with the reference."
