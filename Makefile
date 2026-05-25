# Top-level Makefile for the GNU Hurd / Mach build.
#
# Usage:
#   make                  build for the host's native arch (default)
#   make TARGET=x86_64    cross-build for a different target
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

# TARGET resolution: env > cmdline > host CPU default.
ifndef TARGET
_HOST_CPU := $(shell uname -m)
TARGET := \
  $(if $(filter arm64 aarch64,$(_HOST_CPU)),aarch64, \
  $(if $(filter x86_64,$(_HOST_CPU)),x86_64, \
  $(if $(filter i386 i486 i586 i686,$(_HOST_CPU)),i686, \
  aarch64)))
endif

# Default MIG_TARGET / MIG binary name when invoked outside the dev shell
# (the shell itself exports the right values). Strip any platform suffix
# from TARGET (e.g. i686-xen -> i686) since MIG only cares about CPU ABI;
# Xen and PC-AT share the same MIG binary.
ifndef MIG_TARGET
MIG_TARGET := $(firstword $(subst -, ,$(TARGET)))-gnu
endif
ifndef MIG
MIG := $(MIG_TARGET)-mig
endif

# Layout
PROJ          := $(CURDIR)
SRC           := $(PROJ)/src
WORK          := $(PROJ)/work
TOOLCHAIN     := $(PROJ)/toolchain
DIST_ROOT     := $(PROJ)/dist
DIST          := $(DIST_ROOT)/$(TARGET)

GNUMACH_SRC   := $(SRC)/gnumach
GNUMACH_BUILD := $(WORK)/gnumach/$(TARGET)
MIG_SRC       := $(SRC)/mig
MIG_BUILD     := $(WORK)/mig/$(TARGET)

GNUMACH_CONFIGURED := $(GNUMACH_BUILD)/config.status
MIG_CONFIGURED     := $(MIG_BUILD)/config.status
GNUMACH_KERNEL     := $(GNUMACH_BUILD)/gnumach.elf
# Bootable kernel image — the stripped Image qemu's -kernel consumes.
# GNUMACH_KERNEL (.elf) is the un-stripped linker output we use as the
# build sentinel; on aarch64 qemu silently hangs if given the .elf, so
# the harness must point -kernel at the stripped image instead.
GNUMACH_BOOT_IMAGE := $(GNUMACH_BUILD)/gnumach
MIG_INSTALLED      := $(TOOLCHAIN)/bin/$(MIG)

# Sidekick helper VM artefacts (x86_64 Alpine; built via the root flake's
# `packages.<system>.sidekick` output — see tools/sidekick/default.nix
# and tools/sidekick/init.sh).  Used for ext2 module extraction
# (Gentoo/Guix) and grub-mkrescue ISO assembly (x86_64 inject mode).
SIDEKICK_KERNEL := $(TOOLCHAIN)/sidekick/vmlinuz
SIDEKICK_INITRD := $(TOOLCHAIN)/sidekick/initramfs.cpio.gz
SIDEKICK_STAMP  := $(TOOLCHAIN)/sidekick/.stamp

# Hurd distro image URLs — referenced by tools/run/hurd-*.sh.
# Naming uses our build-system convention (X86_64 / I686); where the
# distro uses its own arch nomenclature, the mapping lives ONLY inside
# the URL string.
# Debian: `latest/hurd-{amd64,i386}/debian-hurd.img.tar.gz` is a versionless
# 302-redirect to the most recently published dated image (e.g.
# debian-hurd-amd64-YYYYMMDD.img.tar.gz).  Same trade-off as Gentoo — the
# cached copy doesn't auto-refresh; `rm -rf work/test-images/debian/<TARGET>/`
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

# Stamps we touch ourselves after invoking gnumach's `make install*` steps.
# We don't anchor on the installed files directly because gnumach's install
# uses `install-sh -C` (compare-only): when the source bytes match the
# destination, the dest isn't touched — its mtime stays old, and our
# staleness heuristic would loop. Stamps decouple "we ran the install"
# from "did install touch the file".
HEADERS_STAMP      := $(DIST)/.headers-installed
DIST_MACH_STAMP    := $(DIST)/.mach-installed

# ---- Help (always-on) ----
.PHONY: help
help:
	@echo "Targets (for TARGET=$(TARGET)):"
	@echo "  all              build the gnumach kernel (default)"
	@echo "  prepare          autoreconf the source trees"
	@echo "  dist-headers     install gnumach public headers into ./dist/$(TARGET)/include"
	@echo "  toolchain        dist-headers + build & install MIG into ./toolchain/"
	@echo "  mach             build gnumach kernel"
	@echo "  dist-mach        install gnumach into ./dist/$(TARGET)/"
	@echo "  dist             install everything (== dist-mach for now)"
	@echo "  check            run all upstream test suites (== check-toolchain + check-mach)"
	@echo "  check-toolchain  run MIG's 'make check' (host-side codegen tests)"
	@echo "  check-mach       run gnumach's 'make check' (kernel tests under QEMU)"
	@echo "  run              boot the built kernel in qemu (SCENARIO=boot by default)"
	@echo "  run-help         show all 'make run' options (TARGET/SCENARIO/RUN_*)"
	@echo "  sidekick         build the helper VM (x86_64 Alpine, used by Hurd scenarios)"
	@echo "  clean            per-subdir 'make clean' — preserves configure state"
	@echo "  clean-dist       rm -rf dist/$(TARGET)/ (just this target)"
	@echo "  mrproper         rm -rf work/ + toolchain/ + all dist/ + all gitignored files"
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
	@for d in $(WORK)/gnumach/* $(WORK)/mig/*; do \
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

clean-dist:
	rm -rf $(DIST)

# mrproper still nukes work/ wholesale — that's a deeper reset and we
# expect users to invoke it when they want a clean slate including
# configure state.
mrproper:
	rm -rf $(WORK)
	rm -rf $(TOOLCHAIN)
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
# See tools/sidekick/{default.nix,packages.nix,init.sh}.
#
# Stamp-file pattern (matches HEADERS_STAMP / DIST_MACH_STAMP
# convention): one recipe produces both SIDEKICK_KERNEL and
# SIDEKICK_INITRD.  Make 3.81 lacks grouped-targets (`&:`, Make 4.3+)
# so listing both files as a target would race under `-j`; using a
# stamp as the sole real target avoids that.
.PHONY: sidekick
sidekick: $(SIDEKICK_STAMP)

$(SIDEKICK_STAMP): tools/sidekick/default.nix tools/sidekick/packages.nix tools/sidekick/init.sh
	@mkdir -p $(dir $(SIDEKICK_KERNEL))
	@echo "  SIDEKICK  building helper VM (x86_64 Alpine + grub-mkrescue + busybox)…"
	$(NIX) --extra-experimental-features 'nix-command flakes' \
	  build .#sidekick \
	  -o $(TOOLCHAIN)/sidekick/result
	cp -f $(TOOLCHAIN)/sidekick/result/vmlinuz             $(SIDEKICK_KERNEL)
	cp -f $(TOOLCHAIN)/sidekick/result/initramfs.cpio.gz   $(SIDEKICK_INITRD)
	@touch $@

# Empty rule: artefact files exist because the stamp recipe produced
# them.  Tells Make how to satisfy a dependency on the artefact paths
# without re-running the build.
$(SIDEKICK_KERNEL) $(SIDEKICK_INITRD): $(SIDEKICK_STAMP) ;

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
_BUILD_GOALS := $(filter-out clean clean-dist mrproper help sidekick,$(_GOALS))

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

_PREPARE_FILES   := $(GNUMACH_SRC)/configure $(MIG_SRC)/configure
_HEADERS_FILES   := $(_PREPARE_FILES) $(HEADERS_STAMP)
_TOOLCHAIN_FILES := $(_HEADERS_FILES) $(MIG_INSTALLED)
_MACH_FILES      := $(_TOOLCHAIN_FILES) $(GNUMACH_KERNEL)
_DIST_MACH_FILES := $(_MACH_FILES) $(DIST_MACH_STAMP)

_SENTINEL.prepare      := $(_PREPARE_FILES)
_PRIMARY.prepare       := $(_PREPARE_FILES)
_WATCH.prepare         := $(GNUMACH_SRC)/configure.ac $(MIG_SRC)/configure.ac

_SENTINEL.dist-headers := $(_HEADERS_FILES)
_PRIMARY.dist-headers  := $(HEADERS_STAMP)
_WATCH.dist-headers    := $(GNUMACH_SRC)/include

_SENTINEL.toolchain    := $(_TOOLCHAIN_FILES)
_PRIMARY.toolchain     := $(MIG_INSTALLED)
_WATCH.toolchain       := $(MIG_SRC) $(GNUMACH_SRC)/include

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
# Outside shell → dispatch.
# Inside shell with mismatched TARGET → dispatch to nest.
# We compare TARGET (the user's desired target) against NIX_TARGET
# (a separate shellHook export, NOT against TARGET via env) because
# command-line `make TARGET=X` overrides $TARGET in subprocess envs
# too — so `$(shell printenv TARGET)` from inside a wrong-target
# shell would return the OVERRIDDEN value, mask the mismatch, and
# silently build with the wrong toolchain.  NIX_TARGET isn't a
# Makefile variable so cmdline overrides don't reach it.
# Older shells without NIX_TARGET set fall through to NEED_DISPATCH
# (empty $(_NIX_TARGET) != any TARGET value), which re-enters with
# a current flake that exports it.
ifndef IN_NIX_SHELL
NEED_DISPATCH := yes
else
_NIX_TARGET := $(shell printenv NIX_TARGET)
ifneq ($(TARGET),$(_NIX_TARGET))
NEED_DISPATCH := yes
endif
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
# ----- Nix available: dispatch through `nix develop -i .#$(TARGET)` ---
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
_dispatch:
	+@$(NIX) --extra-experimental-features 'nix-command flakes' \
	  develop -i .#$(TARGET) \
	  --command make --no-print-directory $(_PARENT_FLAGS) \
	    $(filter-out TARGET=%,$(MAKEOVERRIDES)) $(_BUILD_GOALS)

$(_BUILD_GOALS): _dispatch
	@:
endif

else
# ============================================================
# In the right shell, build sentinels missing — run real build rules.
# ============================================================

# Driven by environment variables that the Nix dev shell exports:
#   TARGET, GNUMACH_HOST, MIG, CC, LD, AR, NM, RANLIB, STRIP, OBJCOPY,
#   TARGET_CC, CFLAGS

# ---- Sanity: must be inside a target dev shell ----
REQUIRED_VARS := TARGET GNUMACH_HOST MIG MIG_TARGET CC CFLAGS

$(foreach v,$(REQUIRED_VARS), \
  $(if $($(v)),,$(error $(v) is not set. Enter a dev shell first: 'nix develop .#aarch64' (or .#x86_64 / .#x86_64-xen / .#i686 / .#i686-xen))))

.PHONY: all dist prepare dist-headers toolchain mach dist-mach \
        check check-toolchain check-mach run run-help

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
# the downstream ./configure / make install-data chain doesn't fire
# spuriously. -fi (force) would unconditionally touch every output,
# defeating that.
prepare: $(GNUMACH_SRC)/configure $(MIG_SRC)/configure

$(GNUMACH_SRC)/configure: $(GNUMACH_SRC)/configure.ac
	cd $(GNUMACH_SRC) && autoreconf -i

$(MIG_SRC)/configure: $(MIG_SRC)/configure.ac
	cd $(MIG_SRC) && autoreconf -i

# ---- dist-headers ----
dist-headers: $(HEADERS_STAMP)

# --enable-platform=$(GNUMACH_PLATFORM) is added only when the dev shell
# set it (x86 targets use "at"/"xen"; aarch64 has no platform option).
#
# USER_MIG is pointed at the eventual install path of our cross MIG so
# that gnumach's tests/configfrag.ac records the right path for the
# userland MIG stub generator. MIG itself is built later in the pipeline
# (the `toolchain` target depends on a configured gnumach for header
# install), so the file at that path doesn't exist yet — but USER_MIG
# is honoured as an env var override of AC_CHECK_PROG without a binary
# existence check, and the path resolves correctly by the time `make
# check-mach` actually exec's it.
$(GNUMACH_CONFIGURED): $(GNUMACH_SRC)/configure
	mkdir -p $(GNUMACH_BUILD)
	cd $(GNUMACH_BUILD) && \
	  USER_MIG=$(TOOLCHAIN)/bin/$(MIG_TARGET)-mig \
	  $(GNUMACH_SRC)/configure --host=$(GNUMACH_HOST) --prefix=$(DIST) \
	    $(if $(GNUMACH_PLATFORM),--enable-platform=$(GNUMACH_PLATFORM))

$(HEADERS_STAMP): $(GNUMACH_CONFIGURED)
	cd $(GNUMACH_BUILD) && $(MAKE) install-data
	@mkdir -p $(@D) && touch $@

# ---- toolchain ----
toolchain: dist-headers $(MIG_INSTALLED)

$(MIG_CONFIGURED): $(MIG_SRC)/configure $(HEADERS_STAMP)
	mkdir -p $(MIG_BUILD)
	cd $(MIG_BUILD) && \
	  CC=gcc TARGET_CPPFLAGS="-I$(DIST)/include" \
	    $(MIG_SRC)/configure --target=$(MIG_TARGET) --prefix=$(TOOLCHAIN)

$(MIG_INSTALLED): $(MIG_CONFIGURED)
	cd $(MIG_BUILD) && $(MAKE) && $(MAKE) install

# ---- mach ----
mach: $(GNUMACH_KERNEL)

$(GNUMACH_KERNEL): toolchain
	cd $(GNUMACH_BUILD) && $(MAKE)

dist-mach: $(DIST_MACH_STAMP)

$(DIST_MACH_STAMP): $(GNUMACH_KERNEL)
	cd $(GNUMACH_BUILD) && $(MAKE) install
	@mkdir -p $(@D) && touch $@

# ---- check ----
# Test suites shipped by the upstream source trees, surfaced as our targets:
#
#   check-toolchain : MIG's 'make check' — host-side codegen tests
#                     (good/, bad/, generate-only/). Always works.
#   check-mach      : gnumach's 'make check' — kernel tests run inside QEMU.
#                     Upstream wiring is i386/x86_64-multiboot; aarch64 may
#                     need additional plumbing in src/gnumach/tests/.
#   check           : both, in the order MIG -> mach.
#
# These intentionally have no _SENTINEL entries — running a test suite is
# not idempotent, so we always dispatch and let the inner make decide.
check-toolchain: toolchain
	@echo "==> check-toolchain ($(TARGET)): running MIG 'make check' in $(MIG_BUILD)"
	@# tests/test_lib.sh on our mig fork honours external CFLAGS (the
	@# stock upstream version hardcoded it and overwrote external values),
	@# so we point the test harness at this target's installed mach
	@# headers via CFLAGS.
	cd $(MIG_BUILD) && $(MAKE) check CFLAGS="-I$(DIST)/include"

# The kernel test suite runs on every TARGET we support; xen variants
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
	@echo "==> check-mach ($(TARGET)): ERROR — darwin host is not supported." >&2
ifeq ($(TARGET),aarch64)
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
	@echo "==> check-mach ($(TARGET)): running gnumach 'make check' in $(GNUMACH_BUILD)"
	cd $(GNUMACH_BUILD) && $(MAKE) check
endif

check: check-toolchain check-mach

# ---- run ----
# `make run TARGET=<arch> SCENARIO=<name>` — ad-hoc qemu launch against
# the kernel we just built.  Architecture comes from TARGET (same
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
#   RUN_ACCEL=1         -accel hvf/kvm when host arch matches TARGET
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
#   sidekick   — needed for any scenario that has to wrap our
#                64-bit gnumach in a GRUB-bootable ISO (TARGET=x86_64
#                + boot OR hurd-debian — qemu's -kernel rejects 64-bit
#                ELFs, see D18), AND for module extraction from qcow2s
#                (hurd-gentoo, hurd-guix regardless of TARGET).
#                Debian i686 inject skips it (Debian publishes
#                standalone modules + i686 ELF is multiboot1-loadable).
#                Vanilla mode skips it for every Hurd scenario.
#
# The expression evaluates at Makefile-parse time.  Cells:
#   RUN_VANILLA=1 + hurd-*                          → empty
#   boot + TARGET=i686/aarch64                      → mach
#   boot + TARGET=x86_64                            → mach sidekick (mkiso)
#   non-vanilla hurd-debian + TARGET=i686           → mach
#   non-vanilla hurd-debian + TARGET=x86_64         → mach sidekick (extract+mkiso)
#   non-vanilla hurd-{gentoo,guix} + any TARGET     → mach sidekick
_RUN_PREREQS := \
  $(if $(and $(filter 1,$(RUN_VANILLA)),$(filter hurd-debian hurd-gentoo hurd-guix,$(SCENARIO))),, \
    mach \
    $(if $(filter hurd-gentoo hurd-guix,$(SCENARIO)),sidekick, \
      $(if $(and $(filter x86_64,$(TARGET)),$(filter boot hurd-debian,$(SCENARIO))),sidekick)))

# Each run is NOT idempotent, so no _SENTINEL entry — every invocation
# re-enters dispatch and re-checks `mach` (skipped if fresh).
run: $(_RUN_PREREQS)
	@GNUMACH_BOOT_IMAGE="$(GNUMACH_BOOT_IMAGE)" \
	 TARGET="$(TARGET)" \
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
	 ./tools/run/dispatch.sh "$(SCENARIO)" $(RUN_ARGS)

# `run-help` has no prereqs — dispatch.sh handles --help before any
# env validation, so the help text works from a clean checkout without
# a built kernel.
run-help:
	@./tools/run/dispatch.sh --help

endif # NEED_DISPATCH

endif # _SHORTCIRCUIT

endif # _BUILD_GOALS not empty
