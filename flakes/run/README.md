<!--
SPDX-FileCopyrightText: 2026 Paulo Duarte <paulofernandobd@gmail.com>
SPDX-License-Identifier: GPL-3.0-or-later
-->

# `make run` harness

Ad-hoc qemu launches against the kernel built by the parent
Makefile. Architecture comes from `ARCH`; scenario from `SCENARIO`.
See the parent `README.md` Run section for the user-facing matrix
and `make run-help` for the full cheat sheet.

This file is the developer reference: how the harness is structured,
how to add a scenario or distro, and the gotchas worth knowing before
you touch any of it.

## Layout

```
flakes/run/
|-- default.nix             # nix-app wrapper (per-arch writeShellApplication)
|-- dispatch.sh             # entry point - validates env, exec's scenario
|-- boot.sh                 # SCENARIO=boot: bare kernel wrapped in a GRUB ISO
|-- hurd-debian.sh          # SCENARIO=hurd-debian: external-ISO boot (option 1)
|-- hurd-gentoo.sh          # SCENARIO=hurd-gentoo: external-ISO boot (option 1)
|-- hurd-guix.sh            # SCENARIO=hurd-guix: external-ISO boot (option 1)
|-- README.md               # this file
`-- lib/
    |-- common.sh           # die(), scenario_check_target(), print_qemu_hint()
    |-- arch-flags.sh       # arch_qemu_for_target(), arch_apply_accel_if_requested()
    |-- distro-urls.sh      # HURD_*_URL definitions (sourced by Makefile + nix-app)
    |-- hurd-common.sh      # fetch/overlay/vanilla helpers (no exec - see below)
    `-- sidekick.sh         # host-side boot-ISO orchestrator
                            #   (make_iso + distro_iso, via the atomic tools)
```

All three Hurd scenarios share the same shape: fetch the distro qcow2,
build an external GRUB ISO from the disk's own grub.cfg (our gnumach, or
the distro's own for `--vanilla`; modules + root pulled from the
UNMODIFIED disk via `search --fs-uuid`), then boot it with the ISO as
`-cdrom` + a COW overlay as the disk. No in-place disk edit, no host-side
`-kernel`/`-initrd` construction.

The boot-ISO orchestration + the sidekick helper VM are described in the
[boot ISO (option 1)](#the-boot-iso-option-1-and-the-sidekick) section below.

## How a scenario script is shaped

Each scenario script is ~15-30 declarative lines: source the libs,
declare `supported_targets`, dispatch on `$ARCH`, call helpers.
`boot.sh` (~12 lines) is the minimal template; the Hurd scripts add
a fetch step and a vanilla/inject branch.

```sh
#!/usr/bin/env bash
set -euo pipefail
. "$(dirname "$0")/lib/common.sh"
. "$(dirname "$0")/lib/arch-flags.sh"
# (+ lib/hurd-common.sh / lib/sidekick.sh for Hurd scenarios)

scenario_check_target "<scenario-name>" "<space-separated ARCHs>"
arch_qemu_for_target "$ARCH"        # sets QEMU, QEMU_MACHINE, QEMU_CPU, QEMU_MEM, QEMU_CONSOLE
arch_apply_accel_if_requested         # may append -accel + override QEMU_CPU when RUN_ACCEL=1

extra_qemu_args=("$@")                # capture RUN_ARGS pass-through

# (optional) scenario-specific QEMU_MACHINE override, e.g.:
# QEMU_MACHINE="-M q35"

case "$ARCH" in ... esac             # pick URLs / paths

# (optional Hurd) vanilla-mode short-circuit:
# hurd_maybe_vanilla_exec "$QEMU" ...  "${extra_qemu_args[@]}"

exec "$QEMU" ... "${extra_qemu_args[@]}"
```

### Adding a new scenario

1. Drop `flakes/run/<scenario>.sh` following the template above.
1. `chmod +x` it.
1. That's it - `dispatch.sh` discovers scenarios by `find`'ing executable
   `*.sh` files in its own directory. `make run SCENARIO=<scenario>`
   works immediately. `--help` and "unknown scenario" listings update
   automatically.

The boot-ISO tools (`sidekick-imgcp` / `sidekick-mkrescue`) resolve on the
dev-shell PATH (native on Linux, `sidekick-run` shim on darwin), so a new
scenario needs no Makefile prereq for them; `_RUN_PREREQS` only carries the
`gnumach` build (skipped for `--vanilla`).

### Adding a new distro + ARCH combo to an existing scenario

1. Add the URL to the parent Makefile (alongside the existing `HURD_*_URL`
   block).
1. Export it from the `run:` recipe (add a line to the env-vars block).
1. Add a case branch to the scenario script's `case "$ARCH" in ...` block.
1. If the scenario supports a new ARCH, add it to the `supported_targets`
   string in the `scenario_check_target` call.

## Modifier flags

All opt-in. Either env-form (`RUN_VANILLA=1 make run ...`) or make
command-line form (`make run RUN_VANILLA=1 ...`) works - see *Dispatch
passthrough* below for why.

| Flag | Effect |
|---|---|
| `RUN_VANILLA=1` | Boot the distro's bundled kernel via internal GRUB (Hurd scenarios only - boot scenario ignores the flag) |
| `RUN_ACCEL=1` | Append `-accel hvf` (darwin) or `-accel kvm` (linux); requires host arch == `ARCH`, falls back to TCG with a warning otherwise |
| `RUN_KEEP_OVERLAY=N` | Keep + reuse overlay slot `N` across runs so state persists (integer >= 1, default 1 -> `overlay-N.qcow2`); without it each run discards a fresh `overlay.qcow2`. Invalid `N` aborts. `nix run` flag: `--keep-overlay[=N]` |
| `RUN_ARGS="..."` | Extra flags appended to the qemu cmdline (e.g., `-s -S`, `-monitor stdio`, `-d int,cpu_reset`) |

### Dispatch passthrough - adding a new env knob

`make run` dispatches through `nix develop -i .#$(ARCH)` to enter
the per-arch nix dev shell. The `-i` flag means "isolated" - the
inner shell starts with a clean env, so arbitrary env vars set by
the caller are wiped on the way in.

Two things survive:

1. **The dev-shell shellHook's exports.** Per-target nix shells
   re-export `ARCH`, `TARGET_CC`, `MIG_TARGET`, `CFLAGS`, etc. That's why `ARCH=i686 make run` works without
   needing explicit forwarding - the outer make parses `.#$(ARCH)`
   to select the shell, and the shell rebuilds the env.

1. **Variables explicitly forwarded by the dispatch recipe.** See
   `_RUN_PASSTHROUGH` in the parent `Makefile` - currently
   `SCENARIO`, `RUN_VANILLA`, `RUN_ACCEL`, `RUN_KEEP_OVERLAY`,
   `RUN_ARGS`. Outer-make expansion captures the value (env or
   command line) and re-injects it as a command-line override into
   the inner make, surviving nix's wipe.

**If you add a new env knob that the scenario script reads, add it
to `_RUN_PASSTHROUGH` too.** Otherwise env-form invocations
(`MY_FLAG=1 make run ...`) will silently drop your flag and the
scenario gets defaults - exactly the bug pattern that demoted
vanilla mode to inject mode for a few weeks before this comment
existed.

### `RUN_ACCEL=1` - risks and compat matrix

This flag overrides the upstream-vetted pinned CPU model
(`pentium3-v1` / `core2duo-v1` / `cortex-a72`) with `-cpu host`,
exposing the full host CPU feature set to gnumach. **gnumach has
not been tested against arbitrary modern CPU features** (newer
SSE/AVX, MTE on Apple Silicon, etc.) - it may panic on unrecognized
CPUID flags or hit untested code paths. The safe upstream-aligned
TCG path is the default contract; acceleration is a "I want this to
go fast" override at your own risk.

If `RUN_ACCEL=1` produces a fresh gnumach panic that doesn't repro
under TCG, that's useful upstream-bug data - worth filing.

Compatibility matrix (host -> accelerated targets):

| host | i686 | x86_64 | aarch64 |
|---------|------|--------|---------|
| x86_64 | yes | yes | no |
| i686 | yes | no | no |
| aarch64 | no | no | yes |

KVM/HVF on an x86_64 host accelerates both x86_64 and i686 guests
(32-bit is a subset of 64-bit, same `/dev/kvm`). All other cross-ISA
combos fall back to TCG with a one-line warning.

## The boot ISO (option 1) and the sidekick

Every Hurd boot under `-nographic` needs an x86 BIOS GRUB ISO: `boot.sh`
wraps our gnumach in one (qemu's `-kernel` rejects 64-bit ELFs, D18), and
the three distro scenarios build one that boots our gnumach (or the
distro's own, for `--vanilla`) while pulling the Hurd modules + root from
the **unmodified** distro disk via GRUB's `search --fs-uuid`. The disk is
never mounted or written - only read.

The host-side orchestration lives in `lib/sidekick.sh` and is identical on
Linux and darwin:

- **`sidekick_make_iso`** (the `boot` scenario): wrap a staging dir +
  grub.cfg into an ISO.
- **`sidekick_distro_iso`** (hurd-{debian,gentoo,guix}): read the distro's
  `/boot/grub/grub.cfg` straight out of the disk image, flatten one-level
  `configfile` includes (Gentoo splits modules into `entry_hurd.cfg`), parse
  its fs UUID + the `multiboot`/`module` recipe (joining backslash-continued
  lines, forcing `console=com0`), and emit an ISO grub.cfg that boots our
  gnumach from the ISO + `search --fs-uuid` for the modules/root on disk.

Both call just **two atomic tools** that have no darwin-native build:

- **`sidekick-imgcp <image> <raw|qcow2> <src> <dest>`** - copy one file out
  of a (partitioned) disk image. Read-only `qemu-storage-daemon` FUSE view
  - `debugfs` dump; the image is never modified.
- **`sidekick-mkrescue -o <iso> <dir>`** - `grub-mkrescue` forced to build
  an i386-pc (x86 BIOS) ISO via `-d <x86_64-grub2>/lib/grub/i386-pc`, so it
  works even on an aarch64 host (the grub tools only manipulate the i386-pc
  modules as data; x86 runs only at boot, in host `qemu-system-x86_64`).

### Where the tools run

On **Linux** they run natively (resolved on the dev-shell PATH). On
**darwin** neither tool has a nixpkgs build, so each is a thin
`sidekick-run <tool> "$@"` shim that forwards the call - argv + stdin/out/err

- exit code - into the **sidekick guest**: a minimal, hardened nix-only NixOS
  microVM (vfkit + Apple Virtualization.framework, SSH-over-vsock, project
  virtiofs-mounted at its real path so host↔guest paths are identical). The
  guest is built on Linux/CI and substituted from cachix (darwin can't build a
  Linux closure); see `flakes/sidekick/{guest,host,tools}.nix` and the
  `sidekick-guest` / `sidekick-run` flake outputs. The guest is kept out of the
  dist + toolchain closures so it can never affect determinism.

## Gotchas

### Exiting qemu in `-nographic` mode

`Ctrl-A X` quits. `Ctrl-A C` switches to the QEMU monitor; `Ctrl-A H`
prints the full escape-prefix cheat sheet. Plain `Ctrl-C` is forwarded
to the guest, not to qemu - that's why it doesn't terminate the VM.

The harness prints a one-line hint to stderr right before exec'ing
qemu (via `print_qemu_hint` in `lib/common.sh`) and ALSO sets the
terminal title to "qemu | <scenario> | ARCH=<arch> | Ctrl-A X to
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
inspect the resolved URL - `hurd_resolve_latest_target` ends in
`|| :` to eat that exit and lets the caller's case statement
classify the result.

### Guix x86_64 usually returns 500

Guix CI aggressively garbage-collects 64-bit `hurd64-barebones.qcow2`
artefacts. As of mid-2026, none of the 10 most recent successful
builds typically have a fetchable `/download/<id>` - the
`/search/latest/image` endpoint correctly returns 500.

The `hurd-guix.sh` script passes the GC-explanation hint as the 4th
arg to `hurd_fetch_via_resolve` only for `ARCH=x86_64`; on the
common 500 path, users see the explanation + the fallback hint
(use `ARCH=i686` instead) inline.

The `ARCH=i686` 32-bit path is reliably available.

### Gentoo's qcow2 URL is versionless

Gentoo publishes `hurd-i686-preview.qcow2` (and amd64 equivalent)
at a single rolling URL. If upstream publishes new content at the
same URL we silently keep the cached file - there's no
checksum-delta auto-refresh. To force a re-fetch:

```sh
rm -rf work/test-images/gentoo/<ARCH>/
```

A future enhancement could re-fetch the `.sha512` periodically and
compare against the cached one. Out of scope for the initial
implementation.

### `gnumach` (stripped image), NOT `gnumach.elf`

qemu's `-kernel` consumes the stripped boot image
(`$(WORK)/gnumach/<target>/gnumach`), not the un-stripped ELF
(`gnumach.elf` in the same dir, aarch64 only). On aarch64, giving
qemu the ELF causes a silent hang - qemu can't parse it as a boot
image. `GNUMACH_KERNEL` always points at the stripped `gnumach`;
the harness never references `gnumach.elf`.

### Vanilla mode + boot scenario

`RUN_VANILLA=1 SCENARIO=boot` is meaningless - there's no distro
kernel to fall back to. The `_RUN_PREREQS` expression in the parent
Makefile only drops the `mach` dependency for `RUN_VANILLA=1` +
Hurd scenarios, so boot still works in this case (just ignores the
vanilla flag). This guards against the cryptic qemu "could not load
kernel image" error from the alternative interpretation.

### Known image issues per scenario

- **`hurd-gentoo` + `ARCH=x86_64`** hangs in openrc's `servers`
  service after rumpdisk's rump kernel fails to attach the qemu
  e1000 NIC (`wm0`) - Gentoo's own wiki flags amd64 as "less stable
  so far than x86". i686 boots cleanly. Image bug, not a harness
  bug. Comment in `hurd-gentoo.sh` for the full diagnosis.
- **`hurd-guix` boots on the default i440fx machine** (like
  `hurd-gentoo`), reaching userland (rumpdisk attaches the IDE disk,
  ext2fs mounts, Guix's shepherd starts services). The old `-M q35`
  override has been dropped: it was needed only for the retired
  in-place overlay approach (which booted the disk's own gfxterm
  GRUB); our external serial-clean ISO + `search --fs-uuid` boots
  fine on i440fx. q35 actively HUNG with the ISO approach - rumpdisk's
  NetBSD AHCI driver loops doing a disk IDENTIFY on the boot CD-ROM's
  ATAPI port (`sd1: timeout waiting for identify`).
