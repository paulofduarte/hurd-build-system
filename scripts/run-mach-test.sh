#!/usr/bin/env bash
#
# Run a single gnumach kernel test under QEMU, bypassing the
# grub-mkrescue / ISO step that gnumach's upstream test harness
# (tests/user-qemu.mk) requires.
#
# Loads the kernel directly via QEMU's -kernel option and the test
# module via the native multiboot1 / guest-loader path:
#
#   x86_64, i686  qemu-system-<arch> -kernel KERNEL -initrd "MODULE ARGS"
#                 (multiboot1 via SeaBIOS-free direct boot)
#   aarch64       qemu-system-aarch64 -kernel KERNEL
#                                     -device guest-loader,file=MODULE,...
#                 (synthesises /chosen/multiboot,module DTB nodes that
#                  aarch64's model_dep.c reads — same path used by the
#                  hand-run boot tests during the v2 re-port)
#
# Why bypass GRUB at all?  Two reasons.
#   * grub-mkrescue isn't available everywhere.  nixpkgs doesn't ship
#     it on darwin, and on aarch64-linux ships only the arm64-efi
#     target — neither produces an ISO that SeaBIOS can boot.
#   * The kernel tests test the kernel, not GRUB.  Direct -kernel boot
#     is faster, more portable, and removes 5 layers of indirection.
#
# Watches QEMU's serial output for gnumach's existing success/failure
# markers; writes a per-test raw log next to the kernel build dir
# (matching the location gnumach's own harness used) for post-run
# inspection.
#
# Usage: scripts/run-mach-test.sh <test_name> <target> [<timeout_sec>]
#
# Expects GNUMACH_BUILD in the environment, pointing at the gnumach
# build dir.  Exits 0 on PASS; non-zero on FAIL (with a short reason
# on stderr).

set -u

usage() {
    echo "usage: $0 <test_name> <target> [<timeout_sec>]" >&2
    exit 2
}

[ $# -ge 2 ] && [ $# -le 3 ] || usage

test_name=$1
target=$2
timeout_sec=${3:-60}

: "${GNUMACH_BUILD:?GNUMACH_BUILD must point at the gnumach build dir}"

kernel="$GNUMACH_BUILD/gnumach"
module="$GNUMACH_BUILD/tests/module-$test_name"
log="$GNUMACH_BUILD/tests/test-$test_name.raw"

# Markers gnumach's tests/testlib.c emits via the serial console.
# Keep these in sync with tests/user-qemu.mk's TEST_START_MARKER /
# TEST_SUCCESS_MARKER / TEST_FAILURE_MARKER.
start_marker="booting-start-of-test"
success_marker="gnumach-test-success-and-reboot"
failure_marker="gnumach-test-failure"

# Console route: same as the GRUB-based path passes via the kernel
# command line (com0 = first PC UART on x86, PL011 on aarch64 virt).
gnumach_args="console=com0"

[ -f "$kernel" ] || { echo "$test_name: missing kernel $kernel" >&2; exit 2; }
[ -f "$module" ] || { echo "$test_name: missing module $module" >&2; exit 2; }

case "$target" in
    x86_64)
        cmd=(qemu-system-x86_64
             -m 256 -nographic -no-reboot -cpu core2duo-v1
             -kernel "$kernel"
             -append "$gnumach_args"
             -initrd "$module $gnumach_args")
        ;;
    i686)
        cmd=(qemu-system-i386
             -m 256 -nographic -no-reboot -cpu pentium3-v1
             -kernel "$kernel"
             -append "$gnumach_args"
             -initrd "$module $gnumach_args")
        ;;
    aarch64)
        cmd=(qemu-system-aarch64
             -M virt -cpu cortex-a72 -m 256 -nographic -no-reboot
             -kernel "$kernel"
             -device "guest-loader,file=$module,bootargs=$gnumach_args")
        ;;
    *)
        echo "$0: unsupported target '$target'" >&2
        exit 2
        ;;
esac

# Run QEMU, capturing serial to the log.  --foreground keeps SIGINT
# forwarded so Ctrl-C still works during long TCG runs; --kill-after
# escalates to SIGKILL if QEMU ignores the initial SIGTERM.
rc=0
timeout --foreground --kill-after=3 "${timeout_sec}s" "${cmd[@]}" >"$log" 2>&1 || rc=$?

if grep -qi "$failure_marker" "$log"; then
    echo "$test_name: FAIL (failure marker emitted)" >&2
    exit 99
fi

if grep -q "$success_marker" "$log"; then
    exit 0
fi

# No success marker and no explicit failure: either we hit the timeout
# (TCG hosts are slow), or the kernel crashed before producing it.
if [ "$rc" -eq 124 ]; then
    echo "$test_name: FAIL (timeout after ${timeout_sec}s)" >&2
    exit 10
fi
echo "$test_name: FAIL (no success marker, qemu exit=$rc — kernel crash?)" >&2
exit 12
