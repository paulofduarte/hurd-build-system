# SPDX-FileCopyrightText: 2026 Paulo Duarte <paulofernandobd@gmail.com>
# SPDX-License-Identifier: GPL-3.0-or-later
# shellcheck shell=bash
# Host-side dispatch to the sidekick VM - sourced by the ABI gate (warm
# `serve`) and the run apps (`oneshot`).  See SIDEKICK-DISPATCHER.md.
# Needs in env: SIDEKICK_KERNEL, SIDEKICK_INITRD; qemu-system-x86_64 on PATH.
#
# Two ways in:
#   warm:   sk_serve_start <ctl> [keepalive]; sk_send <ctl> argv...; sk_serve_stop <ctl>
#           one boot, many fast dispatches; /nix/store is 9p-mounted ro in
#           the VM so store-path args resolve verbatim (transparent shims).
#   oneshot: sk_oneshot <ctl> [extra qemu args...]   (runs <ctl>/run.sh once)

_sk_qemu() {
  qemu-system-x86_64 -nographic -m 512 -no-reboot \
    -kernel "$SIDEKICK_KERNEL" -initrd "$SIDEKICK_INITRD" "$@"
}

# POSIX single-quote one argument so the VM's busybox sh re-parses it exactly.
_sk_q() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }

# ---- warm serve --------------------------------------------------------
sk_serve_start() { # $1 ctldir  $2 keepalive(s)
  local ctl="$1" ka="${2:-60}"
  mkdir -p "$ctl/q"
  printf '%s' "$ka" >"$ctl/keepalive"
  rm -f "$ctl/.ready" "$ctl/.seq"
  _sk_qemu -append "console=ttyS0 loglevel=3 SIDEKICK_MODE=serve" \
    -virtfs "local,path=$ctl,mount_tag=shared,security_model=none,id=shared" \
    -virtfs "local,path=/nix/store,mount_tag=nixstore,security_model=none,readonly=on,id=nixstore" \
    >"$ctl/.qemu.log" 2>&1 &
  echo $! >"$ctl/.qpid"
  local t=0
  while [ ! -e "$ctl/.ready" ]; do
    sleep 0.2
    t=$((t + 1))
    kill -0 "$(cat "$ctl/.qpid" 2>/dev/null)" 2>/dev/null ||
      {
        echo "sidekick: serve VM exited before ready" >&2
        cat "$ctl/.qemu.log" >&2
        return 1
      }
    [ "$t" -gt 900 ] && {
      echo "sidekick: serve VM ready timeout" >&2
      cat "$ctl/.qemu.log" >&2
      return 1
    }
  done
  return 0 # the loop's last body cmd is the -gt test (rc 1); say success explicitly
}

sk_send() { # $1 ctldir ; rest: argv - run in VM, relay stdout/stderr, return its rc
  local ctl="$1"
  shift
  local seq
  seq=$(($(cat "$ctl/.seq" 2>/dev/null || echo 0) + 1))
  echo "$seq" >"$ctl/.seq"
  local cmd="" a
  for a in "$@"; do cmd="$cmd $(_sk_q "$a")"; done
  printf '%s\n' "$cmd" >"$ctl/q/$seq.cmd"
  : >"$ctl/q/$seq.ready"
  while [ ! -e "$ctl/q/$seq.done" ]; do
    sleep 0.1
    kill -0 "$(cat "$ctl/.qpid" 2>/dev/null)" 2>/dev/null ||
      {
        echo "sidekick: serve VM died mid-request" >&2
        return 125
      }
  done
  [ -f "$ctl/q/$seq.out" ] && cat "$ctl/q/$seq.out"
  [ -f "$ctl/q/$seq.err" ] && cat "$ctl/q/$seq.err" >&2
  local rc
  rc=$(cat "$ctl/q/$seq.rc" 2>/dev/null || echo 125)
  rm -f "$ctl/q/$seq".cmd "$ctl/q/$seq".out "$ctl/q/$seq".err "$ctl/q/$seq".rc "$ctl/q/$seq".done "$ctl/q/$seq".ready
  return "$rc"
}

sk_serve_stop() { # $1 ctldir
  kill "$(cat "$1/.qpid" 2>/dev/null)" 2>/dev/null || true
}

# ---- oneshot -----------------------------------------------------------
sk_oneshot() { # $1 ctldir (must contain run.sh) ; rest: extra qemu args (e.g. -drive ...)
  local ctl="$1"
  shift
  rm -f "$ctl/run.rc" "$ctl/run.out"
  _sk_qemu -append "console=ttyS0 loglevel=3 SIDEKICK_MODE=oneshot" \
    -virtfs "local,path=$ctl,mount_tag=shared,security_model=none,id=shared" \
    "$@" >"$ctl/.qemu.log" 2>&1
  cat "$ctl/run.rc" 2>/dev/null || echo 125
}
