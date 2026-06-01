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

# Default MIG_TARGET / MIG binary name when invoked outside the dev shell
# (the shell itself exports the right values). Strip any platform suffix
# from ARCH (e.g. i686-xen -> i686) since MIG only cares about CPU ABI;
# Xen and PC-AT share the same MIG binary.
ifndef MIG_TARGET
MIG_TARGET := $(firstword $(subst -, ,$(ARCH)))-gnu
endif
ifndef MIG
MIG := $(MIG_TARGET)-mig
endif

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
# DIST_MACH / DIST_HURD / DIST_HEADERS each default to DIST (so with no
# override all dist-* targets populate one tree, dist/$(ARCH)) but can be
# pointed at separate trees independently.
DIST          ?= $(DIST_ROOT)/$(ARCH)
DIST_MACH     ?= $(DIST)
DIST_HURD     ?= $(DIST)
DIST_HEADERS  ?= $(DIST)

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

# Build-only sysroot for the public Mach headers.  This is what mig (and any
# other in-tree consumer) depends on — a STABLE location that nothing installs
# into later in the build.  Crucially NOT under $(DIST): the hurd userland's
# `make install` writes $(DIST)/include too, so if mig depended on the dist
# include dir, hurd's install would bump its mtime and make mig perpetually
# stale (a reconfigure/rebuild feedback loop).  dist-headers copies from here
# into the user-facing $(DIST) tree purely as a packaging step.
SYSROOT          := $(WORK)/sysroot/$(ARCH)

MIG_SRC          := $(SRC)/mig
MIG_BUILD        := $(WORK)/mig/$(ARCH)
MIG_INSTALL_DIR  := $(MIG_BUILD)/install
LOCAL_MIG        := $(MIG_INSTALL_DIR)/bin/$(MIG)

# Hurd source clone (populated by `make srcs` from the `hurd-src` flake
# input pin) + in-tree build dir.  See the `hurd` / `dist-hurd` targets.
HURD_SRC         := $(SRC)/hurd
HURD_BUILD       := $(WORK)/hurd/$(ARCH)
HURD_CONFIGURED  := $(HURD_BUILD)/config.status

# Working glibc clone (populated by `make srcs`, hackable like the kernel
# sources — see flakes/sources toolchainOnly + TOOLCHAIN-LIBC-DECOUPLING.md).
GLIBC_SRC        := $(SRC)/glibc

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
	@echo "  all              build the gnumach kernel in-tree (default; same as 'mach')"
	@echo "  prepare          autoreconf the source trees"
	@echo "  dist-headers     copy gnumach public headers into ./dist/$(ARCH)/include (via nix)"
	@echo "  mig              build MIG in-tree under ./work/mig/$(ARCH)/ (incremental — for MIG iteration)"
	@echo "                   (clean nix-built MIG is available via 'nix build .#mig-$(ARCH)')"
	@echo "  mach             build gnumach kernel in-tree under ./work/gnumach/$(ARCH)/ (incremental — for kernel iteration)"
	@echo "  dist-mach        copy clean nix-built kernel into ./dist/$(ARCH)/boot/gnumach"
	@echo "  dist             produce a tarball-ready ./dist/$(ARCH)/ (headers + kernel; mig is host-arch, not bundled)"
	@echo "  hurd             build the Hurd userland in-tree under ./work/hurd/$(ARCH)/ (incremental; needs ARCH=i686|x86_64)"
	@echo "  dist-hurd        copy clean nix-built Hurd userland into ./dist/$(ARCH)/hurd/"
	@echo "  check            run upstream test suites (== check-mach; MIG tests run inline via nix)"
	@echo "  check-mach       run gnumach's 'make check' (kernel tests under QEMU)"
	@echo "  run              boot the built kernel in qemu (SCENARIO=boot by default)"
	@echo "  run-help         show all 'make run' options (ARCH/SCENARIO/RUN_*)"
	@echo "  sidekick         build the helper VM (x86_64 Alpine, used by Hurd scenarios)"
	@echo "  cache-push       push the $(ARCH) dev-shell closure to the project cachix cache"
	@echo "  srcs             populate/reconcile src/ working clones from the nix source pins"
	@echo "  src-<name>       same, for ONE source only (e.g. 'make src-gnumach')"
	@echo "  show-srcs-pins   print the current source pins (what nix is building from)"
	@echo "  pin-srcs         bump the pinned source revs to their forks' branch HEADs (verbose)"
	@echo "  pin-src-<name>   same, for ONE source only (e.g. 'make pin-src-mig')"
	@echo "  check-glibc      deep glibc ABI check vs the reference (Tier-2 abidiff; Linux host)"
	@echo "  check-glibc-full deep + heavy ABI probes (pahole/conform/acc; Linux host)"
	@echo "  rebaseline-ref   re-resolve the frozen *-ref-src pins (new gcc ABI baseline; ~25min)"
	@echo "  clean            per-subdir 'make clean' — preserves configure state"
	@echo "  clean-dist       rm -rf dist/$(ARCH)/ (just this target)"
	@echo "  mrproper         rm -rf work/ + .sidekick/ + all dist/ + flake gc-roots"
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
	rm -rf $(DIST)

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
	rm -rf $(DIST_ROOT)
	git -C $(GNUMACH_SRC) clean -fdX
	git -C $(MIG_SRC)     clean -fdX
	git -C $(HURD_SRC)    clean -fdX

# ---- sidekick (always-on, arch-independent) ----
# Builds the x86_64 Alpine helper VM the harness uses for operations
# darwin can't do natively — ext2 module extraction (Gentoo/Guix) and
# grub-mkrescue ISO assembly (x86_64 inject mode for all three Hurd
# scenarios).  Output is identical x86_64 Alpine on every build host
# (no cross-compilation — we fetch prebuilt Alpine APKs), so the
# initramfs is byte-identical on darwin / linux / arm64 / x86_64.
# See flakes/sidekick/{default.nix,packages.nix,init.sh}.
#
# Stamp-file pattern: one recipe produces both SIDEKICK_KERNEL and
# SIDEKICK_INITRD.  Make 3.81 lacks grouped targets (`&:`, Make 4.3+), so
# listing both as targets would race under `-j`; a single stamp target
# avoids that.
.PHONY: sidekick
sidekick: $(SIDEKICK_STAMP)

$(SIDEKICK_STAMP): flakes/sidekick/default.nix flakes/sidekick/packages.nix flakes/sidekick/init.sh
	@mkdir -p $(dir $(SIDEKICK_KERNEL))
	@echo "  SIDEKICK  building helper VM (x86_64 Alpine + grub-mkrescue + busybox)…"
	$(NIX_FLAKE) build .#sidekick \
	  -o $(SIDEKICK)/result
	cp -f $(SIDEKICK)/result/vmlinuz             $(SIDEKICK_KERNEL)
	cp -f $(SIDEKICK)/result/initramfs.cpio.gz   $(SIDEKICK_INITRD)
	@touch $@

# Empty rule: artefact files exist because the stamp recipe produced
# them.  Tells Make how to satisfy a dependency on the artefact paths
# without re-running the build.
$(SIDEKICK_KERNEL) $(SIDEKICK_INITRD): $(SIDEKICK_STAMP) ;

# ---- cache-push (always-on, arch-independent) ----
# Push the current ARCH's dev-shell closure to the project's cachix cache.
# We push the closure of the dev shell's `inputDerivation` — its output's
# references ARE all the shell's build inputs (the cross-toolchain etc.).
# A dev shell's own `.outPath` is never realised, so walking *that* closure
# pushes nothing; the inputDerivation is the buildable stand-in.  Single-
# target by design (pushes $(ARCH); use ARCH=… for others) to avoid building
# a cross-arch toolchain you didn't ask for.  Requires `cachix authtoken
# <token>` once per host (push authenticated, pull anonymous).  Runs at top
# level — no dev-shell dispatch.
_CACHE_NAME := hurd-build-system

.PHONY: cache-push
cache-push:
	@command -v cachix >/dev/null 2>&1 || \
	  { echo "cache-push: cachix not on PATH (install via home-manager or 'nix profile install nixpkgs#cachix')" >&2; exit 1; }
	@system=$$($(NIX) eval --raw --impure --expr 'builtins.currentSystem' 2>/dev/null); \
	echo "==> Pushing dev-shell closure for $$system / $(ARCH) to '$(_CACHE_NAME)'"; \
	echo "  realising closure"; \
	out=$$($(NIX) --accept-flake-config build --no-link --print-out-paths \
	  ".#devShells.$$system.$(ARCH).inputDerivation" 2>/dev/null) || \
	  { echo "    build failed (is ARCH=$(ARCH) a valid flake output?)" >&2; exit 1; }; \
	echo "  pushing"; \
	$(NIX) --accept-flake-config path-info --recursive "$$out" \
	  | cachix push $(_CACHE_NAME)
	@echo "==> cache-push done"

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
# targets for free).  No file is ever named src-*/pin-src-*, so the recipe
# always runs (effectively phony; .PHONY can't carry a % pattern).
src-%:
	@bash flakes/sources/sync.sh $*

pin-src-%:
	@bash flakes/sources/pin.sh $*

# ---- ABI gate deep checks (arch-specific) ----
# The AUTOMATIC gate (Tier-1 + cheap/Hurd Tier-3 probes 00,10-19) already
# runs inside every nix build whose working glibc diverges from the
# reference — no command needed, DWARF-free, on every host.  These targets
# run the EXPLICIT deep checks the doc reserves for the hacker / CI:
#   check-glibc       deep: + Tier-2 abidiff (struct/signature drift behind
#                     a stable symbol) on unstripped variants built on
#                     demand, + header self-include (probe 21).
#   check-glibc-full  + heavy Tier-3: pahole struct-offsets/layout, glibc
#                     conform, abi-compliance-checker (probes 20,22,23,24).
# Tier-2/heavy tooling (libabigail, pahole) is Linux-only in nixpkgs, so
# these BUILD ONLY ON A LINUX HOST (e.g. `orb` aarch64/x86_64); on darwin
# nix reports the unsupported platform and stops.  The override flags feed
# any src/ working clones, so the check reflects local edits.
# SKIP on darwin: libabigail/pahole are Linux-only in nixpkgs, so these
# deep/full reports only exist on `*-linux` (see packages.nix abiReportPkgs).
# Run them on a Linux host (e.g. `orb` aarch64-linux).  The automatic ABI
# gate runs on every nix build regardless of host.  The planned
# sidekick-backed shim will make these uniform across hosts.
.PHONY: check-glibc check-glibc-full
_DARWIN_SKIP = echo "$@: SKIPPED on darwin — libabigail/pahole are Linux-only in nixpkgs."; \
	echo "  The automatic ABI gate still runs on every nix build here; run this deep check on a Linux host"; \
	echo "  (e.g. 'orb' aarch64-linux).  Uniform sidekick-backed tooling is the planned follow-up."

check-glibc:
	@if [ "$$(uname -s)" = "Darwin" ]; then $(_DARWIN_SKIP); else \
	  $(NIX_FLAKE) build $(_WORKING_OVERRIDES) $(PROJ)\#abi-check-$(ARCH) --no-link -L; fi

check-glibc-full:
	@if [ "$$(uname -s)" = "Darwin" ]; then $(_DARWIN_SKIP); else \
	  $(NIX_FLAKE) build $(_WORKING_OVERRIDES) $(PROJ)\#abi-check-full-$(ARCH) --no-link -L; fi

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
_BUILD_GOALS := $(filter-out clean clean-dist mrproper help sidekick cache-push srcs pin-srcs show-srcs-pins src-% pin-src-% check-glibc check-glibc-full rebaseline-ref,$(_GOALS))

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

_PREPARE_FILES   := $(GNUMACH_SRC)/configure
# The public Mach headers live in the build-only sysroot (mig depends on
# this).  dist-headers additionally copies them into $(DIST_HEADERS)/include
# for packaging, but nothing depends on the dist copy's mtime.
_HEADERS_FILES   := $(SYSROOT)/include
_MIG_FILES       := $(_HEADERS_FILES) $(LOCAL_MIG)
_MACH_FILES      := $(_MIG_FILES) $(GNUMACH_KERNEL)
_DIST_MACH_FILES := $(DIST_MACH)/boot/gnumach

_SENTINEL.prepare      := $(_PREPARE_FILES)
_PRIMARY.prepare       := $(_PREPARE_FILES)
_WATCH.prepare         := $(GNUMACH_SRC)/configure.ac

# `headers` installs the Mach public headers into the build-only sysroot
# (what mig consumes).
_SENTINEL.headers      := $(_HEADERS_FILES)
_PRIMARY.headers       := $(SYSROOT)/include
_WATCH.headers         := $(GNUMACH_SRC)/include

# `dist-headers` copies the sysroot headers into the dist tree (packaging).
# In-tree: `cp -r $(SYSROOT)/include` — its only source is the Mach public
# headers, exactly what `headers` watches.  It no longer pulls from the nix
# gnumach-headers derivation, so flakes/gnumach-headers is not a dependency.
_SENTINEL.dist-headers := $(DIST_HEADERS)/include
_PRIMARY.dist-headers  := $(DIST_HEADERS)/include
_WATCH.dist-headers    := $(GNUMACH_SRC)/include

_SENTINEL.mig          := $(_MIG_FILES)
_PRIMARY.mig           := $(LOCAL_MIG)
_WATCH.mig             := $(MIG_SRC) flakes/mig

_SENTINEL.mach         := $(_MACH_FILES)
_PRIMARY.mach          := $(GNUMACH_KERNEL)
_WATCH.mach            := $(GNUMACH_SRC)

# `hurd` — userland compile.  No single output binary, so the sentinel is a
# build stamp; transitively requires mig + headers (via _MACH_FILES' deps,
# reused here as the toolchain prereqs).  Watch src/hurd for source edits.
_SENTINEL.hurd         := $(_MIG_FILES) $(HURD_BUILD)/.built
_PRIMARY.hurd          := $(HURD_BUILD)/.built
_WATCH.hurd            := $(HURD_SRC)

# `all` = mach + hurd — a COMPOSITE goal: stale iff a component is stale
# (see _stale's _COMPOSE branch).  We do NOT flatten the components'
# primaries+watches into one set: that would compare the OLDEST primary
# (e.g. the gnumach kernel) against EVERY watch (incl. src/hurd), so a tree
# with hurd freshly rebuilt but gnumach untouched would falsely dispatch.
_COMPOSE.all           := mach hurd

# `dist-mach` installs the in-tree kernel into the dist tree — same source
# as `mach` (it no longer copies from the nix gnumach derivation).
_SENTINEL.dist-mach    := $(_DIST_MACH_FILES)
_PRIMARY.dist-mach     := $(DIST_MACH)/boot/gnumach
_WATCH.dist-mach       := $(GNUMACH_SRC)

# `dist-hurd` — install the userland into the dist tree.  Sentinel is the
# installed ext2fs translator (a real install result, mirroring dist-mach's
# boot/gnumach); rebuilds when src/hurd changes (which also bumps .built).
_SENTINEL.dist-hurd    := $(DIST_HURD)/hurd/ext2fs
_PRIMARY.dist-hurd     := $(DIST_HURD)/hurd/ext2fs
_WATCH.dist-hurd       := $(HURD_SRC)

# `dist` = dist-headers + dist-mach + dist-hurd — COMPOSITE (same rationale
# as `all`): stale iff a component is stale, evaluated per component so the
# dist-mach primary is only ever compared against src/gnumach, the dist-hurd
# primary only against src/hurd, etc.
_COMPOSE.dist          := dist-headers dist-mach dist-hurd

# We rely on `git ls-files` to enumerate "real source" — anything else
# (configure, Makefile.in, autom4te.cache/, INSTALL, doc/stamp-vti, ...) is
# generated and shouldn't trigger staleness. This is authoritative: it's
# exactly what `git clean -fdX` would NOT touch.

# Resolve to the oldest existing PRIMARY sentinel for `goal` — the staleness
# reference (an ABSOLUTE path; all _PRIMARY entries are rooted at $(CURDIR)).
# Anything newer than this means real source moved after the goal completed.
#   `-d` is load-bearing: a PRIMARY may be a DIRECTORY (e.g. dist-headers'
#   $(DIST_HEADERS)/include).  Without -d, `ls -t <dir>` lists the dir's
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

.PHONY: all dist prepare headers dist-headers mig mach dist-mach \
        check check-mach run run-help

# Explicit default — `help` (defined above) would otherwise win the
# "first non-dot target" race.
.DEFAULT_GOAL := all

# ---- Default & top-level groupings ----
# `all` and `dist` are NOT aliases: they list real dependencies we'll
# grow over time (e.g. once Hurd userland builds, add `hurd` /
# `dist-hurd` here).
all: mach hurd

dist: dist-headers dist-mach dist-hurd

# ---- prepare ----
# `autoreconf -i` (no -f): install missing aux files and regenerate ONLY
# when inputs are newer than outputs. Without -f, autoreconf won't rewrite
# `configure` if it's already up to date — so the mtime stays stable and
# the downstream ./configure chain doesn't fire spuriously. -fi (force)
# would unconditionally touch every output, defeating that.
#
# MIG no longer has a local autoreconf step — `nix build .#mig-$(ARCH)`
# autoreconfs inside its sandbox.
prepare: $(GNUMACH_SRC)/configure

# In-tree builds carry the plain upstream PACKAGE_VERSION — autoreconf reads
# src/gnumach's committed version.m4 / configure.ac as-is.  The rich build-rev
# version is stamped only on the nix-built shippable artefacts (flakes/gnumach,
# flakes/mig), matching Debian/Guix (snapshot lives in the package, not the
# in-tree binary).  A hacker who wants a custom version edits version.m4.
$(GNUMACH_SRC)/configure: $(GNUMACH_SRC)/configure.ac $(GNUMACH_SRC)/version.m4
	cd $(GNUMACH_SRC) && autoreconf -i

# ---- headers (sysroot) ----
# Install the public Mach headers into the build-only sysroot ($(SYSROOT)),
# in-tree via gnumach's `make install-data`.  This is mig's stable header
# dependency — see the SYSROOT comment for why it must NOT be the dist tree.
# Mirrors the flakes/gnumach-headers derivation: a separate build dir
# configured with a STUB USER_MIG=/bin/true so it can run BEFORE mig exists
# (mig needs these headers; install-data compiles nothing and never invokes
# mig, so the stub satisfies configure's AC_CHECK_PROG).  Headers-only — the
# kernel itself is never built here.
headers: $(SYSROOT)/include

$(GNUMACH_HDR_CONFIGURED): $(GNUMACH_SRC)/configure
	mkdir -p $(GNUMACH_HDR_BUILD)
	cd $(GNUMACH_HDR_BUILD) && \
	  USER_MIG=/bin/true \
	  $(GNUMACH_SRC)/configure --host=$(GNUMACH_HOST) --prefix=$(SYSROOT) \
	    $(if $(GNUMACH_PLATFORM),--enable-platform=$(GNUMACH_PLATFORM))

# Src prereqs ($(GNUMACH_SRC_FILES)) are intentionally omitted here: that var
# is defined further down (next to the kernel rule, after _tracked_files), so
# referencing it at this point would expand empty.  Staleness across source
# edits is handled for the dispatched path by _WATCH.headers
# ($(GNUMACH_SRC)/include); install-data is cheap + idempotent (merges).
$(SYSROOT)/include: $(GNUMACH_HDR_CONFIGURED)
	cd $(GNUMACH_HDR_BUILD) && $(MAKE) install-data
	@touch $(SYSROOT)/include

# ---- dist-headers ----
# Package the Mach headers into the user-facing dist tree by copying them out
# of the sysroot.  A copy (not the source of truth) so nothing depends on this
# dir's mtime — the hurd userland's `make install` also writes $(DIST)/include
# (when DIST_HEADERS == DIST_HURD, the default), and that must not perturb
# mig's staleness.  Merge-copy (no rm -rf) so it coexists with hurd's headers.
dist-headers: $(SYSROOT)/include
	@mkdir -p $(DIST_HEADERS)/include
	cp -r $(SYSROOT)/include/. $(DIST_HEADERS)/include/
	chmod -R u+w $(DIST_HEADERS)/include

# ---- mig ----
# In-tree iterative MIG build.  autoreconf in src/mig (writes
# gitignored files — see the submodule's .gitignore), configure +
# make + make install into $(MIG_INSTALL_DIR).  The wrapper at
# $(LOCAL_MIG) uses dirname-$0/../libexec at runtime, so its sibling
# migcom resolves under $(MIG_INSTALL_DIR)/libexec/.  Re-running
# `make mig` after editing src/mig is incremental (autoreconf -i
# doesn't rewrite up-to-date outputs, and the build dir's
# config.status survives between invocations).
mig: $(LOCAL_MIG)

# $(call _tracked_files,<dir>) — every git-tracked file under <dir>,
# as absolute paths.  Used by the mig + mach rules to list src as
# prereqs so editing src/foo.c triggers the in-tree rebuild.  Without
# this, those rules' only "real" prereqs are configure + headers,
# neither of which moves on src edits — `make mig`/`make mach` after
# editing source would silently fall back to the stale build.  We
# rely on `git ls-files` so generated files (configure, .deps/,
# autom4te.cache/, ...) don't cause spurious rebuilds.  Once the
# rule fires, the inner build's own automake dep tracking handles
# the fine-grained .c→.o decisions.
_tracked_files = $(addprefix $(1)/,$(shell cd $(1) 2>/dev/null && git ls-files))

MIG_SRC_FILES := $(call _tracked_files,$(MIG_SRC))
# Defined here (before the hurd recipe that uses it) so it expands non-empty:
# editing a tracked src/hurd file makes $(HURD_BUILD)/.built stale → inner make
# re-runs (hurd's own dep tracking handles the .c→.o decisions).
HURD_SRC_FILES := $(call _tracked_files,$(HURD_SRC))
$(LOCAL_MIG): $(MIG_SRC)/configure $(SYSROOT)/include $(MIG_SRC_FILES)
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

# ---- mach ----
# In-tree kernel build under $(GNUMACH_BUILD), using the in-tree MIG
# from `make mig`.  USER_MIG/MIG point at $(LOCAL_MIG) explicitly so
# gnumach's AC_CHECK_TOOL doesn't have to discover it via PATH.
# Incremental compile — re-running `make mach` after editing
# src/gnumach rebuilds only the changed translation units.
mach: $(GNUMACH_KERNEL)

$(GNUMACH_CONFIGURED): $(GNUMACH_SRC)/configure $(LOCAL_MIG)
	mkdir -p $(GNUMACH_BUILD)
	cd $(GNUMACH_BUILD) && \
	  USER_MIG=$(LOCAL_MIG) MIG=$(LOCAL_MIG) \
	  $(GNUMACH_SRC)/configure --host=$(GNUMACH_HOST) --prefix=$(DIST_MACH) \
	    $(if $(GNUMACH_PLATFORM),--enable-platform=$(GNUMACH_PLATFORM))

# Src prereqs via $(_tracked_files) — see its defining comment above.
GNUMACH_SRC_FILES := $(call _tracked_files,$(GNUMACH_SRC))
$(GNUMACH_KERNEL): $(LOCAL_MIG) $(GNUMACH_CONFIGURED) $(GNUMACH_SRC_FILES)
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
# (flakes/cross-toolchain/dev-shell.nix); the recipes add MIG=$(LOCAL_MIG)
# (same in-tree mig as mach) + CFLAGS=-fcommon at configure time (hurd
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

$(HURD_BUILD)/.built: $(LOCAL_MIG) $(HURD_CONFIGURED) $(HURD_SRC_FILES)
	cd $(HURD_BUILD) && $(MAKE) MIG=$(LOCAL_MIG) USER_MIG=$(LOCAL_MIG)
	@touch $(HURD_BUILD)/.built

# In-tree builds carry the plain upstream PACKAGE_VERSION (autoreconf reads
# src/hurd's committed configure.ac as-is).  The rich build-rev version is
# stamped only on the nix-built shippable artefacts (flakes/hurd).
$(HURD_SRC)/configure: $(HURD_SRC)/configure.ac
	cd $(HURD_SRC) && autoreconf -i

$(HURD_CONFIGURED): $(LOCAL_MIG) $(HURD_SRC)/configure
	mkdir -p $(HURD_BUILD)
	cd $(HURD_BUILD) && \
	  $(HURD_SRC)/configure $(HURD_CONFIGURE_FLAGS) \
	    MIG=$(LOCAL_MIG) USER_MIG=$(LOCAL_MIG) CFLAGS="-fcommon -g -O2" \
	    --prefix=$(DIST_HURD)

# Install the in-tree userland build into $(DIST_HURD) as a self-contained
# tree.  Counterpart to `hurd`: `make hurd` is fast in-tree iteration; `make
# dist-hurd` produces the installable artefact (like dist-mach).
dist-hurd: $(DIST_HURD)/hurd/ext2fs

# Install the in-tree userland build into $(DIST_HURD) (hurd configured
# --prefix=$(DIST_HURD)).  Under fakeroot: hurd's daemons/ + utils/ install
# some programs `-o root -m 4755` (setuid), which a non-root install can't do
# — fakeroot fakes the chown/setuid so the install completes without touching
# real privilege (the bits are cosmetic for a dev dist tree).  Same MIG as the
# build.  Keyed on the installed ext2fs translator — the headline userland
# output, the analog of dist-mach's boot/gnumach — so dist/ holds only install
# results (no completion stamp).  `make install` rebuilds the whole tree; make
# only compares ext2fs's mtime against the build stamp to decide staleness.
$(DIST_HURD)/hurd/ext2fs: $(HURD_BUILD)/.built
	cd $(HURD_BUILD) && fakeroot $(MAKE) install prefix=$(DIST_HURD) \
	  MIG=$(LOCAL_MIG) USER_MIG=$(LOCAL_MIG)

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
