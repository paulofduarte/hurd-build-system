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

# ARCH resolution: env > cmdline > host CPU default.
ifndef ARCH
_HOST_CPU := $(shell uname -m)
ARCH := \
  $(if $(filter arm64 aarch64,$(_HOST_CPU)),aarch64, \
  $(if $(filter x86_64,$(_HOST_CPU)),x86_64, \
  $(if $(filter i386 i486 i586 i686,$(_HOST_CPU)),i686, \
  aarch64)))
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
# The inner tools/dispatch.sh also defaults to boot, but the make-level
# _RUN_PREREQS rule below needs the value at *parse time* — without
# this default, `make ARCH=x86_64 run` doesn't pick up the
# x86_64+boot → sidekick prereq and the harness errors out.
SCENARIO ?= boot

# Layout.  FLAKES is source-only (the nix sub-flakes for cross-gcc,
# gnumach-headers, mig, sidekick).  BIN holds dev-shell-visible wrapper
# symlinks; SIDEKICK holds the x86_64 helper-VM artefacts.  Both BIN
# and SIDEKICK are gitignored at the repo root so flakes/ stays clean
# (no mixing of tracked sources with build outputs).
PROJ          := $(CURDIR)
SRC           := $(PROJ)/src
WORK          := $(PROJ)/work
FLAKES        := $(PROJ)/flakes
BIN           := $(PROJ)/.bin
SIDEKICK      := $(PROJ)/.sidekick
DIST_ROOT     := $(PROJ)/dist
DIST          := $(DIST_ROOT)/$(ARCH)

GNUMACH_SRC   := $(SRC)/gnumach
GNUMACH_BUILD := $(WORK)/gnumach/$(ARCH)
MIG_SRC       := $(SRC)/mig

GNUMACH_CONFIGURED := $(GNUMACH_BUILD)/config.status
# The bootable kernel image — same file the harness feeds to qemu's
# -kernel.  On aarch64 this is the objcopy'd raw binary (the linker also
# emits gnumach.elf alongside, which qemu silently hangs on; we don't
# track it).  On i386/x86_64 the linker writes gnumach (ELF) directly.
GNUMACH_KERNEL     := $(GNUMACH_BUILD)/gnumach

# Nix-built per-target outputs.  `nix build -o <path>` creates a gc-root
# symlink at <path> pointing into /nix/store; the .bin/ wrapper symlink
# (kept for the dev-shell PATH convention) just re-targets the wrapper
# binary inside that result.  These are regenerated cheaply on every
# build — nix decides whether to rebuild the underlying derivation.
NIX_HEADERS_RESULT := $(FLAKES)/gnumach-headers/result-$(ARCH)
NIX_MIG_RESULT     := $(FLAKES)/mig/result-$(ARCH)
MIG_INSTALLED      := $(BIN)/$(MIG)

# Sidekick helper VM artefacts (x86_64 Alpine; built via the root flake's
# `packages.<system>.sidekick` output — see flakes/sidekick/default.nix
# and flakes/sidekick/init.sh).  Used for ext2 module extraction
# (Gentoo/Guix) and grub-mkrescue ISO assembly (x86_64 inject mode).
SIDEKICK_KERNEL := $(SIDEKICK)/vmlinuz
SIDEKICK_INITRD := $(SIDEKICK)/initramfs.cpio.gz
SIDEKICK_STAMP  := $(SIDEKICK)/.stamp

# Hurd distro image URLs — referenced by tools/hurd-*.sh.
# Naming uses our build-system convention (X86_64 / I686); where the
# distro uses its own arch nomenclature, the mapping lives ONLY inside
# the URL string.
# Debian: `latest/hurd-{amd64,i386}/debian-hurd.img.tar.gz` is a versionless
# 302-redirect to the most recently published dated image (e.g.
# debian-hurd-amd64-YYYYMMDD.img.tar.gz).  Same trade-off as Gentoo — the
# cached copy doesn't auto-refresh; `rm -rf work/test-images/debian/<ARCH>/`
# forces a re-fetch.  Standalone modules (ext2fs.static, exec.static) live
# in the same dir.  Note: Debian does NOT publish ld.so.1 standalone, and
# doesn't need it — exec.static is fully statically linked.
HURD_DEBIAN_X86_64_URL := https://cdimage.debian.org/cdimage/ports/latest/hurd-amd64/debian-hurd.img.tar.gz
HURD_DEBIAN_I686_URL   := https://cdimage.debian.org/cdimage/ports/latest/hurd-i386/debian-hurd.img.tar.gz
HURD_GENTOO_X86_64_URL := https://distfiles.gentoo.org/experimental/amd64/hurd/hurd-x86_64-preview.qcow2
HURD_GENTOO_I686_URL   := https://distfiles.gentoo.org/experimental/x86/hurd/hurd-i686-preview.qcow2
# Guix: /search/latest/image is Cuirass's auto-latest endpoint — server-side
# redirect to the most recent successful build with a fetchable artefact.
# `system:x86_64-linux` refers to the BUILD HOST (Guix only operates x86_64-linux
# build farms for Hurd images), NOT the target arch — the target arch is
# encoded only in the qcow2 filename.  hurd64-barebones.qcow2 artefacts are
# aggressively GC'd by Guix CI; expect 500 most of the time for x86_64.
HURD_GUIX_I686_URL     := https://ci.guix.gnu.org/search/latest/image?query=spec:images+status:success+system:x86_64-linux+hurd-barebones.qcow2
HURD_GUIX_X86_64_URL   := https://ci.guix.gnu.org/search/latest/image?query=spec:images+status:success+system:x86_64-linux+hurd64-barebones.qcow2

# Stamps we touch ourselves after invoking install steps.
#
# - HEADERS_STAMP / DIST_MACH_STAMP: gnumach's install uses
#   `install-sh -C` (compare-only): when the source bytes match the
#   destination, the dest isn't touched — its mtime stays old, and our
#   staleness heuristic would loop.
# - MIG_STAMP: anchored on a /nix/store path that has epoch mtime
#   (nix freezes mtimes for reproducibility), so make's stat() through
#   the symlink would always look older than the prerequisites and the
#   rule would re-fire.
#
# Stamps live with what they describe: MIG_STAMP under flakes/mig/
# (the sub-flake that owns the install), HEADERS_STAMP / DIST_MACH_STAMP
# under $(DIST) (the destination of the install they track).
HEADERS_STAMP      := $(DIST)/.headers-installed
MIG_STAMP          := $(FLAKES)/mig/.mig-$(ARCH)-installed
DIST_MACH_STAMP    := $(DIST)/.mach-installed

# Defensive parse-time check.  The stamps are make's mtime anchor for the
# nix-driven rules, but the *symlinks* they're paired with ($(DIST)/include,
# $(MIG_INSTALLED), $(NIX_*_RESULT)) can be removed independently — by
# `mrproper`, `git clean -fdX`, manual rm, or nix-store gc.  If any of
# those is gone while the stamp survives, make would short-circuit and
# the next `make mach` would run with no MIG on PATH.  Drop the stamp
# whenever its companion artefact is missing so the rule fires again.
ifeq ($(wildcard $(NIX_HEADERS_RESULT)),)
$(shell rm -f $(HEADERS_STAMP))
endif
ifeq ($(wildcard $(DIST)/include),)
$(shell rm -f $(HEADERS_STAMP))
endif
ifeq ($(wildcard $(NIX_MIG_RESULT)),)
$(shell rm -f $(MIG_STAMP))
endif
ifeq ($(wildcard $(MIG_INSTALLED)),)
$(shell rm -f $(MIG_STAMP))
endif

# ---- Help (always-on) ----
.PHONY: help
help:
	@echo "Targets (for ARCH=$(ARCH)):"
	@echo "  all              build the gnumach kernel (default)"
	@echo "  prepare          autoreconf the source trees"
	@echo "  dist-headers     link gnumach public headers under ./dist/$(ARCH)/include (via nix)"
	@echo "  toolchain        dist-headers + link MIG under .bin/ (via nix)"
	@echo "  mach             build gnumach kernel"
	@echo "  dist-mach        install gnumach into ./dist/$(ARCH)/"
	@echo "  dist             install everything (== dist-mach for now)"
	@echo "  check            run upstream test suites (== check-mach; MIG tests run inline via nix)"
	@echo "  check-mach       run gnumach's 'make check' (kernel tests under QEMU)"
	@echo "  run              boot the built kernel in qemu (SCENARIO=boot by default)"
	@echo "  run-help         show all 'make run' options (ARCH/SCENARIO/RUN_*)"
	@echo "  sidekick         build the helper VM (x86_64 Alpine, used by Hurd scenarios)"
	@echo "  cache-push       push the $(ARCH) dev-shell closure to the project cachix cache"
	@echo "  clean            per-subdir 'make clean' — preserves configure state"
	@echo "  clean-dist       rm -rf dist/$(ARCH)/ (just this target)"
	@echo "  mrproper         rm -rf work/ + .bin/ + .sidekick/ + all dist/ + flake gc-roots/stamps"
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
	@# MIG + gnumach-headers are built by nix; clean the per-target
	@# gc-roots, install stamps, and the dev-shell PATH symlinks so the
	@# next build re-pulls them from the store.
	@rm -f $(FLAKES)/mig/result-* $(FLAKES)/gnumach-headers/result-*
	@rm -f $(FLAKES)/mig/.mig-*-installed
	@rm -f $(BIN)/*-mig

clean-dist:
	rm -rf $(DIST)

# mrproper still nukes work/ wholesale — that's a deeper reset and we
# expect users to invoke it when they want a clean slate including
# configure state.  flakes/ holds tracked source files
# (flakes/{cross-gcc,gnumach-headers,mig,sidekick}/), so we can't
# `rm -rf` it; instead, scrub only the gitignored bits inside
# (result-* gc-roots, .mig-*-installed stamps) and drop the
# project-root install directories ($(BIN) and $(SIDEKICK)) wholesale.
mrproper:
	rm -rf $(WORK)
	rm -rf $(BIN) $(SIDEKICK)
	rm -f  $(FLAKES)/gnumach-headers/result-* $(FLAKES)/mig/result-*
	rm -f  $(FLAKES)/mig/.mig-*-installed
	rm -rf $(DIST_ROOT)
	git -C $(GNUMACH_SRC) clean -fdX
	git -C $(MIG_SRC)     clean -fdX

# ---- sidekick (always-on, arch-independent) ----
# Builds the x86_64 Alpine helper VM the harness uses for operations
# darwin can't do natively — ext2 module extraction (Gentoo/Guix) and
# grub-mkrescue ISO assembly (x86_64 inject mode for all three Hurd
# scenarios).  Output is identical x86_64 Alpine on every build host
# (no cross-compilation — we fetch prebuilt Alpine APKs), so the
# initramfs is byte-identical on darwin / linux / arm64 / x86_64.
# See flakes/sidekick/{default.nix,packages.nix,init.sh}.
#
# Stamp-file pattern (matches HEADERS_STAMP / DIST_MACH_STAMP
# convention): one recipe produces both SIDEKICK_KERNEL and
# SIDEKICK_INITRD.  Make 3.81 lacks grouped-targets (`&:`, Make 4.3+)
# so listing both files as a target would race under `-j`; using a
# stamp as the sole real target avoids that.
.PHONY: sidekick
sidekick: $(SIDEKICK_STAMP)

$(SIDEKICK_STAMP): flakes/sidekick/default.nix flakes/sidekick/packages.nix flakes/sidekick/init.sh
	@mkdir -p $(dir $(SIDEKICK_KERNEL))
	@echo "  SIDEKICK  building helper VM (x86_64 Alpine + grub-mkrescue + busybox)…"
	$(NIX) --extra-experimental-features 'nix-command flakes' \
	  build .#sidekick \
	  -o $(SIDEKICK)/result
	cp -f $(SIDEKICK)/result/vmlinuz             $(SIDEKICK_KERNEL)
	cp -f $(SIDEKICK)/result/initramfs.cpio.gz   $(SIDEKICK_INITRD)
	@touch $@

# Empty rule: artefact files exist because the stamp recipe produced
# them.  Tells Make how to satisfy a dependency on the artefact paths
# without re-running the build.
$(SIDEKICK_KERNEL) $(SIDEKICK_INITRD): $(SIDEKICK_STAMP) ;

# ---- cache-push (always-on, arch-independent) ----
# Push the current ARCH's dev-shell closure to the project's cachix
# cache.  Walks the closure explicitly (`nix path-info --recursive`)
# rather than relying on `cachix watch-exec`'s "new paths since command
# started" detection — so it correctly pushes toolchains that were
# already in the store from earlier builds.  Use this whenever you've
# bootstrapped a cross-toolchain locally (~20 min for cross-gcc) and
# want collaborators to skip that rebuild on their machines.
#
# Scope is intentionally single-target: `make cache-push` pushes
# `$(ARCH)` (default aarch64 on aarch64 hosts).  Want a different
# target?  `make cache-push ARCH=i686` etc. — picking up the
# existing ARCH-resolution logic from the top of this Makefile.
# This avoids accidentally triggering a cross-arch toolchain build
# for an arch you don't actively care about.
#
# Requires `cachix authtoken <token>` to have been run once on this
# machine (token is per-user; push is authenticated, pull is anonymous).
# Run from anywhere on the host — no dev-shell dispatch.
_CACHE_NAME := hurd-build-system

.PHONY: cache-push
cache-push:
	@command -v cachix >/dev/null 2>&1 || \
	  { echo "cache-push: cachix not on PATH (install via home-manager or 'nix profile install nixpkgs#cachix')" >&2; exit 1; }
	@system=$$($(NIX) eval --raw --impure --expr 'builtins.currentSystem' 2>/dev/null); \
	echo "==> Pushing dev-shell closure for $$system / $(ARCH) to '$(_CACHE_NAME)'"; \
	shell=$$($(NIX) --accept-flake-config eval --raw \
	  ".#devShells.$$system.$(ARCH).outPath" 2>/dev/null) || \
	  { echo "    eval failed (is ARCH=$(ARCH) a valid flake output?)" >&2; exit 1; }; \
	echo "  realising closure"; \
	$(NIX) --accept-flake-config build --no-link \
	  ".#devShells.$$system.$(ARCH).inputDerivation" >/dev/null 2>&1 || \
	  { echo "    build failed" >&2; exit 1; }; \
	echo "  pushing"; \
	$(NIX) --accept-flake-config path-info --recursive "$$shell" 2>/dev/null \
	  | cachix push $(_CACHE_NAME)
	@echo "==> cache-push done"

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
_BUILD_GOALS := $(filter-out clean clean-dist mrproper help sidekick cache-push,$(_GOALS))

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
# Stamp files (touched by us) are the makefile-tracked staleness anchors.
# Make's stat() follows symlinks, so the NIX_*_RESULT gc-roots — which
# point into /nix/store with epoch mtimes — would otherwise mislead
# every downstream comparison.
_HEADERS_FILES   := $(HEADERS_STAMP)
_TOOLCHAIN_FILES := $(_HEADERS_FILES) $(MIG_STAMP)
_MACH_FILES      := $(_TOOLCHAIN_FILES) $(GNUMACH_KERNEL)
_DIST_MACH_FILES := $(_MACH_FILES) $(DIST_MACH_STAMP)

_SENTINEL.prepare      := $(_PREPARE_FILES)
_PRIMARY.prepare       := $(_PREPARE_FILES)
_WATCH.prepare         := $(GNUMACH_SRC)/configure.ac

_SENTINEL.dist-headers := $(_HEADERS_FILES)
_PRIMARY.dist-headers  := $(HEADERS_STAMP)
_WATCH.dist-headers    := $(GNUMACH_SRC)/include flakes/gnumach-headers

_SENTINEL.toolchain    := $(_TOOLCHAIN_FILES)
_PRIMARY.toolchain     := $(MIG_STAMP)
_WATCH.toolchain       := $(MIG_SRC) $(GNUMACH_SRC)/include flakes/mig flakes/gnumach-headers

_SENTINEL.mach         := $(_MACH_FILES)
_PRIMARY.mach          := $(GNUMACH_KERNEL)
_WATCH.mach            := $(GNUMACH_SRC)

_SENTINEL.all          := $(_MACH_FILES)
_PRIMARY.all           := $(GNUMACH_KERNEL)
_WATCH.all             := $(GNUMACH_SRC)

_SENTINEL.dist-mach    := $(_DIST_MACH_FILES)
_PRIMARY.dist-mach     := $(DIST_MACH_STAMP)
_WATCH.dist-mach       := $(GNUMACH_SRC)

_SENTINEL.dist         := $(_DIST_MACH_FILES)
_PRIMARY.dist          := $(DIST_MACH_STAMP)
_WATCH.dist            := $(GNUMACH_SRC)

# We rely on `git ls-files` to enumerate "real source" — anything else
# (configure, Makefile.in, autom4te.cache/, INSTALL, doc/stamp-vti, ...) is
# generated and shouldn't trigger staleness. This is authoritative: it's
# exactly what `git clean -fdX` would NOT touch.

# Resolve to the oldest existing PRIMARY sentinel for `goal` — the staleness
# reference. Anything newer than this means real source moved after the
# goal was completed.
_oldest_primary = $(shell ls -t $(_PRIMARY.$(1)) 2>/dev/null | tail -1)

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
#   <filename>   — at least one sentinel is missing
#   <filename>   — all sentinels exist but some tracked file is newer
#   (empty)      — fresh, nothing to do
_stale = $(strip \
  $(if $(_SENTINEL.$(1)), \
    $(if $(call _missing_sentinel,$(1)), \
      $(call _missing_sentinel,$(1)), \
      $(call _newer_tracked,$(1))), \
    yes))

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
# call below).  Trade-off: every build pays ~200-500ms for the
# isolated shell spawn; in exchange we get a hard guarantee that
# nothing from the caller's environment leaks into the build — the
# only inputs are what the dev shell explicitly declares.  Direnv,
# host-installed tools, accidental `export`s — none of them can
# perturb the build via this path.  The previous IN_NIX_SHELL +
# NIX_TARGET trust check was bypassable by any caller that just
# `export IN_NIX_SHELL=1`, so it was speed, not safety.
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
#   - --extra-experimental-features enables nix-command + flakes per
#     invocation, so we don't require the user to enable them globally.
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

# Persistent gc-root for the dispatched dev shell.  Stored under
# .gcroots/ (NOT .direnv/) because nix-direnv's _nix_clean_old_gcroots
# wipes all `.direnv/flake-profile*` files on every .envrc reload —
# any profile we created there for a non-current ARCH would get
# nuked, taking its referenced store paths off the gc-protected set.
# Our .gcroots/ is direnv-immune and accumulates one entry per target.
# Both still pin the same store paths as direnv's profile when the
# ARCH matches (content-addressed), so no store-duplication cost.
_FLAKE_PROFILE := .gcroots/$(ARCH)

_RUN_PASSTHROUGH := \
  SCENARIO=$(SCENARIO) \
  RUN_VANILLA=$(RUN_VANILLA) \
  RUN_ACCEL=$(RUN_ACCEL) \
  RUN_KEEP_OVERLAY=$(RUN_KEEP_OVERLAY) \
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
	+@$(NIX) --extra-experimental-features 'nix-command flakes' \
	  develop -i --profile "$(_FLAKE_PROFILE)" .#$(ARCH) \
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
#   ARCH, GNUMACH_HOST, MIG, CC, LD, AR, NM, RANLIB, STRIP, OBJCOPY,
#   TARGET_CC, CFLAGS

# ---- Sanity: must be inside a target dev shell ----
REQUIRED_VARS := ARCH GNUMACH_HOST MIG MIG_TARGET CC CFLAGS

$(foreach v,$(REQUIRED_VARS), \
  $(if $($(v)),,$(error $(v) is not set. Enter a dev shell first: 'nix develop .#aarch64' (or .#x86_64 / .#x86_64-xen / .#i686 / .#i686-xen))))

.PHONY: all dist prepare dist-headers toolchain mach dist-mach \
        check check-mach run run-help

# Explicit default — `help` (defined above) would otherwise win the
# "first non-dot target" race.
.DEFAULT_GOAL := all

# ---- Default & top-level groupings ----
# `all` and `dist` are NOT aliases: they list real dependencies we'll grow
# over time (e.g. once Hurd userland builds, add `hurd` / `dist-hurd` here).
all: mach

dist: dist-mach

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

$(GNUMACH_SRC)/configure: $(GNUMACH_SRC)/configure.ac
	cd $(GNUMACH_SRC) && autoreconf -i

# ---- dist-headers ----
# Public Mach headers come from `nix build .#gnumach-headers-$(ARCH)`.
# The stamp is the makefile-tracked artifact (regular file, real mtime
# we set via touch); $(NIX_HEADERS_RESULT) is a /nix/store symlink whose
# stat() resolves to epoch — useless for make's mtime arithmetic — and
# $(DIST)/include is the user-facing legacy path that consumers expect.
dist-headers: $(HEADERS_STAMP)

$(HEADERS_STAMP): flakes/gnumach-headers/default.nix flake.nix
	@mkdir -p $(dir $(NIX_HEADERS_RESULT))
	$(NIX) --extra-experimental-features 'nix-command flakes' \
	  build .#gnumach-headers-$(ARCH) -o $(NIX_HEADERS_RESULT)
	@mkdir -p $(DIST)
	ln -sfn $(NIX_HEADERS_RESULT)/include $(DIST)/include
	@touch $@

# ---- toolchain ----
# MIG comes from `nix build .#mig-$(ARCH)`.  Its test-suite runs
# inline (doCheck = true), so a successful build means tests passed.
#
# We install a tiny shell shim at $(BIN)/<MIG_TARGET>-mig that
# `exec`s the store-path wrapper directly (NOT a symlink to it).
# The MIG wrapper script uses `dirname "$0"` to locate its sibling
# migcom under `../libexec/<arch>-gnu-migcom`; with a symlink in
# $(BIN), $0 is the symlink path and the lookup lands at
# `<repo>/libexec/...` (nonexistent).  With a shim, $0 becomes the
# absolute store path and the wrapper finds migcom alongside itself
# in the store.
#
# Same stamp pattern as dist-headers above for the same mtime reason.
toolchain: dist-headers $(MIG_STAMP)

$(MIG_STAMP): flakes/mig/default.nix flake.nix
	@mkdir -p $(dir $(NIX_MIG_RESULT))
	$(NIX) --extra-experimental-features 'nix-command flakes' \
	  build .#mig-$(ARCH) -o $(NIX_MIG_RESULT)
	@mkdir -p $(BIN)
	@store=$$(readlink $(NIX_MIG_RESULT)); \
	  printf '#!/bin/sh\nexec %s "$$@"\n' \
	    "$$store/bin/$(MIG_TARGET)-mig" > $(MIG_INSTALLED); \
	  chmod +x $(MIG_INSTALLED)
	@touch $@

# ---- mach ----
# Kernel build still uses a local configured tree under
# $(GNUMACH_BUILD) — the cross-toolchain compiles + links the .elf
# there.  Headers + MIG come in via nix, satisfied by the `toolchain`
# prereq.  USER_MIG points at the same nix-backed wrapper so gnumach's
# tests/configfrag.ac records the path that `make check-mach` will exec.
mach: $(GNUMACH_KERNEL)

$(GNUMACH_CONFIGURED): $(GNUMACH_SRC)/configure $(MIG_STAMP)
	mkdir -p $(GNUMACH_BUILD)
	cd $(GNUMACH_BUILD) && \
	  USER_MIG=$(MIG_INSTALLED) \
	  $(GNUMACH_SRC)/configure --host=$(GNUMACH_HOST) --prefix=$(DIST) \
	    $(if $(GNUMACH_PLATFORM),--enable-platform=$(GNUMACH_PLATFORM))

$(GNUMACH_KERNEL): toolchain $(GNUMACH_CONFIGURED)
	cd $(GNUMACH_BUILD) && $(MAKE)

dist-mach: $(DIST_MACH_STAMP)

$(DIST_MACH_STAMP): $(GNUMACH_KERNEL)
	cd $(GNUMACH_BUILD) && $(MAKE) install
	@mkdir -p $(@D) && touch $@

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
# `make toolchain`, `make mach`, etc.
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
# Prereqs depend on (SCENARIO, RUN_VANILLA):
#   mach       — required by all scenarios EXCEPT the
#                "RUN_VANILLA=1 + Hurd scenario" combination (vanilla
#                Hurd boots the distro's bundled kernel — no need to
#                build ours).  For `boot` (or any unrecognized scenario)
#                RUN_VANILLA is meaningless and mach is always required
#                — this guard prevents the cryptic "could not load
#                kernel image" qemu error from RUN_VANILLA=1 SCENARIO=boot.
#   sidekick   — needed for ANY hurd-* scenario (regenerates the
#                qcow2's grub.cfg so it boots on serial under
#                -nographic; non-vanilla also overlays our kernel).
#                Also needed for boot + ARCH=x86_64 (qemu's -kernel
#                rejects 64-bit ELFs, see D18; routes through
#                GRUB-on-ISO via mkiso).
#   mach       — needed for all non-vanilla scenarios.  Vanilla
#                skips it (booting the distro's bundled kernel —
#                no need to build ours).
#
# Cells (evaluated at Makefile-parse time):
#   RUN_VANILLA=1 + hurd-*                          → sidekick
#   boot + ARCH=i686/aarch64                      → mach
#   boot + ARCH=x86_64                            → mach sidekick
#   non-vanilla hurd-*                              → mach sidekick
_RUN_PREREQS := \
  $(if $(and $(filter 1,$(RUN_VANILLA)),$(filter hurd-debian hurd-gentoo hurd-guix,$(SCENARIO))), \
    sidekick, \
    mach \
    $(if $(filter hurd-debian hurd-gentoo hurd-guix,$(SCENARIO)),sidekick, \
      $(if $(and $(filter x86_64,$(ARCH)),$(filter boot,$(SCENARIO))),sidekick)))

# Each run is NOT idempotent, so no _SENTINEL entry — every invocation
# re-enters dispatch and re-checks `mach` (skipped if fresh).
run: $(_RUN_PREREQS)
	@GNUMACH_KERNEL="$(GNUMACH_KERNEL)" \
	 ARCH="$(ARCH)" \
	 WORK="$(WORK)" \
	 RUN_VANILLA="$(RUN_VANILLA)" \
	 RUN_ACCEL="$(RUN_ACCEL)" \
	 RUN_KEEP_OVERLAY="$(RUN_KEEP_OVERLAY)" \
	 SIDEKICK_KERNEL="$(SIDEKICK_KERNEL)" \
	 SIDEKICK_INITRD="$(SIDEKICK_INITRD)" \
	 HURD_DEBIAN_X86_64_URL="$(HURD_DEBIAN_X86_64_URL)" \
	 HURD_DEBIAN_I686_URL="$(HURD_DEBIAN_I686_URL)" \
	 HURD_GENTOO_X86_64_URL="$(HURD_GENTOO_X86_64_URL)" \
	 HURD_GENTOO_I686_URL="$(HURD_GENTOO_I686_URL)" \
	 HURD_GUIX_I686_URL="$(HURD_GUIX_I686_URL)" \
	 HURD_GUIX_X86_64_URL="$(HURD_GUIX_X86_64_URL)" \
	 ./tools/dispatch.sh "$(SCENARIO)" $(RUN_ARGS)

# `run-help` has no prereqs — dispatch.sh handles --help before any
# env validation, so the help text works from a clean checkout without
# a built kernel.
run-help:
	@./tools/dispatch.sh --help

endif # NEED_DISPATCH

endif # _SHORTCIRCUIT

endif # _BUILD_GOALS not empty
