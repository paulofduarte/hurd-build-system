# `make run` harness

Ad-hoc qemu launches against the kernel built by the parent
Makefile. Architecture comes from `TARGET`; scenario from `SCENARIO`.
See the parent `README.md` Run section for the user-facing matrix
and `make run-help` for the full cheat sheet.

This file is the developer reference: how the harness is structured,
how to add a scenario or distro, and the gotchas worth knowing before
you touch any of it.

## Layout

```
tools/run/
├── dispatch.sh             # entry point — validates env, exec's scenario
├── boot.sh                 # SCENARIO=boot: bare kernel (direct -kernel,
│                           #   or GRUB-on-ISO via sidekick for x86_64)
├── hurd-debian.sh          # SCENARIO=hurd-debian: kernel-overlay inject
├── hurd-gentoo.sh          # SCENARIO=hurd-gentoo: kernel-overlay inject
├── hurd-guix.sh            # SCENARIO=hurd-guix: kernel-overlay inject
├── README.md               # this file
└── lib/
    ├── common.sh           # die(), scenario_check_target(), print_qemu_hint()
    ├── arch-flags.sh       # arch_qemu_for_target(), arch_apply_accel_if_requested()
    ├── hurd-common.sh      # fetch/overlay/vanilla helpers (no exec — see below)
    └── sidekick.sh         # host-side sidekick-VM orchestrator
                            #   (overlay_kernel + prepare_grub + make_iso)
```

All three Hurd scenarios share the same shape: fetch the distro qcow2,
overlay our kernel into it via the sidekick (which also regenerates a
serial-clean grub.cfg from the disk's existing recipe), then boot it
with plain `qemu -drive`.  No more host-side `-kernel`/`-initrd`
construction or per-distro module-chain reverse engineering.

The sidekick helper VM itself lives in `tools/sidekick/` — see the
[Sidekick helper VM](#sidekick-helper-vm) section below.

## How a scenario script is shaped

Each scenario script is ~15-30 declarative lines: source the libs,
declare `supported_targets`, dispatch on `$TARGET`, call helpers.
`boot.sh` (~12 lines) is the minimal template; the Hurd scripts add
a fetch step and a vanilla/inject branch.

```sh
#!/usr/bin/env bash
set -euo pipefail
. "$(dirname "$0")/lib/common.sh"
. "$(dirname "$0")/lib/arch-flags.sh"
# (+ lib/hurd-common.sh / lib/sidekick.sh for Hurd scenarios)

scenario_check_target "<scenario-name>" "<space-separated TARGETs>"
arch_qemu_for_target "$TARGET"        # sets QEMU, QEMU_MACHINE, QEMU_CPU, QEMU_MEM, QEMU_CONSOLE
arch_apply_accel_if_requested         # may append -accel + override QEMU_CPU when RUN_ACCEL=1

extra_qemu_args=("$@")                # capture RUN_ARGS pass-through

# (optional) scenario-specific QEMU_MACHINE override, e.g.:
# QEMU_MACHINE="-M q35"

case "$TARGET" in ... esac             # pick URLs / paths

# (optional Hurd) vanilla-mode short-circuit:
# hurd_maybe_vanilla_exec "$QEMU" ...  "${extra_qemu_args[@]}"

exec "$QEMU" ... "${extra_qemu_args[@]}"
```

### Adding a new scenario

1. Drop `tools/run/<scenario>.sh` following the template above.
2. `chmod +x` it.
3. That's it — `dispatch.sh` discovers scenarios by `find`'ing executable
   `*.sh` files under `tools/run/`.  `make run SCENARIO=<scenario>` works
   immediately.  `--help` and "unknown scenario" listings update automatically.

If the scenario needs the sidekick helper VM (i.e., it reads modules
from a qcow2, or builds a GRUB ISO for x86_64 inject), also add its
name to the `sidekick` prereq filter in the parent Makefile's
`_RUN_PREREQS` expression.

### Adding a new distro + TARGET combo to an existing scenario

1. Add the URL to the parent Makefile (alongside the existing `HURD_*_URL`
   block).
2. Export it from the `run:` recipe (add a line to the env-vars block).
3. Add a case branch to the scenario script's `case "$TARGET" in …` block.
4. If the scenario supports a new TARGET, add it to the `supported_targets`
   string in the `scenario_check_target` call.

## Modifier flags

All env-style, all opt-in:

| Flag | Effect |
|---|---|
| `RUN_VANILLA=1` | Boot the distro's bundled kernel via internal GRUB (Hurd scenarios only — boot scenario ignores the flag) |
| `RUN_ACCEL=1` | Append `-accel hvf` (darwin) or `-accel kvm` (linux); requires host arch == `TARGET`, falls back to TCG with a warning otherwise |
| `RUN_KEEP_OVERLAY=1` | Reuse the per-run qcow2 overlay across invocations (state persists; default discards) |
| `RUN_ARGS="..."` | Extra flags appended to the qemu cmdline (e.g., `-s -S`, `-monitor stdio`, `-d int,cpu_reset`) |

### `RUN_ACCEL=1` — risks and compat matrix

This flag overrides the upstream-vetted pinned CPU model
(`pentium3-v1` / `core2duo-v1` / `cortex-a72`) with `-cpu host`,
exposing the full host CPU feature set to gnumach. **gnumach has
not been tested against arbitrary modern CPU features** (newer
SSE/AVX, MTE on Apple Silicon, etc.) — it may panic on unrecognized
CPUID flags or hit untested code paths. The safe upstream-aligned
TCG path is the default contract; acceleration is a "I want this to
go fast" override at your own risk.

If `RUN_ACCEL=1` produces a fresh gnumach panic that doesn't repro
under TCG, that's useful upstream-bug data — worth filing.

Compatibility matrix (host → accelerated targets):

| host    | i686 | x86_64 | aarch64 |
|---------|------|--------|---------|
| x86_64  | ✓    | ✓      | ✗       |
| i686    | ✓    | ✗      | ✗       |
| aarch64 | ✗    | ✗      | ✓       |

KVM/HVF on an x86_64 host accelerates both x86_64 and i686 guests
(32-bit is a subset of 64-bit, same `/dev/kvm`).  All other cross-ISA
combos fall back to TCG with a one-line warning.

## Sidekick helper VM

The sidekick is a small x86_64 Linux VM the harness uses for
operations darwin can't do natively (mounting/writing ext2 in a
qcow2, running `grub-mkrescue`). Two operations today:

- **`overlay-kernel`**: mount the attached qcow2 read-write,
  regenerate `/boot/grub/grub.cfg` from the distro's existing
  recipe (serial-clean, minimal, with our `console=com0`), and —
  if `/shared/kernel.bin` is present — overwrite the kernel file
  at the path discovered from grub.cfg's first multiboot line.
  Used by every Hurd scenario, in two modes:
  - **inject** (`sidekick_overlay_kernel`): kernel.bin is our
    gnumach; the overlay swaps it for the distro's bundled kernel.
  - **vanilla** (`sidekick_prepare_grub`): no kernel.bin; only
    the grub.cfg regen runs, so the distro's bundled kernel boots
    cleanly on serial.
- **`mkiso`**: assemble a GRUB-bootable ISO from a host-prepared
  staging dir + grub.cfg.  Used by `boot.sh` on x86_64, where
  qemu's `-kernel` rejects 64-bit ELFs (D18) and we wrap gnumach
  in a tiny ISO instead.

The `overlay-kernel` op also handles per-distro grub.cfg quirks:
flattens `configfile` indirection (Gentoo splits modules into
`entry_hurd.cfg`), preserves uppercase variable assignments in the
menuentry body (Gentoo's `DISK=wd0 PART=1 DISKOPT=noide`), and
joins backslash-continued module lines (Debian).

### How it's built

`tools/sidekick/default.nix` is a nix derivation (exposed as
`packages.<system>.sidekick` in the root flake) that:

1. `fetchurl`s pinned Alpine 3.21 x86_64 APKs (listed with sha256s
   in `tools/sidekick/packages.nix`) — kernel + busybox + kmod +
   e2fsprogs + grub + grub-bios + xorriso + mtools + their deps.
2. `tar` + `cpio` + `gzip` (POSIX-only tools, work on darwin) to
   unpack APKs into a rootfs, lay in our `/init` dispatcher, and
   pack the result as `initramfs.cpio.gz`.
3. Extract the kernel `bzImage` from `linux-virt-*.apk` to `vmlinuz`.

**No compilation happens during the build.** Every byte of the
output is either a pre-built Alpine binary or our `/init` script.
That's why the sidekick builds identically on darwin, linux,
aarch64, x86_64 — same Alpine APKs, same POSIX tools, same output.

Output paths after `make sidekick`:

- `toolchain/sidekick/vmlinuz` (~12 MB)
- `toolchain/sidekick/initramfs.cpio.gz` (~40 MB)

### `/init` dispatcher

`tools/sidekick/init.sh` is PID 1 inside the VM. It reads
`SIDEKICK_OP=` from the kernel cmdline and dispatches:

- `SIDEKICK_OP=overlay-kernel`: mount the first writable ext
  partition on `/dev/vd*`, run the grub.cfg regen (flatten
  `configfile` references, awk-extract `multiboot`/`module`/var
  lines from the first non-recovery menuentry, emit a minimal
  serial-clean cfg with our `console=com0` appended), and if
  `/shared/kernel.bin` exists, copy it (gzipped iff the discovered
  path ends in `.gz`) over the file at the disk's kernel path.
- `SIDEKICK_OP=mkiso`: read `/shared/iso-staging/` + `/shared/iso-grub.cfg`,
  run `grub-mkrescue`, write `/shared/out.iso`.

After the op completes, `/init` runs `poweroff -f`. The host's qemu
process exits, control returns to the scenario script, output files
(grub.cfg in place inside the overlay; ISO on the 9p share) are
ready to use.

### Why x86_64 even on aarch64 hosts

The sidekick is always x86_64 Linux regardless of host arch (per
design D13). The `qemu-system-x86_64` invocation hard-codes that.
Rationale:

- For `overlay-kernel`: busybox/awk/gzip + ext2/4 read+write —
  pure file ops, arch-agnostic.
- For `mkiso`: `grub-mkrescue` manipulates files — also arch-agnostic.
  The ISO it produces boots an x86/x86_64 gnumach (the only arches
  Hurd userland exists for today), so an x86 grub-bios is what we need.

Running qemu-system-x86_64 under TCG on aarch64 is ~5× slower than
native, but each op runs once per overlay and the result is cached
via per-overlay stamps. Acceptable.

### Refresh after Alpine version bumps

Bump versions + sha256s in `tools/sidekick/packages.nix`. Easiest
way: download the new APKs, run `shasum -a 256`, paste. Or write a
small `refresh-packages.sh` that walks the Alpine APKINDEX (we did
this once to seed the file; the resulting hashes are in git).

After any bump:

```sh
rm -rf toolchain/sidekick
make sidekick          # rebuilds + caches
```

## Gotchas

### Exiting qemu in `-nographic` mode

`Ctrl-A X` quits. `Ctrl-A C` switches to the QEMU monitor; `Ctrl-A H`
prints the full escape-prefix cheat sheet. Plain `Ctrl-C` is forwarded
to the guest, not to qemu — that's why it doesn't terminate the VM.

The harness prints a one-line hint to stderr right before exec'ing
qemu (via `print_qemu_hint` in `lib/common.sh`) and ALSO sets the
terminal title to "qemu · <scenario> · TARGET=<arch> · Ctrl-A X to
quit" using an OSC 0 escape sequence. The stderr hint scrolls away
quickly under heavy kernel output (a panic loop on `boot` floods in
sub-second); the title bar persists no matter how much the guest
prints.

### Cuirass `/search/latest/image` requires GET, not HEAD

Guix CI's auto-latest endpoint returns 404 to `HEAD` requests but
200 (with a redirect) to `GET`. `hurd_resolve_latest_target` uses
`curl -X GET --max-filesize 1` to follow the redirect without
downloading the body.

`--max-filesize 1` makes curl always exit 63 once it sees the
response body. Under `set -e` the caller would die before it could
inspect the resolved URL — `hurd_resolve_latest_target` ends in
`|| :` to eat that exit and lets the caller's case statement
classify the result.

### Guix x86_64 usually returns 500

Guix CI aggressively garbage-collects 64-bit `hurd64-barebones.qcow2`
artefacts. As of mid-2026, none of the 10 most recent successful
builds typically have a fetchable `/download/<id>` — the
`/search/latest/image` endpoint correctly returns 500.

The `hurd-guix.sh` script passes the GC-explanation hint as the 4th
arg to `hurd_fetch_via_resolve` only for `TARGET=x86_64`; on the
common 500 path, users see the explanation + the fallback hint
(use `TARGET=i686` instead) inline.

The `TARGET=i686` 32-bit path is reliably available.

### Gentoo's qcow2 URL is versionless

Gentoo publishes `hurd-i686-preview.qcow2` (and amd64 equivalent)
at a single rolling URL. If upstream publishes new content at the
same URL we silently keep the cached file — there's no
checksum-delta auto-refresh. To force a re-fetch:

```sh
rm -rf work/test-images/gentoo/<TARGET>/
```

A future enhancement could re-fetch the `.sha512` periodically and
compare against the cached one. Out of scope for the initial
implementation.

### `gnumach` (stripped image), NOT `gnumach.elf`

qemu's `-kernel` consumes the stripped boot image
(`$(WORK)/gnumach/<target>/gnumach`), not the un-stripped ELF
(`gnumach.elf` in the same dir). On aarch64, giving qemu the ELF
causes a silent hang — qemu can't parse it as a boot image. The
parent Makefile defines `GNUMACH_BOOT_IMAGE` separately from
`GNUMACH_KERNEL` (used as the build sentinel) for this reason.

### Vanilla mode + boot scenario

`RUN_VANILLA=1 SCENARIO=boot` is meaningless — there's no distro
kernel to fall back to. The `_RUN_PREREQS` expression in the parent
Makefile only drops the `mach` dependency for `RUN_VANILLA=1` +
Hurd scenarios, so boot still works in this case (just ignores the
vanilla flag). This guards against the cryptic qemu "could not load
kernel image" error from the alternative interpretation.

### Known image issues per scenario

- **`hurd-gentoo` + `TARGET=x86_64`** hangs in openrc's `servers`
  service after rumpdisk's rump kernel fails to attach the qemu
  e1000 NIC (`wm0`) — Gentoo's own wiki flags amd64 as "less stable
  so far than x86".  i686 boots cleanly.  Image bug, not a harness
  bug.  Comment in `hurd-gentoo.sh` for the full diagnosis.
- **`hurd-guix` + `-M q35`** boots correctly but the visible serial
  output stalls for ~3 minutes during gnumach's in-kernel SATA
  probe across q35's 6 empty ICH9-AHCI ports.  q35 is mandatory
  (Guix qcow2 won't boot on i440fx, tested), so the slow probe is
  the accepted cost.  Boot does eventually complete.
