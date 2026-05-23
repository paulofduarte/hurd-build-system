# hurd-build-system

A reproducible, Nix-based cross-build environment for **GNU/Hurd**,
targeting **aarch64-gnu**, **x86_64-gnu** and **i686-gnu**. Build the
GNU/Hurd stack from macOS, Linux, or Windows (via WSL 2) without
polluting your host with cross-toolchains.

Today the build covers the **GNU Mach** microkernel and **GNU MIG**
(its RPC stub generator). The Hurd userland — glibc and the core
servers — is on the roadmap, to land target-by-target once Mach is
stable on each. The aarch64 port is the current focus: the kernel
builds end-to-end and boots cleanly through DTB parsing, page-table
setup, machine_init, and into bootstrap-module loading on QEMU `virt`
(see [Status](#status)). x86_64 and i686 are wired into the build
system and will be validated against current upstream next (see
[Roadmap](#roadmap)).

**Why Nix + git submodules?** Reproducibility is the founding constraint
of this repo. Nix pins every host-side tool — cross-compiler, autotools,
MIG, GNU Make, even the shell — to exact `/nix/store` paths via
`flake.lock`, so two developers on the same commit get bit-identical
build environments. Submodules pin each upstream Hurd source tree (gnumach
and MIG today; glibc and the Hurd servers when they land) to an exact
commit hash recorded in the parent repo, so neither a branch moving
nor a tag being re-tagged can silently change what we build.
Together they make the commit hash of this repo a complete description
of the build inputs. Background reading:
[nix.dev](https://nix.dev/),
[Nix flakes](https://nix.dev/concepts/flakes.html),
[git submodules](https://git-scm.com/book/en/v2/Git-Tools-Submodules),
and the broader [reproducible-builds.org](https://reproducible-builds.org/)
effort.

## Status

| Target | Cross-toolchain | Kernel builds? | Boots? |
|---|---|---|---|
| `aarch64` | aarch64-unknown-none-elf-gcc 14+, GNU MIG (master), binutils 2.46 | ✅ | ✅ kernel boots through DTB / pmap / machine_init; reaches `machine_exec_boot_script` (panics for lack of bootstrap modules, as expected without a userland) |
| `x86_64` | x86_64-unknown-elf-gcc | ✅ | ✅ all kernel tests pass under `qemu-system-x86_64 + KVM` on a Linux/x86_64 host |
| `x86_64-xen` | x86_64-unknown-elf-gcc | ✅ | n/a — gnumach's `tests/Makefrag.am` disables the suite when `--enable-platform=xen` |
| `i686` | i686-unknown-elf-gcc | ✅ | ✅ all kernel tests pass under `qemu-system-i386 + KVM` on a Linux/x86_64 host |
| `i686-xen` | i686-unknown-elf-gcc | ✅ | n/a — same Xen-block guard as `x86_64-xen` |

The `-xen` variants of each x86 target build the same kernel sources with
gnumach's `--enable-platform=xen`, producing a paravirtualised Xen-domU
image instead of the default PC-AT (`at`) build. Both share the same
cross-toolchain and MIG binary as their non-Xen sibling.

The aarch64 port draws from **Sergey Bugaev's `wip-aarch64` branch** of
`github.com/bugaevc/gnumach`, applied as five small, upstream-shaped
commits on top of current `git.savannah.gnu.org/git/hurd/gnumach.git`
master. The port stays inside `aarch64/` for everything new and limits
its footprint outside that directory to 4 shared files / ~22 lines of
strictly-additive changes (a new `EM_AARCH64` constant, cross-arch
`copyinmsg/copyoutmsg` declarations, the matching include in
`kern/exception.c`, and an extension of the linker-symbol filter for
the PIE kernel) — `device/intr.c`, `device/intr.h`, `kern/bootstrap.c`,
and `kern/lock.h` remain bit-identical to upstream master so x86_64
and i686 builds are unaffected.

## Roadmap

1. **Extend kernel test coverage to aarch64.** `make check-toolchain`
   already runs all 12 MIG tests on every target via our mig fork's
   `cross-build-fixes` branch. `make check-mach` runs the upstream
   gnumach kernel-test suite (all tests passing) for `x86_64` and
   `i686` on a Linux/x86_64 host. aarch64 is the missing arch: the
   kernel itself boots cleanly and `machine_exec_boot_script` already
   consumes `multiboot,module` DTB nodes that QEMU's `-device
   guest-loader` synthesises, so the boot protocol is wired. What's
   still missing on aarch64: (a) `tests/start.S` and `tests/syscalls.S`
   have only `__i386__` / `__x86_64__` arms — no aarch64 `_start` or
   `SVC`-based syscall stubs; (b) `tests/user-qemu.mk` hard-codes
   `qemu-system-i386 / x86_64` and the grub-mkrescue ISO pipeline;
   (c) we don't yet have an `aarch64-gnu-gcc` userland cross-toolchain
   (today's `aarch64-unknown-none-elf` is bare-metal), so even with
   (a) and (b) resolved we'd have no way to build the test binaries.
2. **Add the Hurd userland.** Once gnumach is stable on a target, build
   glibc and the core Hurd servers on top.
3. **Docker-based build path (coming soon).** A containerised entry point
   for hosts where Nix isn't an option — same Makefile, same outputs,
   just a thinner prerequisite list.

Support for other architectures (e.g. `arm`, `riscv64`) isn't on the
roadmap, but the `targets` attrset in `flake.nix` is open to extension —
adding a new architecture is a few lines (see
[Adding a new target](#adding-a-new-target)).

## Prerequisites

The build system is designed so that **Nix provides everything else**. The
host only needs:

| Tool | Required version | Notes |
|---|---|---|
| **Nix** | any with flakes support (2.4+, Dec 2021) | provides every other tool, including the cross-toolchain |
| **git** | any | needed to clone the parent repo and fetch submodules |
| **GNU Make** *(recommended)* | 3.81+ | only for the convenience of running `make` from your host shell; if missing, use `nix develop` and run `make` *inside* the dev shell |

macOS and most Linux distros ship git and a sufficiently new make by
default. The only thing you may need to install is Nix itself — see
[nix.dev/install-nix](https://nix.dev/install-nix).

**Windows users**: build via **WSL 2** (Windows Subsystem for Linux,
version 2). Once inside a WSL distro (Ubuntu, Debian, etc.) the same Nix
+ git workflow applies — from Nix's perspective it's just a Linux host.
WSL 1 isn't supported because its translation layer doesn't handle the
file-system features Nix relies on. Make sure the repo is cloned into
the WSL filesystem (e.g. `~/projects/...`), not a Windows-mounted path
(`/mnt/c/...`) — the latter is slow and has case-insensitivity issues.

Nix's flakes and the `nix-command` experimental feature are enabled
per-invocation by the build system, so you don't need any global Nix
configuration.

## Onboarding (3 steps)

### 1. Clone with submodules

```sh
git clone --recurse-submodules https://github.com/paulofduarte/hurd-build-system.git
cd hurd-build-system
```

If you cloned without `--recurse-submodules`, pull them in after:

```sh
git submodule update --init --recursive
```

### 2. Build

```sh
make                    # builds for the host's native arch
make TARGET=x86_64      # cross-build for a specific target
make help               # lists all targets (no nix needed for this one)
```

Standard make flags forward into the dispatched inner make:

```sh
make -j                 # parallel build, unlimited jobs
make -j8                # parallel build, capped at 8
make -k                 # keep going on errors
```

If your host doesn't have GNU Make, enter the dev shell first — it
includes a recent make:

```sh
nix develop             # picks the target matching your host CPU
make                    # now uses the make inside the shell
```

### 3. Run (aarch64 only, for now)

```sh
make dist                                            # stage outputs into dist/aarch64/
nix develop -i .#aarch64 --command \
  qemu-system-aarch64 -machine virt,accel=tcg -cpu cortex-a53 -m 1G -nographic \
    -kernel dist/aarch64/boot/gnumach \
    -append "gnumach cmdline goes here"
```

## Working with the submodules

The submodule URLs in `.gitmodules`:

| Submodule | URL | Tracked branch |
|---|---|---|
| `src/gnumach` | `https://github.com/paulofduarte/gnumach.git` (fork carrying the working aarch64 port) | `aarch64-port` |
| `src/mig` | `https://github.com/paulofduarte/mig.git` (fork carrying the cross-build / test-harness fix) | `cross-build-fixes` |

To advance a submodule to its branch's latest commit:

```sh
git submodule update --remote src/gnumach           # follow aarch64-port
git submodule update --remote src/mig               # follow cross-build-fixes
```

Then `git add src/gnumach src/mig` from the project root and commit to
record the new pin.

Each submodule has extra remotes wired in locally for development
(`bugaevc`, `savannah`, `upstream`). Those aren't in `.gitmodules` —
fresh clones get only `origin`.

## Targets

| Target | Action |
|---|---|
| `all` *(default)* | build the gnumach kernel (currently just `mach`; will grow) |
| `prepare` | `autoreconf -i` on both source trees |
| `dist-headers` | install gnumach public headers into `dist/$(TARGET)/include` |
| `toolchain` | `dist-headers` + build & install MIG into `toolchain/` |
| `mach` | build the gnumach kernel binary |
| `dist-mach` | install gnumach into `dist/$(TARGET)/` |
| `dist` | install everything (currently `dist-mach`; will grow) |
| `clean` | per-subdir `make clean` — preserves configure state |
| `clean-dist` | `rm -rf dist/$(TARGET)/` (current target only) |
| `mrproper` | `rm -rf work/ toolchain/ dist/` + `git clean -fdX` on src trees |

## Directory layout

```
.
├── flake.nix              # Nix dev shells (per-target)
├── flake.lock             # pinned nixpkgs (nixos-25.11)
├── Makefile               # orchestration: dispatches through nix develop
├── src/
│   ├── gnumach/           # submodule → paulofduarte/gnumach @ aarch64-port
│   └── mig/               # submodule → paulofduarte/mig @ cross-build-fixes
├── work/                  # build directories  (gitignored)
│   ├── gnumach/<target>/
│   └── mig/<target>/
├── toolchain/             # installed cross-MIG  (gitignored)
│   └── bin/<target>-gnu-mig
├── dist/<target>/         # final install prefix (gitignored)
│   ├── boot/gnumach
│   ├── include/
│   └── .{headers,mach}-installed       # our staleness stamps
└── LICENSE                # GPL-2.0
```

## How it works

### Dev shell

The flake defines three named dev shells, one per target:

```sh
nix develop                   # picks the target whose CPU matches the host
nix develop .#aarch64         # explicit
nix develop .#x86_64
nix develop .#x86_64-xen      # x86_64, --enable-platform=xen
nix develop .#i686
nix develop .#i686-xen        # i686,   --enable-platform=xen
```

Each shell exports:

- `CC`, `LD`, `AR`, `NM`, `RANLIB`, `STRIP`, `OBJCOPY` — the cross binutils
- `TARGET_CC` — same as `CC`, used by MIG's `cpu.sym` build
- `MIG` — the cross MIG binary name (e.g. `aarch64-gnu-mig`)
- `TARGET`, `GNUMACH_HOST` — target identity for the Makefile
- `CFLAGS="-std=gnu17 -g -O2"` — pin pre-C23 semantics for older Mach code

### Transparent dispatch

The top-level `Makefile` is the single entry point. When invoked outside
the Nix shell — or inside the *wrong* target's shell — it re-enters
`nix develop -i .#<target>` and re-runs itself. So you never need to type
`nix develop` manually; just `make`.

Targets that don't need the cross-toolchain (`clean`, `clean-dist`,
`mrproper`, `help`) run at the top level without spawning a shell.

### Mtime-based short-circuit

If every requested goal's sentinel artefact already exists and no
**tracked** source (per `git ls-files`) is newer than its sentinel, the
Makefile prints `Nothing to be done` and exits — without spawning Nix.
Autoreconf outputs, build artefacts, and editor backups are excluded
automatically because they're gitignored.

### Multi-target builds coexist

Build directories, install prefixes, and stamps are per-target:

```sh
make TARGET=aarch64    dist  # → dist/aarch64/
make TARGET=x86_64     dist  # → dist/x86_64/      (PC-AT)
make TARGET=x86_64-xen dist  # → dist/x86_64-xen/  (Xen domU)
make TARGET=i686       dist  # → dist/i686/        (PC-AT)
make TARGET=i686-xen   dist  # → dist/i686-xen/    (Xen domU)
```

The shared `toolchain/` directory holds all MIG variants side by side
(`aarch64-gnu-mig`, `x86_64-gnu-mig`, `i686-gnu-mig`). Xen targets reuse
their sibling's MIG binary — Xen vs PC-AT is a kernel build configuration,
not a different CPU ABI.

## QEMU notes (aarch64)

After `make dist`, the kernel is at `dist/aarch64/boot/gnumach`. The QEMU
invocation under [Onboarding §3](#3-run-aarch64-only-for-now) uses these
deliberately:

- The **flat binary** (`gnumach`), not `gnumach.elf` — QEMU's `-kernel`
  expects the Linux AArch64 boot-protocol format on the `virt` machine.
- `accel=tcg` — required on macOS / aarch64 hosts; the default HVF fails
  to start execution for this kernel.
- For a full GNU/Hurd boot with userland modules, see Bugaev's
  `src/gnumach/aarch64/BOOTING`, which describes loading modules via
  QEMU's `guest-loader` device.

## Resource footprint

| What | Amount |
|---|---|
| Nix store after first build | ~5 GB |
| RAM headroom for parallel build | ~2 GB |
| Wall time, `make -j` cold from `mrproper` | ~40 s on a modern laptop *(after the toolchain is in the Nix store — see below)* |

**First-build caveat.** The cross-GCC for each `<target>-none-elf` /
`<target>-elf` triple isn't in nixpkgs' binary cache for our host/target
matrix, so the *very first* `nix develop` on a given host always
compiles GCC from source; binutils sometimes comes from cache and
sometimes doesn't. Verified across **Linux x86_64**, **Linux aarch64**,
and **macOS aarch64** — all three paid the same one-time cost.
Reference point: **under 10 min** on an M4 MacBook Pro for the first
target. Longer on older or slower hosts. After that the toolchain
lives in `/nix/store` and subsequent builds reuse it — that's where
the ~40 s incremental figure above comes from. The roadmap item
*"Docker-based build path"* (below) addresses this by shipping a
prebuilt image so users without Nix can skip the cross-toolchain
build entirely.

## Hacking notes

### Patches we carry over upstream

**gnumach.** The `aarch64-port` branch applies Bugaev's
`wip-aarch64` work as five upstream-shaped commits on top of current
savannah master, plus three aarch64 boot-path fixes:

- *Boot stack outside the BSS clear range.* The boot stack lived inside
  the BSS clear region, and modern GCC's compiled `memset` was zeroing
  its own saved return address mid-call (see
  `src/gnumach/aarch64/aarch64/boot.S` + `aarch64/ldscript`). Bugaev's
  GCC 13 likely inlined `memset` and masked the issue; GCC 15 doesn't.
- *DTB cell reader avoids 8-byte unaligned load.* `read_cells()` in
  `device/dtb.c` did `__builtin_memcpy(&tmp, addr, 8); bswap64(tmp)` to
  read a 2-cell DTB property; at -O2 the compiler fuses that into a
  single `LDR Xt`, which requires 8-byte alignment. DTB property data
  is only 4-byte aligned, and with the MMU still off in early boot all
  memory is Device-nGnRnE, so the load takes an alignment fault. With
  no vector table installed yet, the abort vectors to `VBAR_EL1+0x200`
  = physical 0x200 and the CPU loops forever on `udf #0`. Replaced
  with two explicit 4-byte big-endian reads.
- *Bootstrap modules through `kern/bootstrap.c` unchanged.* Rather
  than carry Bugaev's parallel `machine_exec_boot_script()` walker
  (which forks `kern/bootstrap.c` and `device/intr.{c,h}` and is
  aarch64-only), `aarch64/aarch64/model_dep.c` now synthesises a
  multiboot-shaped `boot_info` from the DTB's `/chosen/multiboot,module`
  nodes during `c_boot_entry`.  Upstream `bootstrap_create()` then
  consumes those modules through the same `boot_info.mods_addr`
  pathway it already uses on i386/x86_64.

**mig.** Stock savannah `tests/test_lib.sh` hardcodes
`CFLAGS="-I$TEST_DIR/includes"`, overwriting any externally-supplied
value. That works on Hurd developer boxes (system Mach headers in
the default search path) but breaks `make check` on every other host.
Our fork's `cross-build-fixes` branch appends `${CFLAGS:-}` so the
target's installed Mach headers can be supplied via the standard
env var (`make check CFLAGS=-I/path/to/include`). Suitable for an
upstream submission; carrying it locally for now.

### Upstream gaps we work around

**gnumach kernel test suite.** `make check-mach` forwards into
gnumach's own `make check` for any TARGET in `_MACH_TESTS_SUPPORTED`
— today, `x86_64` and `i686`. The harness builds a GRUB-bootable
ISO via `grub-mkrescue` and runs it under `qemu-system-i386 /
x86_64`; both are pulled into the dev shell on Linux hosts (nixpkgs
doesn't package GRUB on darwin), and the parent Makefile passes
`USER_MIG=$(TOOLCHAIN)/bin/$(MIG_TARGET)-mig` to gnumach's configure
so the userland test binaries link against our cross MIG.
*Validation:* the full suite has been observed passing on a Linux
x86_64 host with KVM acceleration. *Other hosts:* on macOS the
pipeline runs as far as userland-stub generation and test-binary
linking, then fails at the ISO step; on Linux/aarch64 the dev shell
has `grub-mkrescue` but nixpkgs only ships its `arm64-efi` target,
so the produced ISO can't be booted by SeaBIOS. Either way, the
practical execution environment for the kernel tests today is a
Linux/x86_64 host (or a container thereof). *aarch64:* still gated
— `tests/start.S` and `tests/syscalls.S` have only `__i386__` /
`__x86_64__` arms, `tests/user-qemu.mk` hard-codes
`qemu-system-i386 / x86_64`, and we don't yet have an
`aarch64-gnu` userland cross-toolchain. *Xen targets:* tests are
intentionally empty — guarded by `if !PLATFORM_xen` in
`tests/Makefrag.am`.

### When you edit source

`make` detects mtime changes via `git ls-files` — only **tracked** files
trigger a rebuild. Touching `configure`, `Makefile.in`, etc. (autoreconf
outputs, gitignored) is correctly ignored.

### Adding a new target

Add an entry to `targets` in `flake.nix`:

```nix
arm = {
  crossSystem = "arm-none-eabi";
  migTarget   = "arm-gnu";
};
```

Everything else (env exports, banner, Makefile dispatch) follows
automatically.

## License

GPL-2.0 — see [LICENSE](LICENSE). Matches the licensing of the GNU/Hurd
components this build system orchestrates.

The build glue here (`flake.nix`, `Makefile`) is original work licensed
under GPL-2.0. The source trees under `src/` retain their own upstream
licensing.
