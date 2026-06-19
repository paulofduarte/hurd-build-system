#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Paulo Duarte <paulofernandobd@gmail.com>
# SPDX-License-Identifier: GPL-3.0-or-later
# Dispatch one command to the warm sidekick (control dir = $SK_CTL), relay
# its stdout/stderr, and exit with its return code.  This is the canonical
# send used by the transparent tool shims (abidiff/pahole/...): each shim is
#   #!/bin/sh
#   exec /path/sidekick-send <tool> "$@"
# so callers run the tool natively while it actually executes in the VM,
# with /nix/store 9p-mounted so path args resolve verbatim.  The warm VM is
# started/stopped by the lib's sk_serve_start/sk_serve_stop (sidekick-dispatch.sh).
set -u
ctl="${SK_CTL:?sidekick-send: SK_CTL not set}"

seq=$(($(cat "$ctl/.seq" 2>/dev/null || echo 0) + 1))
echo "$seq" >"$ctl/.seq"

_q() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }
cmd=""
for a in "$@"; do cmd="$cmd $(_q "$a")"; done
printf '%s\n' "$cmd" >"$ctl/q/$seq.cmd"
: >"$ctl/q/$seq.ready"

while [ ! -e "$ctl/q/$seq.done" ]; do
  sleep 0.1
  if [ -f "$ctl/.qpid" ] && kill -0 "$(cat "$ctl/.qpid")" 2>/dev/null; then :; else
    echo "sidekick-send: serve VM is gone" >&2
    exit 125
  fi
done

[ -f "$ctl/q/$seq.out" ] && cat "$ctl/q/$seq.out"
[ -f "$ctl/q/$seq.err" ] && cat "$ctl/q/$seq.err" >&2
rc=$(cat "$ctl/q/$seq.rc" 2>/dev/null || echo 125)
rm -f "$ctl/q/$seq".cmd "$ctl/q/$seq".out "$ctl/q/$seq".err "$ctl/q/$seq".rc "$ctl/q/$seq".done "$ctl/q/$seq".ready
exit "$rc"
