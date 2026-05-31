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

**Why Nix?** Reproducibility is the founding constraint of this repo. Nix
pins every input — the cross-compiler, autotools, MIG, GNU Make, the shell,
*and* the upstream Hurd source trees (gnumach and MIG today; glibc and the
Hurd servers when they land) — to exact revisions via `flake.lock`. The
sources are pinned flake inputs (`gnumach-src` / `mig-src`, github forks at a
fixed commit), so neither a branch moving nor a tag being re-tagged can
silently change what we build. Together that makes this repo's commit hash a
complete description of the build inputs. Background reading:
[nix.dev](https://nix.dev/),
[Nix flakes](https://nix.dev/concepts/flakes.html),
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
| **git** | any | needed to clone the repo (and the source trees via `make srcs`) |
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

### 1. Clone

```sh
git clone https://github.com/paulofduarte/hurd-build-system.git
cd hurd-build-system
```

nix builds the kernel + MIG from pinned `*-src` flake inputs, so a plain
clone is enough to build. To *iterate* on the sources (`make mig` / `make
mach`), populate the working clones under `src/` once:

```sh
make srcs        # clone each source's working tree at its pinned rev
```

### 2. Build

```sh
make                    # builds for the host's native arch
make ARCH=x86_64      # cross-build for a specific target
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
make run                                                 # boot scenario, host's default ARCH
make run ARCH=aarch64 SCENARIO=boot                      # explicit; bare kernel via qemu -kernel
make run ARCH=x86_64 SCENARIO=hurd-debian                # Debian Hurd amd64 + our x86_64 kernel
make run ARCH=i686 SCENARIO=hurd-gentoo                  # Gentoo Hurd i686 + our i686 kernel
make run ARCH=i686 SCENARIO=hurd-guix                    # Guix childhurd 32-bit + our i686 kernel
make run ARCH=i686 SCENARIO=hurd-debian RUN_VANILLA=1    # boot distro's bundled kernel instead
make run ARCH=aarch64 RUN_ARGS="-s -S"                   # qemu waits for gdb on :1234
make run RUN_ACCEL=1                                     # -accel hvf/kvm when host matches ARCH
make run ARCH=x86_64 SCENARIO=hurd-debian RUN_REFRESH=1  # force re-fetch of cached distro image
```

All knobs (`ARCH`, `SCENARIO`, `RUN_*`) accept either form — `make run VAR=value` (shown above) or `VAR=value make run` (env-style).  Pick whichever reads better.

Or via `nix run` (no clone needed — uses the cachix-cached nix-built kernel):

```sh
nix run github:paulofduarte/hurd-build-system                     # boot, host's arch
nix run github:paulofduarte/hurd-build-system#aarch64             # boot, aarch64
nix run github:paulofduarte/hurd-build-system#x86_64 hurd-debian  # Debian Hurd x86_64
nix run github:paulofduarte/hurd-build-system#x86_64 hurd-debian --accel
nix run github:paulofduarte/hurd-build-system#i686 hurd-debian --vanilla
nix run github:paulofduarte/hurd-build-system#aarch64 boot --refresh
nix run github:paulofduarte/hurd-build-system#aarch64 -- -- -s -S    # everything after `--` passes to qemu
nix run github:paulofduarte/hurd-build-system#aarch64 --help
```

The `nix run` path uses the nix-built kernel from the project's cachix cache.  Distro images cache at `$XDG_CACHE_HOME/hurd-build-system/test-images/`.

**Scenarios:**

| Scenario | Supported ARCHs | What it boots |
|---|---|---|
| `boot` | `aarch64`, `x86_64`, `i686` | Bare kernel: i686/aarch64 via direct `-kernel`; x86_64 via sidekick-built GRUB ISO (qemu's `-kernel` rejects 64-bit ELFs) |
| `hurd-debian` | `x86_64`, `i686` | Sidekick overlays our gnumach onto Debian's bundled kernel path inside a qcow2 overlay + regenerates a serial-clean grub.cfg; disk's own GRUB drives multiboot |
| `hurd-gentoo` | `x86_64`, `i686` | Same kernel-overlay shape; x86_64 image hangs in openrc (known image bug) |
| `hurd-guix` | `x86_64`, `i686` | Same shape; needs `-M q35`; Guix CI usually 404s the x86_64 qcow2 (aggressive GC) |

**Modifier flags** (env or `make NAME=val`, all opt-in):

| Flag | Effect |
|---|---|
| `RUN_VANILLA=1` | Boot the distro's bundled kernel instead of ours (Hurd scenarios only; sidekick still regenerates grub.cfg for serial output) |
| `RUN_ACCEL=1` | Append `-accel hvf` (darwin) or `-accel kvm` (linux); x86_64 hosts accelerate both x86_64 and i686 targets, others require host arch == `ARCH` |
| `RUN_KEEP_OVERLAY=N` | Keep + reuse overlay slot `N` across runs so guest state persists (integer ≥ 1, default 1 → `overlay-N.qcow2`); without it each run starts fresh from `overlay.qcow2`. `nix run` flag: `--keep-overlay[=N]` |
| `RUN_ARGS="..."` | Extra flags appended to the qemu cmdline (e.g., `-s -S`, `-monitor stdio`) |

See `make run-help` for the cheat sheet, and `flakes/run/README.md` for
how the harness is structured and how to add new scenarios.

## Working with the source trees

The kernel and MIG sources are **pinned flake inputs** (`gnumach-src` /
`mig-src`), not submodules. The fork + branch each tracks is declared in
`flake.nix`, and `flake.lock` records the exact commit nix builds — run `nix
flake metadata` (or `make srcs`, below) to see the current pins. There's no
`.gitmodules`, and nothing to keep in sync.

For iterating on the sources, `make srcs` populates working clones under
`src/` (gitignored) at the pinned revs:

```sh
make srcs          # clone — or reconcile an existing clone to the pinned rev
```

On an existing clone it adds the pinned remote (named `pin`) without
disturbing your other remotes, checks out the rev nix builds, and **refuses**
if a working tree has uncommitted changes. Edit, commit, and push from these
clones as usual — nix keeps building the pinned commit until you advance the
pin:

```sh
make pin-srcs      # bump the pins to the forks' branch HEADs; then `make srcs`
```

`flake.lock` is the single source of truth for what nix builds — there's no
`.gitmodules`, and nothing to keep in sync.

## Targets

| Target | Action |
|---|---|
| `all` *(default)* | build the gnumach kernel (currently just `mach`; will grow) |
| `prepare` | `autoreconf -i` on `src/gnumach` (MIG no longer needs local autoreconf — its nix derivation handles it) |
| `dist-headers` | copy gnumach public headers (from nix-built `gnumach-headers-<ARCH>`) into `dist/$(ARCH)/include` |
| `mig` | build MIG **in-tree** under `work/mig/$(ARCH)/` — incremental compile, the path you want while iterating on `src/mig` inside `nix develop`.  For the clean nix-built wrapper, use `nix build .#mig-<ARCH>` directly — MIG is a host-arch tool, intentionally not bundled into `dist/` |
| `mach` | build the gnumach kernel binary **in-tree** under `work/gnumach/$(ARCH)/` using the in-tree MIG from `make mig` — incremental compile, the path you want while iterating on `src/gnumach` |
| `dist-mach` | copy clean nix-built kernel (`gnumach-<ARCH>`) into `dist/$(ARCH)/boot/gnumach`, plus the GNU Mach Info manual into `dist/$(ARCH)/share/info/mach.info*` and the RPC message-ID table into `dist/$(ARCH)/share/msgids/gnumach.msgids` |
| `dist` | produce a tarball-ready `dist/$(ARCH)/` (= `dist-headers` + `dist-mach`; mig is host-arch, not bundled).  Real copies, not symlinks — `tar czf hurd-build-<arch>.tar.gz dist/$(ARCH)/` ships a self-contained release |
| `check` | run gnumach's `make check` (kernel tests under QEMU); MIG tests run inline via `doCheck=true` on every `nix build .#mig-<arch>` and don't need a separate make target |
| `check-mach` | the actual kernel-tests recipe `check` delegates to |
| `run` | boot the built kernel in qemu — see the [Run](#3-run) section for scenarios/flags |
| `run-help` | print all `make run` options (`ARCH`/`SCENARIO`/`RUN_*`) |
| `sidekick` | build the helper VM (x86_64 Alpine — used by Hurd scenarios for ext2 extraction + grub-mkrescue ISO assembly; auto-built on demand) |
| `cache-push` | push the current `$(ARCH)` dev-shell closure to the project's cachix cache (`hurd-build-system.cachix.org`); requires `cachix authtoken` once per host |
| `clean` | per-subdir `make clean` — preserves configure state |
| `clean-dist` | `rm -rf dist/$(ARCH)/` (current target only) |
| `mrproper` | `rm -rf work/`, the project-root install dir (`.sidekick/`), the flake gc-roots (`flakes/{gnumach-headers,mig,gnumach}/result-*`), `dist/`, plus `git clean -fdX` on the src trees.  The flake sources under `flakes/{cross-toolchain,gnumach-headers,mig,gnumach,sidekick}/` are preserved. |

### Invoking MIG directly

MIG is a *host-arch* code-generator (it runs on your build machine
and emits portable C/H stubs).  Because the binary is host-coupled,
not target-coupled, it intentionally **doesn't ship under
`dist/<target>/`** — that tree is keyed by target architecture
(headers, kernel, …) and mixing in a host-arch tool muddles the
contract.

Three ways to get a working MIG, in order of how clean you want it:

1. **`nix run`** — one-shot invocation, no install:

   ```sh
   # Generate user + server stubs from a .defs file, target aarch64
   nix run .#mig-aarch64 -- \
     -user out_user.c -server out_server.c -header out_user.h \
     -sheader out_server.h \
     path/to/foo.defs
   ```

   The `--` separates flake args from MIG's own argv.  `nix run`
   builds the per-target derivation if it isn't already cached, then
   invokes its primary `bin/<target>-gnu-mig` wrapper.

2. **`nix build`** — install a stable gc-rooted symlink under
   `flakes/mig/result-<target>/`:

   ```sh
   nix build .#mig-aarch64 -o flakes/mig/result-aarch64
   ls flakes/mig/result-aarch64/bin/      # → aarch64-gnu-mig, aarch64-unknown-none-elf-mig
   ./flakes/mig/result-aarch64/bin/aarch64-gnu-mig --help
   ```

   The wrapper resolves `migcom` via `dirname $0/../libexec/`, so it
   works wherever you symlink it.  The cross-prefixed alias
   (`<crossPrefix>-mig`) is what gnumach's `AC_CHECK_TOOL` discovers
   on PATH.

3. **`make mig`** — in-tree iterative build under
   `work/mig/<target>/` for active MIG development.  Same wrapper +
   layout as (2), built incrementally from `src/mig/` after edits
   without going through nix each time.  Pick this only if you're
   editing MIG itself.

For embedding MIG into an external build, prefer (2) — the result
symlink has a stable `<target>-gnu-mig` name your downstream
configure / makefiles can put on PATH.

## Directory layout

```
.
├── flake.nix                       # Nix dev shells + per-target packages
├── flake.lock                      # pinned nixpkgs (nixos-25.11)
├── Makefile                        # orchestration: always dispatches through `nix develop -i`
├── cloud-init.yaml                 # bootstrap recipe for any cloud-init-capable Linux VM
├── src/                            # working clones (gitignored; `make srcs`)
│   └── <name>/                     # one per `<name>-src` flake input (fork + rev in flake.nix)
├── work/                           # local in-tree build dirs (gitignored)
│   ├── mig/<target>/install/       # iterative MIG build (`make mig`)
│   └── gnumach/<target>/           # iterative kernel build (`make mach`)
├── flakes/                         # nix sub-flakes (source-only)
│   ├── cross-toolchain/default.nix # mkDevShell + x86_64-darwin config.sub overlay
│   ├── sources/                    # source-pin helpers (flake.lock → fork-id) + sync.sh (`make srcs`)
│   ├── gnumach-headers/default.nix # per-target headers derivation
│   ├── gnumach-headers/result-*    # per-target gc-root symlinks (gitignored)
│   ├── mig/default.nix             # per-target MIG derivation
│   ├── mig/result-*                # per-target gc-root symlinks (gitignored)
│   ├── mig/.mig-<target>-installed # Makefile staleness stamps (gitignored)
│   ├── gnumach/default.nix         # per-target kernel derivation (clean reproducible build)
│   ├── gnumach/result-*            # per-target gc-root symlinks (gitignored)
│   ├── sidekick/                   # nix derivation for the helper VM (Alpine fetch)
│   └── run/                        # `nix run` + `make run` harness: default.nix wraps
│                                   #   dispatch.sh + scenario scripts + lib/ helpers
├── .sidekick/                      # helper-VM artefacts (vmlinuz + initramfs.cpio.gz, gitignored)
├── dist/<target>/                  # clean install tree — real copies, tarball-able (gitignored)
│   ├── boot/gnumach                # kernel (raw binary on aarch64, ELF on x86_64/i686)
│   ├── boot/gnumach.elf            # aarch64 only — unstripped ELF with DWARF for gdb/addr2line
│   ├── include/                    # gnumach public headers (cp -r from nix-built)
│   └── share/                      # docs from the gnumach package
│       ├── info/mach.info*         # GNU Mach reference manual (~408K Info pages)
│       └── msgids/gnumach.msgids   # RPC message-ID table for trace decoders
│                                   # MIG is host-arch (not target-arch) so it's not bundled here.
│                                   # See "Invoking MIG directly" below.
├── .gcroots/<target>               # per-target dev-shell gc-roots (gitignored)
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
- `ARCH`, `GNUMACH_HOST` — target identity for the Makefile
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
make cache-push                    # current ARCH
make cache-push ARCH=x86_64      # a specific arch
```

`cachix authtoken <token>` once per host is enough; push is
authenticated, pull is anonymous.

**Continuous cache maintenance via GitHub Actions.**  The workflow at
`.github/workflows/cache-toolchains.yml` keeps the cache populated
automatically whenever a toolchain-affecting file lands on `main`
(`flake.nix`, `flake.lock`, `target-archs.nix`,
`flakes/cross-toolchain/**`, `packages.nix`, or the workflow / its
`setup-nix` action) — plus manual dispatch.  It runs in two stages:

- **`plan`** — one runner cross-evaluates every `(host × target)`
  toolchain path (`packages.<host>.toolchain-<arch>`) and probes cachix
  for each with `nix path-info --store` (a `.narinfo` lookup, no
  download).  Cross-eval is pure, so a single runner decides for all
  hosts; any host whose toolchains are all cached spins **no** runner.
  The job emits a build matrix of only the missing host/target pairs.
- **`populate`** — for each host in that matrix, builds only the missing
  targets (`nix build .#toolchain-<arch>`) and pushes them.  The matrix
  spans the four supported host arches: `x86_64-linux` (`ubuntu-latest`),
  `aarch64-linux` (`ubuntu-24.04-arm`), `aarch64-darwin` (`macos-latest`),
  `x86_64-darwin` (`macos-15-intel`).

Only the cross-toolchain is cached — not mig / gnumach-headers / the
kernel, which are cheap to build once the toolchain is in place.

**Cross-host consistency check.**  When a cache run rebuilds ≥1 toolchain
it triggers `.github/workflows/toolchain-sanity-check.yml`, which
cross-builds `make dist` for every target on all four hosts.  A `compare`
gate fails the run unless the hosts **agree** — byte-identical per-file
hashes where a target builds, or an identical (normalised) error signature
where it doesn't — which is what guards the byte-for-byte reproducibility
the [version string](#versioning) advertises.  If a cache run rebuilt
nothing, the toolchains are unchanged and the check is skipped.

To enable the workflows, add the cachix auth token to the repo's
GitHub secrets as `CACHIX_AUTH_TOKEN` (from
[app.cachix.org/personal-auth-tokens](https://app.cachix.org/personal-auth-tokens)).
Trigger manually via the Actions tab → "Cache cross-toolchains" →
"Run workflow" to refresh without a flake change.

### Versioning

Each built artefact gets a rich `PACKAGE_VERSION` (gnumach's `version[]`
banner — what `host_get_kernel_version` returns — and MIG's `--version`),
composed at flake-eval time in `flakes/lib/default.nix` (`composeVersion`
for shipped artifacts, `composeToolchainVersion` for toolchain blocks —
see "Build-rev by artifact role" below).
It is shaped after the GNU Hurd projects' own `git describe --tags`
strings (the form their commit-hooks publish, e.g. gnumach
`v1.8+git20260224-59-g79f3013`):

```
v1.8+git20260224-g79f3013+github.paulofduarte.gnumach+build.gec67ddf
└──── describe-style core ────┘└──── fork / remote ──┘└── build ───┘
```

| field | meaning | source |
|-------|---------|--------|
| `v1.8` | upstream version, `v`-prefixed like the upstream tags | `version.m4` / `configure.ac` |
| `+git<date>` | snapshot date (`YYYYMMDD`) | `gnumach-src` input commit date |
| `-g<src>` | abbreviated source commit | `gnumach-src` input rev |
| `+<host>.<owner>.<repo>` | where the source came from | `flake.lock` (via `flakes/sources`) |
| `+build.g<rev>` | this build-system repo's commit (`-dirty` if its tree is dirty) — **shipped artifacts only** (see below) | flake `self` |

The branch is deliberately not in the fork section — `g<src>` already pins
the commit uniquely, branches move (or get deleted), and detached pins have
no branch.  `make show-srcs-pins` is where you go to see the branch a pin
tracks.

**Build-rev by artifact role.** The `+build.g<rev>` field is provenance
for the **shipped** artifacts — the gnumach kernel and the hurd userland
(the example above is a gnumach string). The **toolchain building
blocks** — gnumach-headers, hurd-headers, mig, glibc-hurd — omit it
(`composeToolchainVersion`): their identity is upstream version + source
rev, so a build-system commit must not rehash them (which would otherwise
force a gcc/glibc rebuild every commit). A single source can back both
roles — `hurd-src` yields the shipped hurd userland (with build-rev) and
the toolchain hurd-headers (without) — so two artefacts from one source
may differ by the build segment, by design. (This role split applies to
the nix-built artefacts only. The in-tree `make` splice — a dev
convenience that rewrites `src/<repo>` — is unchanged and still stamps the
build-rev for every project, so a locally-built `make mig` binary's
version differs cosmetically from the cached/nix `mig` which omits it; the
nix artefacts are the ones whose identity drives rebuilds.)

**Delimiter grammar.** `-` is the git-describe-native separator and stays
inside the core; every appended metadata section is fenced by a `+`.  Split
on `+` → four fields (three when the build-rev is omitted).

**Reproducibility.** Every field is host-independent (the source input's
locked rev/date, the fork-id from `flake.lock`, the build-repo rev — nothing derived from the build host or
the Nix `$out`), so the same commit produces the same version on every
build host. This string also seeds `-frandom-seed` (a `nix32` hash of
`<pname>-<version>`), which is part of why the kernels are byte-identical
across build hosts (see `.github/workflows` sanity check).

**Not strict semver — deliberately.** Matching the upstream Hurd tag style
breaks semver on three counts (the `v` prefix, the two-component `1.8`, and
multiple `+`). `PACKAGE_VERSION` is a free-form string (a 512-byte
`kernel_version_t`), not consumed by semver tooling, so this is fine.

**Caveats.** Because flake eval can't run `git`, the date is the HEAD
*commit* date (not a real tag's date) and there is no commit-count — so the
string is describe-*shaped* but won't always equal a true upstream tag
(real describe would be `v1.8+git20260224-59-g79f3013`, note the `-59-`).
For the nix-built path, a `src/<repo>` working tree that is dirty is
**not** reflected (flake inputs lock to the committed rev); only the
build-system repo's dirtiness shows, as a `-dirty` suffix on the `+build.`
field. Release builds should be clean — given a clean `+build.<rev>`,
`flake.lock` pins the entire toolchain (gcc, binutils + patches, libc), so
the compiler version is already determined by that rev and is additionally
recorded verbatim in the kernel's DWARF
(`readelf -p .debug_str gnumach | grep 'GNU C'`); it is intentionally
**not** duplicated into the version string.

**Local in-tree builds (`make mig` / `make mach`).** The same format is
spliced into `src/<name>/version.m4` (or `configure.ac`) before
`autoreconf`, by `flakes/sources/local-version.sh` calling the same
composer the nix path uses (`.#srcs.<name>.localVersion`). Two differences
from the nix-built string: (1) `<src>` tracks the local working clone's
`HEAD` (which may be ahead of, or independent from, the pin), and (2) when
the local `src/<name>` tree is dirty, a `-dirty` suffix appears on `-g<src>`
in addition to the existing one on `+build.`. The splice is content-aware:
when neither commit nor dirty-set has changed, the file isn't touched and
`autoreconf` does not re-fire. The version file (`version.m4` /
`configure.ac`) will show as modified in `git status` after a local build —
that's expected; the splice is local-only, comparable to what the nix
sandbox does in its private copy of the source. The dirty check
deliberately ignores the version file itself, so the splice doesn't
self-toggle `-dirty` between builds.

### Provisioning a Linux VM via cloud-init

`cloud-init.yaml` at the project root is a self-contained
[cloud-init](https://cloudinit.readthedocs.io/) recipe.  Any
cloud-init-capable Linux VM consuming it as *user-data* boots
fully wired for working on this project:

- nix multi-user installed (Determinate Nix; flakes enabled; `@sudo`
  and `@wheel` groups marked trusted-users).
- `cachix`, `git`, `gnumake`, `starship` installed into a dedicated
  system profile at `/nix/var/nix/profiles/system-tools/`, separate
  from the Determinate Nix daemon's own profile.
- System-wide PATH wiring via `/etc/profile.d/nix-system-tools.sh`
  — every user on the VM gets the tools on PATH, plus a `TERM`
  default and (for interactive bash) the starship hook.
- The project's cachix cache pre-trusted in `nix.conf` and
  `accept-flake-config = true` set, so the flake's `nixConfig`
  applies silently — `nix develop` never hangs on a trust prompt.
- For *emulated* VMs (an x86_64 VM running under rosetta/qemu-user
  on an aarch64 host), `filter-syscalls = false` is added to
  nix.conf automatically — the emulation layer can't honor seccomp
  BPF and nix would otherwise fail to install.  Native VMs leave
  the filter on.

#### How to apply

The exact invocation depends on your VM platform.  cloud-init is
supported across most of the Linux ecosystem; the user-data flag
varies in name:

| Platform | Command |
|---|---|
| AWS EC2 | `aws ec2 run-instances --user-data file://cloud-init.yaml ...` |
| GCP | `gcloud compute instances create … --metadata-from-file user-data=cloud-init.yaml` |
| Azure | `az vm create … --custom-data cloud-init.yaml` |
| Hetzner Cloud | `hcloud server create … --user-data-from-file cloud-init.yaml` |
| DigitalOcean | `doctl compute droplet create … --user-data-file cloud-init.yaml` |
| OpenStack (Nova) | `openstack server create … --user-data cloud-init.yaml` |
| `cloud-localds` + libvirt / qemu | `cloud-localds seed.iso cloud-init.yaml; qemu … -drive file=seed.iso,...` |
| multipass | `multipass launch --cloud-init cloud-init.yaml` |
| Lima | `limactl start --tty=false template://default --set '.cloudinit = "cloud-init.yaml"'` |
| OrbStack | `orb create ubuntu my-hurd-vm --user-data cloud-init.yaml` |

> **Note on OrbStack.** OrbStack offers an unusually convenient
> developer UX on Apple Silicon — fast boot, transparent
> filesystem mount of your macOS home into the VM, and one-command
> shell access — but it's commercial software with a paid tier.
> It's the smoothest path if your host is an ARM Mac and you don't
> mind the price; everything in this section works equivalently on
> any other cloud-init-capable platform listed above.

#### After boot

Once cloud-init finishes, log in once to pick up the bash hooks
(starship), then `cd` into a clone of this repo and run `make`
(or `nix develop .#<arch>` for an interactive shell).  The
cross-toolchain streams in from cachix on first use — no rebuild,
no prompts.

#### Debugging cloud-init

If user-data didn't seem to run, the canonical diagnostic commands
work on any cloud-init system:

```sh
sudo cloud-init status --long             # current state + reason
sudo cat /var/log/cloud-init.log          # full init log
sudo cat /var/log/cloud-init-output.log   # stdout/stderr from runcmd
```

### Mtime-based short-circuit

If every requested goal's sentinel artefact already exists and no
**tracked** source (per `git ls-files`) is newer than its sentinel, the
Makefile prints `Nothing to be done` and exits — without spawning Nix.
Autoreconf outputs, build artefacts, and editor backups are excluded
automatically because they're gitignored.

### Multi-target builds coexist

Build directories, install prefixes, and stamps are per-target:

```sh
make ARCH=aarch64    dist  # → dist/aarch64/
make ARCH=x86_64     dist  # → dist/x86_64/      (PC-AT)
make ARCH=x86_64-xen dist  # → dist/x86_64-xen/  (Xen domU)
make ARCH=i686       dist  # → dist/i686/        (PC-AT)
make ARCH=i686-xen   dist  # → dist/i686-xen/    (Xen domU)
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
| `x86_64-linux`    | ✅ | ~30-60 s |
| `x86_64-darwin`   | ✅ | ~30-60 s |

After that, the toolchain lives in `/nix/store` and subsequent builds
reuse it — that's where the ~40 s incremental figure above comes from.
The Makefile pins it via a gc-root under `.gcroots/<ARCH>` so
`nix-collect-garbage` won't sweep it away.

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
inside our `flakes/mig/default.nix` derivation by passing
`TESTS_ENVIRONMENT="CFLAGS=-I${gnumach-headers}/include"` on the
`make check` invocation, so we don't need a fork patch for it.

### Upstream gaps we work around

**gnumach kernel test suite.** `make check-mach` forwards into
gnumach's own `make check` for the current ARCH.  The harness
builds a GRUB-bootable ISO via `grub-mkrescue` and runs it under
`qemu-system-i386 / x86_64`; the parent Makefile passes
`USER_MIG=$(MIG_INSTALLED)` (the nix-built mig wrapper) to gnumach's
configure so the userland test binaries link against the cross MIG.
*Host constraints:* GRUB/xorriso/mtools and u-boot are only pulled
into the dev shell on Linux hosts (nixpkgs doesn't package GRUB on
darwin, and `ubootQemuAarch64` is aarch64-linux-only), so
`make check-mach` errors out early on darwin with a clear message
pointing at a Linux VM (provisioned via `cloud-init.yaml`) or
another Linux host.
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
