# Top-level Makefile for the GNU Hurd / Mach build.
#
# Usage:
#   make                  build for the host's native arch (default)
#   make ARCH=x86_64    cross-build for a different target
#   make help             list all targets (works even without nix)
#
# If invoked outside the Nix dev shell — or inside the WRONG target's shell —
# this Makefile re-enters the correct shell via `nix develop -i .#<target>`
# automatically. So all you need is `make`.
#
# Optimisations:
#   - `clean`, `clean-dist`, `mrproper`, `help` run at top level without
#     spawning a shell (they don't need the cross-toolchain).
#   - If every build target's artefact already exists, the dispatch is
#     skipped and make prints "Nothing to be done".
#
# Requires Nix (https://nix.dev/install-nix). Flake-related experimental
# features are enabled per-invocation, so no global config is needed.

# Require at least GNU Make 3.81 — that's what macOS still ships in
# /Library/Developer/CommandLineTools/usr/bin/make, and the lowest version
# that supports the features we use ($(or ...), $(eval ...), .DEFAULT_GOAL).
# Lexicographic $(sort) is a safe version-compare here: every GNU Make ever
# released sorts correctly this way up to 9.x.
MIN_MAKE_VERSION := 3.81
ifneq ($(MIN_MAKE_VERSION),$(firstword $(sort $(MIN_MAKE_VERSION) $(MAKE_VERSION))))
$(error This Makefile requires GNU Make $(MIN_MAKE_VERSION) or newer (you have $(MAKE_VERSION)))
endif

NIX_INSTALL_URL := https://nix.dev/install-nix

# ============================================================
# Always-on top-level definitions (visible to every branch).
# ============================================================

# Tooling detection
NIX := $(shell command -v nix 2>/dev/null)

# Shorthand for `nix build` / `develop` / `eval` — enables nix-command
# + flakes per invocation so users don't have to set this in nix.conf
# globally.  Every nix call below that needs flakes uses this.
NIX_FLAKE := $(NIX) --extra-experimental-features 'nix-command flakes'

# ARCH resolution: env > cmdline > host CPU default.
ifndef ARCH
_HOST_CPU := $(shell uname -m)
# $(strip) is load-bearing: the indented `$(if …)` continuation lines leave
# a leading space on the else-branch results, which would corrupt ARCH and
# every `.#$(ARCH)` flake selector / path derived from it.
# The supported targets are x86_64 + i686 (aarch64-gnu isn't upstream yet),
# so an aarch64/arm64 host — and any unrecognised host — defaults to x86_64,
# matching crossToolchain.defaultTargetName.
ARCH := $(strip \
  $(if $(filter i386 i486 i586 i686,$(_HOST_CPU)),i686, \
  x86_64))
endif

# Default MIG_TARGET when invoked outside the dev shell (the shell exports
# it). Strip any platform suffix from ARCH (e.g. i686-xen -> i686) since MIG
# only cares about CPU ABI; Xen and PC-AT share the same MIG binary.
ifndef MIG_TARGET
MIG_TARGET := $(firstword $(subst -, ,$(ARCH)))-gnu
endif
# The mig binary's base name (always a bare name) — used to locate the in-tree
# build output and for `configure --target`.  Distinct from MIG, which is the
# effective mig PROGRAM (a path): the dev shell exports MIG pointing at the
# nix-built working mig, and the in-tree opt-in (below) overrides it.
MIG_NAME := $(MIG_TARGET)-mig

# Default SCENARIO so `make run` works without an explicit override.
# The inner flakes/run/dispatch.sh also defaults to boot, but the make-level
# _RUN_PREREQS rule below needs the value at *parse time* — without
# this default, `make ARCH=x86_64 run` doesn't pick up the
# x86_64+boot → sidekick prereq and the harness errors out.
SCENARIO ?= boot

# Layout.  Two parallel tracks per component:
#   work/<comp>/<arch>/   in-tree iterative builds (fast incremental;
#                         the path for active development of that
#                         component inside `nix develop`).
#   dist/<arch>/          clean reproducible install tree (copies of
#                         nix-built artefacts; tarball-able as a
#                         release with no /nix/store runtime deps for
#                         the kernel + headers).
#
# FLAKES is source-only (the nix sub-flakes for cross-toolchain,
# gnumach-headers, mig, gnumach, sidekick).  SIDEKICK holds the
# x86_64 helper-VM artefacts at the repo root, gitignored.
PROJ          := $(CURDIR)
SRC           := $(PROJ)/src
WORK          := $(PROJ)/work
FLAKES        := $(PROJ)/flakes
SIDEKICK      := $(PROJ)/.sidekick
DIST_ROOT     := $(PROJ)/dist
# DIST is the per-arch output tree; override to install elsewhere.
# DIST_MACH / DIST_HURD / DIST_GLIBC each default to DIST (so with no override
# all dist-* targets populate one tree, dist/$(ARCH)) but can be pointed at
# separate trees independently.
DIST          ?= $(DIST_ROOT)/$(ARCH)
DIST_MACH     ?= $(DIST)
DIST_HURD     ?= $(DIST)
DIST_GLIBC    ?= $(DIST)
# dist-glibc-nix records the last-shipped nix glibc + gcc-lib store paths here —
# under work/ (NOT in the dist tree, which is the shippable artefact), per-ARCH
# in the filename so i686 and x86_64 don't clobber one stamp.  An unchanged pair
# skips the verbatim copy (the resolve is cheap, the cp ~30MB).
DIST_GLIBC_NIX_STAMP := $(WORK)/dist-glibc-nix/$(ARCH).stamp
# dist-libgcc records the last-shipped gcc-runtime store path here (same work/
# per-ARCH scheme); the gcc runtime is independent of the glibc choice.
DIST_LIBGCC_STAMP    := $(WORK)/dist-libgcc/$(ARCH).stamp

# In-tree iterative build dirs.
GNUMACH_SRC      := $(SRC)/gnumach
GNUMACH_BUILD    := $(WORK)/gnumach/$(ARCH)
GNUMACH_KERNEL   := $(GNUMACH_BUILD)/gnumach
GNUMACH_CONFIGURED := $(GNUMACH_BUILD)/config.status
# Separate build dir for the headers-only install: it configures with a stub
# USER_MIG so it can run BEFORE mig exists (mig needs the Mach headers), and
# installs into the build-only SYSROOT below — distinct from the kernel build
# dir, which uses the real mig + --prefix=$(DIST_MACH).
GNUMACH_HDR_BUILD := $(WORK)/gnumach-headers/$(ARCH)
GNUMACH_HDR_CONFIGURED := $(GNUMACH_HDR_BUILD)/config.status
# Stamp for the Mach-headers install, kept in the BUILD dir (not the sysroot).
# Consumers (mig, glibc) depend on this stamp, NOT on $(SYSROOT)/include/mach:
# glibc's own `make install` writes its mach/* wrapper headers into that shared
# dir, bumping its mtime — which, if used as a prereq, would invalidate glibc's
# config.status and loop a rebuild.  The stamp is touched only by mach-headers.
MACH_HDR_STAMP := $(GNUMACH_HDR_BUILD)/.headers-installed

# Build-only sysroot for the cross headers, populated per component (Mach now
# via `mach-headers`; Hurd later, for an opt-in glibc-from-source build).  This
# is what the in-tree mig (and future glibc) depends on — a STABLE location
# nothing installs into later.  Crucially NOT under $(DIST): the hurd userland's
# `make install` writes $(DIST)/include too, so if mig depended on the dist
# include dir, hurd's install would bump its mtime and make mig perpetually
# stale (a reconfigure/rebuild feedback loop).  Headers reach $(DIST) via the
# dist-* targets' own `make install`, not from here.
SYSROOT          := $(WORK)/sysroot/$(ARCH)

MIG_SRC          := $(SRC)/mig
MIG_BUILD        := $(WORK)/mig/$(ARCH)
MIG_INSTALL_DIR  := $(MIG_BUILD)/install
LOCAL_MIG        := $(MIG_INSTALL_DIR)/bin/$(MIG_NAME)

# mig is opt-in in-tree.  The dev shell always exports MIG (the nix-built
# working mig), so mig is available with no `make mig`.  Populating the in-tree
# source (`make src-mig`) flips MIG to the in-tree binary and turns `make mig`
# into a real build; without it `make mig` is a no-op and mach/hurd use the
# shell's MIG.  Keyed on src/mig/.git so it tracks exactly what `make src-mig`
# / `make srcs` create.
ifneq ($(wildcard $(MIG_SRC)/.git),)
MIG_IN_TREE := 1
MIG := $(LOCAL_MIG)
endif

# Hurd source clone (populated by `make srcs` from the `hurd-src` flake
# input pin) + in-tree build dir.  See the `hurd` / `dist-hurd` targets.
HURD_SRC         := $(SRC)/hurd
HURD_BUILD       := $(WORK)/hurd/$(ARCH)
HURD_CONFIGURED  := $(HURD_BUILD)/config.status

# Headers-only build dir for hurd (sibling to GNUMACH_HDR_BUILD): `make
# install-headers` populates $(SYSROOT)/include/hurd, the Hurd half of the
# sysroot the in-tree glibc builds against.
HURD_HDR_BUILD   := $(WORK)/hurd-headers/$(ARCH)
HURD_HDR_CONFIGURED := $(HURD_HDR_BUILD)/config.status
# Stamp for the Hurd-headers install (see MACH_HDR_STAMP for the why): glibc
# installs its own hurd/* headers into $(SYSROOT)/include/hurd, so glibc depends
# on this build-dir stamp instead of that shared, glibc-written directory.
HURD_HDR_STAMP := $(HURD_HDR_BUILD)/.headers-installed

# Working glibc clone (populated by `make srcs`, hackable like the kernel
# sources — see flakes/sources toolchainOnly + TOOLCHAIN-LIBC-DECOUPLING.md).
GLIBC_SRC        := $(SRC)/glibc
# OVERRIDABLE (?=): glibc's build emits objects differing only in case
# (e.g. pthread_atfork.os vs pthread_atfork.oS), which COLLIDE on a
# case-insensitive filesystem — the default on macOS — silently corrupting
# libc_nonshared.a (the symptom is "undefined reference to pthread_atfork" at
# the librt link).  The nix store is a case-sensitive APFS volume for the same
# reason.  On a case-insensitive host, point this at a case-sensitive volume:
#   make glibc GLIBC_BUILD=/Volumes/<case-sensitive>/glibc-$(ARCH)
GLIBC_BUILD      ?= $(WORK)/glibc/$(ARCH)
# glibc refuses an in-src build, so build out-of-tree under build/.  NOTE: no
# trailing inline comment on these := lines — make keeps the whitespace before
# a `#`, and an embedded space would split $(GLIBC_CONFIGURED) into two targets.
GLIBC_BUILDDIR   := $(GLIBC_BUILD)/build
GLIBC_CONFIGURED := $(GLIBC_BUILDDIR)/config.status
# `make glibc` only BUILDS (compiles) glibc — this stamp is its sentinel.
# Installs are DESTDIR-staged (glibc is configured --prefix=/, so its libc.so
# comes out root-relative — a relocatable sysroot consumed via --sysroot):
#   work-glibc  → $(SYSROOT)  (work/sysroot): the BUILD sysroot the in-tree hurd
#                 build links against, beside the mach+hurd headers — mirrors how
#                 mach-headers/hurd-headers populate $(SYSROOT).  Private.
#   dist-glibc  → $(DIST_GLIBC): the shippable copy, distribution only.
GLIBC_BUILT      := $(GLIBC_BUILDDIR)/.glibc-built

# glibc is opt-in in-tree, like mig.  The toolchain (wrapped cc) always carries
# a glibc sysroot, so glibc is available with no `make glibc`.  Populating
# src/glibc (`make src-glibc`) flips GLIBC_IN_TREE on: `make glibc` becomes a
# real raw build (mirroring flakes/cross-toolchain/glibc.nix) and the in-tree
# hurd build links against it; without it `make glibc`/`dist-glibc` are no-ops
# and the userland uses the toolchain's glibc.  Built verbatim — src/glibc must
# carry any patches it needs (e.g. the rtld cross-from-darwin fix the nix build
# applies to vanilla glibc).
ifneq ($(wildcard $(GLIBC_SRC)/.git),)
GLIBC_IN_TREE := 1
endif

# In-tree working-source overrides.  When a src/<name> clone exists, point
# the matching WORKING flake input at it (bare local path → nix git-tree
# semantics: tracked + uncommitted edits, without copying .git) so nix
# builds the working chain from local edits — the point of in-tree
# hacking.  The frozen `*-ref-src` twins are NEVER overridden, so gcc's
# reference glibc — and thus gcc — stays put: a glibc/header/mig hack
# rebuilds the working glibc + userland, never the 25-min gcc.  Applied to
# every nix invocation that builds the userland or its toolchain (dev shell
# + dist-hurd + check-glibc).  (Commit edits before cross-host verifying —
# nix caches the dirty tree per the known dirty-source nuance.)
_WORKING_SRC_NAMES := gnumach mig hurd glibc
_WORKING_OVERRIDES := $(foreach n,$(_WORKING_SRC_NAMES),\
  $(if $(wildcard $(SRC)/$(n)/.git),--override-input $(n)-src $(SRC)/$(n),))


# Dist artefacts — real copies, so each file's mtime is the cp time
# and make's regular mtime arithmetic just works (no separate stamp
# files needed, no /nix/store epoch-mtime trap).  These ARE the
# make rule targets.
#
# Note: MIG is intentionally NOT shipped in dist/.  It's a host-arch
# native binary (built per build host); mixing it with the target-arch
# kernel + headers in a single tree makes no sense for a release.
# Use `nix build .#mig-<arch>` or `make mig` (in-tree dev build) to
# get the wrapper when you need it.

# Sidekick helper VM artefacts (x86_64 Alpine; built via the root flake's
# `packages.<system>.sidekick` output — see flakes/sidekick/default.nix
# and flakes/sidekick/init.sh).  Used for ext2 module extraction
# (Gentoo/Guix) and grub-mkrescue ISO assembly (x86_64 inject mode).
SIDEKICK_KERNEL := $(SIDEKICK)/vmlinuz
SIDEKICK_INITRD := $(SIDEKICK)/initramfs.cpio.gz
SIDEKICK_STAMP  := $(SIDEKICK)/.stamp

# Hurd distro image URLs live in flakes/run/lib/distro-urls.sh (shared
# with the `nix run` apps — single source of truth).  We don't read
# them into make variables; the `run:` recipe sources the file
# inline so dispatch.sh sees them via the environment.

# ---- Help (always-on) ----
.PHONY: help
help:
	@echo "Targets (for ARCH=$(ARCH)):"
	@echo "  all              build the kernel + Hurd userland in-tree (default; = mach + hurd)"
	@echo "  mach             build gnumach kernel in-tree under ./work/gnumach/$(ARCH)/ (incremental — for kernel iteration)"
	@echo "  dist-mach        install the in-tree kernel into ./dist/$(ARCH)/ (boot/gnumach + headers + docs)"
	@echo "  dist             install kernel + Hurd userland + glibc into ./dist/$(ARCH)/ (= dist-mach + dist-hurd + a glibc step; mig is host-arch, not bundled)"
	@echo "  hurd             build the Hurd userland in-tree under ./work/hurd/$(ARCH)/ (incremental; needs ARCH=i686|x86_64)"
	@echo "  dist-hurd        install the in-tree Hurd userland into ./dist/$(ARCH)/ (under fakeroot)"
	@echo "  mig              build MIG in-tree — opt-in for iterating on MIG (run 'make src-mig' first)"
	@echo "                   (otherwise a no-op: MIG is always available without it)"
	@echo "  glibc            build glibc in-tree — opt-in for hacking glibc (run 'make src-glibc' first;"
	@echo "                   else a no-op).  The in-tree userland then links against it."
	@echo "  dist-glibc       install glibc into ./dist/$(ARCH)/ — the in-tree build if opted in (make src-glibc), else the nix deployable glibc"
	@echo "  dist-libgcc      install the gcc base runtime (libgcc_s + libstdc++) from the nix cross-gcc into ./dist/$(ARCH)/lib"
	@echo "  check            run the kernel test suite (== check-mach)"
	@echo "  check-mach       run gnumach's 'make check' (kernel tests under QEMU)"
	@echo "  run              boot the built kernel in qemu (SCENARIO=boot by default)"
	@echo "  run-help         show all 'make run' options (ARCH/SCENARIO/RUN_*)"
	@echo "  sidekick         build the helper VM (x86_64 Debian-tool dispatcher; ABI gate + Hurd run scenarios)"
	@echo "  push-cache       push the $(ARCH) build environment to the shared binary cache"
	@echo "  srcs             populate/reconcile src/ working clones from the pinned source revisions"
	@echo "  src-<name>       same, for ONE source only (e.g. 'make src-gnumach')"
	@echo "  show-srcs-pins   print the current source pins (the revisions the build uses)"
	@echo "  pin-srcs         bump the pinned source revs to their forks' branch HEADs (verbose)"
	@echo "  pin-src-<name>   same, for ONE source only (e.g. 'make pin-src-mig')"
	@echo "  check-glibc      deep ABI check: in-tree glibc vs the nix reference (opt-in 'make src-glibc'; sidekick, all hosts)"
	@echo "  check-glibc-full + heavy ABI probes (pahole/conform/acc; opt-in; sidekick, all hosts)"
	@echo "  rebaseline-ref   re-resolve the frozen reference-source pins (new gcc ABI baseline; ~25min)"
	@echo "  clean            per-subdir 'make clean' — preserves configure state"
	@echo "  clean-dist       rm -rf dist/$(ARCH)/ (just this target)"
	@echo "  mrproper         rm -rf work/ + .sidekick/ + all dist/ + cached build links"
	@if [ -z "$(NIX)" ]; then \
	  echo ""; \
	  echo "Warning: nix is not installed. Targets require it."; \
	  echo "Install from: $(NIX_INSTALL_URL)"; \
	fi

# ---- Clean targets (always-on, no toolchain needed) ----
.PHONY: clean clean-dist mrproper
# `clean` invokes each existing work subdir's own `make clean`. That
# removes object files / generated kernel / etc. while preserving
# config.status, the configured Makefile, and all of autoconf's setup —
# so the next `make` skips ./configure entirely and goes straight to
# rebuilding. The shell loop is portable across BSD/macOS and Linux
# /bin/sh; the inner make uses whatever `$(MAKE)` points to (macOS 3.81
# outside the dev shell, GNU 4.x inside) — both can handle `make clean`,
# which is just rm commands.
clean:
	@for d in $(WORK)/gnumach/*; do \
	  if [ -f "$$d/Makefile" ]; then \
	    echo "  CLEAN  $$d"; \
	    $(MAKE) --no-print-directory -C "$$d" clean; \
	  fi; \
	done
	@# gnumach's own `make clean` doesn't remove the final kernel image
	@# (it's effectively a `mostlyclean`). Explicitly remove the artefacts
	@# our sentinel tracking depends on so the next `make` correctly
	@# detects "needs rebuild".
	@rm -f $(WORK)/gnumach/*/gnumach.elf $(WORK)/gnumach/*/gnumach
	@# MIG, gnumach-headers, and the dist-mach kernel are built by
	@# nix; clean the per-target gc-roots so the next build re-pulls
	@# them from the store.
	@rm -f $(FLAKES)/mig/result-* $(FLAKES)/gnumach-headers/result-* $(FLAKES)/gnumach/result-*

clean-dist:
	@# dist/ may hold read-only trees verbatim-copied from /nix/store (e.g.
	@# dist-glibc-nix's full glibc copy); rm can't unlink inside a read-only
	@# dir, so make the tree writable first.
	@chmod -R u+w $(DIST) 2>/dev/null || true
	rm -rf $(DIST)
	@# the dist-glibc-nix / dist-libgcc store-path stamps live under work/ (they
	@# survive this rm); drop them too, else their "already shipped" record makes
	@# a later `make dist` skip re-populating the freshly-cleaned tree.
	rm -f $(DIST_GLIBC_NIX_STAMP) $(DIST_LIBGCC_STAMP)

# mrproper still nukes work/ wholesale — that's a deeper reset and we
# expect users to invoke it when they want a clean slate including
# configure state.  flakes/ holds tracked source files
# (flakes/{cross-toolchain,gnumach-headers,mig,gnumach,sidekick}/), so we
# can't `rm -rf` it; instead, scrub only the gitignored bits inside
# (result-* gc-roots) and drop the project-root install directory
# ($(SIDEKICK)) wholesale.
mrproper:
	rm -rf $(WORK)
	rm -rf $(SIDEKICK)
	rm -f  $(FLAKES)/gnumach-headers/result-* $(FLAKES)/mig/result-* $(FLAKES)/gnumach/result-* $(FLAKES)/hurd/result-*
	@# dist/ may hold read-only /nix/store copies (dist-glibc-nix); chmod so rm
	@# can unlink inside them (a read-only dir blocks removal of its entries).
	@chmod -R u+w $(DIST_ROOT) 2>/dev/null || true
	rm -rf $(DIST_ROOT)
	@# git clean each working src clone, guarded by `-d .git`: the opt-in clones
	@# (src/mig, src/glibc) may not be present, and a bare `git -C` on a missing
	@# dir would abort mrproper.
	@for s in $(GNUMACH_SRC) $(MIG_SRC) $(HURD_SRC) $(GLIBC_SRC); do \
	  if [ -d "$$s/.git" ]; then echo "  CLEAN  $$s"; git -C "$$s" clean -fdX; fi; \
	done

# ---- sidekick (always-on, arch-independent) ----
# Builds the x86_64 Alpine helper VM the harness uses for operations
# darwin can't do natively — ext2 module extraction (Gentoo/Guix) and
# grub-mkrescue ISO assembly (x86_64 inject mode for all three Hurd
# scenarios).  Output is identical x86_64 Alpine on every build host
# (no cross-compilation — we fetch prebuilt Alpine APKs), so the
# initramfs is byte-identical on darwin / linux / arm64 / x86_64.
# See flakes/sidekick/{default.nix,packages.nix,debian-packages.nix,dispatcher.sh}.
#
# Stamp-file pattern: one recipe produces both SIDEKICK_KERNEL and
# SIDEKICK_INITRD.  Make 3.81 lacks grouped targets (`&:`, Make 4.3+), so
# listing both as targets would race under `-j`; a single stamp target
# avoids that.
.PHONY: sidekick
sidekick: $(SIDEKICK_STAMP)

$(SIDEKICK_STAMP): flakes/sidekick/default.nix flakes/sidekick/packages.nix flakes/sidekick/debian-packages.nix flakes/sidekick/dispatcher.sh
	@mkdir -p $(dir $(SIDEKICK_KERNEL))
	@echo "  SIDEKICK  building helper VM (Debian userland + Alpine linux-virt kernel, generic dispatcher)…"
	$(NIX_FLAKE) build .#sidekick \
	  -o $(SIDEKICK)/result
	cp -f $(SIDEKICK)/result/vmlinuz             $(SIDEKICK_KERNEL)
	cp -f $(SIDEKICK)/result/initramfs.cpio.gz   $(SIDEKICK_INITRD)
	@touch $@

# Empty rule: artefact files exist because the stamp recipe produced
# them.  Tells Make how to satisfy a dependency on the artefact paths
# without re-running the build.
$(SIDEKICK_KERNEL) $(SIDEKICK_INITRD): $(SIDEKICK_STAMP) ;

# ---- push-cache (always-on, arch-independent) ----
# Push the FULL BUILD CLOSURE of the current ARCH's toolchain + dev shell to the
# project's cachix cache — every intermediate derivation output, not just runtime
# references.  Two roots, walked with `nix-store --requisites --include-outputs`
# (build graph + each dep's output), then the .drv files filtered out:
#   toolchain-<arch>                          the wrapped cross-cc.  Its build
#       graph already contains the whole 3-stage bootstrap chain — stage-1 cc,
#       bootstrap glibc, stage-2 cc, the reference glibc + headers/mig, the final
#       gcc and the working glibc — so this one root caches every bootstrap piece
#       without enumerating them.  A fresh machine (or a `glibc-ref-src` bump)
#       then PULLS the heavy seed compilers instead of rebuilding them.
#   devShells.<sys>.<arch>.inputDerivation    the host build tools the shell adds
#       (its output references ARE the shell's build inputs; the shell's own
#       outPath is never realised, so the inputDerivation is the buildable stand-in).
# `cachix push` skips paths already on the cache, so re-pushes are cheap and the
# nixpkgs build deps swept in by --include-outputs cost little.  This mirrors what
# a fresh CI build pushes (cachix-action posts every built path), keeping local +
# CI caches consistent.  Single-target by design (pushes $(ARCH); use ARCH=… for
# others).  Requires `cachix authtoken <token>` once per host (push authenticated,
# pull anonymous).  Runs at top level — no dev-shell dispatch.
_CACHE_NAME := hurd-build-system
# xen kernel variants reuse their CPU sibling's wrapped toolchain (there is no
# `toolchain-<cpu>-xen` output), so strip the suffix for the toolchain root.
_TC_ARCH := $(patsubst %-xen,%,$(ARCH))

.PHONY: push-cache
push-cache:
	@command -v cachix >/dev/null 2>&1 || \
	  { echo "push-cache: cachix not on PATH (install via home-manager or 'nix profile install nixpkgs#cachix')" >&2; exit 1; }
	@system=$$($(NIX) eval --raw --impure --expr 'builtins.currentSystem' 2>/dev/null); \
	roots=".#toolchain-$(_TC_ARCH) .#devShells.$$system.$(ARCH).inputDerivation"; \
	echo "==> Pushing build closure of toolchain + dev shell for $$system / $(ARCH) to '$(_CACHE_NAME)'"; \
	echo "  realising $$roots"; \
	$(NIX) --accept-flake-config build --no-link $$roots 2>/dev/null || \
	  { echo "    build failed (is ARCH=$(ARCH) a valid flake output?)" >&2; exit 1; }; \
	echo "  collecting build closure"; \
	drvs=$$($(NIX) --accept-flake-config path-info --derivation $$roots) || \
	  { echo "    could not resolve derivations" >&2; exit 1; }; \
	echo "  pushing"; \
	nix-store --query --requisites --include-outputs $$drvs \
	  | grep -v '\.drv$$' \
	  | cachix push $(_CACHE_NAME)
	@echo "==> push-cache done"

# ---- srcs (always-on, arch-independent) ----
# Populate / reconcile the src/<name> working clones from the nix source pins
# (.#srcs, derived from flake.lock).  Adds the pinned remote to an existing
# clone without clobbering the dev's other remotes, checks out the rev nix
# builds, and refuses if a working tree is dirty.  `SRCS_DRY_RUN=1 make srcs`
# previews the git commands.  Top level — no dev-shell dispatch.
.PHONY: srcs
srcs:
	@bash flakes/sources/sync.sh

# ---- pin-srcs (always-on, arch-independent) ----
# Bump the pinned source revs to their tracked refs' current HEAD, then print
# a before→after summary of what moved (so the rev change is visible in stdout
# / PR descriptions, not buried in flake.lock JSON).  Auto-discovers which
# inputs to update from `.#srcs`.  Run `make srcs` afterwards to reconcile the
# working clones to the new pins.
.PHONY: pin-srcs
pin-srcs:
	@bash flakes/sources/pin.sh

# ---- show-srcs-pins (always-on, arch-independent) ----
# Print the current source pins (from `.#srcs`) as a tabular line per source —
# read-only, no network, the at-a-glance answer to "what's nix actually
# building from."
.PHONY: show-srcs-pins
show-srcs-pins:
	@bash flakes/sources/show-pins.sh

# ---- per-source src / pin-src (always-on, arch-independent) ----
# `srcs`/`pin-srcs` operate on every source; these let you work with one at a
# time.  `make src-gnumach` reconciles just src/gnumach; `make pin-src-mig`
# bumps only the mig pin.  The source name is passed through to the same
# scripts, which validate it against .#srcs and abort on an unknown name — so
# these pattern rules need no hardcoded source list (a new *-src input gets its
# targets for free).
#
# `src-<name>` is gated by a sentinel against flake.lock: the pin it reconciles
# to is derived from flake.lock (via .#srcs), so a sync is only needed when
# flake.lock moved since the last one (e.g. after `make pin-src-<name>`).  The
# per-source stamp lives under work/ — never in src/, which a stamp would
# dirty.  When flake.lock is unchanged, `make src-<name>` is a no-op (no git
# fetch/checkout).  Removing the stamp — or `make mrproper`, which wipes work/
# — forces a re-sync; `make srcs` (all) stays unconditional as the hammer.
# (pin-src-<name> mutates flake.lock, so it is never gated.)
SRC_STAMP_DIR := $(WORK)/.src-stamps

src-%: $(SRC_STAMP_DIR)/%
	@:

$(SRC_STAMP_DIR)/%: $(PROJ)/flake.lock
	@mkdir -p $(SRC_STAMP_DIR)
	@bash flakes/sources/sync.sh $*
	@touch $@

pin-src-%:
	@bash flakes/sources/pin.sh $*

# Goals that build from each in-tree source — used to auto-bootstrap an absent
# clone (see the _dispatch gating below).  mach + the header/dist goals build
# from src/gnumach; hurd + all/dist build from src/hurd.
#
# hurd/dist-hurd don't need src/gnumach in the BASE config (their Mach headers
# come from the toolchain sysroot, mig from the shell).  But the opt-ins add a
# transitive edge to src/gnumach, so they must bootstrap it too:
#   GLIBC_IN_TREE → hurd → glibc → mach-headers → src/gnumach
#   MIG_IN_TREE   → {hurd,hurd-headers,mig} → in-tree mig → mach-headers → src/gnumach
# The glibc goals bootstrap src ONLY when opted in — the public `dist-glibc`
# without an in-tree src/ dispatches to dist-glibc-nix (a flake build, no src/
# clone), so it must NOT pull src/gnumach+hurd; only its in-tree twin
# (dist-glibc-tree) and glibc/work-glibc need the source trees.
_GNUMACH_GOALS := mach-headers mach dist-mach check check-mach all dist \
                  $(if $(GLIBC_IN_TREE),hurd dist-hurd glibc work-glibc dist-glibc dist-glibc-tree) \
                  $(if $(MIG_IN_TREE),mig hurd dist-hurd hurd-headers)
_HURD_GOALS    := hurd dist-hurd all dist hurd-headers \
                  $(if $(GLIBC_IN_TREE),glibc work-glibc dist-glibc dist-glibc-tree)

# ---- mig (no-op when not opted into in-tree; always-on, arch-independent) ----
# Without an in-tree src/mig, mig is provided by the dev shell ($MIG) — so
# `make mig` does nothing here (no dev-shell dispatch).  Run `make src-mig` to
# populate src/mig; that flips MIG_IN_TREE on and the real in-tree mig build
# (defined down in the dev-shell-dispatched rules) takes over.
ifndef MIG_IN_TREE
.PHONY: mig
mig:
	@echo "mig: provided by the dev shell; run 'make src-mig' to build in-tree."
endif

# ---- glibc (no-op when not opted into in-tree; always-on, arch-independent) ----
# Without an in-tree src/glibc, glibc comes from the toolchain (the wrapped cc's
# baked-in sysroot) — so the in-tree builds `make glibc`/`work-glibc`/
# `dist-glibc-tree` do nothing here.  Run `make src-glibc`; that flips
# GLIBC_IN_TREE on and the real raw in-tree build (defined in the dev-shell-
# dispatched rules) takes over, and the userland links it.  NOTE: the PUBLIC
# `dist-glibc` is NOT a no-op here — it dispatches to dist-glibc-nix (the nix
# deployable glibc), so `make dist`/`dist-glibc` always ship a glibc.
ifndef GLIBC_IN_TREE
.PHONY: glibc work-glibc dist-glibc-tree
glibc work-glibc dist-glibc-tree:
	@echo "$@: opt-in — run 'make src-glibc' to build glibc in-tree (or use 'make dist-glibc' for the nix glibc)."
endif

# ---- ABI gate deep checks for the IN-TREE glibc (opt-in; arch-specific) ----
# The AUTOMATIC gate (Tier-1 + cheap/Hurd Tier-3 probes 00,10-19) already runs
# inside every nix build whose working glibc diverges from the reference — no
# command needed, DWARF-free, on every host.  These targets are the EXPLICIT
# deep/full reports for the IN-TREE glibc hacker (opt-in like glibc/mig):
#   check-glibc       deep — + Tier-2 abidiff (struct/signature drift behind a
#                     stable symbol) + header self-include (probe 21).
#   check-glibc-full  full — + heavy Tier-3: pahole struct-offsets/layout, glibc
#                     conform, abi-compliance-checker (probes 20,22,23,24).
# They install the in-tree glibc into the build sysroot (work-glibc) and compare
# THAT against the frozen nix reference, host-side, via the sidekick VM — the
# Linux-only analysers (abidiff/pahole) are shipped into the Debian VM, so these
# run uniformly on EVERY host now, darwin included (no nixpkgs libabigail/pahole
# dep, no darwin skip).  Filtered out of _BUILD_GOALS: they run host-side; the
# work-glibc sub-make does the dev-shell-dispatched build+install.
.PHONY: check-glibc check-glibc-full
ifndef GLIBC_IN_TREE
check-glibc check-glibc-full:
	@echo "$@: opt-in — run 'make src-glibc' to build glibc in-tree; then this compares it"
	@echo "  against the frozen nix reference (sidekick-backed abidiff/pahole, all hosts)."
else
check-glibc:
	+$(MAKE) --no-print-directory work-glibc ARCH=$(ARCH)
	$(NIX_FLAKE) run $(PROJ)\#abi-report-host-$(ARCH) -- $(SYSROOT) deep
check-glibc-full:
	+$(MAKE) --no-print-directory work-glibc ARCH=$(ARCH)
	$(NIX_FLAKE) run $(PROJ)\#abi-report-host-$(ARCH) -- $(SYSROOT) full
endif

# ---- rebaseline-ref (always-on, arch-independent) ----
# The deliberate "the working ABI changed on purpose — accept it as the new
# baseline" action.  Re-resolves the frozen reference pins (the *-ref-src
# tags) to their current rev, so gcc rebuilds once against the new
# reference (~25 min) and the gate thereafter compares against it.  For a
# NEW release baseline, bump the tag in flake.nix first, then run this.
.PHONY: rebaseline-ref
rebaseline-ref:
	$(NIX_FLAKE) flake update glibc-ref-src gnumach-ref-src hurd-ref-src mig-ref-src

# `hurd` / `dist-hurd` recipes live in the inner-make ("in the right shell")
# branch below, alongside `mach` / `dist-mach` — see there.  They are
# _BUILD_GOALS, so the outer make dispatches them through `nix develop -i
# --profile … .#$(ARCH)` like mach; defining the recipe in the inner branch
# (not here) avoids colliding with the `$(_BUILD_GOALS): _dispatch` stub.

# ============================================================
# Categorize goals & decide whether to dispatch through nix.
# ============================================================

# Goals make will pursue (empty cmdline → default to `all`).
_GOALS := $(or $(MAKECMDGOALS),all)

# Goals that need the cross-toolchain (i.e. are NOT served by always-on rules).
# `sidekick` is filtered out here so standalone `make sidekick` invocations
# don't enter the dev shell — its nix build is arch-independent.  When pulled
# in as a prereq of `run` (which DOES dispatch), it still runs inside the
# dev shell as part of the inner-make recipe.
# `mig` is a build goal ONLY when an in-tree src/mig opts in; without it `make
# mig` is a no-op served by the shell's MIG, so it's filtered out (runs its own
# top-level recipe, no dev-shell dispatch) — like srcs/clean.
_BUILD_GOALS := $(filter-out clean clean-dist mrproper help sidekick push-cache srcs pin-srcs show-srcs-pins src-% pin-src-% $(if $(MIG_IN_TREE),,mig) $(if $(GLIBC_IN_TREE),,glibc work-glibc dist-glibc-tree) check-glibc check-glibc-full rebaseline-ref,$(_GOALS))

# A goal is "satisfied" when:
#   - every required sentinel file exists (covers transitive deps), AND
#   - no tracked file (per `git ls-files`) under its watch-dir is newer
#     than the goal's *own* final output (which would mean a real source
#     change happened after the goal was last completed).
#
# Two separate sentinel sets per goal:
#   _SENTINEL.<goal>  - the files that must exist (own output + transitive
#                       prereqs' outputs)
#   _PRIMARY.<goal>   - the goal's own final output(s); their mtime is the
#                       staleness reference for the `git ls-files -newer`
#                       check. Using the oldest of _PRIMARY (rather than
#                       of _SENTINEL) ensures we don't trip on sources
#                       that are merely newer than upstream artefacts.
#
# Goals with no entry here are conservatively always unsatisfied — dispatch
# runs and gnumach's own make decides what to do.

# The Mach-headers install sentinel.  Keyed on the build-dir STAMP, not
# $(SYSROOT)/include/mach: glibc's own install writes mach/* headers into that
# shared dir, so its mtime isn't a reliable signal (see MACH_HDR_STAMP).
_HEADERS_FILES   := $(MACH_HDR_STAMP)
# In-tree mig is a buildable input, so the built binary is a sentinel/prereq.
# The dev-shell (nix) mig is a fixed external input — not a staleness sentinel
# (else its missing-from-the-worktree path would mark mach/hurd forever stale).
ifdef MIG_IN_TREE
_MIG_FILES       := $(_HEADERS_FILES) $(LOCAL_MIG)
else
_MIG_FILES       := $(_HEADERS_FILES)
endif
_MACH_FILES      := $(_MIG_FILES) $(GNUMACH_KERNEL)
_DIST_MACH_FILES := $(DIST_MACH)/boot/gnumach

# `mach-headers` installs the Mach public headers into the build-only sysroot
# (what the in-tree mig consumes).  Watch the whole src tree (the install target
# takes every tracked .h/.defs as a prereq) — a header edit anywhere re-installs.
_SENTINEL.mach-headers := $(_HEADERS_FILES)
_PRIMARY.mach-headers  := $(MACH_HDR_STAMP)
_WATCH.mach-headers    := $(GNUMACH_SRC)

# `hurd-headers` installs the Hurd public headers into the build-only sysroot
# (the Hurd half of the in-tree glibc's --with-headers sysroot).  Private; keyed
# on the build-dir STAMP (not the shared include/hurd dir glibc writes into).
_SENTINEL.hurd-headers := $(HURD_HDR_STAMP)
_PRIMARY.hurd-headers  := $(HURD_HDR_STAMP)
_WATCH.hurd-headers    := $(HURD_SRC)

# mig compiles against the installed Mach headers (TARGET_CPPFLAGS=-I$(SYSROOT)/
# include; $(LOCAL_MIG) prereq $(MACH_HDR_STAMP)), so watch src/gnumach too:
# editing a Mach header re-installs it and rebuilds mig.
_SENTINEL.mig          := $(_MIG_FILES)
_PRIMARY.mig           := $(LOCAL_MIG)
_WATCH.mig             := $(MIG_SRC) flakes/mig $(GNUMACH_SRC)

# `glibc` — opt-in raw in-tree glibc build (GLIBC_IN_TREE).  `make glibc` only
# compiles, so the sentinel is the build stamp (not an install).  Watch
# src/glibc for source edits.
_SENTINEL.glibc        := $(GLIBC_BUILT)
_PRIMARY.glibc         := $(GLIBC_BUILT)
# glibc consumes, besides src/glibc: the mig stubs ($(GLIBC_BUILT) prereq $(MIG),
# mig opt-in) and the Mach+Hurd headers ($(GLIBC_CONFIGURED) prereqs the
# $(MACH_HDR_STAMP)/$(HURD_HDR_STAMP) stamps).  Watch all their source trees so
# editing the in-tree mig or any Mach/Hurd header re-dispatches glibc; the inner
# prereq chain then rebuilds only what actually changed.
_WATCH.glibc           := $(GLIBC_SRC) $(if $(MIG_IN_TREE),$(MIG_SRC)) $(GNUMACH_SRC) $(HURD_SRC)

# `work-glibc` (private) — install the built glibc into the build sysroot.
# Same input trees as `glibc` (it just installs that build).
_SENTINEL.work-glibc   := $(SYSROOT)/lib/libc.so.0.3
_PRIMARY.work-glibc    := $(SYSROOT)/lib/libc.so.0.3
_WATCH.work-glibc      := $(GLIBC_SRC) $(if $(MIG_IN_TREE),$(MIG_SRC)) $(GNUMACH_SRC) $(HURD_SRC)

# Watch src/gnumach for source edits and, when the mig opt-in is on, src/mig
# too (symmetric with hurd watching src/glibc): editing the in-tree mig then
# re-dispatches mach, whose prereq chain (kernel → $(LOCAL_MIG)) rebuilds mig
# and recompiles the kernel against the regenerated RPC stubs.
_SENTINEL.mach         := $(_MACH_FILES)
_PRIMARY.mach          := $(GNUMACH_KERNEL)
_WATCH.mach            := $(GNUMACH_SRC) $(if $(MIG_IN_TREE),$(MIG_SRC))

# `hurd` — userland compile.  No single output binary, so the sentinel is a
# build stamp; transitively requires mig + headers (via _MIG_FILES) and, when
# the glibc opt-in is on (GLIBC_IN_TREE), the in-tree glibc installed into the
# build sysroot.  The sentinel set MUST mirror the $(HURD_BUILD)/.built prereq
# line: otherwise, with a stale .built from a pre-opt-in build, hurd would
# short-circuit and never build/link the in-tree glibc — the same way mach's
# sentinel pulls in $(LOCAL_MIG) so an unbuilt in-tree mig forces a dispatch.
# Watch src/hurd for source edits and, when the glibc opt-in is on, src/glibc
# too: editing the in-tree glibc then re-dispatches hurd, whose prereq chain
# (.built → libc.so.0.3 → $(GLIBC_BUILT)) rebuilds glibc and relinks the
# userland against it.  src/mig is watched too (mig opt-in): hurd links the
# mig-generated stubs ($(MIG) prereq), so a mig edit must re-dispatch hurd.
# Under the glibc opt-in src/gnumach is also watched: a Mach-header edit rebuilds
# the in-tree glibc (via mach-headers), which the userland then relinks against.
# (src/hurd is already watched, covering the Hurd-header → glibc edge too.)
_SENTINEL.hurd         := $(_MIG_FILES) $(if $(GLIBC_IN_TREE),$(SYSROOT)/lib/libc.so.0.3) $(HURD_BUILD)/.built
_PRIMARY.hurd          := $(HURD_BUILD)/.built
_WATCH.hurd            := $(HURD_SRC) $(if $(MIG_IN_TREE),$(MIG_SRC)) $(if $(GLIBC_IN_TREE),$(GLIBC_SRC) $(GNUMACH_SRC))

# `all` = mach + hurd — a COMPOSITE goal: stale iff a component is stale
# (see _stale's _COMPOSE branch).  We do NOT flatten the components'
# primaries+watches into one set: that would compare the OLDEST primary
# (e.g. the gnumach kernel) against EVERY watch (incl. src/hurd), so a tree
# with hurd freshly rebuilt but gnumach untouched would falsely dispatch.
_COMPOSE.all           := mach hurd

# `dist-mach` installs the in-tree kernel into the dist tree — same source
# as `mach` (it no longer copies from the nix gnumach derivation), so it watches
# the same trees: src/gnumach + src/mig (mig opt-in) for the kernel's mig stubs.
_SENTINEL.dist-mach    := $(_DIST_MACH_FILES)
_PRIMARY.dist-mach     := $(DIST_MACH)/boot/gnumach
_WATCH.dist-mach       := $(GNUMACH_SRC) $(if $(MIG_IN_TREE),$(MIG_SRC))

# `dist-hurd` — install the userland into the dist tree.  Sentinel is the
# installed ext2fs translator (a real install result, mirroring dist-mach's
# boot/gnumach); rebuilds when src/hurd changes (which also bumps .built).
# Watches the same trees as `hurd` (it installs that build): src/mig (mig stubs)
# and, under the glibc opt-in, src/glibc + src/gnumach (the in-tree glibc).
_SENTINEL.dist-hurd    := $(DIST_HURD)/hurd/ext2fs
_PRIMARY.dist-hurd     := $(DIST_HURD)/hurd/ext2fs
_WATCH.dist-hurd       := $(HURD_SRC) $(if $(MIG_IN_TREE),$(MIG_SRC)) $(if $(GLIBC_IN_TREE),$(GLIBC_SRC) $(GNUMACH_SRC))

# `dist-glibc-tree` — install the in-tree glibc into the dist tree (the in-tree
# half of the public `dist-glibc`; opt-in).  Same input trees as `glibc` (it
# just installs that build).
_SENTINEL.dist-glibc-tree := $(DIST_GLIBC)/lib/libc.so.0.3
_PRIMARY.dist-glibc-tree  := $(DIST_GLIBC)/lib/libc.so.0.3
_WATCH.dist-glibc-tree    := $(GLIBC_SRC) $(if $(MIG_IN_TREE),$(MIG_SRC)) $(GNUMACH_SRC) $(HURD_SRC)

# `dist-glibc-nix` — ship the NIX-built deployable glibc (non-opt-in).  Staleness
# is keyed on its store-path stamp, watching the flake that defines the glibc
# (flakes/cross-toolchain: glibc.nix/toolchain.nix); a tracked edit there
# re-dispatches, the recipe re-resolves the out-path, and the stamp-compare
# skips the copy when it's unchanged.  Deliberately does NOT watch src/ trees —
# it builds from the flake, not src/gnumach+hurd (so a non-opt-in `make
# dist-glibc-nix` never triggers the _GNUMACH/_HURD bootstrap clone).
_SENTINEL.dist-glibc-nix := $(DIST_GLIBC_NIX_STAMP)
_PRIMARY.dist-glibc-nix  := $(DIST_GLIBC_NIX_STAMP)
_WATCH.dist-glibc-nix    := flakes/cross-toolchain

# `dist-libgcc` — ship the gcc target runtime (always from the nix cross-gcc,
# independent of the glibc choice).  Same store-path-stamp scheme as
# dist-glibc-nix; watches the toolchain flake (no src/ trees → no bootstrap).
_SENTINEL.dist-libgcc := $(DIST_LIBGCC_STAMP)
_PRIMARY.dist-libgcc  := $(DIST_LIBGCC_STAMP)
_WATCH.dist-libgcc    := flakes/cross-toolchain

# `dist-glibc` — the PUBLIC glibc-shipment goal; a thin composite that resolves
# to the in-tree install (dist-glibc-tree, opt-in) or the nix deployable glibc
# (dist-glibc-nix) — exactly one, chosen by GLIBC_IN_TREE.  Nesting it as a
# _COMPOSE lets the staleness recursion reach the chosen leaf's sentinel.
_COMPOSE.dist-glibc    := $(if $(GLIBC_IN_TREE),dist-glibc-tree,dist-glibc-nix)

# `dist` = dist-mach + dist-hurd + dist-glibc — COMPOSITE (same rationale as
# `all`): stale iff a component is stale, evaluated per component so the
# dist-mach primary is only ever compared against src/gnumach, the dist-hurd
# primary only against src/hurd.  (dist-mach's `make install` lays the Mach
# headers into $(DIST) already, so there is no separate headers step.)
# dist-glibc is itself a composite (the in-tree or nix glibc); dist-libgcc adds
# the gcc runtime (always from nix) — so `make dist` always lands a runnable
# /-rooted glibc + gcc runtime.
_COMPOSE.dist          := dist-mach dist-hurd dist-glibc dist-libgcc

# We rely on `git ls-files` to enumerate "real source" — anything else
# (configure, Makefile.in, autom4te.cache/, INSTALL, doc/stamp-vti, ...) is
# generated and shouldn't trigger staleness. This is authoritative: it's
# exactly what `git clean -fdX` would NOT touch.

# Resolve to the oldest existing PRIMARY sentinel for `goal` — the staleness
# reference (an ABSOLUTE path; all _PRIMARY entries are rooted at $(CURDIR)).
# Anything newer than this means real source moved after the goal completed.
#   `-d` is load-bearing: a PRIMARY may be a DIRECTORY (e.g. a dist tree's
#   install dir).  Without -d, `ls -t <dir>` lists the dir's
#   CONTENTS as bare basenames — losing the path and yielding a name that
#   _newer_tracked_one then resolves inside the (wrong) watch dir, where a
#   missing file makes every `-nt` test true → permanent false-stale.  With
#   -d, ls lists each PRIMARY entry by its own mtime (a dir as itself, the
#   absolute path preserved), which is exactly the goal's completion time.
_oldest_primary = $(shell ls -td $(_PRIMARY.$(1)) 2>/dev/null | tail -1)

# Returns any sentinel file (in the full transitive set) that doesn't exist.
_missing_sentinel = $(strip $(foreach f,$(_SENTINEL.$(1)),$(if $(wildcard $(f)),,$(f))))

# $(call _newer_tracked_one,sentinel,watch_dir) — first tracked file under
# watch_dir that's newer than `sentinel`, else empty.
_newer_tracked_one = $(shell \
  if [ -d $(2) ]; then \
    cd $(2) && git ls-files . 2>/dev/null | while IFS= read -r f; do \
      if [ "$$f" -nt "$(1)" ]; then echo "$(2)/$$f"; break; fi; \
    done; \
  fi)

# Check across all watch dirs for the goal.
_newer_tracked = $(strip $(foreach d,$(_WATCH.$(1)),$(call _newer_tracked_one,$(call _oldest_primary,$(1)),$(d))))

# $(call _stale,goal) returns non-empty if `goal` needs to be rebuilt.
#   _COMPOSE goal — non-empty iff ANY listed component is stale (recursion
#                   terminates: components are leaves with no _COMPOSE).
#   <filename>   — at least one sentinel is missing
#   <filename>   — all sentinels exist but some tracked file is newer
#   (empty)      — fresh, nothing to do
_stale = $(strip \
  $(if $(_COMPOSE.$(1)), \
    $(foreach s,$(_COMPOSE.$(1)),$(call _stale,$(s))), \
    $(if $(_SENTINEL.$(1)), \
      $(if $(call _missing_sentinel,$(1)), \
        $(call _missing_sentinel,$(1)), \
        $(call _newer_tracked,$(1))), \
      yes)))

# Detect any unsatisfied build goal.
_UNSATISFIED :=
$(foreach g,$(_BUILD_GOALS),$(if $(call _stale,$(g)),$(eval _UNSATISFIED := yes)))

# If any clean target is being run alongside build goals, force a dispatch:
# we can't trust the sentinels because clean is about to remove them.
ifneq ($(filter clean clean-dist mrproper,$(_GOALS)),)
ifneq ($(_BUILD_GOALS),)
_UNSATISFIED := yes
endif
endif

# Only enter dispatch/build logic if there are build goals to handle.
ifneq ($(_BUILD_GOALS),)

# ---- Short-circuit: everything satisfied (mtime-wise) ----
# Applies both outside the shell (skips nix dispatch) AND inside it (skips
# the spurious inner-make spawn that would otherwise happen because most
# of our final targets depend on PHONY siblings).
ifndef _UNSATISFIED
.DEFAULT_GOAL := $(firstword $(_BUILD_GOALS))
.PHONY: $(_BUILD_GOALS)
$(_BUILD_GOALS):
	@echo "make: Nothing to be done for '$@'."
_SHORTCIRCUIT := yes
endif

ifndef _SHORTCIRCUIT

# ---- Decide whether dispatch is needed ----
# Always dispatch through `nix develop -i` unless this make IS the
# dispatched inner make (signalled via _MAKE_INNER=1 on the recursive
# call below).  Trade-off: every build pays ~200-500ms for the isolated
# shell spawn; in exchange nothing from the caller's environment (direnv,
# host tools, stray `export`s) can leak into the build — the only inputs
# are what the dev shell declares.
ifndef _MAKE_INNER
NEED_DISPATCH := yes
endif

ifdef NEED_DISPATCH

ifeq ($(NIX),)
# ----- No nix installed: fail with install instructions ---------------
.DEFAULT_GOAL := _no_nix
.PHONY: _no_nix
_no_nix:
	@echo "Error: nix is not installed. This repo's build requires it."
	@echo "Install nix from: $(NIX_INSTALL_URL)"
	@echo ""
	@echo "Run 'make help' to see available targets (no nix needed)."
	@exit 1

$(_BUILD_GOALS): _no_nix
	@:

else
# ----- Nix available: dispatch through `nix develop -i .#$(ARCH)` ---
.DEFAULT_GOAL := _dispatch
.PHONY: _dispatch

# Forward the parent make's flags to the dispatched inner make.
#
# We can't use $(MAKEFLAGS) for this: macOS ships GNU Make 3.81 (2006), which
# doesn't expose `-j` in $(MAKEFLAGS) at all. So we read the parent's argv
# directly via `ps` and filter for option-like tokens (anything starting
# with `-`). Goals and variable overrides are excluded — we already pass
# MAKEOVERRIDES and _BUILD_GOALS explicitly.
_PARENT_ARGV  := $(shell ps -p $$PPID -o args= 2>/dev/null)
_PARENT_FLAGS := $(filter -%,$(_PARENT_ARGV))

# Three things to know about the recipe below:
#   - $(NIX_FLAKE) is `nix --extra-experimental-features 'nix-command
#     flakes'` (see the variable's defining comment) — so we don't
#     require the user to enable these features globally in nix.conf.
#   - We invoke bare `make` (not $(MAKE)) inside the shell so it resolves
#     via PATH to the nix-provided GNU Make 4.4+ (FIFO jobserver). $(MAKE)
#     would bake in the path of the *outer* make — on macOS that's the
#     Xcode-shipped 3.81, which doesn't understand modern -j semantics.
#   - Leading `+` marks the recipe as a recursive-make invocation so GNU
#     make honours -n / -q correctly even though the recipe contains
#     intermediate (non-make) commands.
# `nix develop -i` runs the inner shell with a clean env (the `-i`
# flag is "ignore" / isolated), so any plain env var from the caller
# gets dropped on its way into the recipe.  MAKEOVERRIDES only
# carries `NAME=val` set on the make *command line*, not env vars —
# so vars the user supplied in env form would silently vanish unless
# we explicitly forward each one.  ARCH survives because it's used
# at parse time (`.#$(ARCH)` selector) AND re-exported by the
# dev-shell shellHook; everything else needs to be listed here.
#
# If you add a new run-time knob the scenario script reads from env
# (RUN_*, SCENARIO-adjacent, etc.), add it here AND to
# _RUN_PASSTHROUGH_NAMES — otherwise it'll silently vanish for users
# who set it via env instead of `make NAME=val`.

# Tiny make-isms so we can backslash-escape embedded spaces (needed
# for RUN_ARGS="-monitor none" style values to survive as a single
# argv token into the inner make).
_NULL :=
_SP   := $(_NULL) $(_NULL)

# Persistent gc-root for the dispatched dev shell — pins the store
# closure for the current ARCH so nix-store gc doesn't reclaim it
# between Makefile invocations.  One entry per ARCH; switching
# targets just adds another sibling without invalidating the others.
_FLAKE_PROFILE := .gcroots/$(ARCH)

_RUN_PASSTHROUGH := \
  SCENARIO=$(SCENARIO) \
  RUN_VANILLA=$(RUN_VANILLA) \
  RUN_ACCEL=$(RUN_ACCEL) \
  RUN_KEEP_OVERLAY=$(RUN_KEEP_OVERLAY) \
  RUN_REFRESH=$(RUN_REFRESH) \
  RUN_ARGS=$(subst $(_SP),\$(_SP),$(RUN_ARGS))

# We intentionally do NOT forward $(MAKEOVERRIDES) here.  Two
# reasons: (1) every user-facing knob we have today is already in
# _RUN_PASSTHROUGH, and (2) MAKEOVERRIDES escapes embedded spaces
# with a literal backslash that survives shell tokenization but
# NOT make's own $(filter-out) — meaning we can't reliably filter
# out the duplicate without splitting `RUN_ARGS=-monitor\ none`
# into `RUN_ARGS=-monitor\` (filtered) + `none` (kept → leaks as
# a target name).  Dropping MAKEOVERRIDES sidesteps both problems.
# If we ever add a new cmdline-only knob the inner make needs,
# add it to _RUN_PASSTHROUGH alongside everything else.

_dispatch:
	@mkdir -p $(dir $(_FLAKE_PROFILE))
	+@$(NIX_FLAKE) develop -i --profile "$(_FLAKE_PROFILE)" .#$(ARCH) \
	  --command make --no-print-directory _MAKE_INNER=1 $(_PARENT_FLAGS) \
	    $(_RUN_PASSTHROUGH) $(_BUILD_GOALS)

$(_BUILD_GOALS): _dispatch
	@:

# Auto-bootstrap an absent in-tree source before dispatching the build.  When
# src/gnumach (resp. src/hurd) has no clone and a goal that builds from it is
# requested, make _dispatch depend on src-gnumach (resp. src-hurd): the dev
# shell can't run until the clone completes, so a bare checkout self-bootstraps
# without a manual `make srcs` — robust under -j (a hard prereq, not sibling
# ordering).  Present sources are never touched (no auto-sync; local edits are
# safe).  A stale flake.lock stamp from a since-deleted clone is dropped first
# so src-gnumach actually re-clones rather than short-circuiting.  mig stays
# opt-in — no bootstrap.
ifeq ($(wildcard $(GNUMACH_SRC)/.git),)
ifneq ($(filter $(_GNUMACH_GOALS),$(_BUILD_GOALS)),)
_RESET_GNUMACH_STAMP := $(shell rm -f $(SRC_STAMP_DIR)/gnumach 2>/dev/null)
_dispatch: src-gnumach
endif
endif
ifeq ($(wildcard $(HURD_SRC)/.git),)
ifneq ($(filter $(_HURD_GOALS),$(_BUILD_GOALS)),)
_RESET_HURD_STAMP := $(shell rm -f $(SRC_STAMP_DIR)/hurd 2>/dev/null)
_dispatch: src-hurd
endif
endif
endif

else
# ============================================================
# In the right shell, build sentinels missing — run real build rules.
# ============================================================

# Driven by environment variables that the Nix dev shell exports:
#   ARCH, GNUMACH_HOST, MIG_TARGET, CC, CXX, TARGET_CC,
#   LD, AR, NM, RANLIB, STRIP, OBJCOPY
# (No CFLAGS: post-merge the shell exports none — the kernel takes
# autoconf's `-g -O2` default + gnumach's own `-ffreestanding -nostdlib`;
# `make hurd` passes its `-fcommon …` at configure time in its own recipe.)

# ---- Sanity: must be inside a target dev shell ----
REQUIRED_VARS := ARCH GNUMACH_HOST MIG MIG_TARGET CC

$(foreach v,$(REQUIRED_VARS), \
  $(if $($(v)),,$(error $(v) is not set. Enter a dev shell first: 'nix develop .#x86_64' (or .#x86_64-xen / .#i686 / .#i686-xen))))

.PHONY: all dist mach-headers hurd-headers mig glibc work-glibc mach dist-mach dist-glibc \
        check check-mach run run-help

# Explicit default — `help` (defined above) would otherwise win the
# "first non-dot target" race.
.DEFAULT_GOAL := all

# ---- Default & top-level groupings ----
# `all` and `dist` are NOT aliases: they list real dependencies we'll
# grow over time (e.g. once Hurd userland builds, add `hurd` /
# `dist-hurd` here).
all: mach hurd

# Lockstep with _COMPOSE.dist (above): both list dist-glibc (the public glibc
# step, a composite picking the in-tree or nix glibc) + dist-libgcc (the gcc
# runtime, always from nix) — keep in sync or the staleness gate and the recipe
# disagree (silent mis-ship).
dist: dist-mach dist-hurd dist-glibc dist-libgcc

# $(call _tracked_files,<dir>) — every git-tracked file under <dir>, as
# absolute paths.  Used by the mig/mach/glibc rules to list src as prereqs so
# editing a tracked source triggers the in-tree rebuild (without it, the only
# real prereqs are configure + headers, which don't move on src edits).  Relies
# on `git ls-files` so generated files (configure, .deps/, autom4te.cache/, …)
# never cause spurious rebuilds; once a rule fires, the inner build's automake
# dep tracking handles the fine-grained .c→.o decisions.  Defined up here (ahead
# of the header rules) so the header-source lists below can use it.
_tracked_files = $(addprefix $(1)/,$(shell cd $(1) 2>/dev/null && git ls-files))

# Public-header SOURCES — real prereqs of the header-install targets: every
# tracked .h/.defs across the WHOLE kernel/userland tree.  We deliberately watch
# the entire tree rather than mapping the specific public-header folders: it's
# simpler and stays correct if the layout shifts between versions.  Editing any
# header re-runs install-data / install-headers (cheap, idempotent) and bumps
# the sysroot, so the in-tree mig + glibc reconfigure/rebuild against it; a .c
# edit never trips this (only .h/.defs are listed).  A header that isn't
# actually installed still triggers a (small, incremental) downstream rebuild —
# the safe, conservative direction.
_MACH_HDR_SRC := $(filter %.h %.defs,$(call _tracked_files,$(GNUMACH_SRC)))
_HURD_HDR_SRC := $(filter %.h %.defs,$(call _tracked_files,$(HURD_SRC)))

# In-tree builds carry the plain upstream PACKAGE_VERSION — autoreconf reads
# src/gnumach's committed version.m4 / configure.ac as-is.  The rich build-rev
# version is stamped only on the nix-built shippable artefacts (flakes/gnumach,
# flakes/mig), matching Debian/Guix (snapshot lives in the package, not the
# in-tree binary).  A hacker who wants a custom version edits version.m4.
#
# `autoreconf -i` (no -f): install missing aux files and regenerate ONLY when
# inputs are newer than outputs, so `configure`'s mtime stays stable and the
# downstream ./configure chain doesn't fire spuriously (-fi would touch every
# output unconditionally).  Run on demand by the build — there is no separate
# `prepare` step.
$(GNUMACH_SRC)/configure: $(GNUMACH_SRC)/configure.ac $(GNUMACH_SRC)/version.m4
	cd $(GNUMACH_SRC) && autoreconf -i

# ---- mach-headers (private: populates the build sysroot for in-tree mig) ----
# Install the public Mach headers into the build-only sysroot ($(SYSROOT)),
# in-tree via gnumach's `make install-data`.  This is the in-tree mig's stable
# header dependency — see the SYSROOT comment for why it must NOT be the dist
# tree.  Mirrors the flakes/gnumach-headers derivation: a separate build dir
# configured with a STUB USER_MIG=/bin/true so it can run BEFORE mig exists
# (mig needs these headers; install-data compiles nothing and never invokes
# mig, so the stub satisfies configure's AC_CHECK_PROG).  Headers-only — the
# kernel itself is never built here.
#
# Not in `make help`: it's an internal build step (mig/glibc depend on the
# $(MACH_HDR_STAMP) stamp, so it's built on demand), kept as a target only for
# manual/debug use.  The stamp (not $(SYSROOT)/include/mach) is the sentinel:
# glibc later installs its own mach/* headers into that shared dir, so the dir's
# mtime is NOT a reliable "Mach headers installed" signal — see MACH_HDR_STAMP.
mach-headers: $(MACH_HDR_STAMP)

$(GNUMACH_HDR_CONFIGURED): $(GNUMACH_SRC)/configure
	mkdir -p $(GNUMACH_HDR_BUILD)
	cd $(GNUMACH_HDR_BUILD) && \
	  USER_MIG=/bin/true \
	  $(GNUMACH_SRC)/configure --host=$(GNUMACH_HOST) --prefix=$(SYSROOT) \
	    $(if $(GNUMACH_PLATFORM),--enable-platform=$(GNUMACH_PLATFORM))

# $(_MACH_HDR_SRC) (every tracked .h/.defs in the tree) is a real prereq, so
# editing any Mach header re-runs install-data and re-touches the stamp — which
# the in-tree mig + glibc depend on.  install-data is cheap + idempotent
# (merges); a .c edit never lands here (not a .h/.defs).
$(MACH_HDR_STAMP): $(GNUMACH_HDR_CONFIGURED) $(_MACH_HDR_SRC)
	cd $(GNUMACH_HDR_BUILD) && $(MAKE) install-data
	@touch $(MACH_HDR_STAMP)

# ---- hurd-headers (private: the Hurd half of the in-tree glibc's sysroot) ----
# Install the Hurd public headers into the build-only sysroot via hurd's
# `make install-headers` — a pure file-copy walk (src/hurd/Makefile), so no
# cross compile happens; mig must be discoverable for configure's
# AC_CHECK_TOOL but isn't invoked.  Sibling to mach-headers.  Not in `make help`
# (internal — glibc depends on the $(HURD_HDR_STAMP) stamp, not the shared
# $(SYSROOT)/include/hurd dir that glibc itself writes its hurd/* headers into).
hurd-headers: $(HURD_HDR_STAMP)

$(HURD_HDR_CONFIGURED): $(HURD_SRC)/configure $(MIG)
	mkdir -p $(HURD_HDR_BUILD)
	cd $(HURD_HDR_BUILD) && \
	  $(HURD_SRC)/configure $(HURD_CONFIGURE_FLAGS) \
	    MIG=$(MIG) USER_MIG=$(MIG) --prefix=$(SYSROOT)

# $(_HURD_HDR_SRC) (every tracked .h/.defs) is a real prereq — editing any Hurd
# header re-runs install-headers and re-touches the stamp, which the in-tree
# glibc depends on.  A .c edit never lands here (not a .h/.defs).
# no_deps=t is REQUIRED (matches flakes/hurd-headers): it gates off hurd's
# dependency machinery (Makeconf: `ifneq ($(no_deps),t)`).  Without it,
# install-headers runs `directory-depend` across every subdir — generating .d
# files + mig stubs (looks like a full hurd build) — which RACES under `make -j`
# and corrupts .d files (e.g. utils/msgids.d → "missing separator"), failing the
# headers step before glibc ever configures.  With it, this is a pure header copy.
$(HURD_HDR_STAMP): $(HURD_HDR_CONFIGURED) $(_HURD_HDR_SRC)
	cd $(HURD_HDR_BUILD) && $(MAKE) install-headers prefix=$(SYSROOT) no_deps=t
	@touch $(HURD_HDR_STAMP)

# ---- mig ----
# mig is opt-in in-tree (see the MIG_IN_TREE block near LOCAL_MIG).  With
# src/mig present, `make mig` builds it in-tree: autoreconf in src/mig (writes
# gitignored files), configure + make + make install into $(MIG_INSTALL_DIR);
# the $(LOCAL_MIG) wrapper uses dirname-$0/../libexec, so its sibling migcom
# resolves under $(MIG_INSTALL_DIR)/libexec/.  Re-running after editing src/mig
# is incremental (autoreconf -i doesn't rewrite up-to-date outputs, and the
# build dir's config.status survives).  Without src/mig, mig is provided by the
# dev shell's $MIG and `make mig` is a no-op (defined top-level, near srcs).
ifdef MIG_IN_TREE
mig: $(LOCAL_MIG)
endif

MIG_SRC_FILES := $(call _tracked_files,$(MIG_SRC))
# Defined here (before the hurd recipe that uses it) so it expands non-empty:
# editing a tracked src/hurd file makes $(HURD_BUILD)/.built stale → inner make
# re-runs (hurd's own dep tracking handles the .c→.o decisions).
HURD_SRC_FILES := $(call _tracked_files,$(HURD_SRC))
ifdef MIG_IN_TREE
$(LOCAL_MIG): $(MIG_SRC)/configure $(MACH_HDR_STAMP) $(MIG_SRC_FILES)
	@mkdir -p $(MIG_BUILD)
	@# MIG is a *native* host tool — it runs on the build host and
	@# emits portable .c/.h.  The dev-shell's $CC is the wrapped
	@# `<cpu>-gnu` cross cc (cross-toolchain/dev-shell.nix), which would
	@# fail configure's "can create executables" test on the host.
	@# Override to the native gcc the dev shell also provides via
	@# pkgs.gcc; keep TARGET_CC (exported by the dev shell, the stage-1
	@# cross cc) for the cpu.symc compile.
	cd $(MIG_BUILD) && [ -f config.status ] || \
	  CC=gcc LD= AR= NM= RANLIB= STRIP= OBJCOPY= \
	  $(MIG_SRC)/configure \
	    --target=$(MIG_TARGET) \
	    --prefix=$(MIG_INSTALL_DIR) \
	    TARGET_CPPFLAGS="-I$(SYSROOT)/include"
	cd $(MIG_BUILD) && $(MAKE) CC=gcc install

$(MIG_SRC)/configure: $(MIG_SRC)/configure.ac
	cd $(MIG_SRC) && autoreconf -i
endif

# ---- glibc (opt-in raw in-tree build; mirrors flakes/cross-toolchain/glibc.nix) ----
# With src/glibc present (GLIBC_IN_TREE), build glibc from source against the
# combined Mach+Hurd sysroot.  Built with the LIBC-FREE stage-1 cc ($(GLIBC_CC),
# exported by the dev shell) — the wrapped final cc has glibc baked in, which
# would be circular.  Out-of-tree build dir (glibc refuses an in-src build).
# postInstall mirrors glibc.nix: merge the sysroot's Mach+Hurd headers into the
# install tree (so it's a complete GNU/Hurd sysroot) and augment libc.so's GROUP
# with the Mach/Hurd RPC stub libs (else every userland link fails on undefined
# __mach_port_*/__io_*/…).  Without src/glibc, `make glibc`/`dist-glibc` are
# no-ops (defined top-level, near the mig no-op).  src/glibc is built verbatim:
# it must carry any patches it needs (e.g. the rtld cross-from-darwin fix).
ifdef GLIBC_IN_TREE
GLIBC_SRC_FILES := $(call _tracked_files,$(GLIBC_SRC))

glibc: $(GLIBC_BUILT)

# Two env knobs, both mirroring what the nix glibc build gets implicitly:
#   NIX_HARDENING_ENABLE=  glibc IS the fortify provider and can't be built with
#     it; the dev shell's wrapper would otherwise re-inject -D_FORTIFY_SOURCE=3
#     *after* glibc's own -U_FORTIFY_SOURCE, turning the fortify header's
#     `syslog` into an always_inline that misc/syslog.c can't inline ("inlining
#     failed in call to always_inline syslog").  Disable hardening.
#   --prefix=/  so the installed libc.so GROUP is ROOT-RELATIVE (/lib/...),
#     making the dist a relocatable sysroot (ld resolves /-paths under
#     --sysroot).  Files are staged via DESTDIR at install time (dist-glibc).
# Depend on the header STAMPS, not $(SYSROOT)/include/{mach,hurd}: glibc's own
# `make install` writes mach/* + hurd/* headers into those shared dirs, bumping
# their mtime — keying config.status on the dirs would make glibc invalidate its
# own configure and loop a full rebuild on every subsequent make.  The stamps are
# touched only by mach-headers/hurd-headers, so a real Mach/Hurd header edit
# still re-triggers glibc, but glibc's own install does not.
$(GLIBC_CONFIGURED): $(GLIBC_SRC)/configure $(MACH_HDR_STAMP) $(HURD_HDR_STAMP)
	mkdir -p $(GLIBC_BUILDDIR)
	@# Preflight: glibc emits objects differing only in case (e.g.
	@# pthread_atfork.os vs .oS).  A case-INSENSITIVE filesystem collides them,
	@# silently corrupting libc_nonshared.a → "undefined reference to
	@# pthread_atfork" at the librt link.  Fail fast with guidance instead.
	@touch $(GLIBC_BUILDDIR)/.cstest; \
	if [ -e $(GLIBC_BUILDDIR)/.CSTEST ]; then \
	  rm -f $(GLIBC_BUILDDIR)/.cstest; \
	  echo "ERROR: $(GLIBC_BUILD) is on a case-INSENSITIVE filesystem." >&2; \
	  echo "  glibc's build needs case-sensitivity (pthread_atfork.os vs .oS collide)." >&2; \
	  echo "  Point GLIBC_BUILD at a case-sensitive volume, e.g.:" >&2; \
	  echo "    make glibc GLIBC_BUILD=/Volumes/<case-sensitive>/glibc-$(ARCH)" >&2; \
	  exit 1; \
	fi; \
	rm -f $(GLIBC_BUILDDIR)/.cstest
	cd $(GLIBC_BUILDDIR) && \
	  NIX_HARDENING_ENABLE= \
	  CC="$(GLIBC_CC)" CXX="$(GLIBC_CXX)" BUILD_CC="$(BUILD_CC)" \
	  AR="$(AR)" AS="$(AS)" LD="$(LD)" NM="$(NM)" OBJCOPY="$(OBJCOPY)" \
	  OBJDUMP="$(OBJDUMP)" RANLIB="$(RANLIB)" READELF="$(READELF)" STRIP="$(STRIP)" \
	  $(GLIBC_SRC)/configure \
	    --build=$(BUILD_TRIPLE) \
	    --host=$(GNUMACH_HOST) \
	    --prefix=/ \
	    --libdir=/lib \
	    --sysconfdir=/etc \
	    --datarootdir=/share \
	    --with-headers=$(SYSROOT)/include \
	    --with-binutils=$(BINUTILS_BIN) \
	    --enable-add-ons=libpthread \
	    --enable-obsolete-rpc \
	    --disable-profile --disable-nscd --disable-werror --disable-multilib \
	    libc_cv_ctors_header=yes \
	    libc_cv_slibdir=/lib libc_cv_rtlddir=/lib
	@# --prefix=/ leaves slibdir/rtlddir defaulting to $(exec_prefix)/lib = //lib
	@# (DOUBLE slash, baked into PT_INTERP and the libc.so GROUP; a leading // is
	@# POSIX implementation-defined).  Pin them to single-slash /lib via the
	@# libc_cv_slibdir/libc_cv_rtlddir configure cache vars (AC_SUBST'd straight
	@# into config.make — same mechanism as libc_cv_ctors_header) plus --libdir;
	@# newer glibc derives the lib dirs from these, so this is more robust than a
	@# build-dir configparms (which only overrides by include-order).
	@# --sysconfdir=/etc, --datarootdir=/share: without them --prefix=/ bakes
	@# //etc/{ld.so.cache,localtime} and //share/{locale,zoneinfo} (datarootdir,
	@# NOT datadir, drives localedir).  complocaledir needs no flag — it falls
	@# back to $(libdir)/locale = /lib/locale (libdir-derived).  These mirror the
	@# nix glibc.nix deployable set so in-tree and nix glibc bake identical paths.

# `make glibc` COMPILES only — no install (work-glibc/dist-glibc install).
# Hardening off (read at runtime by the wrapper; see the configure rule).
$(GLIBC_BUILT): $(MIG) $(GLIBC_CONFIGURED) $(GLIBC_SRC_FILES)
	cd $(GLIBC_BUILDDIR) && NIX_HARDENING_ENABLE= $(MAKE)
	@touch $(GLIBC_BUILT)

# ---- work-glibc (private: install glibc into the build sysroot) ----
# Install the built glibc into $(SYSROOT) (work/sysroot) so the in-tree hurd
# build links against it — the build counterpart to dist-glibc, beside the
# mach+hurd headers that mach-headers/hurd-headers already put there.  Staged via
# DESTDIR; --prefix=/ → root-relative libc.so, resolved via --sysroot=$(SYSROOT)
# at the hurd link.  $(SYSROOT)/include already holds the Mach+Hurd headers, so
# no merge is needed (glibc just adds its own).  Augment libc.so's GROUP with the
# Hurd RPC stub libs (root-relative).  Not in `make help` (internal).
work-glibc: $(SYSROOT)/lib/libc.so.0.3

$(SYSROOT)/lib/libc.so.0.3: $(GLIBC_BUILT)
	cd $(GLIBC_BUILDDIR) && NIX_HARDENING_ENABLE= $(MAKE) install DESTDIR=$(SYSROOT)
	chmod -R u+w $(SYSROOT)/lib
	sed -i.bak '/^GROUP/ s|)$$| /lib/libmachuser.so /lib/libhurduser.so )|' $(SYSROOT)/lib/libc.so
	rm -f $(SYSROOT)/lib/libc.so.bak
	@grep -q libmachuser $(SYSROOT)/lib/libc.so || { echo "ERROR: libc.so not augmented"; exit 1; }
	@# i386: in-tree binaries request the /lib/ld.so interpreter; glibc names the
	@# loader ld.so.1 — ship the compat alias (no-op on x86_64: ld-x86-64.so.1).
	@[ -e $(SYSROOT)/lib/ld.so.1 ] && ln -sf ld.so.1 $(SYSROOT)/lib/ld.so || true

# ---- dist-glibc-tree (in-tree half of the public dist-glibc) ----
# Install the built glibc into the dist tree (opt-in; DIST_GLIBC defaults to
# DIST, overridable for a separate sysroot).  Staged via DESTDIR — glibc REJECTS
# `make install prefix=...` (Makerules: "Set DESTDIR instead"), and DESTDIR is
# the right tool anyway.  Configured --prefix=/, so the installed libc.so is
# already ROOT-RELATIVE (/lib/...) — a relocatable sysroot, consumed via
# --sysroot=$(DIST_GLIBC) (the in-tree hurd build does this) or deployed to /.
# Then merge the Mach+Hurd kernel headers (glibc install-headers omits them) and
# augment libc.so's GROUP with the Hurd RPC stub libs (root-relative) — else
# every userland link fails on undefined __mach_port_*/__io_*/….  This is the
# ONLY place the in-tree glibc is installed; `make hurd` (in-tree glibc) depends on it.
dist-glibc-tree: $(DIST_GLIBC)/lib/libc.so.0.3

$(DIST_GLIBC)/lib/libc.so.0.3: $(GLIBC_BUILT)
	chmod -R u+w $(DIST_GLIBC) 2>/dev/null || true
	cd $(GLIBC_BUILDDIR) && NIX_HARDENING_ENABLE= $(MAKE) install DESTDIR=$(DIST_GLIBC)
	chmod -R u+w $(DIST_GLIBC)/include
	cp -an $(SYSROOT)/include/. $(DIST_GLIBC)/include/ ; chmod -R u+w $(DIST_GLIBC)/include
	sed -i.bak '/^GROUP/ s|)$$| /lib/libmachuser.so /lib/libhurduser.so )|' $(DIST_GLIBC)/lib/libc.so
	rm -f $(DIST_GLIBC)/lib/libc.so.bak
	@# i386 /lib/ld.so interpreter compat alias (see work-glibc).
	@[ -e $(DIST_GLIBC)/lib/ld.so.1 ] && ln -sf ld.so.1 $(DIST_GLIBC)/lib/ld.so || true
	@ls $(DIST_GLIBC)/lib/libc.so.0.3 >/dev/null || { echo "ERROR: libc.so.0.3 missing"; exit 1; }
	@grep -q libmachuser $(DIST_GLIBC)/lib/libc.so || { echo "ERROR: libc.so not augmented"; exit 1; }
endif

# ---- dist-glibc (PUBLIC) ----
# The one public glibc-shipment target: dispatch to the in-tree install
# (dist-glibc-tree, when src/glibc is opted in) or the nix deployable glibc
# (dist-glibc-nix) — never both.  `dist` and _COMPOSE.dist[-glibc] reference
# THIS; the two halves below are private (not in `make help`).
.PHONY: dist-glibc
dist-glibc: $(if $(GLIBC_IN_TREE),dist-glibc-tree,dist-glibc-nix)

# Ship the NIX-built deployable glibc into the dist tree — the NON-opt-in glibc
# shipment (the nix half of the public dist-glibc; counterpart to the opt-in
# dist-glibc-tree above).  The nix glibc is configured --prefix=/ (deployPrefix),
# so its whole $out tree (lib + loader + already-augmented GROUP, include, share,
# bin, sbin, …) is ROOT-RELATIVE — a verbatim `cp -a` of the FULL tree IS a
# deployable sysroot.  cp -a clones the store's read-only perms, so chmod -R u+w
# after (else mrproper/clean-dist can't rm it).  NB: glibc's /bin helper SCRIPTS
# (ldd/tzselect/xtrace/mtrace/sotruss) carry a nixpkgs-rewritten /nix/store bash
# shebang — a cosmetic leak in those dev scripts only; the ELF tools
# (sln/zic/iconvconfig/getconf/…) are /-clean.  The gcc runtime (libgcc_s,
# libstdc++, …) is NOT here — it ships via `dist-libgcc` (it's a gcc artefact,
# not glibc, and must ship the same whether glibc is in-tree or nix).  Built
# from the flake (not src/), so no _GNUMACH/_HURD bootstrap clone; store-path-
# stamped so an unchanged glibc skips the copy.  nix is available in the dev shell.
.PHONY: dist-glibc-nix
dist-glibc-nix: $(DIST_GLIBC_NIX_STAMP)

$(DIST_GLIBC_NIX_STAMP): packages.nix flake.lock flakes/cross-toolchain/glibc.nix flakes/cross-toolchain/toolchain.nix
	@mkdir -p $(DIST_GLIBC)/lib $(dir $(DIST_GLIBC_NIX_STAMP))
	@echo "  DIST-GLIBC-NIX  resolving nix glibc-hurd-$(ARCH)…"
	@set -e; \
	glibc=$$($(NIX_FLAKE) build $(_WORKING_OVERRIDES) $(PROJ)\#glibc-hurd-$(ARCH) --no-link --print-out-paths); \
	if [ "$$(cat $(DIST_GLIBC_NIX_STAMP) 2>/dev/null)" = "$$glibc" ] && [ -e $(DIST_GLIBC)/lib/libc.so.0.3 ]; then \
	  echo "  unchanged ($$(basename $$glibc)) — skip copy"; \
	else \
	  echo "  copying $$glibc -> $(DIST_GLIBC) (full glibc tree)"; \
	  chmod -R u+w $(DIST_GLIBC) 2>/dev/null || true; \
	  cp -a $$glibc/. $(DIST_GLIBC); \
	  chmod -R u+w $(DIST_GLIBC) 2>/dev/null || true; \
	  printf '%s' "$$glibc" > $(DIST_GLIBC_NIX_STAMP); \
	fi
	@ls $(DIST_GLIBC)/lib/libc.so.0.3 >/dev/null || { echo "ERROR: libc.so.0.3 missing"; exit 1; }
	@grep -q libmachuser $(DIST_GLIBC)/lib/libc.so || { echo "ERROR: libc.so GROUP not augmented"; exit 1; }

# ---- dist-libgcc ----
# Ship the gcc TARGET RUNTIME into the dist tree — ALWAYS from the nix cross-gcc
# (cross-toolchain), independent of the glibc choice (the runtime is a gcc
# artefact, not glibc; an in-tree glibc doesn't change it).  Ships only the BASE
# runtime — libgcc_s + libstdc++ — each as a SINGLE real .so named by its SONAME
# (libgcc_s.so.1, libstdc++.so.6), the form gcc already gives libgcc_s.  gcc
# ships libstdc++ as libstdc++.so.6.0.34 + a libstdc++.so.6 SONAME symlink; we
# collapse that to one real libstdc++.so.6 (the loader opens the SONAME
# directly, so no symlink is needed and the layout matches libgcc_s).  NOT
# shipped: the bare `.so` dev/link symlinks, the full-version duplicate, the
# libstdc++*-gdb.py pretty-printer, the situational libs
# (libatomic/libitm/libquadmath/libssp, which a C Hurd userland doesn't use; add
# via a DT_NEEDED scan if a future binary needs one).  The libs ship
# RUNPATH=/lib straight from the gcc build (mkGcc bakes `-rpath /lib` and drops
# the store rpath — toolchain.nix), so no rpath scrub is needed; a plain
# copy-by-SONAME (cp -L of libgcc_s.so.1 + libstdc++.so.6) suffices — no patchelf.
# glibc dlopen()s libgcc_s for backtrace()/Hurd assert_backtrace (a DT_NEEDED
# scan misses it), so it MUST be present.  The runtime dir is found by `find`ing
# libgcc_s.so.1 (no hard-coded target tuple); store-path-stamped under work/ so
# an unchanged gcc skips the copy.
.PHONY: dist-libgcc
dist-libgcc: $(DIST_LIBGCC_STAMP)

$(DIST_LIBGCC_STAMP): flake.lock flakes/cross-toolchain/toolchain.nix
	@mkdir -p $(DIST)/lib $(dir $(DIST_LIBGCC_STAMP))
	@echo "  DIST-LIBGCC  resolving nix cross-gcc-$(ARCH) runtime…"
	@set -e; \
	gcclib=$$($(NIX_FLAKE) build $(PROJ)\#cross-gcc-$(ARCH)^lib --no-link --print-out-paths); \
	if [ "$$(cat $(DIST_LIBGCC_STAMP) 2>/dev/null)" = "$$gcclib" ] && [ -e $(DIST)/lib/libgcc_s.so.1 ]; then \
	  echo "  unchanged ($$(basename $$gcclib)) — skip copy"; \
	else \
	  rtdir=$$(dirname $$(find $$gcclib -name libgcc_s.so.1 | head -1)); \
	  echo "  copying gcc base runtime (libgcc_s, libstdc++) from $$rtdir -> $(DIST)/lib"; \
	  chmod -R u+w $(DIST)/lib 2>/dev/null || true; \
	  for soname in libgcc_s.so.1 libstdc++.so.6; do \
	    cp -L "$$rtdir/$$soname" "$(DIST)/lib/$$soname"; \
	    chmod u+w "$(DIST)/lib/$$soname"; \
	  done; \
	  printf '%s' "$$gcclib" > $(DIST_LIBGCC_STAMP); \
	fi
	@ls $(DIST)/lib/libgcc_s.so.1  >/dev/null || { echo "ERROR: libgcc_s.so.1 missing";  exit 1; }
	@ls $(DIST)/lib/libstdc++.so.6 >/dev/null || { echo "ERROR: libstdc++.so.6 missing"; exit 1; }

# ---- mach ----
# In-tree kernel build under $(GNUMACH_BUILD), using $(MIG) — the effective
# mig: the dev-shell's nix mig, or the in-tree build when src/mig opts in.
# USER_MIG/MIG point at it explicitly so gnumach's AC_CHECK_TOOL doesn't have
# to discover it via PATH.  Incremental compile — re-running `make mach` after
# editing src/gnumach rebuilds only the changed translation units.
mach: $(GNUMACH_KERNEL)

$(GNUMACH_CONFIGURED): $(GNUMACH_SRC)/configure $(MIG)
	mkdir -p $(GNUMACH_BUILD)
	cd $(GNUMACH_BUILD) && \
	  USER_MIG=$(MIG) MIG=$(MIG) \
	  $(GNUMACH_SRC)/configure --host=$(GNUMACH_HOST) --prefix=$(DIST_MACH) \
	    $(if $(GNUMACH_PLATFORM),--enable-platform=$(GNUMACH_PLATFORM))

# Src prereqs via $(_tracked_files) — see its defining comment above.
GNUMACH_SRC_FILES := $(call _tracked_files,$(GNUMACH_SRC))
$(GNUMACH_KERNEL): $(MIG) $(GNUMACH_CONFIGURED) $(GNUMACH_SRC_FILES)
	cd $(GNUMACH_BUILD) && $(MAKE)

# ---- dist-mach ----
# Install the in-tree kernel build into $(DIST_MACH).  Counterpart to `mach`:
#   `make mach`       — in-tree compile under work/, fast iteration.
#   `make dist-mach`  — `make install` that in-tree build into $(DIST_MACH)
#                       (gnumach configured --prefix=$(DIST_MACH)); kernel
#                       under boot/ + the share/ docs (mach.info, msgids).
# Depends on the compiled kernel, so it builds first if needed.  gnumach's
# install is plain (no setuid/-o root), so no fakeroot needed here.
dist-mach: $(DIST_MACH)/boot/gnumach

$(DIST_MACH)/boot/gnumach: $(GNUMACH_KERNEL)
	cd $(GNUMACH_BUILD) && $(MAKE) install prefix=$(DIST_MACH)

# ---- hurd / dist-hurd ----
# `make hurd`      — in-tree incremental userland build under
#                    work/hurd/$(ARCH).  Counterpart to `make mach`: edit
#                    src/hurd, re-run, only changed objects recompile.
# `make dist-hurd` — `make install` that in-tree build into dist/$(ARCH).
#
# Aligned with mach: in-tree `make hurd` runs as plain `cd … && make/
# configure` inside the dispatched per-arch dev shell (no inner `nix develop`
# — the pre-merge dual-toolchain era gave hurd its own `.#hurd-$(ARCH)` shell
# + HURD_DEVELOP; the single merged toolchain made that a redundant, un-pinned
# second realization).  The shell exports CC/binutils + HURD_CONFIGURE_FLAGS
# (flakes/cross-toolchain/dev-shell.nix); the recipes add MIG=$(MIG)
# (the same effective mig as mach) + CFLAGS=-fcommon at configure time (hurd
# predates gcc's -fno-common default; scoped here so the kernel never sees it).
.PHONY: hurd dist-hurd

# `make hurd` builds the userland under work/hurd/$(ARCH).  Unlike mach (whose
# kernel is a single file sentinel, $(GNUMACH_KERNEL)), hurd produces many
# outputs and no single binary, so we use a build stamp ($(HURD_BUILD)/.built)
# as its sentinel — touched after a successful compile.  Combined with the
# _SENTINEL.hurd / _WATCH.hurd entries above, a no-op `make hurd` short-circuits
# (no dispatch, no recursing every subdir printing "nothing to be done") unless
# a tracked src/hurd file is newer than the stamp.  The $(HURD_SRC_FILES) prereq
# makes the inner make re-run when source actually changed.
hurd: $(HURD_BUILD)/.built

# With an in-tree glibc (GLIBC_IN_TREE), the userland must link against it, not
# the wrapped cc's baked-in toolchain glibc.  It links against the BUILD sysroot
# $(SYSROOT) (work/sysroot) — where work-glibc installs glibc beside the
# mach+hurd headers — NOT the dist tree (DIST_GLIBC is distribution-only).
# Depend on the work-glibc output ($(SYSROOT)/lib/libc.so.0.3 → pulls work-glibc)
# and pass --sysroot=$(SYSROOT); ld resolves the root-relative libc.so GROUP
# under that sysroot.
_HURD_SYSROOT := $(if $(GLIBC_IN_TREE),--sysroot=$(SYSROOT))

$(HURD_BUILD)/.built: $(MIG) $(if $(GLIBC_IN_TREE),$(SYSROOT)/lib/libc.so.0.3) $(HURD_CONFIGURED) $(HURD_SRC_FILES)
	cd $(HURD_BUILD) && $(MAKE) MIG=$(MIG) USER_MIG=$(MIG)
	@touch $(HURD_BUILD)/.built

# In-tree builds carry the plain upstream PACKAGE_VERSION (autoreconf reads
# src/hurd's committed configure.ac as-is).  The rich build-rev version is
# stamped only on the nix-built shippable artefacts (flakes/hurd).
$(HURD_SRC)/configure: $(HURD_SRC)/configure.ac
	cd $(HURD_SRC) && autoreconf -i

$(HURD_CONFIGURED): $(MIG) $(if $(GLIBC_IN_TREE),$(SYSROOT)/lib/libc.so.0.3) $(HURD_SRC)/configure
	mkdir -p $(HURD_BUILD)
	cd $(HURD_BUILD) && \
	  $(HURD_SRC)/configure $(HURD_CONFIGURE_FLAGS) \
	    MIG=$(MIG) USER_MIG=$(MIG) \
	    CFLAGS="-fcommon -g -O2 $(_HURD_SYSROOT)" \
	    $(if $(GLIBC_IN_TREE),LDFLAGS="$(_HURD_SYSROOT)") \
	    --prefix=/ --libexecdir=/libexec --bindir=/bin --sbindir=/sbin \
	    --sysconfdir=/etc --localstatedir=/var --libdir=/lib --includedir=/include

# Install the in-tree userland build into $(DIST_HURD) as a self-contained
# tree.  Counterpart to `hurd`: `make hurd` is fast in-tree iteration; `make
# dist-hurd` produces the installable artefact (like dist-mach).
dist-hurd: $(DIST_HURD)/hurd/ext2fs

# Install the in-tree userland build into $(DIST_HURD).  Configured --prefix=/
# (root-relative baked paths — LIBEXECDIR=/libexec etc. so a deployed tree finds
# its own console-run/servers), staged via DESTDIR.  Under fakeroot: hurd's
# daemons/ + utils/ install
# some programs `-o root -m 4755` (setuid), which a non-root install can't do
# — fakeroot fakes the chown/setuid so the install completes without touching
# real privilege (the bits are cosmetic for a dev dist tree).  Same MIG as the
# build.  Keyed on the installed ext2fs translator — the headline userland
# output, the analog of dist-mach's boot/gnumach — so dist/ holds only install
# results (no completion stamp).  `make install` rebuilds the whole tree; make
# only compares ext2fs's mtime against the build stamp to decide staleness.
$(DIST_HURD)/hurd/ext2fs: $(HURD_BUILD)/.built
	cd $(HURD_BUILD) && fakeroot $(MAKE) install DESTDIR=$(DIST_HURD) \
	  MIG=$(MIG) USER_MIG=$(MIG)

# ---- check ----
# Test suite shipped by upstream gnumach, surfaced as a make target:
#
#   check-mach : gnumach's 'make check' — kernel tests run inside QEMU.
#                Upstream wiring is i386/x86_64-multiboot; aarch64 may
#                need additional plumbing in src/gnumach/tests/.
#   check      : alias for check-mach (kept for convention/familiarity).
#
# MIG's own test-suite has no make target — it runs inline via doCheck=true
# on every `nix build .#mig-<arch>`, which is transitively triggered by
# `make dist-mach` / `make dist` (the gnumach derivation depends on mig
# via the cross-toolchain).
#
# No _SENTINEL entries — running a test suite is not idempotent, so we
# always dispatch and let the inner make decide.

# The kernel test suite runs on every ARCH we support; xen variants
# self-skip via gnumach's tests/Makefrag.am (`if !PLATFORM_xen` wraps
# the whole tests block) so they no-op without our help.
#
# Darwin can't host check-mach for any target: each target's test
# harness needs a real bootloader that nixpkgs can't build on darwin.
#   - x86_64 / i686: grub-mkrescue / xorriso / mtools — grub2's
#     meta.platforms = linux-only; upstream GRUB doesn't compile
#     cleanly on darwin.
#   - aarch64:       u-boot.bin + mkimage — ubootQemuAarch64 and
#     ubootTools are linux-only in nixpkgs and upstream u-boot's
#     envtools / scripts_dtc collide with darwin's <sys/types.h>
#     (ino_t conflict).
# Fail early with a clear message rather than letting the run die
# mid-pipeline at `<tool>: command not found`.
ifeq ($(shell uname -s),Darwin)
check-mach:
	@echo "==> check-mach ($(ARCH)): ERROR — darwin host is not supported." >&2
ifeq ($(ARCH),aarch64)
	@echo "    aarch64 tests boot through u-boot, which nixpkgs only" >&2
	@echo "    builds on linux (ubootQemuAarch64 / ubootTools are" >&2
	@echo "    linux-only; upstream u-boot doesn't compile cleanly" >&2
	@echo "    on darwin)." >&2
else
	@echo "    x86 tests build a GRUB-bootable ISO via grub-mkrescue," >&2
	@echo "    which nixpkgs only builds on linux (grub2's" >&2
	@echo "    meta.platforms is linux-only; upstream GRUB doesn't" >&2
	@echo "    compile cleanly on darwin)." >&2
endif
	@echo "    Run the tests from a Linux host (orbstack, docker," >&2
	@echo "    native, CI)." >&2
	@exit 1
else
check-mach: mach
	@echo "==> check-mach ($(ARCH)): running gnumach 'make check' in $(GNUMACH_BUILD)"
	cd $(GNUMACH_BUILD) && $(MAKE) check
endif

check: check-mach

# ---- run ----
# `make run ARCH=<arch> SCENARIO=<name>` — ad-hoc qemu launch against
# the kernel we just built.  Architecture comes from ARCH (same
# convention as everything else in this build); SCENARIO selects what
# to do with the built kernel:
#
#   boot          bare kernel via qemu -kernel (all arches)
#   hurd-debian   Debian Hurd userland (x86_64/i686, direct-inject)
#   hurd-gentoo   Gentoo Hurd userland (x86_64/i686, hybrid-extract)
#   hurd-guix     Guix childhurd       (x86_64/i686, hybrid-extract)
#
# Modifier flags:
#   RUN_VANILLA=1       boot the distro's bundled kernel (Hurd only)
#   RUN_ACCEL=1         -accel hvf/kvm when host arch matches ARCH
#   RUN_KEEP_OVERLAY=1  reuse the per-run qcow2 overlay across runs
#   RUN_ARGS="..."      extra flags appended to qemu (e.g., "-s -S")
#
# Prereqs depend on (SCENARIO, RUN_VANILLA).  flakes/run/dispatch.sh
# rejects RUN_VANILLA=1 + SCENARIO=boot upfront (no distro kernel
# to fall back to), so the only case where the kernel isn't needed
# is RUN_VANILLA=1 + hurd-*.  Everything else requires `mach`.
#
#   mach       — needed for all non-vanilla scenarios.
#   sidekick   — needed for ANY hurd-* scenario (regenerates the
#                qcow2's grub.cfg so it boots on serial under
#                -nographic; non-vanilla also overlays our kernel).
#                Also needed for boot + ARCH=x86_64 (qemu's -kernel
#                rejects 64-bit ELFs, see D18; routes through
#                GRUB-on-ISO via mkiso).
#
# Cells (evaluated at Makefile-parse time):
#   RUN_VANILLA=1 + hurd-*               → sidekick
#   RUN_VANILLA=1 + boot                 → (rejected by dispatch.sh; no prereq matters)
#   boot + ARCH=i686/aarch64             → mach
#   boot + ARCH=x86_64                   → mach sidekick
#   non-vanilla hurd-*                   → mach sidekick
_RUN_PREREQS := \
  $(if $(filter 1,$(RUN_VANILLA)), \
    $(if $(filter hurd-debian hurd-gentoo hurd-guix,$(SCENARIO)),sidekick), \
    mach \
    $(if $(filter hurd-debian hurd-gentoo hurd-guix,$(SCENARIO)),sidekick, \
      $(if $(and $(filter x86_64,$(ARCH)),$(filter boot,$(SCENARIO))),sidekick)))

# Each run is NOT idempotent, so no _SENTINEL entry — every invocation
# re-enters dispatch and re-checks `mach` (skipped if fresh).
run: $(_RUN_PREREQS)
	@. ./flakes/run/lib/distro-urls.sh && \
	 GNUMACH_KERNEL="$(GNUMACH_KERNEL)" \
	 ARCH="$(ARCH)" \
	 WORK="$(WORK)" \
	 RUN_VANILLA="$(RUN_VANILLA)" \
	 RUN_ACCEL="$(RUN_ACCEL)" \
	 RUN_KEEP_OVERLAY="$(RUN_KEEP_OVERLAY)" \
	 RUN_REFRESH="$(RUN_REFRESH)" \
	 SIDEKICK_KERNEL="$(SIDEKICK_KERNEL)" \
	 SIDEKICK_INITRD="$(SIDEKICK_INITRD)" \
	 HURD_DEBIAN_X86_64_URL="$$HURD_DEBIAN_X86_64_URL" \
	 HURD_DEBIAN_I686_URL="$$HURD_DEBIAN_I686_URL" \
	 HURD_GENTOO_X86_64_URL="$$HURD_GENTOO_X86_64_URL" \
	 HURD_GENTOO_I686_URL="$$HURD_GENTOO_I686_URL" \
	 HURD_GUIX_I686_URL="$$HURD_GUIX_I686_URL" \
	 HURD_GUIX_X86_64_URL="$$HURD_GUIX_X86_64_URL" \
	 ./flakes/run/dispatch.sh "$(SCENARIO)" $(RUN_ARGS)

# `run-help` has no prereqs — dispatch.sh handles --help before any
# env validation, so the help text works from a clean checkout without
# a built kernel.
run-help:
	@./flakes/run/dispatch.sh --help

endif # NEED_DISPATCH

endif # _SHORTCIRCUIT

endif # _BUILD_GOALS not empty
