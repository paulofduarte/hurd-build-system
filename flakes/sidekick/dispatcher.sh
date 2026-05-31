#!/bin/busybox sh
# Generic sidekick dispatcher — PID 1 in the Debian helper VM.  The VM is
# dumb: it runs host-supplied commands/scripts; all logic lives host-side
# (flakes/run + the ABI gate).  See .claude/docs/build/SIDEKICK-DISPATCHER.md.
#
# Two modes (kernel cmdline SIDEKICK_MODE=):
#   oneshot  run /shared/run.sh once (host staged it + any -drive), capture
#            rc to /shared/run.rc, power off.  Used by overlay-kernel/mkiso.
#   serve    warm command loop: execute queued requests from /shared/q and
#            self-power-off after `keepalive` seconds of inactivity.  Used by
#            the ABI tools (abidiff/pahole) — one boot, many fast dispatches.
bb() { /bin/busybox "$@"; }

# Install busybox applet symlinks (uname, head, awk, mount, insmod, …) into
# /bin — Debian's busybox .deb ships no postinst, so we do it ourselves.
# Must come first; host-supplied scripts expect the usual coreutils names.
/bin/busybox --install -s /bin 2>/dev/null

bb mount -t proc     proc /proc 2>/dev/null
bb mount -t sysfs    sys  /sys  2>/dev/null
bb mount -t devtmpfs dev  /dev  2>/dev/null
bb mkdir -p /shared /mnt /tmp

# 9p-over-virtio stack (decompressed Alpine modules, dependency order).
for ko in /mods/*.ko; do bb insmod "$ko" 2>/dev/null; done
bb mount -t 9p -o trans=virtio,version=9p2000.L shared /shared 2>/dev/null \
  || { echo "FATAL: 9p mount failed" >&2; bb poweroff -f; }

# Optional read-only /nix/store mount (mount_tag=nixstore) so tool
# arguments that are store paths resolve verbatim in the VM — the host
# shim ships `abidiff /nix/store/…/libc.so.0.3 …` unchanged.  Absent for
# ops that don't need it (overlay-kernel/mkiso stage their inputs in /shared).
if bb grep -q nixstore /proc/mounts 2>/dev/null; then :; else
  bb mkdir -p /nix/store 2>/dev/null
  bb mount -t 9p -o trans=virtio,version=9p2000.L,ro nixstore /nix/store 2>/dev/null || true
fi

# Debian glibc multiarch lib paths (no ld.so.cache generated) + tool PATH.
export LD_LIBRARY_PATH=/lib/x86_64-linux-gnu:/usr/lib/x86_64-linux-gnu
export PATH=/usr/bin:/usr/sbin:/bin:/sbin

mode=serve
for a in $(bb cat /proc/cmdline 2>/dev/null); do
  case "$a" in SIDEKICK_MODE=*) mode=${a#SIDEKICK_MODE=} ;; esac
done

if [ "$mode" = oneshot ]; then
  if [ -f /shared/run.sh ]; then
    bb sh /shared/run.sh > /shared/run.out 2>&1; echo $? > /shared/run.rc
  else
    echo "FATAL: oneshot but /shared/run.sh missing" > /shared/run.out; echo 127 > /shared/run.rc
  fi
  bb sync; bb poweroff -f
fi

# ---- serve (warm) ----------------------------------------------------
# Protocol over the 9p dir /shared/q:
#   host writes  <seq>.cmd  (a shell snippet) then  <seq>.ready
#   VM   runs it, writes    <seq>.out / <seq>.err / <seq>.rc, then <seq>.done
# Inactivity timer = keepalive seconds (host seeds /shared/keepalive and may
# raise it; honour the highest).  Coarse 1s poll keeps busybox-sh simple.
bb mkdir -p /shared/q
ka=$(bb cat /shared/keepalive 2>/dev/null); [ -n "$ka" ] || ka=60
: > /shared/.ready    # host waits for this before sending
idle=0
while :; do
  did=0
  for ready in /shared/q/*.ready; do
    [ -e "$ready" ] || continue
    seq=$(bb basename "$ready" .ready)
    nk=$(bb cat /shared/keepalive 2>/dev/null); [ -n "$nk" ] && [ "$nk" -gt "$ka" ] 2>/dev/null && ka=$nk
    bb sh "/shared/q/$seq.cmd" > "/shared/q/$seq.out" 2>"/shared/q/$seq.err"
    echo $? > "/shared/q/$seq.rc"
    bb rm -f "$ready"; bb sync; : > "/shared/q/$seq.done"
    did=1; idle=0
  done
  if [ "$did" = 0 ]; then
    idle=$((idle + 1))
    [ "$idle" -ge "$ka" ] && break
    bb sleep 1
  fi
done
bb sync; bb poweroff -f
