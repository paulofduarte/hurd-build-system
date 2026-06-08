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
# `nix build` with -L (--print-build-logs) so the full build logs stream to the
# terminal, not just the summary.  (eval calls use $(NIX_FLAKE) directly — -L is
# build-only.)
NIX_BUILD := $(NIX_FLAKE) build -L

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

# Boolean-knob normalizer: $(call _bool,VALUE) -> "1" if truthy, "" if falsey.
#   off (""):  empty / 0 / no / off / false   (any case)
#   on  ("1"): anything else — 1 / yes / on / true / …
# Gives GLIBC_IN_TREE / MIG_IN_TREE / MULTI_HOST_BUILDS uniform, case-insensitive
# truthiness — make's bare $(if …)/ifdef otherwise treat ANY non-empty string
# (incl. "0") as true.  $(_lc) lowercases via tr so On/OFF/False also resolve.
_lc   = $(shell printf %s '$(1)' | tr 'A-Z' 'a-z')
_bool = $(if $(filter-out 0 no off false,$(call _lc,$(strip $(1)))),1)

# $(eval $(call _detect_in_tree,FLAG,SRC)): the shared opt-in rule for the four
# in-tree-able modules (mig, glibc, gnumach, hurd).  Auto-enable FLAG (=1) when
# src/<m>/.git is present, UNLESS an explicit env/command-line value was given
# (the $(origin) guard lets `FLAG=0`/`FLAG=1` override the auto-detect); then
# normalize to ""/"1" via _bool.  `override` is required to beat a command-line
# value (make keeps `FLAG=0` verbatim, and "0" is truthy to bare $(if …)).
define _detect_in_tree
ifeq ($$(origin $(1)),undefined)
$(1) := $$(if $$(wildcard $(2)/.git),1)
endif
override $(1) := $$(call _bool,$$($(1)))
endef

# MULTI_HOST_BUILDS (boolean) + ALT_BUILD (tag): optional path segments inserted
# before the target arch in BOTH the work/ and dist/ trees, so builds that share
# one checkout don't collide.  Both off by default → the normal layout
# (work/<c>/<arch>, dist/<arch>) is unchanged for ordinary devs.
#   MULTI_HOST_BUILDS : truthy splits per BUILD HOST — the nix system, e.g.
#                       aarch64-darwin — for cross-host determinism testing where
#                       orb mounts the same checkout over 9p.  It is a BOOLEAN: the
#                       host system is resolved automatically (no value to type);
#                       falsey spellings (0/no/off/false/empty) = off.
#   ALT_BUILD         : arbitrary variant tag (e.g. nix / in-tree) to keep two
#                       configurations' trees side by side on ONE host.
MULTI_HOST_BUILDS ?=
ALT_BUILD         ?=
override MULTI_HOST_BUILDS := $(call _bool,$(MULTI_HOST_BUILDS))
# Resolve the host's nix system tuple (e.g. aarch64-darwin) only when
# MULTI_HOST_BUILDS is on (the $(shell) is guarded by the conditional, lazy).
# From uname — instant, no subprocess `nix eval`: uname -m's arm64 (darwin) maps
# to nix's aarch64; uname -s lowercases to the OS half.
ifneq ($(MULTI_HOST_BUILDS),)
_HOST_SYSTEM := $(subst arm64,aarch64,$(shell uname -m))-$(shell uname -s | tr A-Z a-z)
endif
# $(_VARIANT) = "<host-system>/<alt>/" infix (empty parts dropped), spliced before
# $(ARCH)/$(_TC_ARCH) in every work + dist path below, and forwarded across the
# dev-shell dispatch so the inner make computes the same paths.
_VARIANT := $(if $(_HOST_SYSTEM),$(_HOST_SYSTEM)/)$(if $(ALT_BUILD),$(ALT_BUILD)/)

# DIST is the per-arch output tree; override to install elsewhere.
# DIST_GNUMACH / DIST_HURD / DIST_GLIBC each default to DIST (so with no override
# all dist-* targets populate one tree, dist/$(_VARIANT)$(ARCH)) but can be
# pointed at separate trees independently.
DIST          ?= $(DIST_ROOT)/$(_VARIANT)$(ARCH)
DIST_GNUMACH     ?= $(DIST)
DIST_HURD     ?= $(DIST)
DIST_GLIBC    ?= $(DIST)
# dist-glibc-nix records the last-shipped nix glibc + gcc-lib store paths here —
# under work/ (NOT in the dist tree, which is the shippable artefact), per-ARCH
# (and per-variant) in the filename so i686/x86_64 + variants don't clobber one
# stamp.  An unchanged pair skips the verbatim copy (resolve is cheap, cp ~30MB).
DIST_GLIBC_NIX_STAMP := $(WORK)/dist-glibc-nix/$(_VARIANT)$(ARCH).stamp
# dist-gnumach-nix / dist-hurd-nix record the last-shipped nix kernel / userland
# store path (same work/ per-variant-per-ARCH scheme) so an unchanged package
# skips the verbatim copy.  gnumach is per-ARCH (the kernel differs for xen);
# hurd is per-_TC_ARCH (CPU-ABI userland), but both stamps key on $(ARCH) so the
# i686 and i686-xen dist trees track their own copies independently.
DIST_GNUMACH_NIX_STAMP := $(WORK)/dist-gnumach-nix/$(_VARIANT)$(ARCH).stamp
DIST_HURD_NIX_STAMP    := $(WORK)/dist-hurd-nix/$(_VARIANT)$(ARCH).stamp
# dist-libgcc records the last-shipped gcc-runtime store path here (same work/
# per-ARCH scheme); the gcc runtime is independent of the glibc choice.
DIST_LIBGCC_STAMP    := $(WORK)/dist-libgcc/$(_VARIANT)$(ARCH).stamp
# dist-tzdata records the last-shipped tzdata store path here; tzdata is
# arch-independent, but the stamp tracks the copy into this $(ARCH) dist tree.
DIST_TZDATA_STAMP    := $(WORK)/dist-tzdata/$(_VARIANT)$(ARCH).stamp

# Per-component deterministic dist mtimes: each dist-* recipe stamps the files IT
# wrote into the shared $(DIST) to ITS OWN source's commit date (flake.lock
# `lastModified`), so e.g. /lib's glibc libs carry glibc-src's date while the gcc
# runtime carries nixpkgs' — true provenance instead of nix's 1970 epoch.  The
# untracked nix packages (gcc runtime, tzdata) have no commit we pin, so they use
# the `nixpkgs` snapshot date (the source we DO pin for them).  Parsed with jq
# (dev-shell); empty if flake.lock/jq absent -> that component's mtime left as-is.
src-epoch      = $(shell jq -r '.nodes["$(1)"].locked.lastModified' flake.lock 2>/dev/null)
EPOCH_GNUMACH    := $(call src-epoch,gnumach-src)
EPOCH_HURD    := $(call src-epoch,hurd-src)
EPOCH_GLIBC   := $(call src-epoch,glibc-src)
EPOCH_NIXPKGS := $(call src-epoch,nixpkgs)

# Wall-clock when this make started — the cut between "written by this build"
# (make install / install-info / cp -L set a CURRENT mtime) and earlier
# components' already-stamped files (a past source date).  Evaluated once at parse.
DIST_BUILD_START := $(shell date +%s)

# $(call dist-stamp,<epoch>): stamp the files the calling dist-* recipe just wrote
# into $(DIST) to <epoch>.  Matches files newer than DIST_BUILD_START (this build's
# installs) OR still at the nix store epoch (mtime<=1, from `cp -a`); earlier
# components' files (a past date, 1 < date < start) are left alone, so each
# component owns its files even in the shared /lib, /share/info, /include.
# Idempotent: a skipped (unchanged) component re-running this matches nothing.
# No-op if <epoch> is empty.  Runs in the dev-shell (GNU find/touch).
define dist-stamp
[ -z "$(1)" ] || find $(DIST) \( -type f -o -type l \) \( -newermt @$(DIST_BUILD_START) -o ! -newermt @1 \) -exec touch -h -d @$(1) {} +
endef

# A xen variant shares its CPU sibling's `<cpu>-gnu` ABI: it has no separate
# nix toolchain (`toolchain-<cpu>-xen`) and its entire USERLAND (glibc, the hurd
# servers/libs, mig, the public mach/hurd headers) is byte-identical to the
# non-xen sibling's — "xen" only selects the gnumach KERNEL's platform, and the
# kernel links -ffreestanding -nostdlib and never reads the userland sysroot.
# So strip the suffix and key the userland build/sysroot dirs by $(_TC_ARCH):
# i686 and i686-xen then build the userland ONCE (shared work dirs), and only
# the per-$(ARCH) kernel (GNUMACH_BUILD) + the per-$(ARCH) dist trees differ.
# This matches the nix side (glibc-hurd/hurd/mig are keyed per crossTarget) and
# avoids both a redundant userland rebuild on a variant switch and the spurious
# per-ARCH build-dir paths that otherwise leak into the userland's DWARF.
_TC_ARCH := $(patsubst %-xen,%,$(ARCH))

# In-tree iterative build dirs.  KERNEL dirs are per-$(ARCH) (platform-specific);
# USERLAND dirs are per-$(_TC_ARCH) (shared across a CPU's xen/non-xen variants).
GNUMACH_SRC      := $(SRC)/gnumach
GNUMACH_BUILD    := $(WORK)/gnumach/$(_VARIANT)$(ARCH)
GNUMACH_KERNEL   := $(GNUMACH_BUILD)/gnumach
GNUMACH_CONFIGURED := $(GNUMACH_BUILD)/config.status
# gnumach is opt-in in-tree (like glibc/mig): src/gnumach present -> build the
# kernel from it; absent (or GNUMACH_IN_TREE=0/no/off/false) -> ship/use the nix
# kernel package.  Force on/off via env or command line; an explicit value beats
# the src/gnumach auto-detect and is forwarded across the dev-shell dispatch.
$(eval $(call _detect_in_tree,GNUMACH_IN_TREE,$(GNUMACH_SRC)))
# Separate build dir for the headers-only install: it configures with a stub
# USER_MIG so it can run BEFORE mig exists (mig needs the Mach headers), and
# installs into the build-only SYSROOT below — distinct from the kernel build
# dir, which uses the real mig + --prefix=$(DIST_GNUMACH).
GNUMACH_HDR_BUILD := $(WORK)/gnumach-headers/$(_VARIANT)$(_TC_ARCH)
GNUMACH_HDR_CONFIGURED := $(GNUMACH_HDR_BUILD)/config.status
# Stamp for the Mach-headers install, kept in the BUILD dir (not the sysroot).
# Consumers (mig, glibc) depend on this stamp, NOT on $(SYSROOT)/include/mach:
# glibc's own `make install` writes its mach/* wrapper headers into that shared
# dir, bumping its mtime — which, if used as a prereq, would invalidate glibc's
# config.status and loop a rebuild.  The stamp is touched only by gnumach-headers.
GNUMACH_HDR_STAMP := $(GNUMACH_HDR_BUILD)/.headers-installed
# Staging prefix for the Mach headers: install-data lands here, then they are
# symlink-farmed into $(SYSROOT) with `cp -rs` (see the gnumach-headers recipe).
GNUMACH_HDR_STAGE := $(GNUMACH_HDR_BUILD)/install

# Build-only sysroot for the cross headers, populated per component (Mach now
# via `gnumach-headers`; Hurd later, for an opt-in glibc-from-source build).  This
# is what the in-tree mig (and future glibc) depends on — a STABLE location
# nothing installs into later.  Crucially NOT under $(DIST): the hurd userland's
# `make install` writes $(DIST)/include too, so if mig depended on the dist
# include dir, hurd's install would bump its mtime and make mig perpetually
# stale (a reconfigure/rebuild feedback loop).  Headers reach $(DIST) via the
# dist-* targets' own `make install`, not from here.
SYSROOT          := $(WORK)/sysroot/$(_VARIANT)$(_TC_ARCH)

MIG_SRC          := $(SRC)/mig
MIG_BUILD        := $(WORK)/mig/$(_VARIANT)$(_TC_ARCH)
MIG_INSTALL_DIR  := $(MIG_BUILD)/install
LOCAL_MIG        := $(MIG_INSTALL_DIR)/bin/$(MIG_NAME)

# mig is opt-in in-tree.  The dev shell always exports MIG (the nix-built
# working mig), so mig is available with no `make mig`.  Populating the in-tree
# source (`make src-mig`) flips MIG to the in-tree binary and turns `make mig`
# into a real build; without it `make mig` is a no-op and mach/hurd use the
# shell's MIG.  Keyed on src/mig/.git so it tracks exactly what `make src-mig`
# / `make srcs` create.
#
# Force on/off explicitly with MIG_IN_TREE=1 / MIG_IN_TREE=0 (env or command line,
# same falsey/truthy spellings as GLIBC_IN_TREE): an explicit value skips the
# src/mig auto-detect and is forwarded across the dev-shell dispatch.  MIG (the
# binary) is set to the in-tree build whenever MIG_IN_TREE ends up on, however
# decided — else it stays the dev-shell $MIG.
$(eval $(call _detect_in_tree,MIG_IN_TREE,$(MIG_SRC)))
ifdef MIG_IN_TREE
MIG := $(LOCAL_MIG)
endif

# Hurd source clone (populated by `make srcs` from the `hurd-src` flake
# input pin) + in-tree build dir.  See the `hurd` / `dist-hurd` targets.
HURD_SRC         := $(SRC)/hurd
HURD_BUILD       := $(WORK)/hurd/$(_VARIANT)$(_TC_ARCH)
HURD_CONFIGURED  := $(HURD_BUILD)/config.status
# hurd is opt-in in-tree (like glibc/mig): src/hurd present -> build the userland
# from it; absent (or HURD_IN_TREE=0/no/off/false) -> ship/use the nix hurd
# package.  Force on/off via env or command line; an explicit value beats the
# src/hurd auto-detect and is forwarded across the dev-shell dispatch.
$(eval $(call _detect_in_tree,HURD_IN_TREE,$(HURD_SRC)))

# Rewrite the absolute build-time source dir out of assert()/__FILE__ strings so
# the in-tree-built kernel + userland don't bake the host path into shipped
# .rodata.  ONLY the in-tree builds need this: they configure OUT of tree (in
# $(*_BUILD)) with an absolute $(srcdir), so every __FILE__ is absolute; the nix
# builds compile in-source (relative __FILE__) and are already clean — hence no
# toolchain rebuild and no change to glibc/gcc (also already clean).
# -fmacro-prefix-map (not -ffile-) touches only __FILE__/.rodata, leaving DWARF
# paths intact for offline debugging.  $(1) = the build's absolute source dir.
_macro_prefix_map = -fmacro-prefix-map=$(1)/=

# Headers-only build dir for hurd (sibling to GNUMACH_HDR_BUILD): `make
# install-headers` populates $(SYSROOT)/include/hurd, the Hurd half of the
# sysroot the in-tree glibc builds against.
HURD_HDR_BUILD   := $(WORK)/hurd-headers/$(_VARIANT)$(_TC_ARCH)
HURD_HDR_CONFIGURED := $(HURD_HDR_BUILD)/config.status
# Writable staging for the NIX hurd-headers farm (the in-tree path installs real
# files straight into $(SYSROOT); the nix $out is read-only) — see _farm_nix_headers.
HURD_HDR_STAGE   := $(HURD_HDR_BUILD)/install
# Stamp for the Hurd-headers install (see GNUMACH_HDR_STAMP for the why): glibc
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
#   make glibc GLIBC_BUILD=/Volumes/<case-sensitive>/glibc-$(_TC_ARCH)
GLIBC_BUILD      ?= $(WORK)/glibc/$(_VARIANT)$(_TC_ARCH)
# glibc refuses an in-src build, so build out-of-tree under build/.  NOTE: no
# trailing inline comment on these := lines — make keeps the whitespace before
# a `#`, and an embedded space would split $(GLIBC_CONFIGURED) into two targets.
GLIBC_BUILDDIR   := $(GLIBC_BUILD)/build
GLIBC_CONFIGURED := $(GLIBC_BUILDDIR)/config.status
# Canonical glibc-path roots for -ffile-prefix-map in the in-tree glibc build, so
# it bakes the SAME DWARF paths as the nix glibc (glibc.nix) -> the two are
# byte-identical.  The dev-shell exports these from build-flags.nix (the single
# source); these `?=` defaults match build-flags.nix glibcCanon* for a stray make.
GLIBC_CANON_SRC     ?= /glibc-src
GLIBC_CANON_BUILD   ?= /glibc-build
GLIBC_CANON_SYSROOT ?= /glibc-sysroot
# One canonical root per in-tree gnumach/hurd build: the out-of-tree in-tree
# build maps BOTH its src and build dir to this single name, so (a) the
# MULTI_HOST_BUILDS/ALT_BUILD path infix + cross-host work-path variation don't
# leak into DWARF, and (b) it matches the NIX build (gnumach/default.nix,
# hurd/default.nix build IN-SOURCE and map their one $PWD to the SAME name) so
# in-tree == nix.  Dev-shell exports these from build-flags.nix; `?=` defaults
# match for a stray make.
GNUMACH_CANON_BUILD ?= /gnumach-build
HURD_CANON_BUILD    ?= /hurd-build
# `make glibc` only BUILDS (compiles) glibc — this stamp is its sentinel.
# Installs are DESTDIR-staged (glibc is configured --prefix=/, so its libc.so
# comes out root-relative — a relocatable sysroot consumed via --sysroot):
#   work-glibc  → $(SYSROOT)  (work/sysroot): the BUILD sysroot the in-tree hurd
#                 build links against, beside the mach+hurd headers — mirrors how
#                 gnumach-headers/hurd-headers populate $(SYSROOT).  Private.
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
#
# Force OFF even with src/glibc present (build/ship the NIX glibc — e.g. to A/B
# in-tree vs nix without re-checking-out src/glibc): pass a FALSEY value on the
# command line — GLIBC_IN_TREE=0 (also no/off/false, or empty).  A command-line
# assignment overrides this auto-detect, the normalize below folds falsey->empty
# (make otherwise treats ANY non-empty string, incl. "0", as truthy), and the
# resolved value is forwarded across the dev-shell dispatch (_DIST_PASSTHROUGH) so
# the inner make honours it instead of re-detecting src/glibc.  Pair with
# ALT_BUILD to keep both variants' trees side by side (e.g. ALT_BUILD=nix
# GLIBC_IN_TREE=0).
$(eval $(call _detect_in_tree,GLIBC_IN_TREE,$(GLIBC_SRC)))

# In-tree working-source overrides — SCOPED per nix target + per *_IN_TREE.
# A nix package builds from its pinned *-src by default; `--override-input
# <m>-src src/<m>` repoints an input at the local clone (nix git-tree semantics:
# tracked + uncommitted edits, no .git copy) so nix builds the WORKING source —
# the point of in-tree hacking, and what makes a dist-*-nix half match its in-tree
# twin.  We override an input ONLY when (a) the target actually consumes it AND
# (b) that module's <M>_IN_TREE is on.  So `make gnumach GNUMACH_IN_TREE=0`
# overrides nothing of gnumach's, and a module's src is never dragged in by an
# unrelated build.  The frozen `*-ref-src` twins are NEVER overridden, so gcc
# stays put (a glibc/header/mig hack rebuilds the working chain, never the gcc).
#
# Dependency graph — the WORKING src inputs each nix target transitively consumes
# (verified vs the flake wiring): mig builds against gnumach-headers; gnumach runs
# mig; gnumach-headers is standalone; hurd-headers uses mig as a build tool (which
# drags in gnumach); hurd links the working glibc-hurd + uses mig + mach/hurd
# headers; glibc-hurd farms gnumach+hurd headers + mig.  The wrapped toolchain is
# built from the FROZEN *-ref-src, so a working override never rebuilds gcc.
_dG := gnumach mig                  # gnumach kernel
_dH := hurd mig gnumach glibc       # hurd userland
_dC := glibc gnumach hurd mig       # glibc-hurd (working)
_DEPS.mig               := mig gnumach
_DEPS.gnumach           := $(_dG)
_DEPS.dist-gnumach      := $(_dG)
_DEPS.dist-gnumach-tree := $(_dG)
_DEPS.dist-gnumach-nix  := $(_dG)
_DEPS.gnumach-headers   := gnumach
_DEPS.hurd-headers      := hurd mig gnumach
_DEPS.hurd              := $(_dH)
_DEPS.dist-hurd         := $(_dH)
_DEPS.dist-hurd-tree    := $(_dH)
_DEPS.dist-hurd-nix     := $(_dH)
_DEPS.glibc             := $(_dC)
_DEPS.work-glibc        := $(_dC)
_DEPS.dist-glibc        := $(_dC)
_DEPS.dist-glibc-tree   := $(_dC)
_DEPS.dist-glibc-nix    := $(_dC)
_DEPS.dist              := mig gnumach hurd glibc
_DEPS.all               := mig gnumach hurd glibc

# module → its IN_TREE flag var.
_FLAG.mig     := MIG_IN_TREE
_FLAG.gnumach := GNUMACH_IN_TREE
_FLAG.hurd    := HURD_IN_TREE
_FLAG.glibc   := GLIBC_IN_TREE
# $(call _override1,MODULE): override <m>-src iff <M>_IN_TREE is truthy.  No
# clone-existence test — a truthy flag with an absent src/<m> is caught (fail
# fast) by the _need_src guard below, exactly as for a directly-built module.
_override1 = $(if $($(_FLAG.$(1))),--override-input $(1)-src $(SRC)/$(1))
# $(call _overrides,TARGET): the scoped --override-input set for a nix TARGET.
_overrides = $(foreach d,$(_DEPS.$(1)),$(call _override1,$(d)))

# Dirtiness cascade (in-tree only).  $(call _src_is_dirty,MODULE) -> "1" if
# src/<m> has uncommitted TRACKED changes; $(call _chain_dirty,TARGET) -> non-
# empty if TARGET or ANY of its dependencies ($(_DEPS.TARGET)) is dirty AND that
# dependency is built IN-TREE ($(_FLAG.<dep>) on) — so a nix-served dependency
# (pinned/committed) never marks the build dirty.  Mirrors the chain
# mig <-> gnumach -> glibc -> hurd: a dirty in-tree mig marks gnumach; a dirty
# gnumach marks glibc; a dirty glibc (or its dirty headers) marks hurd.  Lazy
# (`=`) so git only runs when a consumer (a recipe) expands it.
_src_is_dirty = $(shell git -C $(SRC)/$(1) diff --quiet HEAD 2>/dev/null || echo 1)
_chain_dirty  = $(strip $(foreach d,$(_DEPS.$(1)),$(if $($(_FLAG.$(d))),$(call _src_is_dirty,$(d)))))
# glibc's version is NOT stamped (it ships version.h's plain number, release is
# CI-only) — but it carries this internal dirty status so a dirty chain is
# surfaced (a build warning) and CASCADES into hurd's version `-dirty` (hurd's
# _chain_dirty already scans glibc + its deps, so no extra wiring is needed).
GLIBC_DIRTY = $(call _chain_dirty,glibc)

# $(call _nix_build,TARGET,ATTR): realize a nix package — the opted-out path for a
# module's `make <module>` (src absent or <MODULE>_IN_TREE falsey): instead of a
# no-op, build the flake ATTR so it's cached/up to date.  TARGET is the _DEPS key
# (drives the scoped working-source overrides).  Shared by all four modules'
# ifndef stubs (mig, glibc, gnumach, hurd) — keep DRY.
_nix_build = @echo "  NIX-BUILD       $(2)"; $(NIX_BUILD) $(call _overrides,$(1)) $(PROJ)\#$(2) --no-link

# $(call _farm_headers,DIR): symlink-farm DIR/include into the build sysroot
# (cp -rs, mirroring glibc.nix's sysroot construction) — gcc keeps the logical
# $(SYSROOT)/include/... paths (the symlink targets are longer), so an in-tree
# glibc built against these bakes the same header paths whether the Mach/Hurd
# headers came from the in-tree stage or the nix *-headers package.  Shared by
# the in-tree-stage and nix-package header paths (keep DRY).
_farm_headers = mkdir -p $(SYSROOT)/include && cp -rsf $(1)/include/. $(SYSROOT)/include/

# $(call _farm_nix_headers,PKG,STAGE): like _farm_headers but for a nix *-headers
# package, whose $out is READ-ONLY.  An in-tree glibc/hurd installs its OWN generated
# headers OVER the farm (glibc writes mach/mach_interface.h …, hurd/*.h into the same
# sysroot); `install` writes THROUGH the farm symlinks, so they must point at WRITABLE
# files — symlinking straight to the store fails with EACCES.  Stage PKG/include into
# the writable STAGE (cp -a preserves symlinks like mach/machine → DWARF parity with
# the in-tree stage), make it writable, then symlink-farm from there.
_farm_nix_headers = rm -rf $(2); mkdir -p $(2); cp -a $(1)/include $(2)/; chmod -R u+w $(2); $(call _farm_headers,$(2))

# $(call _bake_version,DEPKEY,ATTR,SRCDIR): stamp the in-tree build with the SAME
# composed PACKAGE_VERSION the nix build bakes, so nix == in-tree byte-for-byte.
# autoconf has no configure-time version override (the version is hard-set via
# AC_INIT/version.m4), and building from a sed'd source COPY (as nix does) would
# defeat the in-tree's incremental iteration — so we finish the FRESHLY-GENERATED,
# untracked `configure` (this rule's own autoreconf output; tracked src is never
# touched).  The version itself comes from nix (`.#<ATTR>.version` — the same
# composeVersion, with the working-source overrides) so the two agree by reuse,
# not duplication.  DIRTY FLAG: nix can't see a dirty src (flake inputs lock the
# committed rev), so the in-tree appends `-dirty` right after `-g<src>` when the
# module OR ANY of its in-tree dependency sources ($(_DEPS.DEPKEY)) has uncommitted
# tracked changes — a deliberate divergence that surfaces an uncommitted build
# (e.g. a dirty src/gnumach's mach headers cascade into hurd/glibc).
define _bake_version
	@ver=$$($(NIX_FLAKE) eval --raw $(call _overrides,$(1)) $(PROJ)\#$(2).version 2>/dev/null); \
	[ -n "$$ver" ] || { echo "ERROR: cannot resolve nix $(2).version for the in-tree version stamp"; exit 1; }; \
	$(if $(call _chain_dirty,$(1)),ver="$$(printf %s "$$ver" | sed -E 's/(-g[0-9a-f]+)(\+|$$)/\1-dirty\2/')";) \
	echo "  STAMP-VERSION   $(2) = $$ver"; \
	sed -E -i \
	  -e "s/^PACKAGE_VERSION=.*/PACKAGE_VERSION='$$ver'/" \
	  -e "s/^VERSION=.*/VERSION='$$ver'/" \
	  -e "s/^(PACKAGE_STRING='.*) [^ ']*'/\1 $$ver'/" \
	  $(3)/configure
endef


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
	@echo "  all              build the kernel + Hurd userland in-tree (default; = gnumach + hurd)"
	@echo "  gnumach          build gnumach kernel in-tree under ./work/gnumach/$(ARCH)/ (incremental — for kernel iteration)"
	@echo "  dist-gnumach        install the in-tree kernel into ./dist/$(ARCH)/ (boot/gnumach + headers + docs)"
	@echo "  dist             install kernel + Hurd userland + glibc into ./dist/$(ARCH)/ (= dist-gnumach + dist-hurd + a glibc step; mig is host-arch, not bundled)"
	@echo "  hurd             build the Hurd userland in-tree under ./work/hurd/$(_TC_ARCH)/ (incremental; needs ARCH=i686|x86_64)"
	@echo "  dist-hurd        install the in-tree Hurd userland into ./dist/$(ARCH)/ (under fakeroot)"
	@echo "  mig              build MIG in-tree — opt-in for iterating on MIG (run 'make src-mig' first)"
	@echo "                   (otherwise a no-op: MIG is always available without it)"
	@echo "  glibc            build glibc in-tree — opt-in for hacking glibc (run 'make src-glibc' first;"
	@echo "                   else a no-op).  The in-tree userland then links against it."
	@echo "  dist-glibc       install glibc into ./dist/$(ARCH)/ — the in-tree build if opted in (make src-glibc), else the nix deployable glibc"
	@echo "  dist-libgcc      install the gcc base runtime (libgcc_s + libstdc++) from the nix cross-gcc into ./dist/$(ARCH)/lib"
	@echo "  check            run the kernel test suite (== check-gnumach)"
	@echo "  check-gnumach       run gnumach's 'make check' (kernel tests under QEMU)"
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
	@# The CURRENT variant's gnumach build (MULTI_HOST_BUILDS/ALT_BUILD-scoped);
	@# `mrproper` nukes every variant.
	@if [ -f $(GNUMACH_BUILD)/Makefile ]; then \
	  echo "  CLEAN  $(GNUMACH_BUILD)"; \
	  $(MAKE) --no-print-directory -C $(GNUMACH_BUILD) clean; \
	fi
	@# gnumach's own `make clean` doesn't remove the final kernel image
	@# (it's effectively a `mostlyclean`). Explicitly remove the artefacts
	@# our sentinel tracking depends on so the next `make` correctly
	@# detects "needs rebuild".
	@rm -f $(GNUMACH_BUILD)/gnumach.elf $(GNUMACH_BUILD)/gnumach
	@# MIG, gnumach-headers, and the dist-gnumach kernel are built by
	@# nix; clean the per-target gc-roots so the next build re-pulls
	@# them from the store.
	@rm -f $(FLAKES)/mig/result-* $(FLAKES)/gnumach-headers/result-* $(FLAKES)/gnumach/result-*

clean-dist:
	@# dist/ may hold read-only trees verbatim-copied from /nix/store (e.g.
	@# dist-glibc-nix's full glibc copy); rm can't unlink inside a read-only
	@# dir, so make the tree writable first.
	@chmod -R u+w $(DIST) 2>/dev/null || true
	rm -rf $(DIST)
	@# the dist-*-nix / dist-libgcc store-path stamps live under work/ (they
	@# survive this rm); drop them too, else their "already shipped" record makes
	@# a later `make dist` skip re-populating the freshly-cleaned tree.
	rm -f $(DIST_GLIBC_NIX_STAMP) $(DIST_GNUMACH_NIX_STAMP) $(DIST_HURD_NIX_STAMP) $(DIST_LIBGCC_STAMP)

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
	$(NIX_BUILD) .#sidekick \
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

# ---- mig (no-op when not opted into in-tree; always-on, arch-independent) ----
# Without an in-tree src/mig, mig is provided by the dev shell ($MIG) — so
# `make mig` does nothing here (no dev-shell dispatch).  Run `make src-mig` to
# populate src/mig; that flips MIG_IN_TREE on and the real in-tree mig build
# (defined down in the dev-shell-dispatched rules) takes over.
ifndef MIG_IN_TREE
.PHONY: mig
mig:
	$(call _nix_build,mig,mig-$(_TC_ARCH))
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
glibc:
	$(call _nix_build,glibc,glibc-hurd-$(_TC_ARCH))
work-glibc dist-glibc-tree:
	@echo "$@: opt-in — run 'make src-glibc' for the in-tree glibc (dist-glibc ships the nix glibc)."
endif

# ---- gnumach / hurd (opt-out: realize the nix package; always-on) ----
# Without src/<m> (or <M>_IN_TREE=0), `make gnumach`/`make hurd` build the nix
# kernel/userland package (so it's cached + up to date), matching mig/glibc; the
# dist-*-tree halves stay opt-in.  These live up here (top-level) — NOT in the
# dev-shell-dispatched recipe block below — so they resolve even when the goal is
# filtered out of _BUILD_GOALS (opted-out → no dispatch).  With src present, the
# real in-tree builds (the ifdef <M>_IN_TREE rules below) take over.
ifndef GNUMACH_IN_TREE
.PHONY: gnumach dist-gnumach-tree
gnumach:
	$(call _nix_build,gnumach,gnumach-$(ARCH))
dist-gnumach-tree:
	@echo "$@: opt-in — run 'make src-gnumach' for the in-tree kernel (dist-gnumach ships the nix kernel)."
endif

ifndef HURD_IN_TREE
.PHONY: hurd dist-hurd-tree
hurd:
	$(call _nix_build,hurd,hurd-$(_TC_ARCH))
dist-hurd-tree:
	@echo "$@: opt-in — run 'make src-hurd' for the in-tree userland (dist-hurd ships the nix hurd)."
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
	$(NIX_FLAKE) run $(PROJ)\#abi-report-host-$(_TC_ARCH) -- $(SYSROOT) deep
check-glibc-full:
	+$(MAKE) --no-print-directory work-glibc ARCH=$(ARCH)
	$(NIX_FLAKE) run $(PROJ)\#abi-report-host-$(_TC_ARCH) -- $(SYSROOT) full
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
# branch below, alongside `mach` / `dist-gnumach` — see there.  They are
# _BUILD_GOALS, so the outer make dispatches them through `nix develop -i
# --profile … .#$(ARCH)` like mach; defining the recipe in the inner branch
# (not here) avoids colliding with the `$(_BUILD_GOALS): _dispatch` stub.

# ============================================================
# Categorize goals & decide whether to dispatch through nix.
# ============================================================

# Goals make will pursue (empty cmdline → default to `all`).
_GOALS := $(or $(MAKECMDGOALS),all)

# Fail fast on a forced *_IN_TREE without its source.  The auto-detect only turns
# these on when src/<module> IS present, so on + absent means the user forced it
# (e.g. GLIBC_IN_TREE=1) without `make src-<module>`.  Rather than a confusing
# build error deep in the dispatch, $(error) here — but ONLY when a goal that
# actually needs that source is requested (so `make help GLIBC_IN_TREE=1` is fine).
# This also covers the DEPENDENCY case (e.g. building hurd with MIG_IN_TREE=1 but
# no src/mig): the lists below are DERIVED from the same _DEPS graph that scopes
# the overrides — _NEEDS_<M>_SRC = every goal whose _DEPS contains <m> — so a
# truthy <D>_IN_TREE with a missing dependency clone errors, never silently
# falls back to the pinned source.  Single source of truth, no drift.
_DEP_GOALS := mig gnumach dist-gnumach dist-gnumach-tree dist-gnumach-nix gnumach-headers \
              hurd-headers hurd dist-hurd dist-hurd-tree dist-hurd-nix \
              glibc work-glibc dist-glibc dist-glibc-tree dist-glibc-nix dist all
_needs = $(strip $(foreach g,$(_DEP_GOALS),$(if $(filter $(1),$(_DEPS.$(g))),$(g))))
_NEEDS_GNUMACH_SRC := $(call _needs,gnumach)
_NEEDS_MIG_SRC     := $(call _needs,mig)
_NEEDS_HURD_SRC    := $(call _needs,hurd)
_NEEDS_GLIBC_SRC   := $(call _needs,glibc)
define _need_src
ifeq ($$(wildcard $(2)/.git),)
ifneq ($$(filter $(3),$$(_GOALS)),)
$$(error $(1) is set but its in-tree source is missing at src/$(4) — run `make src-$(4)` first, or set $(1)=0 to use the $(5))
endif
endif
endef
ifdef GLIBC_IN_TREE
$(eval $(call _need_src,GLIBC_IN_TREE,$(GLIBC_SRC),$(_NEEDS_GLIBC_SRC),glibc,nix glibc))
endif
ifdef MIG_IN_TREE
$(eval $(call _need_src,MIG_IN_TREE,$(MIG_SRC),$(_NEEDS_MIG_SRC),mig,dev-shell mig))
endif
ifdef GNUMACH_IN_TREE
$(eval $(call _need_src,GNUMACH_IN_TREE,$(GNUMACH_SRC),$(_NEEDS_GNUMACH_SRC),gnumach,nix gnumach))
endif
ifdef HURD_IN_TREE
$(eval $(call _need_src,HURD_IN_TREE,$(HURD_SRC),$(_NEEDS_HURD_SRC),hurd,nix hurd))
endif

# Goals that need the cross-toolchain (i.e. are NOT served by always-on rules).
# `sidekick` is filtered out here so standalone `make sidekick` invocations
# don't enter the dev shell — its nix build is arch-independent.  When pulled
# in as a prereq of `run` (which DOES dispatch), it still runs inside the
# dev shell as part of the inner-make recipe.
# `mig` is a build goal ONLY when an in-tree src/mig opts in; without it `make
# mig` is a no-op served by the shell's MIG, so it's filtered out (runs its own
# top-level recipe, no dev-shell dispatch) — like srcs/clean.
_BUILD_GOALS := $(filter-out clean clean-dist mrproper help sidekick push-cache srcs pin-srcs show-srcs-pins src-% pin-src-% $(if $(MIG_IN_TREE),,mig) $(if $(GLIBC_IN_TREE),,glibc work-glibc dist-glibc-tree) $(if $(GNUMACH_IN_TREE),,gnumach dist-gnumach-tree) $(if $(HURD_IN_TREE),,hurd dist-hurd-tree) check-glibc check-glibc-full rebaseline-ref,$(_GOALS))

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
# shared dir, so its mtime isn't a reliable signal (see GNUMACH_HDR_STAMP).
_HEADERS_FILES   := $(GNUMACH_HDR_STAMP)
# In-tree mig is a buildable input, so the built binary is a sentinel/prereq.
# The dev-shell (nix) mig is a fixed external input — not a staleness sentinel
# (else its missing-from-the-worktree path would mark mach/hurd forever stale).
ifdef MIG_IN_TREE
_MIG_FILES       := $(_HEADERS_FILES) $(LOCAL_MIG)
else
_MIG_FILES       := $(_HEADERS_FILES)
endif
_GNUMACH_FILES      := $(_MIG_FILES) $(GNUMACH_KERNEL)
_DIST_GNUMACH_FILES := $(DIST_GNUMACH)/boot/gnumach

# `gnumach-headers` installs the Mach public headers into the build-only sysroot
# (what the in-tree mig consumes).  Watch the whole src tree (the install target
# takes every tracked .h/.defs as a prereq) — a header edit anywhere re-installs.
_SENTINEL.gnumach-headers := $(_HEADERS_FILES)
_PRIMARY.gnumach-headers  := $(GNUMACH_HDR_STAMP)
_WATCH.gnumach-headers    := $(GNUMACH_SRC)

# `hurd-headers` installs the Hurd public headers into the build-only sysroot
# (the Hurd half of the in-tree glibc's --with-headers sysroot).  Private; keyed
# on the build-dir STAMP (not the shared include/hurd dir glibc writes into).
_SENTINEL.hurd-headers := $(HURD_HDR_STAMP)
_PRIMARY.hurd-headers  := $(HURD_HDR_STAMP)
_WATCH.hurd-headers    := $(HURD_SRC)

# mig compiles against the installed Mach headers (TARGET_CPPFLAGS=-I$(SYSROOT)/
# include; $(LOCAL_MIG) prereq $(GNUMACH_HDR_STAMP)), so watch src/gnumach too:
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
# $(GNUMACH_HDR_STAMP)/$(HURD_HDR_STAMP) stamps).  Watch all their source trees so
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
_SENTINEL.gnumach      := $(_GNUMACH_FILES)
_PRIMARY.gnumach       := $(GNUMACH_KERNEL)
_WATCH.gnumach         := $(GNUMACH_SRC) $(if $(MIG_IN_TREE),$(MIG_SRC))

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
# the in-tree glibc (via gnumach-headers), which the userland then relinks against.
# (src/hurd is already watched, covering the Hurd-header → glibc edge too.)
_SENTINEL.hurd         := $(_MIG_FILES) $(if $(GLIBC_IN_TREE),$(SYSROOT)/lib/libc.so.0.3) $(HURD_BUILD)/.built
_PRIMARY.hurd          := $(HURD_BUILD)/.built
_WATCH.hurd            := $(HURD_SRC) $(if $(MIG_IN_TREE),$(MIG_SRC)) $(if $(GLIBC_IN_TREE),$(GLIBC_SRC) $(GNUMACH_SRC))

# `all` = mach + hurd — a COMPOSITE goal: stale iff a component is stale
# (see _stale's _COMPOSE branch).  We do NOT flatten the components'
# primaries+watches into one set: that would compare the OLDEST primary
# (e.g. the gnumach kernel) against EVERY watch (incl. src/hurd), so a tree
# with hurd freshly rebuilt but gnumach untouched would falsely dispatch.
_COMPOSE.all           := gnumach hurd

# `dist-gnumach` / `dist-hurd` dispatch in-tree-vs-nix exactly like `dist-glibc`
# (see _COMPOSE.dist-glibc below): staleness recurses into the ACTIVE half, which
# carries its own sentinel.  The in-tree half watches src/ (+ src/mig stubs; the
# glibc opt-in adds src/glibc+gnumach for the userland); the nix half is keyed on
# its store-path stamp and watches only the flake (never src/, so a non-opt-in
# build never expects a clone).
_COMPOSE.dist-gnumach       := $(if $(GNUMACH_IN_TREE),dist-gnumach-tree,dist-gnumach-nix)
_SENTINEL.dist-gnumach-tree := $(DIST_GNUMACH)/boot/gnumach
_PRIMARY.dist-gnumach-tree  := $(DIST_GNUMACH)/boot/gnumach
_WATCH.dist-gnumach-tree    := $(GNUMACH_SRC) $(if $(MIG_IN_TREE),$(MIG_SRC))
_SENTINEL.dist-gnumach-nix  := $(DIST_GNUMACH_NIX_STAMP)
_PRIMARY.dist-gnumach-nix   := $(DIST_GNUMACH_NIX_STAMP)
_WATCH.dist-gnumach-nix     := flakes/gnumach

_COMPOSE.dist-hurd       := $(if $(HURD_IN_TREE),dist-hurd-tree,dist-hurd-nix)
_SENTINEL.dist-hurd-tree := $(DIST_HURD)/hurd/ext2fs
_PRIMARY.dist-hurd-tree  := $(DIST_HURD)/hurd/ext2fs
_WATCH.dist-hurd-tree    := $(HURD_SRC) $(if $(MIG_IN_TREE),$(MIG_SRC)) $(if $(GLIBC_IN_TREE),$(GLIBC_SRC) $(GNUMACH_SRC))
_SENTINEL.dist-hurd-nix  := $(DIST_HURD_NIX_STAMP)
_PRIMARY.dist-hurd-nix   := $(DIST_HURD_NIX_STAMP)
_WATCH.dist-hurd-nix     := flakes/hurd

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

# `dist-tzdata` — ship the IANA tz db (from the pinned nixpkgs tzdata).  Same
# store-path-stamp scheme.  No _WATCH dir: tzdata's only input is the nixpkgs pin
# (flake.lock, the recipe's prereq), and the store-path stamp makes a dispatch a
# no-op when unchanged — so a MISSING sentinel is the outer gate's only trigger
# (the inner recipe's `: flake.lock` prereq + the stamp catch a pin bump once any
# dist component dispatches).
_SENTINEL.dist-tzdata := $(DIST_TZDATA_STAMP)
_PRIMARY.dist-tzdata  := $(DIST_TZDATA_STAMP)

# `dist-glibc` — the PUBLIC glibc-shipment goal; a thin composite that resolves
# to the in-tree install (dist-glibc-tree, opt-in) or the nix deployable glibc
# (dist-glibc-nix) — exactly one, chosen by GLIBC_IN_TREE.  Nesting it as a
# _COMPOSE lets the staleness recursion reach the chosen leaf's sentinel.
_COMPOSE.dist-glibc    := $(if $(GLIBC_IN_TREE),dist-glibc-tree,dist-glibc-nix)

# `dist` = dist-gnumach + dist-hurd + dist-glibc — COMPOSITE (same rationale as
# `all`): stale iff a component is stale, evaluated per component so the
# dist-gnumach primary is only ever compared against src/gnumach, the dist-hurd
# primary only against src/hurd.  (dist-gnumach's `make install` lays the Mach
# headers into $(DIST) already, so there is no separate headers step.)
# dist-glibc is itself a composite (the in-tree or nix glibc); dist-libgcc adds
# the gcc runtime (always from nix) — so `make dist` always lands a runnable
# /-rooted glibc + gcc runtime.
_COMPOSE.dist          := dist-gnumach dist-hurd dist-glibc dist-libgcc dist-tzdata

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
# between Makefile invocations.  One entry per ARCH (and variant — see
# $(_VARIANT)); switching targets/hosts just adds another sibling without
# invalidating the others, and the gcroot profile doesn't flip-flop cross-host
# on a shared checkout.
_FLAKE_PROFILE := .gcroots/$(_VARIANT)$(ARCH)

_RUN_PASSTHROUGH := \
  SCENARIO=$(SCENARIO) \
  RUN_VANILLA=$(RUN_VANILLA) \
  RUN_ACCEL=$(RUN_ACCEL) \
  RUN_KEEP_OVERLAY=$(RUN_KEEP_OVERLAY) \
  RUN_REFRESH=$(RUN_REFRESH) \
  RUN_ARGS=$(subst $(_SP),\$(_SP),$(RUN_ARGS))

# Output / build-location overrides.  Same problem as above: the inner make runs
# under `nix develop -i` (clean env) with MAKEOVERRIDES dropped, so a
# `make dist DIST=/foo` or `make glibc GLIBC_BUILD=/bar` would silently revert to
# the inner default.  Forward the RESOLVED values (plain paths, no embedded
# spaces, so none of the MAKEOVERRIDES escaping hazards apply).  When the user
# didn't override, these equal the inner `?=` defaults ($(DIST_ROOT)/$(ARCH) etc.,
# computed identically from the same $(PROJ)+$(ARCH) on both sides), so forwarding
# is a no-op — and when they did, the override now survives the dispatch.  The
# whole DIST family is listed so an individual DIST_GNUMACH/HURD/GLIBC override also
# carries through, not just a top-level DIST.
_DIST_PASSTHROUGH := \
  DIST_ROOT=$(DIST_ROOT) \
  DIST=$(DIST) \
  DIST_GNUMACH=$(DIST_GNUMACH) \
  DIST_HURD=$(DIST_HURD) \
  DIST_GLIBC=$(DIST_GLIBC) \
  GLIBC_BUILD=$(GLIBC_BUILD) \
  ALT_BUILD=$(ALT_BUILD) \
  _HOST_SYSTEM=$(_HOST_SYSTEM) \
  GLIBC_IN_TREE=$(GLIBC_IN_TREE) \
  MIG_IN_TREE=$(MIG_IN_TREE) \
  GNUMACH_IN_TREE=$(GNUMACH_IN_TREE) \
  HURD_IN_TREE=$(HURD_IN_TREE)
# _HOST_SYSTEM (resolved) + ALT_BUILD: forward the variant infix's inputs so the
# inner make computes the SAME work/ paths (DIST is already forwarded resolved
# above).  Forwarding the RESOLVED _HOST_SYSTEM means the inner needn't re-run
# `nix eval` and can't disagree with the outer.  The four *_IN_TREE flags: forward
# the resolved choice so an explicit force on/off (e.g. GLIBC_IN_TREE=0 — use the
# nix glibc even with src/glibc checked out) survives the dispatch, else the inner
# re-detects src/{glibc,mig,gnumach,hurd} and flips it back.

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
	    $(_RUN_PASSTHROUGH) $(_DIST_PASSTHROUGH) $(_BUILD_GOALS)

$(_BUILD_GOALS): _dispatch
	@:

# No source auto-bootstrap: all four modules (mig, glibc, gnumach, hurd) are
# opt-in in-tree.  An absent src/<m> means "use the nix package" — never an
# auto-clone.  Forcing <M>_IN_TREE=1 without the source fails fast via the
# _need_src guard (with a `make src-<m>` hint); `make src-<m>` clones on demand.
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

.PHONY: all dist gnumach-headers hurd-headers mig glibc work-glibc gnumach dist-gnumach dist-glibc \
        check check-gnumach run run-help

# Explicit default — `help` (defined above) would otherwise win the
# "first non-dot target" race.
.DEFAULT_GOAL := all

# ---- Default & top-level groupings ----
# `all` and `dist` are NOT aliases: they list real dependencies we'll
# grow over time (e.g. once Hurd userland builds, add `hurd` /
# `dist-hurd` here).
all: gnumach hurd

# Lockstep with _COMPOSE.dist (above): the COMPONENTS (dist-glibc + dist-libgcc +
# dist-tzdata) must match both lists or the staleness gate and the recipe disagree
# (silent mis-ship).  dist-normalize is NOT a component (it ships nothing) — it's a
# post-step appended ONLY here; under `.NOTPARALLEL: dist` the prereqs run serially
# left-to-right, so it runs LAST, after every component has populated $(DIST).
dist: dist-gnumach dist-hurd dist-glibc dist-libgcc dist-tzdata dist-normalize

# Serialize dist's components under `make -j` — they contend on two shared
# resources and otherwise corrupt each other:
#   - the glibc build dir: work-glibc (pulled in by dist-hurd, install ->
#     $(SYSROOT)) and dist-glibc-tree (install -> $(DIST_GLIBC)) both run
#     `make install` in the SAME $(GLIBC_BUILDDIR); glibc regenerates
#     intermediates (build/mach/stubs, stubsT) IN the build dir, so two
#     concurrent installs race -> "mach/stubs Error 1".
#   - the dist tree: dist-glibc(-nix)'s `chmod -R u+w $(DIST)` walks the whole
#     tree while dist-gnumach/dist-hurd/dist-libgcc are writing into it.
# `.NOTPARALLEL: dist` serializes ONLY dist's immediate prerequisites; each
# component still builds internally with -j, and the individual `dist-*` targets
# are unaffected (full parallelism when built on their own).  This is why
# `make dist` failed under -j while each `dist-*` run alone succeeded.  Needs
# GNU make 4.4 (the dispatched inner make); the outer make never parses this
# rule (it lives in the inner-only build-rules branch).
.NOTPARALLEL: dist

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
	$(call _bake_version,gnumach,gnumach-$(ARCH),$(GNUMACH_SRC))

# ---- gnumach-headers (private: populates the build sysroot for in-tree mig) ----
# Install the public Mach headers into the build-only sysroot ($(SYSROOT)),
# in-tree via gnumach's `make install-data` into a staging prefix + `cp -rs` farm
# (see the recipe below for why the symlink farm matters).  This is the in-tree
# mig's stable header dependency — see the SYSROOT comment for why it must NOT be
# the dist tree.  Mirrors the flakes/gnumach-headers derivation: a separate build
# dir configured with a STUB USER_MIG=/bin/true so it can run BEFORE mig exists
# (mig needs these headers; install-data compiles nothing and never invokes
# mig, so the stub satisfies configure's AC_CHECK_PROG).  Headers-only — the
# kernel itself is never built here.
#
# Not in `make help`: it's an internal build step (mig/glibc depend on the
# $(GNUMACH_HDR_STAMP) stamp, so it's built on demand), kept as a target only for
# manual/debug use.  The stamp (not $(SYSROOT)/include/mach) is the sentinel:
# glibc later installs its own mach/* headers into that shared dir, so the dir's
# mtime is NOT a reliable "Mach headers installed" signal — see GNUMACH_HDR_STAMP.
gnumach-headers: $(GNUMACH_HDR_STAMP)

# No --enable-platform here (unlike the kernel build): this sysroot is shared
# across a CPU's xen/non-xen variants ($(_TC_ARCH)), and the installed PUBLIC
# Mach headers are byte-identical regardless of platform (the flag selects
# kernel-internal/device code, not the userland RPC ABI).  Omitting it keeps the
# shared headers deterministic no matter which variant's dev shell builds first.
ifdef GNUMACH_IN_TREE
$(GNUMACH_HDR_CONFIGURED): $(GNUMACH_SRC)/configure
	mkdir -p $(GNUMACH_HDR_BUILD)
	cd $(GNUMACH_HDR_BUILD) && \
	  USER_MIG=/bin/true \
	  $(GNUMACH_SRC)/configure --host=$(GNUMACH_HOST) --prefix=$(GNUMACH_HDR_STAGE)

# $(_MACH_HDR_SRC) (every tracked .h/.defs in the tree) is a real prereq, so
# editing any Mach header re-runs install-data and re-touches the stamp — which
# the in-tree mig + glibc depend on.  install-data is cheap + idempotent
# (merges); a .c edit never lands here (not a .h/.defs).
#
# install-data into a STAGING prefix, then symlink-farm into $(SYSROOT) with
# `cp -rs` — MIRRORING glibc.nix's `cp -rs ${gnumach-headers}/include/.`.  gnumach
# ships mach/machine -> i386 (symlink); when glibc compiles against the sysroot gcc
# realpath-resolves that link.  With REAL files in the sysroot the realpath is the
# short in-sysroot mach/i386, so gcc bakes `mach/i386` into libc.so's DWARF; with
# `cp -rs` symlinks (to the longer staging path, exactly as nix's point to the
# store) gcc keeps the logical `mach/machine`.  So this makes the in-tree glibc
# bake the SAME mach/machine paths as the nix glibc — the last cross-build diff.
# `cp -rs` preserves the machine->i386 symlink and turns the regular headers into
# symlinks to the stage; -f makes it idempotent (replaces a prior run's entries,
# and the first run's old real files).  glibc's own mach/* wrapper headers, written
# into the same dir later, are left untouched (distinct filenames).
$(GNUMACH_HDR_STAMP): $(GNUMACH_HDR_CONFIGURED) $(_MACH_HDR_SRC)
	rm -rf $(GNUMACH_HDR_STAGE)
	cd $(GNUMACH_HDR_BUILD) && $(MAKE) install-data
	$(call _farm_headers,$(GNUMACH_HDR_STAGE))
	@touch $(GNUMACH_HDR_STAMP)
else
# Opted out of the in-tree kernel: populate the build sysroot from the NIX
# gnumach-headers package (same cp -rs farm) so an in-tree glibc/mig still finds
# the Mach headers, and the in-tree glibc bakes the same header paths it would
# against the in-tree stage.
$(GNUMACH_HDR_STAMP): packages.nix flake.lock flakes/gnumach-headers/default.nix
	@mkdir -p $(dir $(GNUMACH_HDR_STAMP))
	@echo "  GNUMACH-HEADERS-NIX  resolving nix gnumach-headers-$(ARCH)…"
	@set -e; \
	pkg=$$($(NIX_BUILD) $(call _overrides,gnumach-headers) $(PROJ)\#gnumach-headers-$(ARCH) --no-link --print-out-paths); \
	$(call _farm_nix_headers,$$pkg,$(GNUMACH_HDR_STAGE))
	@touch $(GNUMACH_HDR_STAMP)
endif

# ---- hurd-headers (private: the Hurd half of the in-tree glibc's sysroot) ----
# Install the Hurd public headers into the build-only sysroot via hurd's
# `make install-headers` — a pure file-copy walk (src/hurd/Makefile), so no
# cross compile happens; mig must be discoverable for configure's
# AC_CHECK_TOOL but isn't invoked.  Sibling to gnumach-headers.  Not in `make help`
# (internal — glibc depends on the $(HURD_HDR_STAMP) stamp, not the shared
# $(SYSROOT)/include/hurd dir that glibc itself writes its hurd/* headers into).
hurd-headers: $(HURD_HDR_STAMP)

ifdef HURD_IN_TREE
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
else
# Opted out of the in-tree userland: populate the build sysroot from the NIX
# hurd-headers package (cp -rs farm) so an in-tree glibc still finds the Hurd
# headers.  Real-file (in-tree install-headers) vs cp -rs symlink is proven
# equivalent for glibc's DWARF (gcc keeps the logical sysroot path — no shorter
# symlink target like mach/machine here).
$(HURD_HDR_STAMP): packages.nix flake.lock flakes/hurd-headers/default.nix
	@mkdir -p $(dir $(HURD_HDR_STAMP))
	@echo "  HURD-HEADERS-NIX  resolving nix hurd-headers-$(_TC_ARCH)…"
	@set -e; \
	pkg=$$($(NIX_BUILD) $(call _overrides,hurd-headers) $(PROJ)\#hurd-headers-$(_TC_ARCH) --no-link --print-out-paths); \
	$(call _farm_nix_headers,$$pkg,$(HURD_HDR_STAGE))
	@touch $(HURD_HDR_STAMP)
endif

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
$(LOCAL_MIG): $(MIG_SRC)/configure $(GNUMACH_HDR_STAMP) $(MIG_SRC_FILES)
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
	$(call _bake_version,mig,mig-$(_TC_ARCH),$(MIG_SRC))
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
# touched only by gnumach-headers/hurd-headers, so a real Mach/Hurd header edit
# still re-triggers glibc, but glibc's own install does not.
$(GLIBC_CONFIGURED): $(GLIBC_SRC)/configure $(GNUMACH_HDR_STAMP) $(HURD_HDR_STAMP)
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
	  echo "    make glibc GLIBC_BUILD=/Volumes/<case-sensitive>/glibc-$(_TC_ARCH)" >&2; \
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
	    --localstatedir=/var \
	    --bindir=/bin \
	    --sbindir=/sbin \
	    --libexecdir=/libexec \
	    --includedir=/include \
	    --with-headers=$(SYSROOT)/include \
	    --with-binutils=$(BINUTILS_BIN) \
	    --enable-add-ons=libpthread \
	    --enable-obsolete-rpc \
	    --disable-profile --disable-nscd --disable-werror --disable-multilib \
	    libc_cv_ctors_header=yes \
	    libc_cv_slibdir=/lib libc_cv_rtlddir=/lib \
	    libc_cv_complocaledir=/lib/locale libc_cv_sysconfdir=/etc \
	    libc_cv_localstatedir=/var libc_cv_rootsbindir=/sbin
	@# --prefix=/ leaves slibdir/rtlddir defaulting to $(exec_prefix)/lib = //lib
	@# (DOUBLE slash, baked into PT_INTERP and the libc.so GROUP; a leading // is
	@# POSIX implementation-defined).  Pin them to single-slash /lib via the
	@# libc_cv_slibdir/libc_cv_rtlddir configure cache vars (AC_SUBST'd straight
	@# into config.make — same mechanism as libc_cv_ctors_header) plus --libdir;
	@# newer glibc derives the lib dirs from these, so this is more robust than a
	@# build-dir configparms (which only overrides by include-order).
	@# The remaining dirs all default to $(prefix)/<dir> = //<dir> under --prefix=/
	@# (double slash baked into generated scripts/paths — e.g. xtrace's
	@# pcprofiledump='//bin/...').  So pin EVERY install dir to a single-slash root,
	@# matching glibc.nix's deployable set EXACTLY (--bindir/--sbindir/--libexecdir/
	@# --localstatedir/--includedir + the libc_cv_* cache vars), so the in-tree and
	@# nix glibc bake byte-identical paths everywhere.  (NB: this dir set is now
	@# duplicated with glibc.nix — a candidate to define once in nix + pass through
	@# the dev-shell env, like the GLIBC_CANON_* roots.)

# `make glibc` COMPILES only — no install (work-glibc/dist-glibc install).
# Hardening off (read at runtime by the wrapper; see the configure rule).
# NIX_CFLAGS_COMPILE adds the determinism -ffile-prefix-maps that make the in-tree
# glibc bake the SAME DWARF paths as the nix glibc (glibc.nix): the build dir ->
# /glibc-build, src -> /glibc-src, sysroot -> /glibc-sysroot (canon roots from the
# dev-shell, build-flags.nix).  PLUS a "/."-collapse for glibc's Machrules
# server-stub vpath:
#   vpath %_server.c $(addprefix $(objpfx),$(sort $(dir $(server-interfaces))))
# $(dir faultexc) = "./" (dir-less interface) puts $(objpfx)./ on the vpath; a stub
# resolving through it bakes "$(GLIBC_BUILDDIR)/hurd/./…" into DWARF DW_AT_name
# (which path wins is build-order-dependent -> libhurduser diverges).  The
# "$(GLIBC_BUILDDIR)/hurd/." map collapses the "/.".  ORDER MATTERS: gcc's
# -ffile-prefix-map is LAST-match-wins, so the specific hurd/. map MUST come AFTER
# the general $(GLIBC_BUILDDIR) map — otherwise the general one wins and keeps "./".
$(GLIBC_BUILT): $(MIG) $(GLIBC_CONFIGURED) $(GLIBC_SRC_FILES)
	$(if $(GLIBC_DIRTY),@echo "  WARNING         in-tree glibc chain is DIRTY (uncommitted src) — not for release; flagged internally + cascaded to hurd's version")
	cd $(GLIBC_BUILDDIR) && NIX_HARDENING_ENABLE= \
	  NIX_CFLAGS_COMPILE="$$NIX_CFLAGS_COMPILE -ffile-prefix-map=$(GLIBC_BUILDDIR)=$(GLIBC_CANON_BUILD) -ffile-prefix-map=$(GLIBC_SRC)=$(GLIBC_CANON_SRC) -ffile-prefix-map=$(SYSROOT)=$(GLIBC_CANON_SYSROOT) -ffile-prefix-map=$(GLIBC_BUILDDIR)/hurd/.=$(GLIBC_CANON_BUILD)/hurd" \
	  $(MAKE)
	@touch $(GLIBC_BUILT)

# ---- work-glibc (private: install glibc into the build sysroot) ----
# Install the built glibc into $(SYSROOT) (work/sysroot) so the in-tree hurd
# build links against it — the build counterpart to dist-glibc, beside the
# mach+hurd headers that gnumach-headers/hurd-headers already put there.  Staged via
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
	@$(call dist-stamp,$(EPOCH_GLIBC))
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
#
# share/info/dir: the nix glibc ships its OWN standalone dir, and a verbatim cp -a
# would lay it over the dir that dist-gnumach/dist-hurd already merged into — clobbering
# their entries and bringing glibc's build's default header (the in-tree
# dist-glibc-tree never does this: its `make install` install-info MERGES libc into
# the accumulated dir).  So mirror `make install` here: stash the accumulated dir
# across the copy, restore it (discarding glibc's standalone one), then install-info
# the glibc's libc.info into it — keeping the "each package merges its own info"
# model + the texinfo-det.nix total-order sort, so in-tree and nix dirs match.
.PHONY: dist-glibc-nix
dist-glibc-nix: $(DIST_GLIBC_NIX_STAMP)

$(DIST_GLIBC_NIX_STAMP): packages.nix flake.lock flakes/cross-toolchain/glibc.nix flakes/cross-toolchain/toolchain.nix
	@mkdir -p $(DIST_GLIBC)/lib $(dir $(DIST_GLIBC_NIX_STAMP))
	@echo "  DIST-GLIBC-NIX  resolving nix glibc-hurd-$(_TC_ARCH)…"
	@set -e; \
	glibc=$$($(NIX_BUILD) $(call _overrides,dist-glibc-nix) $(PROJ)\#glibc-hurd-$(_TC_ARCH) --no-link --print-out-paths); \
	if [ "$$(cat $(DIST_GLIBC_NIX_STAMP) 2>/dev/null)" = "$$glibc" ] && [ -e $(DIST_GLIBC)/lib/libc.so.0.3 ]; then \
	  echo "  unchanged ($$(basename $$glibc)) — skip copy"; \
	else \
	  echo "  copying $$glibc -> $(DIST_GLIBC) (full glibc tree)"; \
	  chmod -R u+w $(DIST_GLIBC) 2>/dev/null || true; \
	  acc=$$(mktemp); cp -a $(DIST_GLIBC)/share/info/dir "$$acc" 2>/dev/null || acc=; \
	  cp -a $$glibc/. $(DIST_GLIBC); \
	  chmod -R u+w $(DIST_GLIBC) 2>/dev/null || true; \
	  if [ -n "$$acc" ]; then cp -a "$$acc" $(DIST_GLIBC)/share/info/dir; rm -f "$$acc"; else rm -f $(DIST_GLIBC)/share/info/dir; fi; \
	  [ -e $(DIST_GLIBC)/share/info/libc.info ] && install-info --quiet --info-dir=$(DIST_GLIBC)/share/info $(DIST_GLIBC)/share/info/libc.info || true; \
	  printf '%s' "$$glibc" > $(DIST_GLIBC_NIX_STAMP); \
	fi
	@ls $(DIST_GLIBC)/lib/libc.so.0.3 >/dev/null || { echo "ERROR: libc.so.0.3 missing"; exit 1; }
	@grep -q libmachuser $(DIST_GLIBC)/lib/libc.so || { echo "ERROR: libc.so GROUP not augmented"; exit 1; }
	@$(call dist-stamp,$(EPOCH_GLIBC))

# ---- dist-libgcc ----
# Ship the gcc TARGET RUNTIME + its docs into the dist tree — ALWAYS from the nix
# cross-gcc (cross-toolchain), independent of the glibc choice (these are gcc
# artefacts, not glibc).  Copies the WHOLE gcc lib output (i686-gnu/lib) in its
# native symlink layout: the full runtime set (libgcc_s, libstdc++, libatomic,
# libitm, libquadmath, libssp) + libstdc++*-gdb.py (the gdb pretty-printer hook —
# kept; toolchain.nix's postFixup rewrites its baked store paths to the deployed
# /lib + /share/gcc-<ver>/python, so it's cross-host pure and target-correct).
# Also installs
# the gcc info manuals (gcc/cpp/gccint/cppinternals/gccinstall + libquadmath/libitm
# for two of the runtime libs) into share/info via install-info, and the gcc man
# pages into share/man.  All three nix outputs (^lib/^info/^man) are byte-identical
# cross-host (verified), so a plain copy + the now-deterministic install-info
# (texinfo total-order patch) keep the dist reproducible — no rpath scrub / patchelf
# (the libs carry NO RUNPATH: toolchain.nix drops both the nixpkgs store rpath and
# the /lib one, matching Debian GNU/Hurd).  glibc dlopen()s libgcc_s for
# backtrace()/Hurd assert_backtrace (a DT_NEEDED scan misses it), so it MUST be
# present.  Store-path-stamped (lib+info+man) under work/ so an unchanged gcc skips
# the copy.  Resolved via $(_TC_ARCH) (xen suffix stripped): a xen variant reuses
# its CPU sibling's final gcc (same `<cpu>-gnu` ABI).
.PHONY: dist-libgcc
dist-libgcc: $(DIST_LIBGCC_STAMP)

$(DIST_LIBGCC_STAMP): flake.lock flakes/cross-toolchain/toolchain.nix
	@mkdir -p $(DIST)/lib $(DIST)/share/info $(DIST)/share/man $(dir $(DIST_LIBGCC_STAMP))
	@echo "  DIST-LIBGCC  resolving nix cross-gcc-$(_TC_ARCH) {lib,info,man}…"
	@set -e; \
	gcclib=$$($(NIX_BUILD) $(PROJ)\#cross-gcc-$(_TC_ARCH)^lib  --no-link --print-out-paths); \
	gccinfo=$$($(NIX_BUILD) $(PROJ)\#cross-gcc-$(_TC_ARCH)^info --no-link --print-out-paths); \
	gccman=$$($(NIX_BUILD) $(PROJ)\#cross-gcc-$(_TC_ARCH)^man  --no-link --print-out-paths); \
	stamp="$$gcclib $$gccinfo $$gccman"; \
	if [ "$$(cat $(DIST_LIBGCC_STAMP) 2>/dev/null)" = "$$stamp" ] && [ -e $(DIST)/lib/libgcc_s.so.1 ]; then \
	  echo "  unchanged — skip copy"; \
	else \
	  rtdir=$$(dirname $$(find $$gcclib -name libgcc_s.so.1 | head -1)); \
	  echo "  copying whole gcc runtime ($$(ls $$rtdir | grep -c '\.so') libs) -> $(DIST)/lib"; \
	  chmod -R u+w $(DIST)/lib 2>/dev/null || true; \
	  cp -a $$rtdir/. $(DIST)/lib/; \
	  echo "  copying gcc man -> $(DIST)/share/man"; \
	  cp -a $$gccman/share/man/. $(DIST)/share/man/; \
	  echo "  installing gcc info -> $(DIST)/share/info"; \
	  cp -L $$gccinfo/share/info/*.info* $(DIST)/share/info/; \
	  chmod -R u+w $(DIST)/share/info; \
	  for inf in $$gccinfo/share/info/*.info; do \
	    install-info --quiet --info-dir=$(DIST)/share/info "$(DIST)/share/info/$$(basename $$inf)" || true; \
	  done; \
	  printf '%s' "$$stamp" > $(DIST_LIBGCC_STAMP); \
	fi
	@ls $(DIST)/lib/libgcc_s.so.1  >/dev/null || { echo "ERROR: libgcc_s.so.1 missing";  exit 1; }
	@ls $(DIST)/lib/libstdc++.so.6 >/dev/null || { echo "ERROR: libstdc++.so.6 missing"; exit 1; }
	@ls $(DIST)/lib/libatomic.so.1 >/dev/null || { echo "ERROR: libatomic.so.1 missing"; exit 1; }
	@$(call dist-stamp,$(EPOCH_NIXPKGS))

# ---- dist-tzdata ----
# Ship the IANA timezone database so glibc's TZ/localtime works (without it the
# target has only UTC).  Copied from the pinned nixpkgs `tzdata` (re-exported as
# the flake package `tzdata`) — arch-independent, zic-compiled data, verified
# byte-identical cross-host (so one package serves every target, no $(_TC_ARCH)
# keying).  Lands in /share/zoneinfo, which is glibc's compiled TZDIR
# ($(datadir)/zoneinfo under our --datarootdir=/share deploy prefix).  Also drops
# a default /etc/localtime -> /share/zoneinfo/UTC (admin-overridable).  Store-path
# -stamped so an unchanged tzdata skips the copy.
.PHONY: dist-tzdata
dist-tzdata: $(DIST_TZDATA_STAMP)

$(DIST_TZDATA_STAMP): flake.lock
	@mkdir -p $(DIST)/share $(DIST)/etc $(dir $(DIST_TZDATA_STAMP))
	@echo "  DIST-TZDATA  resolving nix tzdata…"
	@set -e; \
	tz=$$($(NIX_BUILD) $(PROJ)\#tzdata^out --no-link --print-out-paths); \
	if [ "$$(cat $(DIST_TZDATA_STAMP) 2>/dev/null)" = "$$tz" ] && [ -e $(DIST)/share/zoneinfo/UTC ]; then \
	  echo "  unchanged ($$(basename $$tz)) — skip copy"; \
	else \
	  echo "  copying zoneinfo ($$(find $$tz/share/zoneinfo -type f | grep -c .) files) -> $(DIST)/share/zoneinfo"; \
	  chmod -R u+w $(DIST)/share/zoneinfo 2>/dev/null || true; \
	  rm -rf $(DIST)/share/zoneinfo; \
	  cp -a $$tz/share/zoneinfo $(DIST)/share/zoneinfo; \
	  ln -sfn /share/zoneinfo/UTC $(DIST)/etc/localtime; \
	  printf '%s' "$$tz" > $(DIST_TZDATA_STAMP); \
	fi
	@ls $(DIST)/share/zoneinfo/UTC >/dev/null || { echo "ERROR: zoneinfo/UTC missing"; exit 1; }
	@$(call dist-stamp,$(EPOCH_NIXPKGS))

# ---- dist-normalize ----
# Final, DRY filesystem-hygiene pass over the WHOLE assembled dist (perms here;
# per-component MTIMES are stamped by each dist-* recipe's $(call dist-stamp,…)).
# Nix store outputs are canonicalised to read-only + mtime=1 (unavoidable — nix
# forces it in canonicalisePathMetaData) and `cp -a` clones that into $(DIST):
#   - perms: owner-write so the deployed tree is editable (libs/bins stay 0755,
#     data 0644 — `chmod -R u+w` only adds the missing u+w to the store's r-x).
#   - share/info/dir: the merged Info index has no single source (libc + hurd +
#     gcc all install-info into it) — date it from glibc-src (libc.info dominates).
#   - straggler: any file a component's dist-stamp missed (still at the nix epoch)
#     -> the nixpkgs snapshot date, belt-and-braces.
# (The per-recipe chmods that remain are FUNCTIONAL — they make a prior tree
# writable so a re-copy/install can overwrite, and let install-info write `dir`.)
# Runs LAST via `.NOTPARALLEL: dist`.
.PHONY: dist-normalize
dist-normalize:
	@[ -d $(DIST) ] || { echo "  DIST-NORMALIZE  no $(DIST) — skip"; exit 0; }
	@echo "  DIST-NORMALIZE  owner-write perms + finalize mtimes over $(DIST)"
	@chmod -R u+w $(DIST)
	@[ -e $(DIST)/share/info/dir ] && [ -n "$(EPOCH_GLIBC)" ] && touch -d @$(EPOCH_GLIBC) $(DIST)/share/info/dir || true
	@[ -n "$(EPOCH_NIXPKGS)" ] && find $(DIST) \( -type f -o -type l \) ! -newermt @1 -exec touch -h -d @$(EPOCH_NIXPKGS) {} + || true

# ---- gnumach (opt-in in-tree; else the nix kernel) ----
# In-tree kernel build under $(GNUMACH_BUILD), using $(MIG) — the effective
# mig: the dev-shell's nix mig, or the in-tree build when src/mig opts in.
# USER_MIG/MIG point at it explicitly so gnumach's AC_CHECK_TOOL doesn't have
# to discover it via PATH.  Incremental compile — re-running `make gnumach` after
# editing src/gnumach rebuilds only the changed translation units.  Without
# src/gnumach (or GNUMACH_IN_TREE=0), `make gnumach` realizes the nix kernel.
ifdef GNUMACH_IN_TREE
gnumach: $(GNUMACH_KERNEL)

$(GNUMACH_CONFIGURED): $(GNUMACH_SRC)/configure $(MIG)
	mkdir -p $(GNUMACH_BUILD)
	cd $(GNUMACH_BUILD) && \
	  USER_MIG=$(MIG) MIG=$(MIG) \
	  CFLAGS="-g -O2 $(call _macro_prefix_map,$(GNUMACH_SRC))" \
	  $(GNUMACH_SRC)/configure --host=$(GNUMACH_HOST) --prefix=$(DIST_GNUMACH) \
	    $(if $(GNUMACH_PLATFORM),--enable-platform=$(GNUMACH_PLATFORM))

# Src prereqs via $(_tracked_files) — see its defining comment above.
GNUMACH_SRC_FILES := $(call _tracked_files,$(GNUMACH_SRC))
# Map the build dir + source to canonicals (GNUMACH_CANON_*, build-flags.nix) so
# neither the MULTI_HOST_BUILDS/ALT_BUILD path infix nor the in-tree-vs-nix path
# delta leaks into DWARF — gnumach/default.nix maps to the SAME names → in-tree==nix.
# Pin mach.info's "last updated …" to the gnumach source's commit date so it's
# deterministic AND matches the nix build (which touches the same via
# srcInput.lastModified).  This gnumach's mdate-sh (and even automake 1.18's)
# IGNORES SOURCE_DATE_EPOCH despite its header comment — it reads the .texi FILE
# MTIME — so we set that mtime directly (the in-tree clone is at the locked rev,
# same commit/epoch via `git log %ct`; mtime only, git-invisible, no content
# touch).  VERSION=<rich> overrides automake's $(VERSION) — which it hardcodes
# into the generated Makefile from the (plain) version.m4, out of reach of the
# configure PACKAGE_VERSION sed _bake_version does — so mach.info's "@set
# VERSION/EDITION" is the rich composed version too (a command-line make var
# wins; no tracked version.m4 touch).  Same value + dirty cascade _bake_version
# stamps into config.h for the binaries.
$(GNUMACH_KERNEL): $(MIG) $(GNUMACH_CONFIGURED) $(GNUMACH_SRC_FILES)
	@ver=$$($(NIX_FLAKE) eval --raw $(call _overrides,gnumach) $(PROJ)\#gnumach-$(ARCH).version 2>/dev/null); \
	[ -n "$$ver" ] || { echo "ERROR: cannot resolve nix gnumach-$(ARCH).version for VERSION= (mach.info)"; exit 1; }; \
	$(if $(call _chain_dirty,gnumach),ver=$$(printf %s "$$ver" | sed -E 's/(-g[0-9a-f]+)(\+|$$)/\1-dirty\2/');) \
	sde=$$(git -C $(GNUMACH_SRC) log -1 --format=%ct 2>/dev/null); \
	[ -n "$$sde" ] && touch -d @$$sde $(GNUMACH_SRC)/doc/*.texi; \
	cd $(GNUMACH_BUILD) && \
	  NIX_CFLAGS_COMPILE="$$NIX_CFLAGS_COMPILE -ffile-prefix-map=$(GNUMACH_BUILD)=$(GNUMACH_CANON_BUILD) -ffile-prefix-map=$(GNUMACH_SRC)=$(GNUMACH_CANON_BUILD)" \
	  NIX_HARDENING_ENABLE= \
	  $(MAKE) VERSION="$$ver"

# In-tree install: `make install` the work/ build into $(DIST_GNUMACH) (configured
# --prefix=$(DIST_GNUMACH)); kernel under boot/ + share/ docs (mach.info, msgids).
# gnumach's install is plain (no setuid/-o root), so no fakeroot needed.
dist-gnumach-tree: $(DIST_GNUMACH)/boot/gnumach

$(DIST_GNUMACH)/boot/gnumach: $(GNUMACH_KERNEL)
	cd $(GNUMACH_BUILD) && $(MAKE) install prefix=$(DIST_GNUMACH)
	@$(call dist-stamp,$(EPOCH_GNUMACH))
endif  # GNUMACH_IN_TREE — the opted-out `gnumach`/`dist-gnumach-tree` stubs are top-level (above)

# ---- dist-gnumach ----
# Public target: dispatch in-tree-vs-nix like dist-glibc.  In-tree → install the
# work/ build; else → copy the nix kernel package.
.PHONY: dist-gnumach dist-gnumach-tree dist-gnumach-nix
dist-gnumach: $(if $(GNUMACH_IN_TREE),dist-gnumach-tree,dist-gnumach-nix)

# Ship the NIX-built kernel into the dist tree (the non-opt-in half of
# dist-gnumach; counterpart to dist-glibc-nix).  Resolved per-$(ARCH) — the kernel
# is the ONLY per-ARCH package, so i686 vs i686-xen differ HERE and nowhere else.
# $out = boot/gnumach (+ .elf) + include/mach + share/ (mach.info, .defs, msgids);
# store-path-stamped so an unchanged kernel skips the copy.  share/info/dir is
# stashed/restored across the copy + libc-style merged (see dist-glibc-nix).
dist-gnumach-nix: $(DIST_GNUMACH_NIX_STAMP)

$(DIST_GNUMACH_NIX_STAMP): packages.nix flake.lock flakes/gnumach/default.nix
	@mkdir -p $(DIST_GNUMACH)/boot $(dir $(DIST_GNUMACH_NIX_STAMP))
	@echo "  DIST-GNUMACH-NIX  resolving nix gnumach-$(ARCH)…"
	@set -e; \
	pkg=$$($(NIX_BUILD) $(call _overrides,dist-gnumach-nix) $(PROJ)\#gnumach-$(ARCH) --no-link --print-out-paths); \
	if [ "$$(cat $(DIST_GNUMACH_NIX_STAMP) 2>/dev/null)" = "$$pkg" ] && [ -e $(DIST_GNUMACH)/boot/gnumach ]; then \
	  echo "  unchanged ($$(basename $$pkg)) — skip copy"; \
	else \
	  echo "  copying $$pkg -> $(DIST_GNUMACH)"; \
	  chmod -R u+w $(DIST_GNUMACH) 2>/dev/null || true; \
	  acc=$$(mktemp); cp -a $(DIST_GNUMACH)/share/info/dir "$$acc" 2>/dev/null || acc=; \
	  cp -a $$pkg/. $(DIST_GNUMACH); \
	  chmod -R u+w $(DIST_GNUMACH) 2>/dev/null || true; \
	  if [ -n "$$acc" ]; then cp -a "$$acc" $(DIST_GNUMACH)/share/info/dir; rm -f "$$acc"; else rm -f $(DIST_GNUMACH)/share/info/dir; fi; \
	  [ -e $(DIST_GNUMACH)/share/info/mach.info ] && install-info --quiet --info-dir=$(DIST_GNUMACH)/share/info $(DIST_GNUMACH)/share/info/mach.info || true; \
	  printf '%s' "$$pkg" > $(DIST_GNUMACH_NIX_STAMP); \
	fi
	@ls $(DIST_GNUMACH)/boot/gnumach >/dev/null || { echo "ERROR: boot/gnumach missing"; exit 1; }
	@$(call dist-stamp,$(EPOCH_GNUMACH))

# ---- hurd / dist-hurd ----
# `make hurd`      — in-tree incremental userland build under
#                    work/hurd/$(_TC_ARCH).  Counterpart to `make mach`: edit
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

# `make hurd` builds the userland under work/hurd/$(_TC_ARCH).  Unlike mach (whose
# kernel is a single file sentinel, $(GNUMACH_KERNEL)), hurd produces many
# outputs and no single binary, so we use a build stamp ($(HURD_BUILD)/.built)
# as its sentinel — touched after a successful compile.  Combined with the
# _SENTINEL.hurd / _WATCH.hurd entries above, a no-op `make hurd` short-circuits
# (no dispatch, no recursing every subdir printing "nothing to be done") unless
# a tracked src/hurd file is newer than the stamp.  The $(HURD_SRC_FILES) prereq
# makes the inner make re-run when source actually changed.  Without src/hurd
# (or HURD_IN_TREE=0), `make hurd` realizes the nix userland instead.
ifdef HURD_IN_TREE
hurd: $(HURD_BUILD)/.built

# With an in-tree glibc (GLIBC_IN_TREE), the userland must link against it, not
# the wrapped cc's baked-in toolchain glibc.  It links against the BUILD sysroot
# $(SYSROOT) (work/sysroot) — where work-glibc installs glibc beside the
# mach+hurd headers — NOT the dist tree (DIST_GLIBC is distribution-only).
# Depend on the work-glibc output ($(SYSROOT)/lib/libc.so.0.3 → pulls work-glibc)
# and pass --sysroot=$(SYSROOT); ld resolves the root-relative libc.so GROUP
# under that sysroot.
#
# The explicit -L$(SYSROOT)/lib is load-bearing for the STATIC bootstrap servers
# (ext2fs.static etc.).  Their `-static -lc` pulls glibc's static archives
# (libc.a ldscript -> libcrt/libmachuser/libhurduser .a), and the wrapped cc's
# baked `-L<nix-glibc-farm>/lib` otherwise wins over --sysroot — so the link
# would embed the NIX glibc's objects, not the in-tree ones.  That both diverges
# the .static binaries cross-host (nix glibc carries per-host sandbox build paths
# in its DWARF) and silently bypasses a hacked src/glibc for exactly the servers
# that boot the system.  A command-line -L precedes the wrapper's baked -L, so
# this makes the in-tree archives win.  (The dynamic servers only record the
# libc.so.0.3 soname, embedding no glibc objects, so they were already fine.)
_HURD_SYSROOT := $(if $(GLIBC_IN_TREE),--sysroot=$(SYSROOT))
_HURD_LDFLAGS := $(if $(GLIBC_IN_TREE),--sysroot=$(SYSROOT) -L$(SYSROOT)/lib)

$(HURD_BUILD)/.built: $(MIG) $(if $(GLIBC_IN_TREE),$(SYSROOT)/lib/libc.so.0.3) $(HURD_CONFIGURED) $(HURD_SRC_FILES)
	cd $(HURD_BUILD) && \
	  NIX_CFLAGS_COMPILE="$$NIX_CFLAGS_COMPILE -ffile-prefix-map=$(HURD_BUILD)=$(HURD_CANON_BUILD) -ffile-prefix-map=$(HURD_SRC)=$(HURD_CANON_BUILD)" \
	  $(MAKE) MIG=$(MIG) USER_MIG=$(MIG)
	@touch $(HURD_BUILD)/.built

# In-tree builds stamp the SAME composed build-rev version the nix build bakes
# (via _bake_version → nix `.#hurd-….version`), so nix == in-tree; a dirty
# src/hurd additionally gets `-dirty` after `-g<src>` (nix can't see that).
$(HURD_SRC)/configure: $(HURD_SRC)/configure.ac
	cd $(HURD_SRC) && autoreconf -i
	$(call _bake_version,hurd,hurd-$(_TC_ARCH),$(HURD_SRC))

$(HURD_CONFIGURED): $(MIG) $(if $(GLIBC_IN_TREE),$(SYSROOT)/lib/libc.so.0.3) $(HURD_SRC)/configure
	mkdir -p $(HURD_BUILD)
	cd $(HURD_BUILD) && \
	  $(HURD_SRC)/configure $(HURD_CONFIGURE_FLAGS) \
	    MIG=$(MIG) USER_MIG=$(MIG) \
	    CFLAGS="-fcommon -g -O2 $(_HURD_SYSROOT) $(call _macro_prefix_map,$(HURD_SRC))" \
	    $(if $(GLIBC_IN_TREE),LDFLAGS="$(_HURD_LDFLAGS)") \
	    --prefix=/ --libexecdir=/libexec --bindir=/bin --sbindir=/sbin \
	    --sysconfdir=/etc --localstatedir=/var --libdir=/lib --includedir=/include

# In-tree install: `make install` the work/ userland into $(DIST_HURD) as a
# self-contained tree.  `make hurd` is fast in-tree iteration; dist-hurd-tree
# produces the installable artefact (like dist-gnumach-tree).
dist-hurd-tree: $(DIST_HURD)/hurd/ext2fs

# Install the in-tree userland build into $(DIST_HURD).  Configured --prefix=/
# (root-relative baked paths — LIBEXECDIR=/libexec etc. so a deployed tree finds
# its own console-run/servers), staged via DESTDIR.  Under fakeroot: hurd's
# daemons/ + utils/ install
# some programs `-o root -m 4755` (setuid), which a non-root install can't do
# — fakeroot fakes the chown/setuid so the install completes without touching
# real privilege (the bits are cosmetic for a dev dist tree).  Same MIG as the
# build.  Keyed on the installed ext2fs translator — the headline userland
# output, the analog of dist-gnumach's boot/gnumach — so dist/ holds only install
# results (no completion stamp).  `make install` rebuilds the whole tree; make
# only compares ext2fs's mtime against the build stamp to decide staleness.
$(DIST_HURD)/hurd/ext2fs: $(HURD_BUILD)/.built
	cd $(HURD_BUILD) && fakeroot $(MAKE) install DESTDIR=$(DIST_HURD) \
	  MIG=$(MIG) USER_MIG=$(MIG)
	@# hurd's `make install` doesn't merge hurd.info into the shared Info dir, so
	@# add the Hurd entry explicitly — as dist-gnumach-tree does for mach.info and
	@# dist-hurd-nix for the nix path — or the merged index loses "* Hurd: (hurd)".
	@[ -e $(DIST_HURD)/share/info/hurd.info ] && install-info --quiet --info-dir=$(DIST_HURD)/share/info $(DIST_HURD)/share/info/hurd.info || true
	@$(call dist-stamp,$(EPOCH_HURD))
endif  # HURD_IN_TREE — the opted-out `hurd`/`dist-hurd-tree` stubs are top-level (above)

# ---- dist-hurd ----
# Public target: dispatch in-tree-vs-nix like dist-glibc.  In-tree → install the
# work/ build; else → copy the nix hurd userland package.
.PHONY: dist-hurd dist-hurd-tree dist-hurd-nix
dist-hurd: $(if $(HURD_IN_TREE),dist-hurd-tree,dist-hurd-nix)

# Ship the NIX-built userland into the dist tree (the non-opt-in half of
# dist-hurd; counterpart to dist-glibc-nix).  Resolved per-$(_TC_ARCH) — the
# userland is CPU-ABI-keyed, shared across xen/non-xen (so i686 == i686-xen here).
# $out = hurd/ translators + lib/ + libexec/ + include/hurd + bin/sbin utils;
# store-path-stamped so an unchanged userland skips the copy.  share/info/dir is
# stashed/restored across the copy + hurd.info merged (see dist-glibc-nix).
dist-hurd-nix: $(DIST_HURD_NIX_STAMP)

$(DIST_HURD_NIX_STAMP): packages.nix flake.lock flakes/hurd/default.nix
	@mkdir -p $(DIST_HURD)/hurd $(dir $(DIST_HURD_NIX_STAMP))
	@echo "  DIST-HURD-NIX  resolving nix hurd-$(_TC_ARCH)…"
	@set -e; \
	pkg=$$($(NIX_BUILD) $(call _overrides,dist-hurd-nix) $(PROJ)\#hurd-$(_TC_ARCH) --no-link --print-out-paths); \
	if [ "$$(cat $(DIST_HURD_NIX_STAMP) 2>/dev/null)" = "$$pkg" ] && [ -e $(DIST_HURD)/hurd/ext2fs ]; then \
	  echo "  unchanged ($$(basename $$pkg)) — skip copy"; \
	else \
	  echo "  copying $$pkg -> $(DIST_HURD)"; \
	  chmod -R u+w $(DIST_HURD) 2>/dev/null || true; \
	  acc=$$(mktemp); cp -a $(DIST_HURD)/share/info/dir "$$acc" 2>/dev/null || acc=; \
	  cp -a $$pkg/. $(DIST_HURD); \
	  chmod -R u+w $(DIST_HURD) 2>/dev/null || true; \
	  if [ -n "$$acc" ]; then cp -a "$$acc" $(DIST_HURD)/share/info/dir; rm -f "$$acc"; else rm -f $(DIST_HURD)/share/info/dir; fi; \
	  [ -e $(DIST_HURD)/share/info/hurd.info ] && install-info --quiet --info-dir=$(DIST_HURD)/share/info $(DIST_HURD)/share/info/hurd.info || true; \
	  printf '%s' "$$pkg" > $(DIST_HURD_NIX_STAMP); \
	fi
	@ls $(DIST_HURD)/hurd/ext2fs >/dev/null || { echo "ERROR: hurd/ext2fs missing"; exit 1; }
	@$(call dist-stamp,$(EPOCH_HURD))

# ---- check ----
# Test suite shipped by upstream gnumach, surfaced as a make target:
#
#   check-gnumach : gnumach's 'make check' — kernel tests run inside QEMU.
#                Upstream wiring is i386/x86_64-multiboot; aarch64 may
#                need additional plumbing in src/gnumach/tests/.
#   check      : alias for check-gnumach (kept for convention/familiarity).
#
# MIG's own test-suite has no make target — it runs inline via doCheck=true
# on every `nix build .#mig-<arch>`, which is transitively triggered by
# `make dist-gnumach` / `make dist` (the gnumach derivation depends on mig
# via the cross-toolchain).
#
# No _SENTINEL entries — running a test suite is not idempotent, so we
# always dispatch and let the inner make decide.

# The kernel test suite runs on every ARCH we support; xen variants
# self-skip via gnumach's tests/Makefrag.am (`if !PLATFORM_xen` wraps
# the whole tests block) so they no-op without our help.
#
# Darwin can't host check-gnumach for any target: each target's test
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
check-gnumach:
	@echo "==> check-gnumach ($(ARCH)): ERROR — darwin host is not supported." >&2
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
check-gnumach: gnumach
	@echo "==> check-gnumach ($(ARCH)): running gnumach 'make check' in $(GNUMACH_BUILD)"
	cd $(GNUMACH_BUILD) && $(MAKE) check
endif

check: check-gnumach

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
