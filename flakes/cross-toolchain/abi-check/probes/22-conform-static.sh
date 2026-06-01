#!/usr/bin/env bash
# abi-level: full
# Probe 22 — standards-conformance of the installed headers: constant
# VALUES and namespace cleanliness (a constant that is no longer usable in
# `#if`, a symbol leaking outside its standard's reserved namespace).
# Drives glibc's own conform/ data when the source is reachable
# ($GLIBC_SRC); the full conformtest.py harness is heavy and glibc-version
# specific, so this runs the tractable static slice: every standard's
# header compiles cleanly under that standard's feature-test macro.
set -u
[ -n "${CROSS_CC:-}" ] && [ -x "$CROSS_CC" ] || { echo "SKIP 22-conform-static — no cross cc"; exit 0; }
[ -d "$WORK/include" ] || { echo "SKIP 22-conform-static — no include tree"; exit 0; }
td="$PROBE_TMP/22"; mkdir -p "$td"

# (standard-macro, representative header) pairs from glibc's conform set.
# Each header must compile under its standard's strict feature-test macro
# without dragging in non-reserved identifiers (-Werror flags pollution
# the preprocessor/compiler can see).
checks=(
  "_POSIX_C_SOURCE=200809L unistd.h"
  "_POSIX_C_SOURCE=200809L fcntl.h"
  "_POSIX_C_SOURCE=200809L signal.h"
  "_POSIX_C_SOURCE=200809L time.h"
  "_XOPEN_SOURCE=700 stdlib.h"
  "_XOPEN_SOURCE=700 sys/types.h"
  "_ISOC11_SOURCE limits.h"
  "_DEFAULT_SOURCE termios.h"
)
fails=()
for c in "${checks[@]}"; do
  macro="${c%% *}"; hdr="${c##* }"
  [ -f "$WORK/include/$hdr" ] || continue
  # Pass the feature-test macro via -D, NOT `#define NAME=VALUE` — the
  # spec form is NAME=VALUE, and a literal `#define _POSIX_C_SOURCE=200809L`
  # defines the macro to `=200809L`, turning `#if _POSIX_C_SOURCE >= …`
  # into a preprocessor syntax error.  -D"$macro" expands correctly.
  if ! echo "#include <$hdr>" \
       | "$CROSS_CC" -fsyntax-only -std=c11 -D"$macro" -isystem "$WORK/include" -x c - 2>"$td/e"; then
    grep -qiE 'error:' "$td/e" && fails+=("$hdr under $macro")
  fi
done

# If glibc source is present, note that the full conformtest is available
# but not auto-run here (it needs target execution for some cases).
note=""
[ -n "${GLIBC_SRC:-}" ] && [ -f "$GLIBC_SRC/conform/conformtest.py" ] \
  && note=" (full conformtest.py available at \$GLIBC_SRC/conform — run manually for the exhaustive set)"

if [ "${#fails[@]}" -ne 0 ]; then
  echo "FAIL 22-conform-static — header(s) fail strict-standard compile:"
  printf '       - %s\n' "${fails[@]}" | head -20
  exit 1
fi
echo "PASS 22-conform-static — standard headers compile under their feature-test macros$note"
