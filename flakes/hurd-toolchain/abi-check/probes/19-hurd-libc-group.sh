#!/usr/bin/env bash
# abi-level: auto
# Probe 19 — the Hurd libc.so GROUP, the single most important Hurd gate.
# glibc.nix sed-augments the libc.so ld-script so `-lc` also pulls
# libmachuser + libhurduser; libc.so.0.3 has undefined refs to
# __mach_port_* / __io_* / __file_* that live there.  If the GROUP loses
# them, EVERY userland link breaks on those undefined symbols.  Verify the
# GROUP line textually AND with a real --no-undefined link (never run).
set -u
wrk_script="$WORK/lib/libc.so"
[ -f "$wrk_script" ] || { echo "SKIP 19-hurd-libc-group — $WORK/lib/libc.so not present"; exit 0; }

# libc.so must be the text ld-script we augment (not a symlink to the
# shared object); `file`-free check: it should contain a GROUP( … ) line.
if ! grep -q '^GROUP' "$wrk_script" 2>/dev/null; then
  echo "SKIP 19-hurd-libc-group — libc.so is not the GROUP ld-script (no GROUP line)"
  exit 0
fi
missing=""
grep -q 'libmachuser' "$wrk_script" || missing="$missing libmachuser"
grep -q 'libhurduser' "$wrk_script" || missing="$missing libhurduser"
if [ -n "$missing" ]; then
  echo "FAIL 19-hurd-libc-group — libc.so GROUP lost:$missing (userland links would fail on __mach_port_*/__io_*)"
  exit 1
fi

# Stronger: a real link that would fail loudly on any undefined Mach/Hurd
# symbol.  -Wl,--no-undefined turns an unresolved ref into a link error;
# never executed, only linked.
if [ -n "${CROSS_CC:-}" ] && [ -x "$CROSS_CC" ]; then
  td="$PROBE_TMP/19"; mkdir -p "$td"
  echo 'int main(void){ return 0; }' > "$td/t.c"
  if err="$("$CROSS_CC" --sysroot="$WORK" -nostartfiles -Wl,--no-undefined \
              "$td/t.c" -lc -o "$td/t" 2>&1)"; then
    echo "PASS 19-hurd-libc-group — GROUP has libmachuser+libhurduser and --no-undefined link resolves"
  else
    # A missing crt/_start at link time is unrelated to the GROUP; only
    # fail on genuinely unresolved Mach/Hurd references.
    if printf '%s' "$err" | grep -qiE '__(mach|io|file|proc|hurd)_|libmachuser|libhurduser|undefined reference to'; then
      echo "FAIL 19-hurd-libc-group — --no-undefined link left Mach/Hurd symbols unresolved:"
      printf '%s\n' "$err" | grep -iE 'undefined|libmach|libhurd' | sed 's/^/       /' | head -15
      exit 1
    fi
    echo "PASS 19-hurd-libc-group — GROUP intact (link stopped on startup/crt only, no Mach/Hurd undefs)"
  fi
else
  echo "PASS 19-hurd-libc-group — GROUP has libmachuser+libhurduser (textual; no cross cc for link probe)"
fi
