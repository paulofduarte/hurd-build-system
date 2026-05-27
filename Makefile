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
# FLAKES is source-only (the nix sub-flakes for cross-gcc,
# gnumach-headers, mig, gnumach, sidekick).  SIDEKICK holds the
# x86_64 helper-VM artefacts at the repo root, gitignored.
PROJ          := $(CURDIR)
SRC           := $(PROJ)/src
WORK          := $(PROJ)/work
FLAKES        := $(PROJ)/flakes
SIDEKICK      := $(PROJ)/.sidekick
DIST_ROOT     := $(PROJ)/dist
DIST          := $(DIST_ROOT)/$(ARCH)

# In-tree iterative build dirs.
GNUMACH_SRC      := $(SRC)/gnumach
GNUMACH_BUILD    := $(WORK)/gnumach/$(ARCH)
GNUMACH_KERNEL   := $(GNUMACH_BUILD)/gnumach
GNUMACH_CONFIGURED := $(GNUMACH_BUILD)/config.status

MIG_SRC          := $(SRC)/mig
MIG_BUILD        := $(WORK)/mig/$(ARCH)
MIG_INSTALL_DIR  := $(MIG_BUILD)/install
LOCAL_MIG        := $(MIG_INSTALL_DIR)/bin/$(MIG)

# Nix-built per-target outputs.  `nix build -o <path>` creates a
# gc-root symlink at <path> pointing into /nix/store.  Each `dist-*`
# rule copies real bytes out of these into the user-visible $(DIST)
# tree, so dist/<arch>/ is a self-contained release prefix — no
# symlinks back into /nix/store for the kernel or headers (the MIG
# wrapper script still embeds a /nix/store *string* near its top,
# but doesn't reference it at runtime; lookup is $0-relative).
NIX_HEADERS_RESULT := $(FLAKES)/gnumach-headers/result-$(ARCH)
NIX_MIG_RESULT     := $(FLAKES)/mig/result-$(ARCH)
NIX_MACH_RESULT    := $(FLAKES)/gnumach/result-$(ARCH)

# Dist artefacts — real copies, so each file's mtime is the cp time
# and make's regular mtime arithmetic just works (no separate stamp
# files needed, no /nix/store epoch-mtime trap).  These ARE the
# make rule targets.
DIST_INCLUDE := $(DIST)/include
DIST_MIG     := $(DIST)/bin/$(MIG)
DIST_MIGCOM  := $(DIST)/libexec/$(MIG_TARGET)-migcom
DIST_KERNEL  := $(DIST)/boot/gnumach

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

# No separate stamps — dist files are real copies (not symlinks into
# /nix/store), so each file's mtime is the cp time and make's regular
# mtime arithmetic is the staleness check.  In-tree artefacts
# ($(GNUMACH_KERNEL), $(LOCAL_MIG)) are real files too.

# ---- Help (always-on) ----
.PHONY: help
help:
	@echo "Targets (for ARCH=$(ARCH)):"
	@echo "  all              build the gnumach kernel in-tree (default; same as 'mach')"
	@echo "  prepare          autoreconf the source trees"
	@echo "  dist-headers     copy gnumach public headers into ./dist/$(ARCH)/include (via nix)"
	@echo "  mig              build MIG in-tree under ./work/mig/$(ARCH)/ (incremental — for MIG iteration)"
	@echo "  dist-mig         copy clean nix-built MIG into ./dist/$(ARCH)/{bin,libexec}/"
	@echo "  mach             build gnumach kernel in-tree under ./work/gnumach/$(ARCH)/ (incremental — for kernel iteration)"
	@echo "  dist-mach        copy clean nix-built kernel into ./dist/$(ARCH)/boot/gnumach"
	@echo "  dist             produce a tarball-ready ./dist/$(ARCH)/ (headers + mig + kernel)"
	@echo "  check            run upstream test suites (== check-mach; MIG tests run inline via nix)"
	@echo "  check-mach       run gnumach's 'make check' (kernel tests under QEMU)"
	@echo "  run              boot the built kernel in qemu (SCENARIO=boot by default)"
	@echo "  run-help         show all 'make run' options (ARCH/SCENARIO/RUN_*)"
	@echo "  sidekick         build the helper VM (x86_64 Alpine, used by Hurd scenarios)"
	@echo "  cache-push       push the $(ARCH) dev-shell closure to the project cachix cache"
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
# (flakes/{cross-gcc,gnumach-headers,mig,gnumach,sidekick}/), so we
# can't `rm -rf` it; instead, scrub only the gitignored bits inside
# (result-* gc-roots) and drop the project-root install directory
# ($(SIDEKICK)) wholesale.
mrproper:
	rm -rf $(WORK)
	rm -rf $(SIDEKICK)
	rm -f  $(FLAKES)/gnumach-headers/result-* $(FLAKES)/mig/result-* $(FLAKES)/gnumach/result-*
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
# Stamp-file pattern: one recipe produces both SIDEKICK_KERNEL and
# SIDEKICK_INITRD.  Make 3.81 lacks grouped-targets (`&:`, Make 4.3+)
# so listing both files as a target would race under `-j`; using a
# stamp as the sole real target avoids that.  (The component targets
# above all use real artefacts as their make rules — see the comment
# at $(DIST_INCLUDE) / $(LOCAL_MIG) / $(DIST_KERNEL) — but the
# sidekick build can't pull the same trick without Make 4.3+.)
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
# Sentinel files are real artefacts (dist copies or in-tree binaries),
# not stamps — each has a real mtime (cp / install time) that make's
# arithmetic uses for staleness checks.
_HEADERS_FILES   := $(DIST_INCLUDE)
_MIG_FILES       := $(_HEADERS_FILES) $(LOCAL_MIG)
_MACH_FILES      := $(_MIG_FILES) $(GNUMACH_KERNEL)
_DIST_MIG_FILES  := $(DIST_MIG) $(DIST_MIGCOM)
_DIST_MACH_FILES := $(DIST_KERNEL)
_DIST_FILES      := $(_HEADERS_FILES) $(_DIST_MIG_FILES) $(_DIST_MACH_FILES)

_SENTINEL.prepare      := $(_PREPARE_FILES)
_PRIMARY.prepare       := $(_PREPARE_FILES)
_WATCH.prepare         := $(GNUMACH_SRC)/configure.ac

_SENTINEL.dist-headers := $(_HEADERS_FILES)
_PRIMARY.dist-headers  := $(DIST_INCLUDE)
_WATCH.dist-headers    := $(GNUMACH_SRC)/include flakes/gnumach-headers

_SENTINEL.mig          := $(_MIG_FILES)
_PRIMARY.mig           := $(LOCAL_MIG)
_WATCH.mig             := $(MIG_SRC) flakes/mig

_SENTINEL.dist-mig     := $(_DIST_MIG_FILES)
_PRIMARY.dist-mig      := $(DIST_MIG)
_WATCH.dist-mig        := $(MIG_SRC) flakes/mig

_SENTINEL.mach         := $(_MACH_FILES)
_PRIMARY.mach          := $(GNUMACH_KERNEL)
_WATCH.mach            := $(GNUMACH_SRC)

_SENTINEL.all          := $(_MACH_FILES)
_PRIMARY.all           := $(GNUMACH_KERNEL)
_WATCH.all             := $(GNUMACH_SRC)

_SENTINEL.dist-mach    := $(_DIST_MACH_FILES)
_PRIMARY.dist-mach     := $(DIST_KERNEL)
_WATCH.dist-mach       := $(GNUMACH_SRC) flakes/gnumach

_SENTINEL.dist         := $(_DIST_FILES)
_PRIMARY.dist          := $(DIST_KERNEL)
_WATCH.dist            := $(GNUMACH_SRC) $(MIG_SRC) flakes/gnumach flakes/mig flakes/gnumach-headers

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

.PHONY: all dist prepare dist-headers mig dist-mig mach dist-mach \
        check check-mach run run-help

# Explicit default — `help` (defined above) would otherwise win the
# "first non-dot target" race.
.DEFAULT_GOAL := all

# ---- Default & top-level groupings ----
# `all` and `dist` are NOT aliases: they list real dependencies we'll
# grow over time (e.g. once Hurd userland builds, add `hurd` /
# `dist-hurd` here).
all: mach

dist: dist-headers dist-mig dist-mach

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
# Public Mach headers come from `nix build .#gnumach-headers-$(ARCH)`,
# copied (not symlinked) into $(DIST_INCLUDE) so the dist/ tree is
# self-contained and tarball-able.  The directory's mtime is set
# explicitly at the end so make's stat() sees a real timestamp
# (cp -r preserves source mtimes, which are /nix/store epoch).
dist-headers: $(DIST_INCLUDE)

$(DIST_INCLUDE): flakes/gnumach-headers/default.nix flake.nix
	@mkdir -p $(dir $(NIX_HEADERS_RESULT))
	$(NIX) --extra-experimental-features 'nix-command flakes' \
	  build .#gnumach-headers-$(ARCH) -o $(NIX_HEADERS_RESULT)
	@mkdir -p $(DIST)
	@rm -rf $(DIST_INCLUDE)
	cp -r $(NIX_HEADERS_RESULT)/include $(DIST_INCLUDE)
	chmod -R u+w $(DIST_INCLUDE)
	@touch $(DIST_INCLUDE)

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

# Src files are listed as prereqs so editing src/mig/foo.c triggers
# this rule.  Without them, the rule's only "real" prereqs are
# configure + the headers, neither of which moves on src edits — so
# `make mig` after editing source would silently fall back to the
# stale build.  We use `git ls-files` to exclude generated files
# (configure, autom4te.cache/, ...) that would otherwise cause false
# rebuilds.  Once the rule fires, mig's own automake dep tracking
# decides what to recompile.
MIG_SRC_FILES := $(addprefix $(MIG_SRC)/,$(shell cd $(MIG_SRC) 2>/dev/null && git ls-files))
$(LOCAL_MIG): $(MIG_SRC)/configure $(DIST_INCLUDE) $(MIG_SRC_FILES)
	@mkdir -p $(MIG_BUILD)
	@# MIG is a *native* host tool — it runs on the build host and
	@# emits portable .c/.h.  The dev-shell's $CC is the cross
	@# compiler (cross-gcc/default.nix shellHook pins it to the
	@# kernel-side toolchain), which would fail configure's "can
	@# create executables" test on the host.  Override to the native
	@# gcc that the dev shell also provides via pkgs.gcc; keep
	@# TARGET_CC (already exported by the dev shell) for cpu.symc.
	cd $(MIG_BUILD) && [ -f config.status ] || \
	  CC=gcc LD= AR= NM= RANLIB= STRIP= OBJCOPY= \
	  $(MIG_SRC)/configure \
	    --target=$(MIG_TARGET) \
	    --prefix=$(MIG_INSTALL_DIR) \
	    TARGET_CPPFLAGS="-I$(DIST_INCLUDE)"
	cd $(MIG_BUILD) && $(MAKE) CC=gcc install

$(MIG_SRC)/configure: $(MIG_SRC)/configure.ac
	cd $(MIG_SRC) && autoreconf -i

# ---- dist-mig ----
# Clean nix-built MIG — wrapper and migcom copied into $(DIST)/{bin,
# libexec}/ as real files.  The wrapper computes its libexec via
# dirname-$0/../libexec at runtime, so this layout works whether
# dist/ stays here or gets tarballed and extracted elsewhere.
# Install -m sets executable mode (defaults differ across platforms).
dist-mig: $(DIST_MIG)

$(DIST_MIG): flakes/mig/default.nix flake.nix
	@mkdir -p $(dir $(NIX_MIG_RESULT))
	$(NIX) --extra-experimental-features 'nix-command flakes' \
	  build .#mig-$(ARCH) -o $(NIX_MIG_RESULT)
	@mkdir -p $(DIST)/bin $(DIST)/libexec
	install -m 0755 $(NIX_MIG_RESULT)/bin/$(MIG_TARGET)-mig $(DIST_MIG)
	install -m 0755 $(NIX_MIG_RESULT)/libexec/$(MIG_TARGET)-migcom $(DIST_MIGCOM)

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
	  $(GNUMACH_SRC)/configure --host=$(GNUMACH_HOST) --prefix=$(DIST) \
	    $(if $(GNUMACH_PLATFORM),--enable-platform=$(GNUMACH_PLATFORM))

# See the MIG_SRC_FILES rationale above — same problem, same fix.
# Gnumach's own automake-generated .Po deps handle .c→.o; we just
# need to make sure outer make actually enters the recipe.
GNUMACH_SRC_FILES := $(addprefix $(GNUMACH_SRC)/,$(shell cd $(GNUMACH_SRC) 2>/dev/null && git ls-files))
$(GNUMACH_KERNEL): $(LOCAL_MIG) $(GNUMACH_CONFIGURED) $(GNUMACH_SRC_FILES)
	cd $(GNUMACH_BUILD) && $(MAKE)

# ---- dist-mach ----
# Clean nix-built kernel, copied into $(DIST_KERNEL) as a real file.
# Counterpart to `mach`:
#
#   `make mach`       — in-tree, incremental, fast iteration
#   `make dist-mach`  — nix-built, fully reproducible, cacheable via
#                       cachix; the file that ships in a release
#                       tarball of dist/<arch>/.
#
# Also pulls in the docs the gnumach package emits alongside the
# kernel — `share/info/mach.info*` (the GNU Mach reference manual,
# ~408K of Info pages) and `share/msgids/gnumach.msgids` (~12K, the
# RPC message-ID table debuggers use to decode wire traces).  These
# come from the same nix derivation as the kernel, so adding them
# here is free — and they're exactly what a userspace SDK consumer
# wants alongside the kernel + headers + mig.
dist-mach: $(DIST_KERNEL)

$(DIST_KERNEL): flakes/gnumach/default.nix flake.nix
	@mkdir -p $(dir $(NIX_MACH_RESULT))
	$(NIX) --extra-experimental-features 'nix-command flakes' \
	  build .#gnumach-$(ARCH) -o $(NIX_MACH_RESULT)
	@mkdir -p $(DIST)/boot
	install -m 0644 $(NIX_MACH_RESULT)/boot/gnumach $(DIST_KERNEL)
	@# Refresh share/ each time so removed files don't linger.  The
	@# cp -r preserves /nix/store epoch mtimes, so touch the tree
	@# afterwards to give make sane staleness arithmetic.
	@rm -rf $(DIST)/share
	cp -r $(NIX_MACH_RESULT)/share $(DIST)/share
	chmod -R u+w $(DIST)/share
	@find $(DIST)/share -exec touch {} +

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
# `make dist-mig` / `make dist-mach` / `make dist`.
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
