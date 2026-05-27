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
| `aarch64` | aarch64-unknown-none-elf-gcc 14+, GNU MIG (master), binutils 2.46 | ✅ | ✅ kernel boots, all 11 kernel tests pass under `qemu-system-aarch64 -M virt` via the guest-loader test harness |
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

1. **Submit aarch64-port + aarch64-tests upstream.** Fifteen
   commits — nine kernel-side (the import + four follow-up Bugaev-port
   fixes found by the test suite) and six test-side (start.S,
   syscalls.S, testlib_thread_start.c, user-qemu.mk wiring +
   guest-loader runner, plus per-test aarch64 arms).  Each commit is
   one logical change, named `subsystem: terse description` per
   savannah convention.  Patch series targeting `bug-hurd@gnu.org`.
2. **Add the Hurd userland.** Once gnumach is upstream, build glibc
   and the core Hurd servers on top.
3. **Docker-based build path (coming soon).** A containerised entry
   point for hosts where Nix isn't an option — same Makefile, same
   outputs, just a thinner prerequisite list.

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

### 3. Run

```sh
make run                                            # boot scenario, host's default TARGET
make run TARGET=aarch64 SCENARIO=boot               # explicit; bare kernel via qemu -kernel
make run TARGET=x86_64 SCENARIO=hurd-debian         # Debian Hurd amd64 + our x86_64 kernel
make run TARGET=i686 SCENARIO=hurd-gentoo           # Gentoo Hurd i686 + our i686 kernel
make run TARGET=i686 SCENARIO=hurd-guix             # Guix childhurd 32-bit + our i686 kernel
RUN_VANILLA=1 make run TARGET=i686 SCENARIO=hurd-debian   # boot distro's bundled kernel instead
RUN_ARGS="-s -S" make run TARGET=aarch64            # qemu waits for gdb on :1234
RUN_ACCEL=1 make run                                # -accel hvf/kvm when host matches TARGET
```

**Scenarios:**

| Scenario | Supported TARGETs | What it boots |
|---|---|---|
| `boot` | `aarch64`, `x86_64`, `i686` | Bare kernel: i686/aarch64 via direct `-kernel`; x86_64 via sidekick-built GRUB ISO (qemu's `-kernel` rejects 64-bit ELFs) |
| `hurd-debian` | `x86_64`, `i686` | Sidekick overlays our gnumach onto Debian's bundled kernel path inside a qcow2 overlay + regenerates a serial-clean grub.cfg; disk's own GRUB drives multiboot |
| `hurd-gentoo` | `x86_64`, `i686` | Same kernel-overlay shape; x86_64 image hangs in openrc (known image bug) |
| `hurd-guix` | `x86_64`, `i686` | Same shape; needs `-M q35`; Guix CI usually 404s the x86_64 qcow2 (aggressive GC) |

**Modifier flags** (env or `make NAME=val`, all opt-in):

| Flag | Effect |
|---|---|
| `RUN_VANILLA=1` | Boot the distro's bundled kernel instead of ours (Hurd scenarios only; sidekick still regenerates grub.cfg for serial output) |
| `RUN_ACCEL=1` | Append `-accel hvf` (darwin) or `-accel kvm` (linux); x86_64 hosts accelerate both x86_64 and i686 targets, others require host arch == `TARGET` |
| `RUN_KEEP_OVERLAY=1` | Reuse the per-run qcow2 overlay across invocations (state persists) |
| `RUN_ARGS="..."` | Extra flags appended to the qemu cmdline (e.g., `-s -S`, `-monitor stdio`) |

See `make run-help` for the cheat sheet, and `tools/run/README.md` for
how the harness is structured and how to add new scenarios.

## Working with the submodules

The submodule URLs in `.gitmodules`:

| Submodule | URL | Tracked branch |
|---|---|---|
| `src/gnumach` | `https://github.com/paulofduarte/gnumach.git` (fork carrying the working aarch64 port + its kernel test arms) | `aarch64-tests` |
| `src/mig` | `https://github.com/paulofduarte/mig.git` (now tracking upstream-equivalent `master`) | `master` |

The `aarch64-tests` branch is `aarch64-port` (the kernel-side port,
nine commits on top of savannah master) plus six commits adding the
test-suite aarch64 arms.  Tracking it gives the parent build access
to both the port and the validated test machinery in one go; if you
only want the kernel port without the test work, point the submodule
at `aarch64-port` instead.

`src/mig` previously tracked a `cross-build-fixes` branch carrying a
`test_lib.sh` patch (preserving externally-supplied `CFLAGS`).  That
fix has been merged upstream, so the fork now tracks plain `master`
in lockstep with savannah.

To advance a submodule to its branch's latest commit:

```sh
git submodule update --remote src/gnumach           # follow aarch64-tests
git submodule update --remote src/mig               # follow master
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
| `prepare` | `autoreconf -i` on `src/gnumach` (MIG no longer needs local autoreconf — its nix derivation handles it) |
| `dist-headers` | symlink the gnumach public headers from the nix-built `gnumach-headers-<TARGET>` package into `dist/$(TARGET)/include` |
| `toolchain` | `dist-headers` + symlink the nix-built `mig-<TARGET>` wrapper into `toolchain/bin/<arch>-gnu-mig` |
| `mach` | build the gnumach kernel binary |
| `dist-mach` | install gnumach into `dist/$(TARGET)/` |
| `dist` | install everything (currently `dist-mach`; will grow) |
| `check` | run gnumach's `make check` (kernel tests under QEMU); MIG tests run inline via `doCheck=true` on every `nix build .#mig-<arch>` and don't need a separate make target |
| `check-mach` | the actual kernel-tests recipe `check` delegates to |
| `run` | boot the built kernel in qemu — see the [Run](#3-run) section for scenarios/flags |
| `run-help` | print all `make run` options (`TARGET`/`SCENARIO`/`RUN_*`) |
| `sidekick` | build the helper VM (x86_64 Alpine — used by Hurd scenarios for ext2 extraction + grub-mkrescue ISO assembly; auto-built on demand) |
| `cache-push` | push the current `$(TARGET)` dev-shell closure to the project's cachix cache (`hurd-build-system.cachix.org`); requires `cachix authtoken` once per host |
| `clean` | per-subdir `make clean` — preserves configure state |
| `clean-dist` | `rm -rf dist/$(TARGET)/` (current target only) |
| `mrproper` | `rm -rf work/`, the toolchain build outputs (`toolchain/bin`, `toolchain/sidekick`, the `result-*` gc-roots, the per-target install stamps), `dist/`, plus `git clean -fdX` on the src trees.  The flake sources under `toolchain/{gnumach-headers,mig}/` are preserved. |

## Directory layout

```
.
├── flake.nix                       # Nix dev shells + per-target packages
├── flake.lock                      # pinned nixpkgs (nixos-25.11)
├── Makefile                        # orchestration: always dispatches through `nix develop -i`
├── cloud-init.yaml                 # bootstrap recipe for orb-style Linux VMs
├── .envrc                          # nix-direnv hook (`use flake .#${TARGET:-aarch64}`)
├── src/
│   ├── gnumach/                    # submodule → paulofduarte/gnumach @ aarch64-tests
│   └── mig/                        # submodule → paulofduarte/mig @ master
├── work/                           # local build directories (gitignored)
│   └── gnumach/<target>/
├── toolchain/                      # nix-driven toolchain artefacts
│   ├── gnumach-headers/default.nix # per-target headers derivation (tracked)
│   ├── gnumach-headers/result-*    # per-target gc-root symlinks (gitignored)
│   ├── mig/default.nix             # per-target MIG derivation (tracked)
│   ├── mig/result-*                # per-target gc-root symlinks (gitignored)
│   ├── bin/<target>-gnu-mig        # PATH-discovery symlinks to the mig/result-*
│   ├── sidekick/                   # helper-VM artefacts (vmlinuz + initramfs.cpio.gz)
│   └── .mig-<target>-installed     # Makefile staleness stamps
├── dist/<target>/                  # final install prefix (gitignored)
│   ├── boot/gnumach
│   ├── include/                    # symlink → nix-built gnumach-headers-<target>
│   └── .{headers,mach}-installed   # staleness stamps
├── .gcroots/<target>               # per-target dev-shell gc-roots (gitignored)
├── .direnv/                        # nix-direnv per-project state (gitignored)
├── tools/                          # build-time utilities (in-repo)
│   ├── run/                        # `make run` harness scenarios + libs
│   └── sidekick/                   # nix derivation for the helper VM (Alpine fetch)
└── LICENSE                         # GPL-2.0
```

## How it works

### Dev shell

The flake defines five named dev shells, one per target:

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

The top-level `Makefile` is the single entry point. Every build target
re-enters `nix develop -i .#<target>` (always — strict isolation) and
re-runs itself, so the build's only inputs are what the dev shell
declares.  You never need to type `nix develop` manually; just `make`.

Targets that don't need the cross-toolchain run at the top level
without spawning a shell: `clean`, `clean-dist`, `mrproper`, `help`,
`sidekick`, and `cache-push`.

### Binary cache

The flake declares the project's [cachix](https://cachix.org/) cache
(`hurd-build-system`) via `nixConfig`, so anyone using the flake is
offered the prebuilt cross-toolchains as a substituter the first time
they enter the shell.  Accept the trust prompt once and `nix develop`
pulls aarch64/i686/x86_64 cross-gccs as binary downloads instead of
bootstrapping each one (~20 min/target → ~30 s/target).

To populate the cache after a fresh cross-toolchain build:

```sh
make cache-push                    # current TARGET
make cache-push TARGET=x86_64      # a specific arch
```

`cachix authtoken <token>` once per host is enough; push is
authenticated, pull is anonymous.

### Direnv (optional)

If you use [direnv](https://direnv.net/) + nix-direnv, the project's
`.envrc` activates `.#${TARGET:-aarch64}` automatically when you `cd`
into the repo.  Set `TARGET` in your shell before `cd` to pick a
different default for that direnv-driven shell.  The Makefile's
dispatch is unaffected — it always enters its own isolated shell per
`make` invocation.

The cloud-init template at the project root (`cloud-init.yaml`) is
the easiest way to provision an orbstack Linux VM with nix +
cachix + direnv + nix-direnv ready to go — see the next section.

### Provisioning an orbstack VM

`cloud-init.yaml` at the project root is a self-contained cloud-init
recipe.  When orbstack creates a Linux VM and consumes that file as
user-data, the VM boots fully wired:

- nix multi-user installed (flakes + the primary user trusted).
- `cachix`, `direnv`, `nix-direnv`, `starship` in the user's nix
  profile.
- bash hooks for direnv + starship; nix-direnv configured as direnv's
  plugin with the env-diff banner suppressed.
- For x86_64 VMs on Apple Silicon hosts (which run under rosetta and
  can't load seccomp BPF), `filter-syscalls = false` is added to
  nix.conf automatically based on the presence of
  `/proc/sys/fs/binfmt_misc/rosetta`.  Native VMs keep the seccomp
  filter enabled.

Apply when creating an orbstack machine:

```sh
orb create ubuntu my-hurd-vm -u cloud-init.yaml
```

After boot, log out and back in once (so the bash hooks load), then
`cd` into a clone of this repo with direnv allow'd and the cross
toolchains stream in from cachix in seconds.

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
matrix.  The project's cachix cache
(`hurd-build-system.cachix.org`) holds prebuilt cross-toolchains for
the host/target combinations we've populated, so on supported hosts
the *very first* `nix develop` pulls them as binary downloads —
typically **under a minute per target**, network-bound rather than
CPU-bound.

| Host arch  | Cached on cachix? | First `nix develop` for a target |
|---|---|---|
| `aarch64-darwin`  | ✅ | ~30-60 s |
| `aarch64-linux`   | ✅ | ~30-60 s |
| `x86_64-darwin`   | not yet | ~10-20 min (bootstraps cross-GCC) |
| `x86_64-linux`    | not yet | ~10-20 min (bootstraps cross-GCC) |

After that, the toolchain lives in `/nix/store` and subsequent builds
reuse it — that's where the ~40 s incremental figure above comes from.
With `direnv` (or a Makefile-side gc-root via `.gcroots/<target>`),
`nix-collect-garbage` won't sweep the toolchain away on regular gc
runs.

## Hacking notes

### Patches we carry over upstream

**gnumach.** We track `aarch64-tests`, which is `aarch64-port` (the
kernel-side port of Bugaev's `wip-aarch64`, in nine upstream-shaped
commits on top of savannah master) plus six commits that add the
upstream test suite's aarch64 arms.  The kernel port carries Bugaev's
import plus four follow-up fixes found while bringing up the test
suite:

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
- *phystokv contract for synthesised boot modules.* `bootstrap_create`
  calls `phystokv()` on `boot_info.mods_addr` and on each module's
  `string` field, expecting both to hold *physical* addresses.  The
  initial aarch64 synthesiser stored kernel-virtual pointers, which
  then mapped to bogus split-half addresses after `phystokv` ran.
  Convert with `kvtophys` at population time.
- *Reserve module physical pages from the heap.* `free_bootstrap_pages`
  asserts every page it releases is `VM_PT_RESERVED`.  On x86 biosmem
  carves modules out of the heap range so vm_page_init defaults them
  to reserved; the aarch64 path was handing all RAM to vm_page,
  including module-occupied pages.  Add `pmap_reserve_phys_range`,
  call it for each module during DTB walk, and cap `vm_page_load_heap`
  below the lowest module so module pages stay registered but
  reserved.
- *`_fpu_save_state` / `_fpu_load_state` FPSR/FPCR field order.* The
  asm read/wrote the two SPR fields swapped relative to
  `struct aarch64_float_state`'s layout, silently corrupting them
  across every `thread_get_state`/`thread_set_state` cycle.
- *Strict-alignment check on `AARCH64_FLOAT_STATE` setstatus.* MIG
  places the `new_state[]` array at an 8-byte-aligned offset from the
  request message header, but `alignof(struct aarch64_float_state)`
  is 16 (due to `__int128 v[32]`).  The kernel rejected every
  legitimate write with `KERN_INVALID_ARGUMENT`; replace with a
  copy-into-aligned-local before validating.

**mig.** No carried patches.  `src/mig` tracks vanilla `master` from
savannah.  The kernel test-harness CFLAGS issue (stock
`tests/test_lib.sh` overwriting external `CFLAGS`) is worked around
inside our `toolchain/mig/default.nix` derivation by passing
`TESTS_ENVIRONMENT="CFLAGS=-I${gnumach-headers}/include"` on the
`make check` invocation, so we don't need a fork patch for it.

### Upstream gaps we work around

**gnumach kernel test suite.** `make check-mach` forwards into
gnumach's own `make check` for the current TARGET.  The harness
builds a GRUB-bootable ISO via `grub-mkrescue` and runs it under
`qemu-system-i386 / x86_64`; the parent Makefile passes
`USER_MIG=$(MIG_INSTALLED)` (the nix-built mig wrapper) to gnumach's
configure so the userland test binaries link against the cross MIG.
*Host constraints:* GRUB/xorriso/mtools and u-boot are only pulled
into the dev shell on Linux hosts (nixpkgs doesn't package GRUB on
darwin, and `ubootQemuAarch64` is aarch64-linux-only), so
`make check-mach` errors out early on darwin with a clear message
pointing at orbstack or another Linux host.
*Validation:* the full x86_64 / i686 suite has been observed passing
on a Linux/x86_64 host with KVM acceleration.
*aarch64:* the `aarch64-tests` branch routes the kernel tests
through QEMU's `-device guest-loader` (no GRUB) so the same
harness works on any aarch64-linux host with `qemu-system-aarch64`.
All 11 user-space tests pass under `qemu-system-aarch64 -M virt`.
On non-x86 hosts the run uses TCG and is slow; bump
`MACH_TEST_TIMEOUT` if 60 s isn't enough.
*Xen targets:* tests are intentionally empty — guarded by
`if !PLATFORM_xen` in `tests/Makefrag.am`.

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
  platform    = null;            # or "at" / "xen" if gnumach has a platform for it
};
```

Everything else (env exports, per-target dev shell, per-target
`mig-arm` and `gnumach-headers-arm` packages, Makefile dispatch)
follows automatically from the `targets` attrset.

## License

GPL-2.0 — see [LICENSE](LICENSE). Matches the licensing of the GNU/Hurd
components this build system orchestrates.

The build glue here (`flake.nix`, `Makefile`) is original work licensed
under GPL-2.0. The source trees under `src/` retain their own upstream
licensing.
