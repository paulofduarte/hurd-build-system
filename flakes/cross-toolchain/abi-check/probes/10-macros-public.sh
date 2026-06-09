#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Paulo Duarte <paulofernandobd@gmail.com>
# SPDX-License-Identifier: GPL-3.0-or-later
# abi-level: auto
# Probe 10 - public macro VALUES.  errno/signal/O_*/RLIMIT_*/_SC_* and
# function-like-macro bodies are constant-folded into callers at compile
# time: they are not symbols and not in DWARF, so neither Tier-1 nor
# Tier-2 sees a changed #define.  Preprocess a fixed public-header
# umbrella with the cross cc against each sysroot and diff the defines.
set -u
td="$PROBE_TMP/10"; mkdir -p "$td"

# Public headers present across the Hurd glibc include tree.  Missing
# ones are skipped per-sysroot, so the umbrella can list extras safely.
umbrella='errno.h signal.h fcntl.h limits.h stdio.h stdlib.h unistd.h string.h
          time.h sched.h sys/types.h sys/stat.h sys/resource.h sys/mman.h
          sys/socket.h netinet/in.h termios.h dlfcn.h pthread.h'

gen() { # $1 = sysroot root -> sorted "KEY<TAB>VALUE" macro map
  local root="$1" h
  : > "$td/in.c"
  for h in $umbrella; do [ -f "$root/include/$h" ] && echo "#include <$h>" >> "$td/in.c"; done
  # -dM dumps all defines after preprocessing.  -isystem (NOT -nostdinc:
  # glibc headers `#include_next <limits.h>` etc., which need the
  # compiler's own resource headers - those are identical for ref+working
  # since it's the same cross cc, so they cancel in the diff).  Drop the
  # compiler/internal builtins (^_, GNUC/STDC family) - we want libc
  # macros, not toolchain identity.  Key = token after `#define ` up to
  # the first space (includes `(args)` for function-like macros).
  "$CROSS_CC" -E -dM -O2 -isystem "$root/include" -x c "$td/in.c" 2>/dev/null \
    | grep -E '^#define [A-Za-z]' \
    | grep -vE '^#define (__|_[A-Z]|GNUC|STDC|GXX)' \
    | sed -E 's/^#define ([^ ]+) ?/\1\t/' \
    | LC_ALL=C sort
}
gen "$REF"  > "$td/ref"
gen "$WORK" > "$td/wrk"
[ -s "$td/ref" ] || { echo "SKIP 10-macros-public - could not preprocess umbrella"; exit 0; }

# Changed VALUE on a macro present in both = the dangerous case.
changed="$(awk -F'\t' 'NR==FNR { v[$1] = $2; next }
                       ($1 in v) && v[$1] != $2 { print $1": "v[$1]" -> "$2 }' \
           "$td/ref" "$td/wrk")"
# A removed public macro is a source-API change, not a binary-ABI break:
# #defines are constant-folded into callers, so nothing in libgcc_s /
# libstdc++ or already-built userland binds to one.  Report for review,
# never fatal - else a routine upstream header cleanup on the moving
# working branch trips the gate against the frozen reference tag (e.g. the
# 2.43 branch commenting out the non-compilable PF_LINK/AF_LINK defines).
# A genuine source break surfaces as a userland build failure anyway.
removed="$(comm -23 <(cut -f1 "$td/ref") <(cut -f1 "$td/wrk"))"

rc=0
if [ -n "$changed" ]; then
  echo "FAIL 10-macros-public - public macro value(s) changed:"
  printf '       - %s\n' $(printf '%s\n' "$changed" | head -25)
  rc=1
else
  n_rm="$(printf '%s' "$removed" | grep -c . || true)"
  echo "PASS 10-macros-public - no public macro value changes (removed: ${n_rm:-0}, review-only)"
fi
# Removals are review-only (see above): list them whether or not the gate failed.
if [ -n "$removed" ]; then
  echo "       note: public macro(s) removed (source-API only, review): $(printf '%s ' $(printf '%s\n' "$removed" | head -25))"
fi
exit "$rc"
