#!/usr/bin/env bash
# SCENARIO=hurd-debian — Debian Hurd userland; direct-inject of our kernel.
# Debian publishes standalone multiboot modules in the disk-image dir,
# so we bypass GRUB entirely: -kernel <ours> + -initrd <theirs> + -drive.
set -euo pipefail
. "$(dirname "$0")/lib/common.sh"
. "$(dirname "$0")/lib/arch-flags.sh"
. "$(dirname "$0")/lib/hurd-common.sh"
. "$(dirname "$0")/lib/sidekick.sh"   # for x86_64 inject (mkiso path)

scenario_check_target "hurd-debian" "x86_64 i686"
arch_qemu_for_target "$TARGET"
arch_apply_accel_if_requested

extra_qemu_args=("$@")   # capture RUN_ARGS pass-through

case "$TARGET" in
  x86_64) url="$HURD_DEBIAN_X86_64_URL" ;;
  i686)   url="$HURD_DEBIAN_I686_URL" ;;
esac

cache="$(hurd_cache_dir debian "$TARGET")"
hurd_fetch_once "$url" "$cache/debian-hurd.img.tar.gz"

# The tarball contains a DATED .img file (e.g. `debian-hurd-i386-20260314.img`)
# matching the dated tarball it redirects to — NOT a generic `debian-hurd.img`.
# Peek inside before extracting so we know which name to expect.
img_name=$(tar -tzf "$cache/debian-hurd.img.tar.gz" | grep -E '\.img$' | head -1)
[ -n "$img_name" ] || die "debian-hurd.img.tar.gz contains no *.img file (layout changed?)"
[ -f "$cache/$img_name" ] || tar -xzf "$cache/debian-hurd.img.tar.gz" -C "$cache"

overlay="$cache/overlay.qcow2"
hurd_make_overlay "$cache/$img_name" "$overlay" raw

# Vanilla path: let Debian's GRUB boot the bundled kernel.
# $QEMU_MACHINE expanded unquoted so RUN_ACCEL=1's "-accel hvf/kvm" propagates;
# empty in the no-accel default case (Debian has no per-scenario machine override).
hurd_maybe_vanilla_exec "$QEMU" -nographic -m "$QEMU_MEM" $QEMU_MACHINE -cpu "$QEMU_CPU" \
  -drive file="$overlay",format=qcow2,if=ide \
  "${extra_qemu_args[@]}"

# i686 and x86_64 use different boot models — full details in
# .claude/docs/HURD-BOOT-CHAINS.md.  Per-module args reach gnumach
# literally; bash escapes (\${...}, \$(...)) prevent shell expansion.
case "$TARGET" in
  i686)
    # Static-exec, in-kernel disk driver.  Standalone modules from
    # Debian's URL; root on hd0s2 (hd0s1=swap, verified empirically).
    debian_base="$(dirname "$url")"
    hurd_fetch_once "$debian_base/ext2fs.static" "$cache/ext2fs.static"
    hurd_fetch_once "$debian_base/exec.static"   "$cache/exec.static"

    modules="$cache/ext2fs.static --multiboot-command-line=\${kernel-command-line} --host-priv-port=\${host-port} --device-master-port=\${device-port} --exec-server-task=\${exec-task} -T typed \${root} \$(task-create) \$(task-resume),$cache/exec.static \$(exec-task=task-create)"
    cmdline="root=device:hd0s2 console=$QEMU_CONSOLE"
    ;;

  x86_64)
    # Dynamic-exec, userland rumpdisk.  5-module chain extracted from
    # the disk image (Debian doesn't publish them standalone).  Loader
    # is /lib/ld-x86-64.so.1 — NOT /lib/ld.so.1 (that path is i386).
    extracted="$cache/extracted-amd64"
    sidekick_extract "$cache/$img_name" "$extracted" \
      "hurd/pci-arbiter.static hurd/acpi.static hurd/rumpdisk.static hurd/ext2fs.static lib/ld-x86-64.so.1"
    for m in pci-arbiter.static acpi.static rumpdisk.static ext2fs.static ld-x86-64.so.1; do
      [ -s "$extracted/$m" ] || die "amd64 module missing after sidekick extract: $m"
    done

    # Chain verbatim from Debian's amd64 grub.cfg.  Each module's
    # first arg after the file path is argv[0] (program name for the
    # .static modules; `exec` for ld.so to drive it into load-and-run
    # mode).  Only pci-arbiter has $(task-resume) — others wait for
    # --next-task=${X-task} handoffs.  ext2fs has no --host-priv-port
    # / --device-master-port (rumpdisk owns block I/O).
    modules="$extracted/pci-arbiter.static pci-arbiter --host-priv-port=\${host-port} --device-master-port=\${device-port} --next-task=\${acpi-task} \$(pci-task=task-create) \$(task-resume)"
    modules="$modules,$extracted/acpi.static acpi --next-task=\${disk-task} \$(acpi-task=task-create)"
    modules="$modules,$extracted/rumpdisk.static rumpdisk --next-task=\${fs-task} \$(disk-task=task-create)"
    modules="$modules,$extracted/ext2fs.static ext2fs --readonly --multiboot-command-line=\${kernel-command-line} --exec-server-task=\${exec-task} -T typed \${root} \$(fs-task=task-create)"
    modules="$modules,$extracted/ld-x86-64.so.1 exec /hurd/exec \$(exec-task=task-create)"

    # Modern part:N: syntax required — rumpdisk exposes only whole
    # disks; slice translation happens in storeio.  Legacy wd0sN
    # fails with "No such device or address" after rumpdisk attaches.
    cmdline="root=part:2:device:wd0 console=$QEMU_CONSOLE"
    ;;
esac

hurd_exec_with_our_kernel "$overlay" "$modules" "$cmdline" "${extra_qemu_args[@]}"
