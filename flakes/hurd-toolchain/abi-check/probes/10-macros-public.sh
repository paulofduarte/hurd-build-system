#!/usr/bin/env bash
# abi-level: auto
# Probe 10 — public macro VALUES.  errno/signal/O_*/RLIMIT_*/_SC_* and
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

gen() { # $1 = sysroot root → sorted "KEY<TAB>VALUE" macro map
  local root="$1" h
  : > "$td/in.c"
  for h in $umbrella; do [ -f "$root/include/$h" ] && echo "#include <$h>" >> "$td/in.c"; done
  # -dM dumps all defines after preprocessing.  -isystem (NOT -nostdinc:
  # glibc headers `#include_next <limits.h>` etc., which need the
  # compiler's own resource headers — those are identical for ref+working
  # since it's the same cross cc, so they cancel in the diff).  Drop the
  # compiler/internal builtins (^_, GNUC/STDC family) — we want libc
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
[ -s "$td/ref" ] || { echo "SKIP 10-macros-public — could not preprocess umbrella"; exit 0; }

# Changed VALUE on a macro present in both = the dangerous case.
changed="$(awk -F'\t' 'NR==FNR { v[$1] = $2; next }
                       ($1 in v) && v[$1] != $2 { print $1": "v[$1]" -> "$2 }' \
           "$td/ref" "$td/wrk")"
# A removed public macro can break `#ifdef`/use sites too.
removed="$(comm -23 <(cut -f1 "$td/ref") <(cut -f1 "$td/wrk"))"

rc=0
if [ -n "$changed" ]; then
  echo "FAIL 10-macros-public — public macro value(s) changed:"
  printf '       - %s\n' $(printf '%s\n' "$changed" | head -25)
  rc=1
fi
if [ -n "$removed" ]; then
  echo "FAIL 10-macros-public — public macro(s) removed: $(printf '%s ' $(printf '%s\n' "$removed" | head -25))"
  rc=1
fi
[ "$rc" -eq 0 ] && echo "PASS 10-macros-public — no public macro value/removal changes"
exit "$rc"
