#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Paulo Duarte <paulofernandobd@gmail.com>
# SPDX-License-Identifier: GPL-3.0-or-later
# sidekick-run — transparently run a Linux-only build tool inside the sidekick
# microVM (darwin host) as if it were native: argv + stdin/stdout/stderr + exit
# code + a determinism-relevant env whitelist are all forwarded over SSH-on-vsock.
#
#   sidekick-run <tool> [args...]
#
# The VM is booted on first use (one per host, lock-guarded) and reused warm via
# an SSH ControlMaster; it powers ITSELF off when idle (the monitor lives in the
# guest — see flakes/sidekick/guest.nix — so nothing runs on the host). Nothing
# host-specific is baked into the guest: the project path and a dedicated throwaway
# pubkey are injected on the kernel cmdline at boot.
#
# All @tokens@ are substituted by flakes/sidekick/host.nix at build time.
set -euo pipefail

VFKIT='@vfkit@'
SOCAT='@socat@'
SSH='@ssh@'
SSHKEYGEN='@sshkeygen@'
ART='@artifacts@' # dir with kernel, initrd, store.img, cmdline

die() {
  echo "sidekick-run: $*" >&2
  exit 1
}

[ "$#" -ge 1 ] || die "usage: sidekick-run <tool> [args...]  |  --status  |  --stop"

# Project root = the virtiofs share root, mounted host-identically in the guest.
PROJECT="${SIDEKICK_PROJECT:-$(git rev-parse --show-toplevel 2>/dev/null || true)}"
[ -n "$PROJECT" ] || die "cannot determine project root (set SIDEKICK_PROJECT or run inside the repo)"

CTL="$PROJECT/work/sidekick"
mkdir -p "$CTL"
SSH_SOCK="$CTL/ssh-vsock.sock"
CTL_SOCK="$CTL/vfkit.sock"
BOOTLOG="$CTL/boot.log"
PIDFILE="$CTL/vfkit.pid"
KEY="$CTL/id_ed25519"
MUX="$CTL/ssh-mux"

ssh_opts=(
  -F none # ignore the host's ~/.ssh/config (e.g. macOS-only UseKeychain) entirely
  -o StrictHostKeyChecking=no
  -o UserKnownHostsFile=/dev/null
  -o LogLevel=ERROR
  -o ConnectTimeout=10
  -o ControlMaster=auto
  -o "ControlPath=$MUX"
  -o ControlPersist=60 # warm-reuse window; guest self-poweroff handles real idle
  -o "ProxyCommand=$SOCAT - UNIX-CONNECT:$SSH_SOCK"
  -i "$KEY"
)

vm_alive() {
  [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null && [ -S "$SSH_SOCK" ]
}

# vfkit VMs belonging to THIS checkout — matched by our unique control-socket
# path, which only the launcher carries (in --restful-uri). Used to reap orphans
# so the VM is a strict singleton.
our_vms() { pgrep -f -- "$CTL_SOCK" 2>/dev/null; }

rest_stop() {
  # vfkit REST: POST /vm/state {"state":"Stop"} (needs proper HTTP framing).
  [ -S "$CTL_SOCK" ] || return 0
  local body='{"state":"Stop"}'
  printf 'POST /vm/state HTTP/1.0\r\nContent-Type: application/json\r\nContent-Length: %s\r\n\r\n%s' \
    "${#body}" "$body" | "$SOCAT" - "UNIX-CONNECT:$CTL_SOCK" >/dev/null 2>&1 || true
}

boot_vm() {
  # Critical section: only one booter at a time. macOS has no flock(1), so use an
  # atomic mkdir lock with stale-holder steal (boots are quick + rare).
  local lockd="$CTL/lock.d" waited=0
  while ! mkdir "$lockd" 2>/dev/null; do
    if [ -f "$lockd/pid" ] && ! kill -0 "$(cat "$lockd/pid" 2>/dev/null)" 2>/dev/null; then
      rm -rf "$lockd"
      continue
    fi
    vm_alive && return 0 # another booter won the race
    sleep 0.2
    waited=$((waited + 1))
    [ "$waited" -gt 600 ] && die "timed out waiting for the boot lock"
  done
  echo $$ >"$lockd/pid"
  trap 'rm -rf "$lockd"' RETURN
  vm_alive && return 0

  rm -f "$SSH_SOCK" "$CTL_SOCK" "$BOOTLOG"
  # Singleton: vm_alive was false, so any vfkit still on our sockets is a stale
  # orphan (crashed dispatcher / killed shell). Reap it before launching one.
  for p in $(our_vms); do kill "$p" 2>/dev/null || true; done
  [ -f "$KEY" ] || "$SSHKEYGEN" -t ed25519 -N '' -C sidekick -f "$KEY" >/dev/null 2>&1
  local authkey cmdline
  authkey=$(base64 <"$KEY.pub" | tr -d '\n')
  cmdline="$(cat "$ART/cmdline") sidekick.project=$PROJECT sidekick.authkey=$authkey"

  "$VFKIT" \
    --cpus 2 --memory 2048 \
    --bootloader "linux,kernel=$ART/kernel,initrd=$ART/initrd,cmdline=\"$cmdline\"" \
    --device virtio-rng \
    --device "virtio-blk,path=$ART/store.img,readonly" \
    --device "virtio-fs,sharedDir=$PROJECT,mountTag=project" \
    --device "virtio-serial,logFilePath=$BOOTLOG" \
    --device "virtio-vsock,port=2222,socketURL=$SSH_SOCK,connect" \
    --restful-uri "unix://$CTL_SOCK" >>"$BOOTLOG" 2>&1 &
  echo $! >"$PIDFILE"

  # Wait for the vsock ssh socket, then for sshd to actually answer.
  for _ in $(seq 1 120); do
    [ -S "$SSH_SOCK" ] && break
    kill -0 "$(cat "$PIDFILE")" 2>/dev/null || {
      tail -20 "$BOOTLOG" >&2
      die "vfkit exited during boot"
    }
    sleep 0.5
  done
  for _ in $(seq 1 80); do
    "$SSH" "${ssh_opts[@]}" sidekick@sidekick true 2>/dev/null && break
    sleep 0.5
  done
  "$SSH" "${ssh_opts[@]}" sidekick@sidekick true 2>/dev/null || {
    tail -30 "$BOOTLOG" >&2
    die "sshd-over-vsock never came up"
  }
}

# Management subcommands (no VM boot).
case "${1:-}" in
  --status)
    if vm_alive; then
      p=$(cat "$PIDFILE")
      printf 'sidekick: UP — sidekick-vm pid %s (up %s)\n' \
        "$p" "$(ps -o etime= -p "$p" 2>/dev/null | tr -d ' ')"
    else
      echo "sidekick: down"
    fi
    exit 0
    ;;
  --stop)
    rest_stop # may already power it off, leaving the pid dead
    sleep 2
    { [ -f "$PIDFILE" ] && kill "$(cat "$PIDFILE")" 2>/dev/null; } || true
    for p in $(our_vms); do kill "$p" 2>/dev/null || true; done
    rm -f "$PIDFILE" "$SSH_SOCK" "$CTL_SOCK" "$MUX"
    echo "sidekick: stopped"
    exit 0
    ;;
esac

vm_alive || boot_vm

# Build the remote command: cd to the caller's cwd (identical path via virtiofs),
# forward a determinism-relevant env whitelist, exec the tool with exact argv.
remote_cwd=$(printf '%q' "$PWD")
env_prefix=""
for v in SOURCE_DATE_EPOCH TZ LANG LC_ALL LC_COLLATE LC_CTYPE LANGUAGE; do
  if [ -n "${!v:-}" ]; then
    env_prefix+="$(printf '%s=%q ' "$v" "${!v}")"
  fi
done
argv=""
for a in "$@"; do argv+="$(printf '%q ' "$a")"; done

exec "$SSH" "${ssh_opts[@]}" sidekick@sidekick \
  "cd $remote_cwd && exec env $env_prefix$argv"
