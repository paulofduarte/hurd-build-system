# SPDX-FileCopyrightText: 2026 Paulo Duarte <paulofernandobd@gmail.com>
# SPDX-License-Identifier: GPL-3.0-or-later
# Top-level Makefile for the GNU Hurd / Mach build.
#
# Usage:
#   make                  build for the host's native arch (default)
#   make ARCH=x86_64    cross-build for a different target
#   make help             list all targets (works even without nix)
#
# Outside the Nix dev shell (or inside the WRONG target's shell), re-enters the
# correct shell via `nix develop -i .#<target>`.  clean/clean-dist/mrproper/help
# run at top level (no toolchain); dispatch is skipped if everything exists.
#
# Requires Nix (https://nix.dev/install-nix); flake features enabled per-invocation.

# Require GNU Make 3.81 (what macOS ships, lowest with $(or)/$(eval)/.DEFAULT_GOAL).
# Lexicographic $(sort) is a safe version-compare up to GNU Make 9.x.
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

# Enables nix-command + flakes per invocation so no global nix.conf is needed.
# ca-derivations: the working gnumach/hurd headers are content-addressed
# (early cutoff for the glibc-hurd rebuild cascade) - anything evaluating
# their closure needs the feature.
NIX_FLAKE := $(NIX) --extra-experimental-features 'nix-command flakes ca-derivations'
# -L streams full build logs (build-only; eval calls use $(NIX_FLAKE) directly).
NIX_BUILD := $(NIX_FLAKE) build -L

# ARCH resolution: env > cmdline > host CPU default.
ifndef ARCH
_HOST_CPU := $(shell uname -m)
# $(strip) is load-bearing: the indented `$(if ...)` continuation lines leave a
# leading space that would corrupt ARCH and every `.#$(ARCH)` selector/path.
# Supported targets are x86_64 + i686 (aarch64-gnu isn't upstream yet); any
# unrecognised host defaults to x86_64, matching crossToolchain.defaultTargetName.
ARCH := $(strip \
  $(if $(filter i386 i486 i586 i686,$(_HOST_CPU)),i686, \
  x86_64))
endif

# Default MIG_TARGET when outside the dev shell (the shell exports it).  Strip any
# platform suffix (i686-xen -> i686): MIG only cares about CPU ABI; Xen and PC-AT
# share one MIG binary.
ifndef MIG_TARGET
MIG_TARGET := $(firstword $(subst -, ,$(ARCH)))-gnu
endif
# The mig binary's base name - locates the in-tree build output + `configure
# --target`.  Distinct from MIG, the effective mig PROGRAM (a path): the dev shell
# exports MIG (nix working mig); the in-tree opt-in (below) overrides it.
MIG_NAME := $(MIG_TARGET)-mig

# Default SCENARIO so `make run` works without an override.  _RUN_PREREQS below
# needs the value at PARSE time - else `make ARCH=x86_64 run` misses the
# x86_64+boot -> sidekick prereq.
SCENARIO ?= boot

# Layout.  Two parallel tracks per component:
#   work/<comp>/<arch>/   in-tree iterative builds (fast incremental).
#   dist/<arch>/          clean reproducible install tree (tarball-able release,
#                         no /nix/store runtime deps).
# FLAKES is source-only (the nix sub-flakes); SIDEKICK holds the x86_64
# helper-VM artefacts, gitignored.
PROJ          := $(CURDIR)
SRC           := $(PROJ)/src
WORK          := $(PROJ)/work
FLAKES        := $(PROJ)/flakes
SIDEKICK      := $(PROJ)/.sidekick
DIST_ROOT     := $(PROJ)/dist

# Boolean-knob normalizer: $(call _bool,VALUE) -> "1" if truthy, "" if falsey
# (empty/0/no/off/false, any case).  Needed because bare $(if)/ifdef treat ANY
# non-empty string - incl. "0" - as true.  $(_lc) lowercases via tr.
_lc   = $(shell printf %s '$(1)' | tr 'A-Z' 'a-z')
_bool = $(if $(filter-out 0 no off false,$(call _lc,$(strip $(1)))),1)

# $(eval $(call _detect_in_tree,FLAG,SRC)): shared opt-in rule for the four
# in-tree-able modules (mig, glibc, gnumach, hurd).  Auto-enable FLAG when
# src/<m>/.git is present unless an explicit value was given ($(origin) guard
# lets FLAG=0/1 override), then normalize via _bool.  `override` is required to
# beat a command-line value ("0" is truthy to bare $(if ...)).
define _detect_in_tree
ifeq ($$(origin $(1)),undefined)
$(1) := $$(if $$(wildcard $(2)/.git),1)
endif
override $(1) := $$(call _bool,$$($(1)))
endef

# MULTI_HOST_BUILDS (boolean) + ALT_BUILD (tag): optional path segments inserted
# before the target arch in BOTH work/ and dist/, so builds sharing one checkout
# don't collide.  Both off by default -> normal layout unchanged.
#   MULTI_HOST_BUILDS : truthy splits per BUILD HOST (auto-resolved nix system),
#                       for cross-host determinism testing where orb mounts the
#                       same checkout over 9p.
#   ALT_BUILD         : variant tag (e.g. nix / in-tree) to keep two configs'
#                       trees side by side on ONE host.
MULTI_HOST_BUILDS ?=
ALT_BUILD         ?=
override MULTI_HOST_BUILDS := $(call _bool,$(MULTI_HOST_BUILDS))
# Resolve the host's nix system tuple only when MULTI_HOST_BUILDS is on (lazy
# $(shell) under the conditional).  From uname, no `nix eval`: arm64 -> aarch64;
# uname -s lowercased is the OS half.
ifneq ($(MULTI_HOST_BUILDS),)
_HOST_SYSTEM := $(subst arm64,aarch64,$(shell uname -m))-$(shell uname -s | tr A-Z a-z)
endif
# $(_VARIANT) = "<host-system>/<alt>/" infix (empty parts dropped), spliced before
# $(ARCH)/$(_TC_ARCH) in every work + dist path, forwarded across the dispatch so
# the inner make computes the same paths.
_VARIANT := $(if $(_HOST_SYSTEM),$(_HOST_SYSTEM)/)$(if $(ALT_BUILD),$(ALT_BUILD)/)

# DIST is the per-arch output tree; override to install elsewhere.  DIST_GNUMACH/
# HURD/GLIBC each default to DIST (one shared tree) but can point elsewhere
# independently.
DIST          ?= $(DIST_ROOT)/$(_VARIANT)$(ARCH)
DIST_GNUMACH     ?= $(DIST)
DIST_HURD     ?= $(DIST)
DIST_GLIBC    ?= $(DIST)
# Store-path stamps under work/ (NOT the shippable dist tree), per-variant-per-ARCH
# so targets/variants don't clobber one stamp; an unchanged store path skips the
# verbatim copy.  Keyed on $(ARCH) so i686 and i686-xen track copies independently.
DIST_GLIBC_STAMP       := $(WORK)/dist-glibc/$(_VARIANT)$(ARCH).stamp
DIST_GNUMACH_NIX_STAMP := $(WORK)/dist-gnumach-nix/$(_VARIANT)$(ARCH).stamp
DIST_HURD_NIX_STAMP    := $(WORK)/dist-hurd-nix/$(_VARIANT)$(ARCH).stamp
# The split gcc runtime libs (one nix derivation + one dist-gcc-<lib> target each).
# `make dist` ships ONLY libgcc by default (glibc dlopens libgcc_s.so.1 for
# pthread_cancel unwinding); the rest are opt-in: `make dist-gcc-<lib>` directly, or
# DIST_GCC_LIBS="libstdc++ libgomp" to fold them into `make dist`.
_GCC_RT_LIBS  := libgcc libstdc++ libatomic libitm libquadmath libssp libgomp
DIST_GCC_LIBS ?=
# Each lib's primary shared object (the dist-presence assert + stamp check file).
_RT_SO.libgcc       := libgcc_s.so.1
_RT_SO.libstdc++    := libstdc++.so.6
_RT_SO.libatomic    := libatomic.so.1
_RT_SO.libitm       := libitm.so.1
_RT_SO.libquadmath  := libquadmath.so.0
_RT_SO.libssp       := libssp.so.0
_RT_SO.libgomp      := libgomp.so.1
DIST_GCC_STAMP_DIR   := $(WORK)/dist-gcc
DIST_TZDATA_STAMP    := $(WORK)/dist-tzdata/$(_VARIANT)$(ARCH).stamp
# In-tree dist install stamps.  The dist tree is mtime-normalised to the source
# epoch by _dist_finalize, so it can't be the staleness baseline (always older than
# src mtime -> permanently stale).  Each dist-*-tree touches its stamp on completion,
# giving the gate a real "last installed" time.
DIST_GNUMACH_TREE_STAMP := $(WORK)/dist-gnumach-tree/$(_VARIANT)$(ARCH).stamp
DIST_HURD_TREE_STAMP    := $(WORK)/dist-hurd-tree/$(_VARIANT)$(ARCH).stamp

# Per-component deterministic dist mtimes: each dist-* stamps the files IT wrote
# into the shared $(DIST) to ITS OWN source's commit date (flake.lock
# `lastModified`) - true provenance, not nix's 1970 epoch.  Untracked nix packages
# (gcc runtime, tzdata) have no pinned commit, so they use the `nixpkgs` snapshot
# date.  Parsed with jq; empty if flake.lock/jq absent -> mtime left as-is.
_src_epoch      = $(shell jq -r '.nodes["$(1)"].locked.lastModified' flake.lock 2>/dev/null)
EPOCH_GNUMACH    := $(call _src_epoch,gnumach-src)
EPOCH_HURD    := $(call _src_epoch,hurd-src)
EPOCH_GLIBC   := $(call _src_epoch,glibc-src)
EPOCH_NIXPKGS := $(call _src_epoch,nixpkgs)

# Wall-clock when this make started - the cut between "written by this build"
# (CURRENT mtime) and earlier components' already-stamped files (a past date).
DIST_BUILD_START := $(shell date +%s)

# $(call _dist_finalize,<epoch>): normalise the files the calling dist-* just wrote
# into $(DIST) - owner-writable PERMS + deterministic MTIME <epoch>.  Matches items
# newer than DIST_BUILD_START (this build's installs) OR still at the nix store
# epoch (mtime<=1, from `cp -a`); earlier components' files (1<date<start) are left
# alone, so each owns its slice of the shared /lib, /share/info, /include.
# Idempotent; no-op if <epoch> empty.  chmod targets files+dirs (bare chmod follows
# symlinks); touch targets files+symlinks (-h).  Runs in the dev-shell (GNU find/touch).
define _dist_finalize
[ -z "$(1)" ] || { \
  find $(DIST) \( -type f -o -type d \) \( -newermt @$(DIST_BUILD_START) -o ! -newermt @1 \) -exec chmod u+w {} + ; \
  find $(DIST) \( -type f -o -type l \) \( -newermt @$(DIST_BUILD_START) -o ! -newermt @1 \) -exec touch -h -d @$(1) {} + ; \
}
endef

# $(call _make_writable,DIR): make a subtree writable - tolerant of a read-only
# /nix/store copy (`cp -a` clones the store's r-o perms) and a missing dir.  Used
# after a store copy (so writes + _dist_finalize can touch it) and by clean/mrproper.
_make_writable = chmod -R u+w $(1) 2>/dev/null || true

# A xen variant shares its CPU sibling's `<cpu>-gnu` ABI: "xen" only selects the
# gnumach KERNEL's platform (built -ffreestanding -nostdlib, never reads the
# userland sysroot), so the entire userland is byte-identical to the non-xen
# sibling's.  Key userland build/sysroot dirs by $(_TC_ARCH) so i686 and i686-xen
# build the userland ONCE (shared work dirs); only the per-$(ARCH) kernel + dist
# trees differ.  Matches the nix side; avoids a redundant rebuild on variant switch
# and spurious per-ARCH paths leaking into DWARF.
_TC_ARCH := $(patsubst %-xen,%,$(ARCH))

# In-tree iterative build dirs.  KERNEL dirs are per-$(ARCH) (platform-specific);
# USERLAND dirs are per-$(_TC_ARCH) (shared across a CPU's xen/non-xen variants).
GNUMACH_SRC      := $(SRC)/gnumach
GNUMACH_BUILD    := $(WORK)/gnumach/$(_VARIANT)$(ARCH)
GNUMACH_KERNEL   := $(GNUMACH_BUILD)/gnumach
GNUMACH_CONFIGURED := $(GNUMACH_BUILD)/config.status
# gnumach is opt-in in-tree (like glibc/mig): src/gnumach present -> build from it;
# absent (or GNUMACH_IN_TREE falsey) -> use the nix kernel package.  An explicit
# value beats the auto-detect and is forwarded across the dispatch.
$(eval $(call _detect_in_tree,GNUMACH_IN_TREE,$(GNUMACH_SRC)))
# Separate build dir for the headers-only install: configures with a stub USER_MIG
# so it can run BEFORE mig exists (mig needs the Mach headers), and installs into the
# build-only SYSROOT - distinct from the kernel build dir (real mig + --prefix=$(DIST_GNUMACH)).
GNUMACH_HDR_BUILD := $(WORK)/gnumach-headers/$(_VARIANT)$(_TC_ARCH)
GNUMACH_HDR_CONFIGURED := $(GNUMACH_HDR_BUILD)/config.status
# Mach-headers install stamp, in the BUILD dir not the sysroot.  Consumers (mig,
# glibc) depend on this, NOT $(SYSROOT)/include/mach: glibc's install writes mach/*
# wrapper headers there, bumping its mtime - which as a prereq would invalidate
# glibc's config.status and loop a rebuild.  Touched only by gnumach-headers.
GNUMACH_HDR_STAMP := $(GNUMACH_HDR_BUILD)/.headers-installed
# Staging prefix: install-data lands here, then `cp -rs` symlink-farms into
# $(SYSROOT) (see the gnumach-headers recipe).
GNUMACH_HDR_STAGE := $(GNUMACH_HDR_BUILD)/install

# Build-only sysroot for the cross headers (Mach via gnumach-headers, Hurd via
# hurd-headers), what the in-tree mig + glibc depend on - a STABLE location nothing
# installs into later.  NOT under $(DIST): hurd's `make install` writes $(DIST)/include
# too, so depending on the dist include dir would bump its mtime and make mig
# perpetually stale (reconfigure/rebuild loop).
SYSROOT          := $(WORK)/sysroot/$(_VARIANT)$(_TC_ARCH)

MIG_SRC          := $(SRC)/mig
MIG_BUILD        := $(WORK)/mig/$(_VARIANT)$(_TC_ARCH)
MIG_INSTALL_DIR  := $(MIG_BUILD)/install
LOCAL_MIG        := $(MIG_INSTALL_DIR)/bin/$(MIG_NAME)

# mig is opt-in in-tree.  The dev shell always exports MIG (the nix working mig),
# so mig is available with no `make mig`.  `make src-mig` flips MIG to the in-tree
# binary and turns `make mig` into a real build; without it `make mig` is a no-op.
# Force on/off with MIG_IN_TREE=1/0 (explicit value skips auto-detect, forwarded
# across the dispatch).  MIG points at the in-tree build whenever MIG_IN_TREE is on,
# else stays the dev-shell $MIG.
$(eval $(call _detect_in_tree,MIG_IN_TREE,$(MIG_SRC)))
ifdef MIG_IN_TREE
MIG := $(LOCAL_MIG)
endif

# Hurd source clone (populated by `make src`) + in-tree build dir.
HURD_SRC         := $(SRC)/hurd
HURD_BUILD       := $(WORK)/hurd/$(_VARIANT)$(_TC_ARCH)
HURD_CONFIGURED  := $(HURD_BUILD)/config.status
# hurd is opt-in in-tree (like glibc/mig): src/hurd present -> build from it;
# absent (or HURD_IN_TREE falsey) -> use the nix hurd package.  An explicit value
# beats the auto-detect and is forwarded across the dispatch.
$(eval $(call _detect_in_tree,HURD_IN_TREE,$(HURD_SRC)))

# Rewrite the absolute build-time source dir out of assert()/__FILE__ strings so the
# in-tree kernel + userland don't bake the host path into shipped .rodata.  ONLY the
# in-tree builds need this (they configure OUT of tree with absolute $(srcdir), so
# __FILE__ is absolute; nix builds compile in-source, already clean).
# -fmacro-prefix-map (not -ffile-) touches only __FILE__/.rodata, leaving DWARF intact.
# $(1) = the build's absolute source dir.
_macro_prefix_map = -fmacro-prefix-map=$(1)/=

# $(call _det_maps,build,src,canon): out-of-tree gnumach/hurd -ffile-prefix-maps -
# build dir + source both map to <canon> so DWARF matches the nix build.  (glibc's
# 4-map set differs, stays inline.)
_det_maps = -ffile-prefix-map=$(1)=$(3) -ffile-prefix-map=$(2)=$(3)

# Headers-only build dir for hurd (sibling to GNUMACH_HDR_BUILD): `make
# install-headers` populates the Hurd half of the in-tree glibc's sysroot.
HURD_HDR_BUILD   := $(WORK)/hurd-headers/$(_VARIANT)$(_TC_ARCH)
HURD_HDR_CONFIGURED := $(HURD_HDR_BUILD)/config.status
# Writable staging for the NIX hurd-headers farm (the nix $out is read-only) -
# see _farm_nix_headers.
HURD_HDR_STAGE   := $(HURD_HDR_BUILD)/install
# Hurd-headers install stamp (see GNUMACH_HDR_STAMP): glibc writes its own hurd/*
# headers into the shared sysroot dir, so glibc depends on this build-dir stamp.
HURD_HDR_STAMP := $(HURD_HDR_BUILD)/.headers-installed

# Working glibc clone (populated by `make src`, hackable like the kernel
# sources - see TOOLCHAIN-LIBC-DECOUPLING.md).
# Canonical gnumach/hurd path roots for -ffile-prefix-map in the in-tree builds,
# so they bake the SAME DWARF paths as the nix builds - byte-identical.  Each maps
# BOTH src and build dir to a single name, so the variant infix + cross-host
# work-path variation don't leak into DWARF.  SINGLE SOURCE OF TRUTH:
# build-flags.nix, exported by the dev-shell as env vars.  No `?=` fallback ON
# PURPOSE - a stray make outside the dev shell must FAIL via $(call _req_env,...),
# not silently compile with an empty map and diverge.  Values:
# GNUMACH_CANON_BUILD, HURD_CANON_BUILD, BASE_CFLAGS, HURD_EXTRA_CFLAGS.
# $(call _req_env,VAR...): recipe guard - fail if any VAR is unset (a stray make
# outside the dev shell would compile with empty maps/flags and silently diverge).
_req_env = $(foreach v,$(1),[ -n "$($(v))" ] || { echo "ERROR: $(v) unset - build via the dev shell (make dispatches into nix develop)"; exit 1; }; )

# glibc is nix-only (the gcc model): the pinned `glibc-src` flake input + patches in
# flakes/cross-toolchain/glibc.nix.  Version picking = edit the input in flake.nix.
# No in-tree build; the toolchain (wrapped cc) always carries the nix glibc sysroot.
# In-tree gnumach/hurd/mig changes still reach it: their scoped --override-input set
# rebuilds the nix glibc (RPC changes ripple into libmachuser/libhurduser).

# In-tree working-source overrides - SCOPED per nix target + per *_IN_TREE.
# `--override-input <m>-src src/<m>` repoints a nix input at the local clone (nix
# git-tree semantics: tracked + uncommitted edits) so nix builds the WORKING source
# - what makes a dist-*-nix half match its in-tree twin.  Override ONLY when the
# target consumes the input AND that module's <M>_IN_TREE is on, so a module's src is
# never dragged in by an unrelated build.  The frozen `*-ref-src` twins are NEVER
# overridden, so a glibc/header/mig hack never rebuilds gcc.
#
# Dependency graph - the WORKING src inputs each nix target transitively consumes:
# mig builds against gnumach-headers; gnumach runs mig; hurd-headers uses mig (which
# drags in gnumach); hurd links glibc-hurd + uses mig + mach/hurd headers; glibc-hurd
# farms gnumach+hurd headers + mig.
_DG := gnumach mig                  # gnumach kernel
_DH := hurd mig gnumach             # hurd userland
_DC := gnumach hurd mig             # the nix glibc (RPC headers + mig stubs)
_DEPS.mig               := mig gnumach
_DEPS.gnumach           := $(_DG)
_DEPS.dist-gnumach      := $(_DG)
_DEPS.dist-gnumach-tree := $(_DG)
_DEPS.dist-gnumach-nix  := $(_DG)
_DEPS.gnumach-headers   := gnumach
_DEPS.hurd-headers      := hurd mig gnumach
_DEPS.hurd              := $(_DH)
_DEPS.dist-hurd         := $(_DH)
_DEPS.dist-hurd-tree    := $(_DH)
_DEPS.dist-hurd-nix     := $(_DH)
_DEPS.glibc             := $(_DC)
_DEPS.dist-glibc        := $(_DC)
_DEPS.dist              := mig gnumach hurd
_DEPS.all               := mig gnumach hurd
# The split gcc runtime libs sit on the WORKING glibc -> same transitive srcs.
$(foreach l,$(_GCC_RT_LIBS),$(eval _DEPS.dist-gcc-$(l) := $(_DC)))

# module -> its IN_TREE flag var.
_FLAG.mig     := MIG_IN_TREE
_FLAG.gnumach := GNUMACH_IN_TREE
_FLAG.hurd    := HURD_IN_TREE
# $(call _override1,MODULE): override <m>-src iff <M>_IN_TREE is truthy.  No
# clone-existence test - a truthy flag with absent src/<m> is caught by _need_src below.
_override1 = $(if $($(_FLAG.$(1))),--override-input $(1)-src $(SRC)/$(1))
# $(call _overrides,TARGET): the scoped --override-input set for a nix TARGET.
# When any module override is active, the build-rev input rides along: overriding
# unmatches the lock and nix drops self's rev, so composeVersion needs the real
# token explicitly (see the _BUILD_REV block) - else the overridden builds bake
# `+build.gunknown` and diverge from the no-override/CI builds.
_overrides = $(foreach d,$(_DEPS.$(1)),$(call _override1,$(d)))$(if $(strip $(foreach d,$(_DEPS.$(1)),$(call _override1,$(d)))), --override-input build-rev path:$(abspath $(BUILD_REV_DIR)))

# module -> its in-tree clone dir (the staleness twin of _override1's src path).
_SRCDIR.mig     := $(MIG_SRC)
_SRCDIR.gnumach := $(GNUMACH_SRC)
_SRCDIR.hurd    := $(HURD_SRC)
# $(call _intree_srcs,TARGET): the src dirs TARGET's overrides drag in (opted-in
# modules only) - derived from the same _DEPS graph that scopes _overrides, so the
# staleness watches can't drift from the override set.  Feeds _WATCH.<nix-half>.
_intree_srcs = $(strip $(foreach d,$(_DEPS.$(1)),$(if $($(_FLAG.$(d))),$(_SRCDIR.$(d)))))

# Forces a stamped recipe to re-run (used via a conditional prereq when the goal's
# sources fingerprint is stale - see below).
.PHONY: _FORCE
_FORCE:

# The store-path-stamped nix halves.  mtime can't see what their resolve actually
# reads: a repo COMMIT moves every drv's buildRev token without touching file
# mtimes, an overridden src/<m> changes outside the stamp's prereq list, and a flag
# FLIP changes the resolve while every file stays old.  So each goal records a
# SOURCES FINGERPRINT beside its stamp (<stamp>.fp): the git-content state of
# everything the resolve reads, and each OPTED-IN dep module likewise.  Untracked
# files are invisible to nix's git fetcher AND to the fingerprint, so the two agree
# by construction.  A fingerprint mismatch makes the goal gate-stale and _FORCEs its
# recipe (which re-resolves; the store-path compare still guards the copy); a match
# is a true "Nothing to be done".  Over-triggering (an irrelevant tracked edit ->
# one cheap re-eval) is the only failure mode; a false skip cannot happen.
_OVR_GOALS = dist-glibc dist-gnumach-nix dist-hurd-nix $(addprefix dist-gcc-,$(_GCC_RT_LIBS))

# The repo fingerprint is SCOPED to the flake-eval read surface - the root nix
# files, flakes/, the build-rev input dir, and the Makefile (recipe semantics) -
# so tracked-noise edits (docs, cloud-init, CI) stop re-firing resolves.  The
# audited eval surface: every readFile/import in the flake stays inside this set
# (flakes/sources reads flake.lock; module reads come from the *-src INPUTS,
# covered by the lock in-scope or the per-module fps below).  Two invariants
# guard the scoping:
#   - anything NEW the eval reads from the repo must live in (or be added to)
#     $(_FP_SCOPE) - an out-of-scope read is a silent under-coverage;
#   - artifacts that bake the +build.<rev> token (the kernel/userland dists)
#     carry the token as an EXPLICIT fp term below, since out-of-scope commits
#     legitimately move it.
_FP_SCOPE := Makefile flake.nix flake.lock packages.nix target-archs.nix .build-rev flakes
_REV_GOALS := dist-gnumach-nix dist-hurd-nix

# $(call _git_fp,DIR): content fingerprint of what nix's git fetcher sees in DIR.
_git_fp = $(shell git -C $(1) rev-parse --short HEAD 2>/dev/null)$(shell git -C $(1) diff --quiet HEAD 2>/dev/null || echo .d$$(git -C $(1) diff HEAD 2>/dev/null | git hash-object --stdin | cut -c1-12))
# Memoized lazily (first use) so `make help`/plain parses don't pay the git cost.
# Repo: committed blob ids (ls-tree) + the dirty delta, both path-scoped.
_FP_REPO    = $(or $(__fp_repo),$(eval __fp_repo := $(shell { git ls-tree -r HEAD -- $(_FP_SCOPE); git diff HEAD -- $(_FP_SCOPE); } 2>/dev/null | git hash-object --stdin | cut -c1-16))$(__fp_repo))
_FP.mig     = $(or $(__fp_mig),$(eval __fp_mig := $(call _git_fp,$(MIG_SRC)))$(__fp_mig))
_FP.gnumach = $(or $(__fp_gnumach),$(eval __fp_gnumach := $(call _git_fp,$(GNUMACH_SRC)))$(__fp_gnumach))
_FP.hurd    = $(or $(__fp_hurd),$(eval __fp_hurd := $(call _git_fp,$(HURD_SRC)))$(__fp_hurd))
# IN-TREE goals carry an ENV fingerprint: the scoped repo fp ONLY (recipes +
# the dev-shell/toolchain eval surface).  Module srcs deliberately stay on the
# fast mtime path - a .c edit must rebuild INCREMENTALLY, never trigger the
# env-change clean below.  On env-fp mismatch the configure rules WIPE the
# build dir first: artifacts compiled under a superseded env can't be trusted
# and make's mtimes can't see flag changes (the 2026-06-12 naked-install
# scatter; the long-deferred config-fingerprint sentinel).
_ENV_GOALS := gnumach hurd mig gnumach-headers hurd-headers dist-gnumach-tree dist-hurd-tree
_FP_GOALS  := $(_OVR_GOALS) $(_ENV_GOALS)
# $(call _goal_fp,GOAL): the goal's full fingerprint - scoped repo, the build-rev
# token for the version-bearing goals, + each opted-in dep module.
_goal_fp = repo=$(_FP_REPO)$(if $(filter $(1),$(_REV_GOALS)), rev=$(_BUILD_REV))$(foreach d,$(_DEPS.$(1)),$(if $($(_FLAG.$(d))), $(d)=$(_FP.$(d))))
# $(call _fp_of,GOAL): the fingerprint a goal records - env-only for in-tree
# goals, the full composition for the override-resolving nix halves.
_fp_of = $(if $(filter $(1),$(_ENV_GOALS)),repo=$(_FP_REPO),$(call _goal_fp,$(1)))
# $(call _fp_stale,GOAL): non-empty iff GOAL has been built (its stamp exists) and
# its recorded fingerprint differs.  A missing STAMP is deliberately not fp-stale:
# make builds a missing target when requested anyway, and a never-built sibling
# must not permanently _FORCE the dist-gcc pattern rule.
_fp_stale = $(if $(filter $(1),$(_FP_GOALS)),$(shell if [ -e $(_MARK.$(1)) ]; then [ "$$(cat $(_MARK.$(1)).fp 2>/dev/null)" = "$(call _fp_of,$(1))" ] || echo $(1)-fp; fi))
# $(call _fp_write,GOAL): recipe tail - record the fingerprint the build used.
_fp_write = printf '%s' "$(call _fp_of,$(1))" > $(_MARK.$(1)).fp
# $(call _env_clean,GOAL,DIRS): configure-rule head - on env-fp mismatch wipe
# DIRS so the rebuild starts clean under the new env.
_env_clean = if [ -n "$(call _fp_stale,$(1))" ]; then echo "  ENV-CLEAN  $(1)"; rm -rf $(2); fi

# Dirtiness cascade (in-tree only).  $(call _src_is_dirty,MODULE) -> "1" if src/<m>
# has uncommitted TRACKED changes; $(call _chain_dirty,TARGET) -> non-empty if TARGET
# or any IN-TREE dep is dirty (a nix-served dep is pinned/committed, never dirty).
# Lazy (`=`) so git only runs when a recipe expands it.
_src_is_dirty = $(shell git -C $(SRC)/$(1) diff --quiet HEAD 2>/dev/null || echo 1)
_chain_dirty  = $(strip $(foreach d,$(_DEPS.$(1)),$(if $($(_FLAG.$(d))),$(call _src_is_dirty,$(d)))))

# $(call _nix_build,TARGET,ATTR): realize a nix package - the opted-out path for a
# module's `make <module>`, building the flake ATTR.  TARGET is the _DEPS key (drives
# the scoped overrides).  Shared by all four modules' ifndef stubs.
_nix_build = @echo "  NIX-BUILD       $(2)"; $(NIX_BUILD) $(call _overrides,$(1)) $(PROJ)\#$(2) --no-link

# $(call _farm_headers,DIR): symlink-farm DIR/include into the build sysroot (cp -rs,
# mirroring glibc.nix) - gcc keeps the logical $(SYSROOT)/include/... paths (symlink
# targets are longer), so an in-tree glibc bakes the same header paths whether the
# headers came from the in-tree stage or the nix *-headers package.
_farm_headers = mkdir -p $(SYSROOT)/include && cp -rsf $(1)/include/. $(SYSROOT)/include/

# $(call _farm_nix_headers,PKG,STAGE): like _farm_headers but for a nix *-headers
# package, whose $out is READ-ONLY.  An in-tree glibc/hurd installs its OWN headers
# OVER the farm; `install` writes THROUGH the farm symlinks, so they must point at
# WRITABLE files (symlinking straight to the store fails EACCES).  Stage PKG/include
# into the writable STAGE (cp -a preserves symlinks like mach/machine -> DWARF parity),
# make it writable, then farm from there.
_farm_nix_headers = rm -rf $(2); mkdir -p $(2); cp -a $(1)/include $(2)/; $(call _make_writable,$(2)); $(call _farm_headers,$(2))

# $(call _nix_version,DEPKEY,ATTR): resolve ATTR's composed version from nix into shell
# $ver, append `-dirty` when the in-tree chain has uncommitted src (nix can't see it -
# flake inputs lock the committed rev), then guard non-empty.  Guard LAST so the helper
# ends on a definite command; a trailing optional $(if) would leave `; ;` at the call site.
#
# buildRev splice: any `--override-input` unmatches the committed lock, so nix drops
# `self.shortRev` and buildRev falls to `unknown` (version ends `+build.gunknown`).
# buildRev is `self` metadata, independent of the source overrides - re-resolve it from a
# no-override eval and splice it in so the in-tree rev token equals the all-nix build's.
define _nix_version
ver=$$($(NIX_FLAKE) eval --raw $(call _overrides,$(1)) $(PROJ)\#$(2).version 2>/dev/null); \
$(if $(strip $(call _overrides,$(1))),btok=$$($(NIX_FLAKE) eval --raw $(PROJ)\#$(2).version 2>/dev/null | sed -n 's/.*+build\.\(.*\)$$/\1/p'); [ -n "$$btok" ] && ver=$$(printf %s "$$ver" | sed "s/+build\.gunknown$$/+build.$$btok/");) \
$(if $(call _chain_dirty,$(1)),ver=$$(printf %s "$$ver" | sed -E 's/(-g[0-9a-f]+)(\+|$$)/\1-dirty\2/');) \
[ -n "$$ver" ] || { echo "ERROR: cannot resolve nix $(2).version"; exit 1; }
endef

# The baked version's staleness sentinel.  The composed version embeds the REPO's
# buildRev (+ each module's -dirty flag), but the configure rules' prereqs only
# watch module files - so a repo commit (or a dirty-flag flip) left a STALE
# +build.<rev> baked in src/<m>/configure, diverging the in-tree build from nix
# (which re-evals self.rev on every change) in everything that embeds the version:
# version.texi, mach/hurd.info, the kernel banner, the version-printing servers.
# Write-if-changed at parse time; the configure rules depend on it.
_VERSION_FP := $(shell git rev-parse --short HEAD 2>/dev/null)$(shell git diff --quiet HEAD 2>/dev/null || echo .rdirty).m$(call _src_is_dirty,mig)g$(call _src_is_dirty,gnumach)h$(call _src_is_dirty,hurd)
VERSION_FP_STAMP := $(WORK)/version-fp
$(shell mkdir -p $(WORK) 2>/dev/null; [ "`cat $(VERSION_FP_STAMP) 2>/dev/null`" = "$(_VERSION_FP)" ] || printf %s "$(_VERSION_FP)" > $(VERSION_FP_STAMP))

# The real `+build.g<rev>` token for override-resolved nix builds.  Any
# `--override-input` unmatches the committed lock and nix drops BOTH self.shortRev
# and self.dirtyShortRev on a CLEAN tree, so the overridden builds baked
# `+build.gunknown` while everything else carried the real rev (the 32-combo
# matrix caught it).  Maintain the token (`<short>[-dirty]`, matching nix's
# dirtyShortRev shape) in a path-input dir and add it to every override set;
# composeVersion prefers it over self.  Write-if-changed: the content (not mtime)
# keys the nix path input.
_BUILD_REV := $(shell git rev-parse --short HEAD 2>/dev/null)$(shell git diff --quiet HEAD 2>/dev/null || echo -dirty)
BUILD_REV_DIR := $(WORK)/build-rev
$(shell mkdir -p $(BUILD_REV_DIR) 2>/dev/null; [ "`cat $(BUILD_REV_DIR)/rev 2>/dev/null`" = "$(_BUILD_REV)" ] || printf %s "$(_BUILD_REV)" > $(BUILD_REV_DIR)/rev)

# $(call _bake_version,DEPKEY,ATTR,SRCDIR): stamp the in-tree build with the SAME
# composed PACKAGE_VERSION the nix build bakes, so nix == in-tree byte-for-byte.
# autoconf has no configure-time version override (hard-set via AC_INIT/version.m4),
# so we sed the FRESHLY-GENERATED, untracked `configure` (this rule's own autoreconf
# output; tracked src is never touched).  Version (incl. -dirty for an uncommitted
# chain) comes from _nix_version, so nix and in-tree agree by reuse.
define _bake_version
	@$(call _nix_version,$(1),$(2)); \
	echo "  STAMP-VERSION   $(2) = $$ver"; \
	sed -E -i \
	  -e "s/^PACKAGE_VERSION=.*/PACKAGE_VERSION='$$ver'/" \
	  -e "s/^VERSION=.*/VERSION='$$ver'/" \
	  -e "s/^(PACKAGE_STRING='.*) [^ ']*'/\1 $$ver'/" \
	  $(3)/configure
endef


# Dist artefacts - real copies, so each file's mtime is the cp time and make's mtime
# arithmetic works (no stamp files, no /nix/store epoch-mtime trap).  MIG is NOT
# shipped in dist/: it's a host-arch native binary, mixing it with the target-arch
# kernel + headers makes no sense for a release.  Use `nix build .#mig-<arch>` or
# `make mig` for the wrapper.

# Sidekick helper VM artefacts (x86_64 Alpine, built via the root flake's `sidekick`
# output).  Used for ext2 module extraction (Gentoo/Guix) and grub-mkrescue ISO
# assembly (x86_64 inject mode).
SIDEKICK_KERNEL := $(SIDEKICK)/vmlinuz
SIDEKICK_INITRD := $(SIDEKICK)/initramfs.cpio.gz
SIDEKICK_STAMP  := $(SIDEKICK)/.stamp

# Hurd distro image URLs live in flakes/run/lib/distro-urls.sh (shared with the
# `nix run` apps).  The `run:` recipe sources it inline so dispatch.sh sees them via
# the environment - not read into make variables.

# ---- Help (always-on) ----
.PHONY: help
help:
	@echo "Targets (for ARCH=$(ARCH)):"
	@echo "  all              build the kernel + Hurd userland in-tree (default; = gnumach + hurd)"
	@echo "  gnumach          build the gnumach kernel - in-tree under ./work/gnumach/$(ARCH)/"
	@echo "                   if opted in (make src-gnumach), else the nix kernel"
	@echo "  dist-gnumach     install the kernel into ./dist/$(ARCH)/ - the in-tree build if"
	@echo "                   opted in (make src-gnumach), else the nix kernel"
	@echo "  dist             install kernel + Hurd userland + glibc + libgcc + tzdata"
	@echo "                   into ./dist/$(ARCH)/ (= dist-gnumach + dist-hurd + dist-glibc +"
	@echo "                   dist-gcc-libgcc + dist-tzdata; mig is host-arch, not bundled)"
	@echo "  hurd             build the Hurd userland - in-tree under ./work/hurd/$(_TC_ARCH)/"
	@echo "                   if opted in (make src-hurd), else the nix userland"
	@echo "  dist-hurd        install the Hurd userland into ./dist/$(ARCH)/ - the in-tree build"
	@echo "                   if opted in (make src-hurd), else the nix userland"
	@echo "  mig              build MIG in-tree - opt-in for iterating on MIG (run 'make src-mig' first;"
	@echo "                   otherwise a no-op, MIG is always available)"
	@echo "  glibc            realize the nix glibc (nix-only; version = the glibc-src input"
	@echo "                   in flake.nix, patches in flakes/cross-toolchain/glibc.nix)"
	@echo "  dist-glibc       install the nix deployable glibc into ./dist/$(ARCH)/"
	@echo "  dist-gcc-<lib>   install ONE gcc runtime lib into ./dist/$(ARCH)/lib"
	@echo "                   (libgcc, libstdc++, libatomic, libitm, libquadmath,"
	@echo "                   libssp, libgomp).  'make dist' ships only libgcc; opt the"
	@echo "                   rest in per-target or via DIST_GCC_LIBS=\"libstdc++ ...\""
	@echo "  dist-tzdata      install the IANA timezone db (zoneinfo) into ./dist/$(ARCH)/share"
	@echo "  check            run the kernel test suite (== check-gnumach)"
	@echo "  check-gnumach    run gnumach's 'make check' (kernel tests under QEMU)"
	@echo "  run              boot the built kernel in qemu (SCENARIO=boot by default)"
	@echo "  run-help         show all 'make run' options (ARCH/SCENARIO/RUN_*)"
	@echo "  sidekick         build the helper VM (x86_64 Debian-tool dispatcher;"
	@echo "                   ABI gate + Hurd run scenarios)"
	@echo "  push-cache       push the $(ARCH) build environment to the shared binary cache"
	@echo "  src              populate/reconcile src/ working clones from the pinned source revisions"
	@echo "  src-<name>       same, for ONE source only (e.g. 'make src-gnumach')"
	@echo "  show-src-pins    print the current source pins (the revisions the build uses)"
	@echo "  lint-reuse       REUSE license-compliance check (SPDX headers + LICENSES/ + REUSE.toml)"
	@echo "  pin-src          bump the pinned source revs to their forks' branch HEADs (verbose)"
	@echo "  pin-src-<name>   same, for ONE source only (e.g. 'make pin-src-mig')"
	@echo "  rebaseline-ref   re-resolve the frozen reference-source pins"
	@echo "                   (new gcc ABI baseline; ~25min)"
	@echo "  clean            per-subdir 'make clean' - preserves configure state"
	@echo "  clean-dist       rm -rf dist/$(ARCH)/ (just this target)"
	@echo "  mrproper         rm -rf work/ + .sidekick/ + all dist/ + cached build links"
	@if [ -z "$(NIX)" ]; then \
	  echo ""; \
	  echo "Warning: nix is not installed. Targets require it."; \
	  echo "Install from: $(NIX_INSTALL_URL)"; \
	fi

# ---- Clean targets (always-on, no toolchain needed) ----
.PHONY: clean clean-dist mrproper
# `clean` invokes each work subdir's own `make clean` - removes object files while
# preserving config.status + autoconf setup, so the next `make` skips ./configure.
# $(MAKE) is whatever's in scope (macOS 3.81 / GNU 4.x); both handle `make clean`.
clean:
	@# The CURRENT variant's gnumach build (MULTI_HOST_BUILDS/ALT_BUILD-scoped);
	@# `mrproper` nukes every variant.
	@if [ -f $(GNUMACH_BUILD)/Makefile ]; then \
	  echo "  CLEAN  $(GNUMACH_BUILD)"; \
	  $(MAKE) --no-print-directory -C $(GNUMACH_BUILD) clean; \
	fi
	@# gnumach's `make clean` is effectively `mostlyclean` - it leaves the kernel
	@# image.  Remove the artefacts sentinel tracking depends on so the next `make`
	@# detects "needs rebuild".
	@rm -f $(GNUMACH_BUILD)/gnumach.elf $(GNUMACH_BUILD)/gnumach
	@# MIG, gnumach-headers, dist-gnumach kernel are nix-built; clean their
	@# gc-roots so the next build re-pulls them from the store.
	@rm -f $(FLAKES)/mig/result-* $(FLAKES)/gnumach-headers/result-* $(FLAKES)/gnumach/result-*

clean-dist:
	@# dist/ may hold read-only trees copied from /nix/store (e.g. dist-glibc);
	@# rm can't unlink inside a read-only dir, so make the tree writable first.
	@$(call _make_writable,$(DIST))
	rm -rf $(DIST)
	@# the dist-*-nix / dist-gcc-<lib> store-path stamps live under work/ (survive this
	@# rm); drop them too, else their "already shipped" record makes a later `make
	@# dist` skip re-populating the freshly-cleaned tree.
	rm -f $(DIST_GLIBC_STAMP) $(DIST_GNUMACH_NIX_STAMP) $(DIST_HURD_NIX_STAMP) $(DIST_GLIBC_STAMP).fp $(DIST_GNUMACH_NIX_STAMP).fp $(DIST_HURD_NIX_STAMP).fp
	rm -f $(DIST_GCC_STAMP_DIR)/*.stamp $(DIST_GCC_STAMP_DIR)/*.fp

# mrproper nukes work/ wholesale - a deeper reset including configure state.
# flakes/ holds tracked sources, so scrub only its gitignored result-* gc-roots,
# and drop $(SIDEKICK) wholesale.
mrproper:
	rm -rf $(WORK)
	rm -rf $(SIDEKICK)
	rm -f  $(FLAKES)/gnumach-headers/result-* $(FLAKES)/mig/result-* $(FLAKES)/gnumach/result-* $(FLAKES)/hurd/result-*
	@# dist/ may hold read-only /nix/store copies (dist-glibc); chmod so rm can
	@# unlink inside them (a read-only dir blocks removal of its entries).
	@$(call _make_writable,$(DIST_ROOT))
	rm -rf $(DIST_ROOT)
	@# git clean each working src clone, guarded by `-d .git`: the opt-in clones
	@# (src/mig) may be absent, and a bare `git -C` on a missing dir
	@# would abort mrproper.
	@for s in $(GNUMACH_SRC) $(MIG_SRC) $(HURD_SRC); do \
	  if [ -d "$$s/.git" ]; then echo "  CLEAN  $$s"; git -C "$$s" clean -fdX; fi; \
	done

# ---- sidekick (always-on, arch-independent) ----
# Builds the x86_64 Alpine helper VM for operations darwin can't do natively - ext2
# module extraction (Gentoo/Guix) and grub-mkrescue ISO assembly (x86_64 inject mode).
# Output is identical on every build host (prebuilt Alpine APKs, no cross-compile),
# so the initramfs is byte-identical.
#
# One recipe produces both SIDEKICK_KERNEL and SIDEKICK_INITRD.  Make 3.81 lacks
# grouped targets (`&:`, Make 4.3+), so listing both would race under `-j`; a single
# stamp target avoids that.
.PHONY: sidekick
sidekick: $(SIDEKICK_STAMP)

$(SIDEKICK_STAMP): flakes/sidekick/default.nix flakes/sidekick/packages.nix flakes/sidekick/debian-packages.nix flakes/sidekick/dispatcher.sh
	@mkdir -p $(dir $(SIDEKICK_KERNEL))
	@echo "  SIDEKICK  building helper VM (Debian userland + Alpine linux-virt kernel, generic dispatcher)..."
	$(NIX_BUILD) .#sidekick \
	  -o $(SIDEKICK)/result
	cp -f $(SIDEKICK)/result/vmlinuz             $(SIDEKICK_KERNEL)
	cp -f $(SIDEKICK)/result/initramfs.cpio.gz   $(SIDEKICK_INITRD)
	@touch $@

# Empty rule: the artefacts exist because the stamp recipe produced them - lets a
# dependency on the artefact paths be satisfied without re-running the build.
$(SIDEKICK_KERNEL) $(SIDEKICK_INITRD): $(SIDEKICK_STAMP) ;

# ---- push-cache (always-on, arch-independent) ----
# Push the FULL BUILD CLOSURE of the current ARCH's toolchain + dev shell to cachix -
# every intermediate derivation output, not just runtime refs.  Two roots, walked
# with `nix-store --requisites --include-outputs`, then .drv filtered:
#   toolchain-<arch>                          the wrapped cross-cc; its build graph
#       already contains the whole bootstrap chain, so this one root caches every
#       bootstrap piece (a fresh machine then PULLS the heavy seed compilers).
#   devShells.<sys>.<arch>.inputDerivation    the host build tools the shell adds
#       (the shell's own outPath is never realised, so its inputDerivation is the
#       buildable stand-in).
# `cachix push` skips already-cached paths, so re-pushes are cheap.  Mirrors a fresh
# CI build, keeping local + CI caches consistent.  Single-target (use ARCH=...).
# Requires `cachix authtoken <token>` once per host.  Top level - no dispatch.
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

# ---- src (always-on, arch-independent) ----
# Populate / reconcile the src/<name> working clones from the nix source pins
# (.#srcs, from flake.lock): adds the pinned remote without clobbering others, checks
# out the rev nix builds, refuses if a tree is dirty.  `SRCS_DRY_RUN=1 make src`
# previews the git commands.  Top level - no dispatch.
.PHONY: src
src:
	@bash flakes/sources/sync.sh

# ---- pin-src (always-on, arch-independent) ----
# Bump the pinned source revs to their tracked refs' HEAD, then print a before->after
# summary (so the rev change is visible in stdout/PRs, not buried in flake.lock).
# Auto-discovers inputs from `.#srcs`.  Run `make src` afterwards.
.PHONY: pin-src
pin-src:
	@bash flakes/sources/pin.sh

# ---- show-src-pins (always-on, arch-independent) ----
# Print the current source pins (from `.#srcs`), one tabular line per source -
# read-only, no network.
.PHONY: show-src-pins
show-src-pins:
	@bash flakes/sources/show-pins.sh

# ---- lint-reuse (always-on, arch-independent) ----
# REUSE license-compliance check (per-file SPDX headers + LICENSES/ +
# REUSE.toml) - the same gate the `REUSE lint` CI workflow runs.  Top level,
# no dispatch: licensing is arch-independent, so it runs reuse straight from
# nixpkgs rather than entering a per-arch dev shell.
.PHONY: lint-reuse
lint-reuse:
	@$(NIX_FLAKE) run nixpkgs#reuse -- lint

# ---- per-source src / pin-src (always-on, arch-independent) ----
# Per-source counterparts to src/pin-src.  The source name passes through to the
# same scripts, which validate it against .#srcs and abort on an unknown name - so a
# new *-src input gets its targets for free (no hardcoded list).
#
# `src-<name>` is gated by a sentinel against flake.lock: the pin it reconciles to is
# derived from flake.lock, so a sync is only needed when flake.lock moved (e.g. after
# `make pin-src-<name>`).  The stamp lives under work/, never src/ (which it would
# dirty).  Removing it (or `make mrproper`) forces a re-sync; `make src` stays
# unconditional.  (pin-src-<name> mutates flake.lock, so it is never gated.)
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
# Without src/mig, mig comes from the dev shell ($MIG) - `make mig` realizes the nix
# package here (no dispatch).  `make src-mig` flips MIG_IN_TREE on and the in-tree
# build (dispatched rules below) takes over.
ifndef MIG_IN_TREE
.PHONY: mig
mig:
	$(call _nix_build,mig,mig-$(_TC_ARCH))
endif

# ---- glibc (nix-only; always-on, arch-independent) ----
# glibc comes from the toolchain (wrapped cc's sysroot); `make glibc` realizes the
# nix package - with the scoped overrides, so in-tree gnumach/hurd/mig changes
# rebuild it (RPC stubs).  No in-tree glibc build: version picking = the glibc-src
# input in flake.nix; patches live in flakes/cross-toolchain/glibc.nix.
.PHONY: glibc
glibc:
	$(call _nix_build,glibc,glibc-hurd-$(_TC_ARCH))

# ---- gnumach / hurd (opt-out: realize the nix package; always-on) ----
# Without src/<m> (or <M>_IN_TREE=0), `make gnumach`/`make hurd` build the nix
# package, matching mig/glibc; the dist-*-tree halves stay opt-in.  Top-level (not in
# the dispatched block) so they resolve when the goal is filtered out of _BUILD_GOALS.
# With src present, the in-tree builds below take over.
ifndef GNUMACH_IN_TREE
.PHONY: gnumach dist-gnumach-tree
gnumach:
	$(call _nix_build,gnumach,gnumach-$(ARCH))
dist-gnumach-tree:
	@echo "$@: opt-in - run 'make src-gnumach' for the in-tree kernel (dist-gnumach ships the nix kernel)."
endif

ifndef HURD_IN_TREE
.PHONY: hurd dist-hurd-tree
hurd:
	$(call _nix_build,hurd,hurd-$(_TC_ARCH))
dist-hurd-tree:
	@echo "$@: opt-in - run 'make src-hurd' for the in-tree userland (dist-hurd ships the nix hurd)."
endif

# ---- rebaseline-ref (always-on, arch-independent) ----
# The deliberate "the working ABI changed on purpose - accept it" action.
# Re-resolves the frozen reference pins (*-ref-src) to their current rev, so gcc
# rebuilds once against the new reference (~25 min) and the gate compares against it
# thereafter.  For a NEW release baseline, bump the tag in flake.nix first.
.PHONY: rebaseline-ref
rebaseline-ref:
	$(NIX_FLAKE) flake update glibc-ref-src gnumach-ref-src hurd-ref-src mig-ref-src

# `hurd` / `dist-hurd` recipes live in the inner-make branch below, alongside `mach` /
# `dist-gnumach` - _BUILD_GOALS dispatched through `nix develop`.  Defining them in the
# inner branch avoids colliding with the `$(_BUILD_GOALS): _dispatch` stub.

# ============================================================
# Categorize goals & decide whether to dispatch through nix.
# ============================================================

# Goals make will pursue (empty cmdline -> default to `all`).
_GOALS := $(or $(MAKECMDGOALS),all)

# Fail fast on a forced *_IN_TREE without its source.  The auto-detect only turns
# these on when src/<module> is present, so on + absent means a forced flag without
# `make src-<module>`.  $(error) here rather than deep in the dispatch, but ONLY when
# a goal needing that source is requested (so `make help MIG_IN_TREE=1` is fine).
# Covers the DEPENDENCY case too (hurd with MIG_IN_TREE=1 but no src/mig):
# _NEEDS_<M>_SRC = every goal whose _DEPS contains <m>, derived from the same graph
# that scopes the overrides - so no drift.
_DEP_GOALS := mig gnumach dist-gnumach dist-gnumach-tree dist-gnumach-nix gnumach-headers \
              hurd-headers hurd dist-hurd dist-hurd-tree dist-hurd-nix \
              glibc dist-glibc dist all \
              $(addprefix dist-gcc-,$(_GCC_RT_LIBS))
_needs = $(strip $(foreach g,$(_DEP_GOALS),$(if $(filter $(1),$(_DEPS.$(g))),$(g))))
_NEEDS_GNUMACH_SRC := $(call _needs,gnumach)
_NEEDS_MIG_SRC     := $(call _needs,mig)
_NEEDS_HURD_SRC    := $(call _needs,hurd)
define _need_src
ifeq ($$(wildcard $(2)/.git),)
ifneq ($$(filter $(3),$$(_GOALS)),)
$$(error $(1) is set but its in-tree source is missing at src/$(4) - run `make src-$(4)` first, or set $(1)=0 to use the $(5))
endif
endif
endef
ifdef MIG_IN_TREE
$(eval $(call _need_src,MIG_IN_TREE,$(MIG_SRC),$(_NEEDS_MIG_SRC),mig,dev-shell mig))
endif
ifdef GNUMACH_IN_TREE
$(eval $(call _need_src,GNUMACH_IN_TREE,$(GNUMACH_SRC),$(_NEEDS_GNUMACH_SRC),gnumach,nix gnumach))
endif
ifdef HURD_IN_TREE
$(eval $(call _need_src,HURD_IN_TREE,$(HURD_SRC),$(_NEEDS_HURD_SRC),hurd,nix hurd))
endif

# Goals that need the cross-toolchain (NOT served by always-on rules).  `sidekick` is
# filtered so standalone `make sidekick` doesn't enter the dev shell (arch-independent
# build); pulled in as a `run` prereq it still runs inside.  `mig` is a build goal
# ONLY when src/mig opts in; otherwise filtered out (top-level no-op recipe, no
# dispatch) - like src/clean.
_BUILD_GOALS := $(filter-out clean clean-dist mrproper help sidekick push-cache src pin-src show-src-pins lint-reuse src-% pin-src-% glibc $(if $(MIG_IN_TREE),,mig) $(if $(GNUMACH_IN_TREE),,gnumach dist-gnumach-tree) $(if $(HURD_IN_TREE),,hurd dist-hurd-tree) rebaseline-ref,$(_GOALS))

# Per-goal staleness inputs for the dispatch gate (_stale recurses over them):
#   _MARK.<goal>   the completion marker - its stamp/output.  Existence is the
#                  sentinel; its mtime is the staleness baseline.
#   _WATCH.<goal>  the DIRECT src dirs the recipe reads.  Transitive src arrives via
#                  _SDEPS, NOT here (gnumach-headers watches src/gnumach; glibc reaches
#                  it by depending on gnumach-headers).
#   _SDEPS.<goal>  upstream GOALS - flag-gated: an in-tree module is a src-dependency,
#                  a nix module is a fixed external input (no edge).
# A goal is stale if its mark is missing, a watched file out-dates the mark, or any
# _SDEPS goal is stale.  A goal with neither _MARK nor _SDEPS is conservatively stale.
#
# CONTRACT: the gate watches the MARK, not every artifact beneath it - checking
# the whole build tree per run would forfeit the short-circuit.  Hand-deleting an
# individual artifact (a lib under work/hurd, an object dir) requires removing the
# goal's mark too (e.g. work/hurd/<arch>/.built) so the inner make gets a chance
# to re-derive it; `clean`/`mrproper` already do this for what they remove.

# Marks - build outputs (NOT epoch-normalised, unlike the shipped dist tree) + the
# dist work-side stamps.  GNUMACH_HDR_STAMP is the build-dir stamp, not the shared
# $(SYSROOT)/include/mach glibc later writes into.
_MARK.gnumach-headers   := $(GNUMACH_HDR_STAMP)
_MARK.hurd-headers      := $(HURD_HDR_STAMP)
_MARK.mig               := $(LOCAL_MIG)
_MARK.gnumach           := $(GNUMACH_KERNEL)
_MARK.hurd              := $(HURD_BUILD)/.built
_MARK.dist-gnumach-tree := $(DIST_GNUMACH_TREE_STAMP)
_MARK.dist-gnumach-nix  := $(DIST_GNUMACH_NIX_STAMP)
_MARK.dist-hurd-tree    := $(DIST_HURD_TREE_STAMP)
_MARK.dist-hurd-nix     := $(DIST_HURD_NIX_STAMP)
_MARK.dist-glibc        := $(DIST_GLIBC_STAMP)
$(foreach l,$(_GCC_RT_LIBS),$(eval _MARK.dist-gcc-$(l) := $(DIST_GCC_STAMP_DIR)/$(l)-$(_VARIANT)$(ARCH).stamp))
_MARK.dist-tzdata       := $(DIST_TZDATA_STAMP)

# Direct src watches (transitive src flows through _SDEPS).  The nix dist halves watch
# their flake + (via _intree_srcs) the src of every OPTED-IN module their overrides
# drag in - flag-gated, so a non-opt-in build never expects a clone.
_WATCH.gnumach-headers  := $(GNUMACH_SRC)
_WATCH.hurd-headers     := $(HURD_SRC)
_WATCH.mig              := $(MIG_SRC) flakes/mig
_WATCH.gnumach          := $(GNUMACH_SRC)
_WATCH.hurd             := $(HURD_SRC)
_WATCH.dist-gnumach-nix := flakes/gnumach $(call _intree_srcs,dist-gnumach-nix)
_WATCH.dist-hurd-nix    := flakes/hurd $(call _intree_srcs,dist-hurd-nix)
_WATCH.dist-glibc       := flakes/cross-toolchain $(call _intree_srcs,dist-glibc)
$(foreach l,$(_GCC_RT_LIBS),$(eval _WATCH.dist-gcc-$(l) := flakes/cross-toolchain $(call _intree_srcs,dist-gcc-$(l))))
# (dist-*-tree inherit src via _SDEPS; dist-tzdata's only input is the
# nixpkgs pin - flake.lock, the recipe's prereq - so a missing mark is its trigger.)

# Dep graph - flag-gated: $(if X_IN_TREE,...) drops the edge when the module is nix
# (the matching dist-*-nix half then watches the flake directly instead).
_SDEPS.mig               := gnumach-headers
_SDEPS.gnumach           := gnumach-headers $(if $(MIG_IN_TREE),mig)
_SDEPS.hurd              := hurd-headers gnumach-headers $(if $(MIG_IN_TREE),mig)
_SDEPS.dist-gnumach-tree := gnumach
_SDEPS.dist-hurd-tree    := hurd
_SDEPS.dist-gnumach      := $(if $(GNUMACH_IN_TREE),dist-gnumach-tree,dist-gnumach-nix)
_SDEPS.dist-hurd         := $(if $(HURD_IN_TREE),dist-hurd-tree,dist-hurd-nix)
_SDEPS.all               := gnumach hurd
_SDEPS.dist              := dist-gnumach dist-hurd dist-glibc dist-gcc-libgcc $(addprefix dist-gcc-,$(DIST_GCC_LIBS)) dist-tzdata

# `git ls-files` enumerates "real source" - generated files (configure, Makefile.in,
# autom4te.cache/, ...) shouldn't trigger staleness.  Authoritative: exactly what
# `git clean -fdX` would NOT touch.

# $(call _mark_missing,goal) - the mark's path if it doesn't exist, else empty.
_mark_missing = $(if $(wildcard $(_MARK.$(1))),,$(_MARK.$(1)))

# $(call _newer_tracked_one,ref,watch_dir) - first git-tracked file under watch_dir
# newer than `ref` (absolute path), else empty.  A missing `ref` makes every `-nt`
# true -> every watched file "newer" (so a missing mark also reads as stale).
_newer_tracked_one = $(shell \
  if [ -d $(2) ]; then \
    cd $(2) && git ls-files . 2>/dev/null | while IFS= read -r f; do \
      if [ "$$f" -nt "$(1)" ]; then echo "$(2)/$$f"; break; fi; \
    done; \
  fi)

# Any watched file newer than the goal's own mark.
_newer_tracked = $(strip $(foreach d,$(_WATCH.$(1)),$(call _newer_tracked_one,$(_MARK.$(1)),$(d))))

# $(call _stale,goal) - non-empty if `goal` needs rebuilding.  Recurses through
# _SDEPS (a DAG -> terminates): stale if its mark is missing, a watched file out-dates
# the mark, or any _SDEPS goal is stale.  Transitive src reaches a goal through its
# deps' own watches, so each src dir is compared against the nearest mark.  A goal
# with neither _MARK nor _SDEPS is conservatively stale (returns its own name).
_stale = $(strip \
  $(if $(_MARK.$(1))$(_SDEPS.$(1)), \
    $(call _fp_stale,$(1)) \
    $(if $(_MARK.$(1)),$(call _mark_missing,$(1)) $(call _newer_tracked,$(1))) \
    $(foreach d,$(_SDEPS.$(1)),$(call _stale,$(d))), \
    $(1)))

# Detect any unsatisfied build goal.
_UNSATISFIED :=
$(foreach g,$(_BUILD_GOALS),$(if $(call _stale,$(g)),$(eval _UNSATISFIED := yes)))

# A clean target alongside build goals forces a dispatch - the sentinels can't be
# trusted, clean is about to remove them.
ifneq ($(filter clean clean-dist mrproper,$(_GOALS)),)
ifneq ($(_BUILD_GOALS),)
_UNSATISFIED := yes
endif
endif

# Only enter dispatch/build logic if there are build goals to handle.
ifneq ($(_BUILD_GOALS),)

# ---- Short-circuit: everything satisfied (mtime-wise) ----
# Applies outside the shell (skips nix dispatch) AND inside it (skips the spurious
# inner-make spawn most final targets would trigger via PHONY siblings).
ifndef _UNSATISFIED
.DEFAULT_GOAL := $(firstword $(_BUILD_GOALS))
.PHONY: $(_BUILD_GOALS)
$(_BUILD_GOALS):
	@echo "make: Nothing to be done for '$@'."
_SHORTCIRCUIT := yes
endif

ifndef _SHORTCIRCUIT

# ---- Decide whether dispatch is needed ----
# Always dispatch through `nix develop -i` unless this make IS the dispatched inner
# make (_MAKE_INNER=1).  The isolated shell spawn costs ~200-500ms but ensures nothing
# from the caller's environment (direnv, host tools, stray exports) leaks into the build.
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

# Forward the parent make's flags to the inner make.  Can't use $(MAKEFLAGS): macOS's
# GNU Make 3.81 doesn't expose `-j` there at all.  So read the parent's argv via `ps`
# and filter option-like tokens (starting with `-`); goals + overrides pass separately.
_PARENT_ARGV  := $(shell ps -p $$PPID -o args= 2>/dev/null)
# Whitelist, not every dash token: the argv can contain option-like words that
# are NOT make flags (a -f from a wrapper script, terms of a compound command);
# forward only the flags worth propagating into the inner make.
_PARENT_FLAGS := $(filter -j -j% -k -l% -n -q -s -B,$(filter -%,$(_PARENT_ARGV)))

# Two things about the recipe below:
#   - bare `make` (not $(MAKE)) inside the shell resolves via PATH to the nix-provided
#     GNU Make 4.4+ (FIFO jobserver); $(MAKE) would bake in the OUTER make's path - on
#     macOS the 3.81 that doesn't understand modern -j.
#   - leading `+` marks the recipe recursive-make so GNU make honours -n/-q despite
#     the intermediate non-make commands.
# `nix develop -i` runs the inner shell with a clean (isolated) env, dropping any plain
# env var from the caller.  MAKEOVERRIDES only carries `NAME=val` set on the command
# line, not env vars, so env-form vars must each be forwarded explicitly.  ARCH survives
# (used at parse time + re-exported by the shellHook); everything else is listed below.
# A new env-read run-time knob must be added to _RUN_PASSTHROUGH or it vanishes for
# users who set it via env.

# Tiny make-isms to backslash-escape embedded spaces (so RUN_ARGS="-monitor none"
# survives as a single argv token into the inner make).
_NULL :=
_SP   := $(_NULL) $(_NULL)

# Persistent gc-root for the dispatched dev shell - pins the current ARCH's store
# closure so nix-store gc doesn't reclaim it between invocations.  One entry per
# ARCH+variant, so switching targets/hosts adds a sibling without invalidating the
# others or flip-flopping cross-host on a shared checkout.
_FLAKE_PROFILE := .gcroots/$(_VARIANT)$(ARCH)

_RUN_PASSTHROUGH := \
  SCENARIO=$(SCENARIO) \
  RUN_VANILLA=$(RUN_VANILLA) \
  RUN_ACCEL=$(RUN_ACCEL) \
  RUN_KEEP_OVERLAY=$(RUN_KEEP_OVERLAY) \
  RUN_REFRESH=$(RUN_REFRESH) \
  RUN_ARGS=$(subst $(_SP),\$(_SP),$(RUN_ARGS))

# Output / build-location overrides.  Same problem as above: the inner make runs under
# clean env with MAKEOVERRIDES dropped, so `make dist DIST=/foo` would revert to the
# inner default.  Forward the RESOLVED values (plain paths, no escaping hazards).
# Without an override these equal the inner `?=` defaults (no-op); with one, the
# override survives.  The whole DIST family is listed so an individual
# DIST_GNUMACH/HURD/GLIBC override also carries through.
_DIST_PASSTHROUGH := \
  DIST=$(DIST) \
  DIST_GNUMACH=$(DIST_GNUMACH) \
  DIST_HURD=$(DIST_HURD) \
  DIST_GLIBC=$(DIST_GLIBC) \
  DIST_GCC_LIBS="$(DIST_GCC_LIBS)" \
  ALT_BUILD=$(ALT_BUILD) \
  _HOST_SYSTEM=$(_HOST_SYSTEM) \
  MIG_IN_TREE=$(MIG_IN_TREE) \
  GNUMACH_IN_TREE=$(GNUMACH_IN_TREE) \
  HURD_IN_TREE=$(HURD_IN_TREE)
# _HOST_SYSTEM + ALT_BUILD: forward the variant infix's inputs so the inner make
# computes the SAME work/ paths.  Forwarding the RESOLVED _HOST_SYSTEM means the inner
# needn't re-run `nix eval` and can't disagree.  The *_IN_TREE flags: forward the
# resolved choice so an explicit force on/off (e.g. MIG_IN_TREE=0) survives, else the
# inner re-detects src/ and flips it back.

# Intentionally NOT forwarding $(MAKEOVERRIDES): (1) every user-facing knob is already
# in _RUN_PASSTHROUGH, and (2) MAKEOVERRIDES escapes embedded spaces with a backslash
# that survives shell tokenization but NOT make's $(filter-out), so the duplicate can't
# be dropped without splitting `RUN_ARGS=-monitor\ none` (the `none` would leak as a
# target).  A new cmdline-only knob goes in _RUN_PASSTHROUGH.

_dispatch:
	@mkdir -p $(dir $(_FLAKE_PROFILE))
	+@$(NIX_FLAKE) develop -i --profile "$(_FLAKE_PROFILE)" .#$(ARCH) \
	  --command make --no-print-directory _MAKE_INNER=1 $(_PARENT_FLAGS) \
	    $(_RUN_PASSTHROUGH) $(_DIST_PASSTHROUGH) $(_BUILD_GOALS)

$(_BUILD_GOALS): _dispatch
	@:

# No source auto-bootstrap: an absent src/<m> means "use the nix package", never an
# auto-clone.  Forcing <M>_IN_TREE=1 without the source fails fast via _need_src;
# `make src-<m>` clones on demand.
endif

else
# ============================================================
# In the right shell, build sentinels missing - run real build rules.
# ============================================================

# Driven by environment variables the Nix dev shell exports:
#   ARCH, GNUMACH_HOST, MIG_TARGET, CC, CXX, TARGET_CC, LD, AR, NM, RANLIB, STRIP, OBJCOPY
# (No CFLAGS: the shell exports none - the kernel takes autoconf's `-g -O2` +
# gnumach's `-ffreestanding -nostdlib`; `make hurd` passes its `-fcommon` at configure.)

# ---- Sanity: must be inside a target dev shell ----
REQUIRED_VARS := ARCH GNUMACH_HOST MIG MIG_TARGET CC

$(foreach v,$(REQUIRED_VARS), \
  $(if $($(v)),,$(error $(v) is not set. Enter a dev shell first: 'nix develop .#x86_64' (or .#x86_64-xen / .#i686 / .#i686-xen))))

.PHONY: all dist gnumach-headers hurd-headers mig glibc gnumach dist-gnumach dist-glibc \
        check check-gnumach run run-help

# Explicit default - `help` (above) would otherwise win the "first non-dot target" race.
.DEFAULT_GOAL := all

# ---- Default & top-level groupings ----
all: gnumach hurd

# Lockstep with _SDEPS.dist (above): the components must match both lists or the
# staleness gate and the recipe disagree (silent mis-ship).  No whole-tree post-step:
# each dist-* finalises only its slice via $(call _dist_finalize,...).
dist: dist-gnumach dist-hurd dist-glibc dist-gcc-libgcc $(addprefix dist-gcc-,$(DIST_GCC_LIBS)) dist-tzdata

# Serialize dist's components under `make -j` - they contend on a shared resource
# and otherwise corrupt each other:
#   - the dist tree: dist-glibc's `chmod -R u+w $(DIST)` walks the whole tree
#     while dist-gnumach/dist-hurd/dist-gcc-<lib> write into it.
# `.NOTPARALLEL: dist` serializes ONLY dist's immediate prerequisites; each component
# still builds internally with -j, and the individual `dist-*` targets get full
# parallelism on their own.  Needs GNU make 4.4 (inner make); the outer make never
# parses this rule (inner-only branch).
.NOTPARALLEL: dist

# $(call _tracked_files,<dir>) - every git-tracked file under <dir>, as absolute
# paths.  Used by mig/mach/glibc rules to list src as prereqs so a tracked-source edit
# triggers the in-tree rebuild.  `git ls-files` so generated files (.deps/,
# autom4te.cache/, ...) never cause spurious rebuilds; once a rule fires, automake's dep
# tracking handles the .c->.o decisions.  Defined here so the header-source lists below
# can use it.
_tracked_files = $(addprefix $(1)/,$(shell cd $(1) 2>/dev/null && git ls-files))

# Public-header SOURCES - prereqs of the header-install targets: every tracked .h/.defs
# across the WHOLE tree (simpler than mapping specific folders, stays correct if the
# layout shifts).  Editing any header re-runs install-data/install-headers (cheap,
# idempotent) and bumps the sysroot, so the in-tree mig + glibc rebuild; a .c edit
# never trips this.
_MACH_HDR_SRC := $(filter %.h %.defs,$(call _tracked_files,$(GNUMACH_SRC)))
_HURD_HDR_SRC := $(filter %.h %.defs,$(call _tracked_files,$(HURD_SRC)))

# `autoreconf -i` (no -f): install missing aux files and regenerate ONLY when inputs
# are newer than outputs, so `configure`'s mtime stays stable and the downstream
# ./configure chain doesn't fire spuriously (-fi would touch every output).  Run on
# demand.  (_bake_version then stamps the rich build-rev version into the
# freshly-generated configure, matching the nix artefacts.)
$(GNUMACH_SRC)/configure: $(GNUMACH_SRC)/configure.ac $(GNUMACH_SRC)/version.m4 $(VERSION_FP_STAMP)
	cd $(GNUMACH_SRC) && autoreconf -i
	$(call _bake_version,gnumach,gnumach-$(ARCH),$(GNUMACH_SRC))

# ---- gnumach-headers (private: populates the build sysroot for in-tree mig) ----
# Install the public Mach headers into the build-only sysroot via gnumach's `make
# install-data` into a staging prefix + `cp -rs` farm (see the recipe for why the
# symlink farm matters).  The in-tree mig's stable header dependency (must NOT be the
# dist tree - see SYSROOT).  Mirrors flakes/gnumach-headers: a separate build dir
# configured with a STUB USER_MIG=/bin/true so it can run BEFORE mig exists
# (install-data never invokes mig, so the stub satisfies AC_CHECK_PROG).
# Not in `make help` - internal (mig/glibc depend on the stamp); kept for debug.
gnumach-headers: $(GNUMACH_HDR_STAMP)

# No --enable-platform here (unlike the kernel): this sysroot is shared across a CPU's
# xen/non-xen variants, and the PUBLIC Mach headers are byte-identical regardless of
# platform (the flag selects kernel-internal code, not the RPC ABI), so the shared
# headers stay deterministic whichever variant builds first.
# $(call _headers_nix,tag,attr,stage,stamp): resolve the nix headers package, cp -rs
# farm it into <stage>, and stamp.
define _headers_nix
	@mkdir -p $(dir $(4)); \
	echo "  HEADERS-NIX  resolving nix $(2)..."; \
	set -e; \
	pkg=$$($(NIX_BUILD) $(call _overrides,$(1)) $(PROJ)\#$(2) --no-link --print-out-paths); \
	$(call _farm_nix_headers,$$pkg,$(3)); \
	touch $(4)
endef

ifdef GNUMACH_IN_TREE
$(GNUMACH_HDR_CONFIGURED): $(GNUMACH_SRC)/configure
	mkdir -p $(GNUMACH_HDR_BUILD)
	cd $(GNUMACH_HDR_BUILD) && \
	  USER_MIG=/bin/true \
	  $(GNUMACH_SRC)/configure --host=$(GNUMACH_HOST) --prefix=$(GNUMACH_HDR_STAGE)

# $(_MACH_HDR_SRC) is a real prereq, so editing any Mach header re-runs install-data
# (cheap + idempotent) and re-touches the stamp the in-tree mig + glibc depend on.
#
# install-data into a STAGING prefix, then symlink-farm into $(SYSROOT) with `cp -rs`
# - MIRRORING glibc.nix.  gnumach ships mach/machine -> i386 (symlink); gcc
# realpath-resolves it when glibc compiles against the sysroot.  With REAL files the
# realpath is the short in-sysroot mach/i386, so gcc bakes `mach/i386` into libc.so's
# DWARF; with `cp -rs` symlinks (to the longer staging path, like nix's point to the
# store) gcc keeps the logical `mach/machine` - so in-tree glibc bakes the SAME paths
# as nix.  -f makes it idempotent; glibc's own mach/* wrapper headers (distinct names)
# written here later are untouched.
$(GNUMACH_HDR_STAMP): $(GNUMACH_HDR_CONFIGURED) $(_MACH_HDR_SRC)
	rm -rf $(GNUMACH_HDR_STAGE)
	cd $(GNUMACH_HDR_BUILD) && $(MAKE) install-data
	$(call _farm_headers,$(GNUMACH_HDR_STAGE))
	@touch $(GNUMACH_HDR_STAMP)
else
# Opted out of the in-tree kernel: populate the build sysroot from the NIX
# gnumach-headers package (same cp -rs farm) so an in-tree glibc/mig still finds the
# Mach headers and bakes the same paths.
$(GNUMACH_HDR_STAMP): $(if $(call _fp_stale,gnumach-headers),_FORCE)
	$(call _headers_nix,gnumach-headers,gnumach-headers-$(ARCH),$(GNUMACH_HDR_STAGE),$(GNUMACH_HDR_STAMP))
	@$(call _fp_write,gnumach-headers)
endif

# ---- hurd-headers (private: the Hurd half of the in-tree glibc's sysroot) ----
# Install the Hurd public headers into the build-only sysroot via hurd's `make
# install-headers` - a pure file-copy walk, no cross compile; mig must be discoverable
# for AC_CHECK_TOOL but isn't invoked.  Sibling to gnumach-headers.  Not in `make help`
# - internal (glibc depends on the stamp).
hurd-headers: $(HURD_HDR_STAMP)

ifdef HURD_IN_TREE
$(HURD_HDR_CONFIGURED): $(HURD_SRC)/configure $(MIG)
	mkdir -p $(HURD_HDR_BUILD)
	cd $(HURD_HDR_BUILD) && \
	  $(HURD_SRC)/configure $(HURD_CONFIGURE_FLAGS) \
	    MIG=$(MIG) USER_MIG=$(MIG) --prefix=$(SYSROOT)

# $(_HURD_HDR_SRC) is a real prereq - editing any Hurd header re-runs
# install-headers and re-touches the stamp the in-tree glibc depends on.
# no_deps=t is REQUIRED (matches flakes/hurd-headers): it gates off hurd's
# dependency machinery (Makeconf: `ifneq ($(no_deps),t)`).  Without it,
# install-headers runs `directory-depend` across every subdir (generating .d files
# + mig stubs) which RACES under `make -j` and corrupts .d files (e.g. utils/msgids.d
# -> "missing separator").  With it, this is a pure header copy.
$(HURD_HDR_STAMP): $(HURD_HDR_CONFIGURED) $(_HURD_HDR_SRC)
	cd $(HURD_HDR_BUILD) && $(MAKE) install-headers prefix=$(SYSROOT) no_deps=t
	@touch $(HURD_HDR_STAMP)
else
# Opted out of the in-tree userland: populate the build sysroot from the NIX
# hurd-headers package (cp -rs farm).  Real-file vs cp -rs symlink is equivalent for
# glibc's DWARF here (no shorter symlink target like mach/machine to collapse).
$(HURD_HDR_STAMP): $(if $(call _fp_stale,hurd-headers),_FORCE)
	$(call _headers_nix,hurd-headers,hurd-headers-$(_TC_ARCH),$(HURD_HDR_STAGE),$(HURD_HDR_STAMP))
	@$(call _fp_write,hurd-headers)
endif

# ---- mig ----
# mig is opt-in in-tree.  With src/mig present, `make mig` builds it: autoreconf +
# configure + make install into $(MIG_INSTALL_DIR); the $(LOCAL_MIG) wrapper uses
# dirname-$0/../libexec, so its sibling migcom resolves under .../libexec/.  Re-running
# after a src/mig edit is incremental.  Without src/mig, mig is the dev shell's $MIG
# and `make mig` is the top-level no-op.
ifdef MIG_IN_TREE
mig: $(LOCAL_MIG)
endif

MIG_SRC_FILES := $(call _tracked_files,$(MIG_SRC))
# Defined here (before the hurd recipe that uses it) so it expands non-empty: a
# tracked src/hurd edit makes $(HURD_BUILD)/.built stale -> inner make re-runs.
HURD_SRC_FILES := $(call _tracked_files,$(HURD_SRC))
ifdef MIG_IN_TREE
$(LOCAL_MIG): $(MIG_SRC)/configure $(GNUMACH_HDR_STAMP) $(MIG_SRC_FILES) $(if $(call _fp_stale,mig),_FORCE)
	@$(call _env_clean,mig,$(MIG_BUILD) $(MIG_INSTALL_DIR))
	@mkdir -p $(MIG_BUILD)
	@# MIG is a *native* host tool - runs on the build host, emits portable
	@# .c/.h.  The dev-shell's $CC is the wrapped `<cpu>-gnu` cross cc, which
	@# fails configure's "can create executables" test on the host.  Override
	@# to the native pkgs.gcc; keep TARGET_CC (bootstrap-gcc, exported
	@# by the dev shell) for the cpu.symc compile.
	cd $(MIG_BUILD) && [ -f config.status ] || \
	  CC=gcc LD= AR= NM= RANLIB= STRIP= OBJCOPY= \
	  $(MIG_SRC)/configure \
	    --target=$(MIG_TARGET) \
	    --prefix=$(MIG_INSTALL_DIR) \
	    TARGET_CPPFLAGS="-I$(SYSROOT)/include"
	@# Scrub 0-byte cpu.* residue: mig's `gawk > cpu.symc` truncates the target
	@# before running gawk and upstream has no .DELETE_ON_ERROR, so a failed run
	@# leaves an empty file a resume would trust by mtime (empty cpu.h -> the
	@# global.c "undeclared identifier" wall).
	@find $(MIG_BUILD) -maxdepth 1 \( -name 'cpu.sym[co]' -o -name cpu.h \) -size 0 -delete 2>/dev/null || true
	cd $(MIG_BUILD) && $(MAKE) CC=gcc install
	@$(call _fp_write,mig)

$(MIG_SRC)/configure: $(MIG_SRC)/configure.ac $(VERSION_FP_STAMP)
	cd $(MIG_SRC) && autoreconf -i
	$(call _bake_version,mig,mig-$(_TC_ARCH),$(MIG_SRC))
endif


# ---- dist-glibc ----
# Ship the NIX-built deployable glibc into the dist tree (glibc is nix-only; the
# scoped overrides rebuild it from in-tree gnumach/hurd/mig srcs when opted in).  The
# nix glibc is configured --prefix=/ (deployPrefix), so its whole $out tree is
# ROOT-RELATIVE - a verbatim `cp -a` IS a deployable sysroot.  cp -a clones the
# store's read-only perms, so chmod -R u+w after.  NB: glibc's /bin helper SCRIPTS
# carry a nixpkgs-rewritten /nix/store bash shebang - a cosmetic leak in dev scripts
# only; the ELF tools are /-clean.  The gcc runtime ships via `dist-gcc-<lib>`.
# Store-path-stamped.
#
# share/info/dir: the nix glibc ships its OWN standalone dir, and a verbatim cp -a would
# clobber the dir dist-gnumach/dist-hurd already merged into.  So mirror `make install`:
# stash the accumulated dir across the copy, restore it (discarding glibc's standalone
# one), then install-info glibc's libc.info into it - keeping the "each package merges
# its own info" model + the texinfo-det.nix total-order sort.
.PHONY: dist-glibc
# $(call _stamp_skip,stamp,value,key): the store copy can be skipped - <stamp> already
# records <value> and the <key> output is present.  $(call _assert_file,path,name):
# fail the recipe if <path> is missing.  Shared by every dist store-copy below.
_stamp_skip  = [ "$$(cat $(1) 2>/dev/null)" = "$(2)" ] && [ -e $(3) ]
_assert_file = ls $(1) >/dev/null || { echo "ERROR: $(2) missing"; exit 1; }
# $(call _dist_done,stamp): record completion - the staleness baseline for a dist goal
# (its output is mtime-normalised by _dist_finalize, so it can't be the mark).  Touched
# on EVERY run, copy or skip, so a confirmed-current dist out-dates its src.
_dist_done   = mkdir -p $(dir $(1)) && touch $(1)
# $(call _dist_nix_copy,target,DEST,attr,STAMP,keyfile,infofile): resolve the nix
# package (with <target>'s scoped overrides), copy its tree into DEST (skip if the
# store path is unchanged), preserve share/info/dir, re-register <infofile>, stamp,
# assert <keyfile>.  Per-module post-checks + _dist_finalize go in the caller.
define _dist_nix_copy
	@mkdir -p $(dir $(2)/$(5)) $(dir $(4)); \
	echo "  DIST-NIX  resolving nix $(3)..."; \
	set -e; \
	pkg=$$($(NIX_BUILD) $(call _overrides,$(1)) $(PROJ)\#$(3) --no-link --print-out-paths); \
	if $(call _stamp_skip,$(4),$$pkg,$(2)/$(5)); then \
	  echo "  unchanged ($$(basename $$pkg)) - skip copy"; \
	else \
	  echo "  copying $$pkg -> $(2)"; \
	  acc=$$(mktemp); cp -a $(2)/share/info/dir "$$acc" 2>/dev/null || acc=; \
	  cp -a $$pkg/. $(2); \
	  $(call _make_writable,$(2)); \
	  if [ -n "$$acc" ]; then cp -a "$$acc" $(2)/share/info/dir; rm -f "$$acc"; else rm -f $(2)/share/info/dir; fi; \
	  [ -e $(2)/share/info/$(6) ] && install-info --quiet --info-dir=$(2)/share/info $(2)/share/info/$(6) || true; \
	  printf '%s' "$$pkg" > $(4); \
	fi; \
	$(call _fp_write,$(1)); \
	$(call _dist_done,$(4)); \
	$(call _assert_file,$(2)/$(5),$(5))
endef

dist-glibc: $(DIST_GLIBC_STAMP)

# No file prereqs: the scoped fingerprint covers the whole flake-eval surface
# (every file the old explicit prereq lists named, and more), so the _FORCE
# conditional is the single staleness source for the fp-covered stamp rules.
$(DIST_GLIBC_STAMP): $(if $(call _fp_stale,dist-glibc),_FORCE)
	$(call _dist_nix_copy,dist-glibc,$(DIST_GLIBC),glibc-hurd-$(_TC_ARCH),$(DIST_GLIBC_STAMP),lib/libc.so.0.3,libc.info)
	@grep -q libmachuser $(DIST_GLIBC)/lib/libc.so || { echo "ERROR: libc.so GROUP not augmented"; exit 1; }
	@$(call _dist_finalize,$(EPOCH_GLIBC))

# ---- dist-gcc-<lib> (per-lib gcc runtime) ----
# Ship ONE gcc target-runtime lib into the dist tree, from its own nix derivation
# (cross-gcc-rt-<lib>-<arch>, built against the WORKING glibc - see
# flakes/cross-toolchain/gcc-runtime.nix).  Copies the lib's shared objects in their
# native symlink layout (+ libstdc++'s *-gdb.py pretty-printer hook) and its own info
# docs (libgomp.info, ...); the compiler's gcc.info/man belong to a deployable-toolchain
# artifact, not the runtime dist.  The libs carry NO RUNPATH (NIX_DONT_SET_RPATH,
# matching Debian GNU/Hurd) and the nix outputs are byte-identical cross-host, so a
# plain copy + the deterministic install-info keep the dist reproducible.
# `make dist` pulls ONLY dist-gcc-libgcc by default - glibc dlopen()s libgcc_s for
# backtrace()/Hurd assert_backtrace (a DT_NEEDED scan misses it), so it MUST be present;
# the other libs ship when something needs them (opt-in: `make dist-gcc-<lib>` or
# DIST_GCC_LIBS).  Store-path-stamped.  Resolved via $(_TC_ARCH): a xen variant reuses
# its CPU sibling's runtime.
.PHONY: $(addprefix dist-gcc-,$(_GCC_RT_LIBS))
$(addprefix dist-gcc-,$(_GCC_RT_LIBS)): dist-gcc-%: $(DIST_GCC_STAMP_DIR)/%-$(_VARIANT)$(ARCH).stamp ;

# Conditional _FORCE: no $* in plain prereqs, so the pattern forces when ANY lib's
# fingerprint is stale (siblings then re-resolve too - cheap, and only when something
# actually changed); the recipe still scopes its overrides + fp write per-goal.
$(DIST_GCC_STAMP_DIR)/%-$(_VARIANT)$(ARCH).stamp: $(if $(strip $(foreach l,$(_GCC_RT_LIBS),$(call _fp_stale,dist-gcc-$(l)))),_FORCE)
	@mkdir -p $(DIST)/lib $(dir $@)
	@echo "  DIST-GCC     resolving nix cross-gcc-rt-$*-$(_TC_ARCH)..."
	@set -e; \
	out=$$($(NIX_BUILD) $(call _overrides,dist-gcc-$*) $(PROJ)\#cross-gcc-rt-$*-$(_TC_ARCH) --no-link --print-out-paths); \
	if $(call _stamp_skip,$@,$$out,$(DIST)/lib/$(_RT_SO.$*)); then \
	  echo "  unchanged - skip copy"; \
	else \
	  cp -a $$out/lib/*.so* $(DIST)/lib/; \
	  $(call _make_writable,$(DIST)/lib); \
	  echo "  copied $$(ls $$out/lib | grep -c '\.so') .so entries -> $(DIST)/lib"; \
	  if [ -d $$out/share/info ]; then \
	    mkdir -p $(DIST)/share/info; \
	    cp -L $$out/share/info/*.info* $(DIST)/share/info/ 2>/dev/null || true; \
	    $(call _make_writable,$(DIST)/share/info); \
	    for inf in $$out/share/info/*.info; do \
	      install-info --quiet --info-dir=$(DIST)/share/info \
	        "$(DIST)/share/info/$$(basename $$inf)" || true; \
	    done; \
	  fi; \
	  printf '%s' "$$out" > $@; \
	fi
	@$(call _fp_write,dist-gcc-$*)
	@$(call _dist_done,$@)
	@$(call _assert_file,$(DIST)/lib/$(_RT_SO.$*),$(_RT_SO.$*))
	@$(call _dist_finalize,$(EPOCH_NIXPKGS))

# ---- dist-tzdata ----
# Ship the IANA timezone database so glibc's TZ/localtime works (without it the target
# has only UTC).  Copied from the pinned nixpkgs `tzdata` - arch-independent,
# byte-identical cross-host (one package serves every target).  Lands in /share/zoneinfo
# (glibc's compiled TZDIR under our --datarootdir=/share deploy prefix); also drops a
# default /etc/localtime -> /share/zoneinfo/UTC.  Store-path-stamped.
.PHONY: dist-tzdata
dist-tzdata: $(DIST_TZDATA_STAMP)

$(DIST_TZDATA_STAMP): flake.lock
	@mkdir -p $(DIST)/share $(DIST)/etc $(dir $(DIST_TZDATA_STAMP))
	@echo "  DIST-TZDATA  resolving nix tzdata..."
	@set -e; \
	tz=$$($(NIX_BUILD) $(PROJ)\#tzdata^out --no-link --print-out-paths); \
	if $(call _stamp_skip,$(DIST_TZDATA_STAMP),$$tz,$(DIST)/share/zoneinfo/UTC); then \
	  echo "  unchanged ($$(basename $$tz)) - skip copy"; \
	else \
	  echo "  copying zoneinfo ($$(find $$tz/share/zoneinfo -type f | grep -c .) files) -> $(DIST)/share/zoneinfo"; \
	  rm -rf $(DIST)/share/zoneinfo; \
	  cp -a $$tz/share/zoneinfo $(DIST)/share/zoneinfo; \
	  ln -sfn /share/zoneinfo/UTC $(DIST)/etc/localtime; \
	  printf '%s' "$$tz" > $(DIST_TZDATA_STAMP); \
	fi
	@$(call _dist_done,$(DIST_TZDATA_STAMP))
	@$(call _assert_file,$(DIST)/share/zoneinfo/UTC,zoneinfo/UTC)
	@$(call _dist_finalize,$(EPOCH_NIXPKGS))

# ---- gnumach (opt-in in-tree; else the nix kernel) ----
# In-tree kernel build under $(GNUMACH_BUILD), using $(MIG) - the effective mig (nix
# mig, or the in-tree build under the mig opt-in).  USER_MIG/MIG point at it explicitly
# so gnumach's AC_CHECK_TOOL needn't discover it via PATH.  Incremental.  Without
# src/gnumach, `make gnumach` realizes the nix kernel (top-level).
ifdef GNUMACH_IN_TREE
gnumach: $(GNUMACH_KERNEL)

$(GNUMACH_CONFIGURED): $(GNUMACH_SRC)/configure $(MIG) $(if $(call _fp_stale,gnumach),_FORCE)
	@$(call _req_env,BASE_CFLAGS)
	@$(call _env_clean,gnumach,$(GNUMACH_BUILD))
	mkdir -p $(GNUMACH_BUILD)
	cd $(GNUMACH_BUILD) && \
	  USER_MIG=$(MIG) MIG=$(MIG) \
	  CFLAGS="$(BASE_CFLAGS) $(call _macro_prefix_map,$(GNUMACH_SRC))" \
	  $(GNUMACH_SRC)/configure --host=$(GNUMACH_HOST) --prefix=$(DIST_GNUMACH) \
	    $(if $(GNUMACH_PLATFORM),--enable-platform=$(GNUMACH_PLATFORM))

GNUMACH_SRC_FILES := $(call _tracked_files,$(GNUMACH_SRC))
# Map the build dir + source to canonicals (GNUMACH_CANON_*) so neither the variant
# infix nor the in-tree-vs-nix path delta leaks into DWARF - gnumach/default.nix maps
# to the SAME names -> in-tree==nix.  Pin mach.info's "last updated ..." to the source's
# commit date to match the nix build: this gnumach's mdate-sh IGNORES SOURCE_DATE_EPOCH
# despite its header comment - it reads the .texi FILE MTIME - so set that mtime
# directly (mtime only, git-invisible).  VERSION=<rich> overrides automake's $(VERSION)
# - which it hardcodes into the Makefile from the plain version.m4, out of reach of
# _bake_version's configure sed - so mach.info's "@set VERSION" is the rich version too.
# One inner-make invocation for BUILD and INSTALL: `make install` can RECOMPILE
# stale objects and REGENERATE mach.info, so it must carry the exact same
# determinism env as the build - a half-stale tree otherwise gets its rebuild
# at install time NAKED (raw DWARF paths, automake's plain VERSION and the
# build-date mdate in mach.info; seen on the 2026-06-12 linux matrix).
# automake generates the info set INTO SRCDIR (gitignored), so one naked regen
# poisons every later build on both hosts - the rm below forces a fresh regen
# under THIS invocation's env every time (makeinfo is ~seconds), making the
# shipped docs deterministic by construction instead of by mtime trust.
define _gnumach_make
	@$(call _req_env,GNUMACH_CANON_BUILD)
	@$(call _nix_version,gnumach,gnumach-$(ARCH)); \
	sde=$$(git -C $(GNUMACH_SRC) log -1 --format=%ct 2>/dev/null); \
	[ -n "$$sde" ] && touch -d @$$sde $(GNUMACH_SRC)/doc/*.texi; \
	rm -f $(GNUMACH_SRC)/doc/mach.info* $(GNUMACH_SRC)/doc/version.texi $(GNUMACH_SRC)/doc/stamp-vti; \
	cd $(GNUMACH_BUILD) && \
	  NIX_CFLAGS_COMPILE="$$NIX_CFLAGS_COMPILE $(call _det_maps,$(GNUMACH_BUILD),$(GNUMACH_SRC),$(GNUMACH_CANON_BUILD))" \
	  NIX_HARDENING_ENABLE= \
	  $(MAKE) VERSION="$$ver" $(1)
endef

$(GNUMACH_KERNEL): $(MIG) $(GNUMACH_CONFIGURED) $(GNUMACH_SRC_FILES)
	$(call _gnumach_make,)
	@$(call _fp_write,gnumach)

# In-tree install: `make install` the work/ build into $(DIST_GNUMACH); kernel under
# boot/ + share/ docs.  gnumach's install is plain (no setuid), no fakeroot.
dist-gnumach-tree: $(DIST_GNUMACH_TREE_STAMP)

# Stamp target, not the epoch-stamped dist kernel (mtime-normalised by _dist_finalize).
$(DIST_GNUMACH_TREE_STAMP): $(GNUMACH_KERNEL) $(if $(call _fp_stale,dist-gnumach-tree),_FORCE)
	$(call _gnumach_make,install prefix=$(DIST_GNUMACH))
	@$(call _assert_file,$(DIST_GNUMACH)/boot/gnumach,boot/gnumach)
	@$(call _fp_write,dist-gnumach-tree)
	@$(call _dist_finalize,$(EPOCH_GNUMACH))
	@$(call _dist_done,$@)
endif  # GNUMACH_IN_TREE - opted-out `gnumach`/`dist-gnumach-tree` stubs are top-level (above)

# ---- dist-gnumach ----
# Public target: dispatch in-tree-vs-nix like dist-glibc.
.PHONY: dist-gnumach dist-gnumach-tree dist-gnumach-nix
dist-gnumach: $(if $(GNUMACH_IN_TREE),dist-gnumach-tree,dist-gnumach-nix)

# Ship the NIX-built kernel into the dist tree (non-opt-in half).  Resolved per-$(ARCH)
# - the kernel is the ONLY per-ARCH package, so i686 vs i686-xen differ HERE and nowhere
# else.  Store-path-stamped; share/info/dir stashed/restored + merged (see dist-glibc).
dist-gnumach-nix: $(DIST_GNUMACH_NIX_STAMP)

$(DIST_GNUMACH_NIX_STAMP): $(if $(call _fp_stale,dist-gnumach-nix),_FORCE)
	$(call _dist_nix_copy,dist-gnumach-nix,$(DIST_GNUMACH),gnumach-$(ARCH),$(DIST_GNUMACH_NIX_STAMP),boot/gnumach,mach.info)
	@$(call _dist_finalize,$(EPOCH_GNUMACH))

# ---- hurd / dist-hurd ----
# `make hurd`      - in-tree incremental userland build (counterpart to `make mach`).
# `make dist-hurd` - `make install` that build into dist/$(ARCH).
#
# In-tree `make hurd` runs as plain `cd ... && make/configure` inside the dispatched
# per-arch dev shell.  The shell exports CC/binutils + HURD_CONFIGURE_FLAGS; the recipes
# add MIG=$(MIG) + CFLAGS=-fcommon at configure time (hurd predates gcc's -fno-common
# default; scoped here so the kernel never sees it).
.PHONY: hurd dist-hurd

# Unlike gnumach (a single-file sentinel), hurd produces many outputs and no single
# binary, so the sentinel is a build stamp ($(HURD_BUILD)/.built), touched after a
# successful compile.  With _MARK.hurd/_WATCH.hurd above, a no-op `make hurd`
# short-circuits unless a tracked src/hurd file is newer than the stamp; the
# $(HURD_SRC_FILES) prereq makes the inner make re-run on a real change.  Without
# src/hurd, `make hurd` realizes the nix userland (top-level).
ifdef HURD_IN_TREE
hurd: $(HURD_BUILD)/.built

# The in-tree userland links against the wrapped cc's nix glibc (glibc is nix-only;
# its headers/libs ride the toolchain's baked -isystem/-L).
# Same build/install env unification as _gnumach_make: hurd's `make install`
# relinks/recompiles stale pieces, so it carries the canon maps too.  $(1) =
# command wrapper (fakeroot for install), $(2) = extra goals/vars.
define _hurd_make
	@$(call _req_env,HURD_CANON_BUILD)
	cd $(HURD_BUILD) && \
	  NIX_CFLAGS_COMPILE="$$NIX_CFLAGS_COMPILE $(call _det_maps,$(HURD_BUILD),$(HURD_SRC),$(HURD_CANON_BUILD))" \
	  $(1) $(MAKE) MIG=$(MIG) USER_MIG=$(MIG) $(2)
endef

$(HURD_BUILD)/.built: $(MIG) $(HURD_CONFIGURED) $(HURD_SRC_FILES)
	$(call _hurd_make,,)
	@touch $(HURD_BUILD)/.built
	@$(call _fp_write,hurd)

# _bake_version stamps the SAME composed build-rev version the nix build bakes, so
# nix == in-tree; a dirty src/hurd additionally gets `-dirty` (nix can't see that).
$(HURD_SRC)/configure: $(HURD_SRC)/configure.ac $(VERSION_FP_STAMP)
	cd $(HURD_SRC) && autoreconf -i
	$(call _bake_version,hurd,hurd-$(_TC_ARCH),$(HURD_SRC))

$(HURD_CONFIGURED): $(MIG) $(HURD_SRC)/configure $(if $(call _fp_stale,hurd),_FORCE)
	@$(call _req_env,BASE_CFLAGS HURD_EXTRA_CFLAGS HURD_DEPLOY_FLAGS)
	@$(call _env_clean,hurd,$(HURD_BUILD))
	mkdir -p $(HURD_BUILD)
	cd $(HURD_BUILD) && \
	  $(HURD_SRC)/configure $(HURD_CONFIGURE_FLAGS) \
	    MIG=$(MIG) USER_MIG=$(MIG) \
	    CFLAGS="$(HURD_EXTRA_CFLAGS) $(BASE_CFLAGS) $(call _macro_prefix_map,$(HURD_SRC))" \
	    $(HURD_DEPLOY_FLAGS)

# In-tree install: `make install` the work/ userland into $(DIST_HURD) as a
# self-contained tree (the installable artefact, like dist-gnumach-tree).
dist-hurd-tree: $(DIST_HURD_TREE_STAMP)

# Configured --prefix=/ (root-relative baked paths - LIBEXECDIR=/libexec etc. so a
# deployed tree finds its own servers), staged via DESTDIR.  Under fakeroot: hurd
# installs some programs `-o root -m 4755` (setuid), which a non-root install can't do -
# fakeroot fakes the chown/setuid (cosmetic for a dev dist tree).  Keyed on the installed
# ext2fs translator (headline output, analog of boot/gnumach) so dist/ holds only install
# results, no completion stamp.  Stamp target, not the epoch-stamped ext2fs.
$(DIST_HURD_TREE_STAMP): $(HURD_BUILD)/.built $(if $(call _fp_stale,dist-hurd-tree),_FORCE)
	$(call _hurd_make,fakeroot,install DESTDIR=$(DIST_HURD))
	@# hurd's `make install` doesn't merge hurd.info into the shared Info dir, so
	@# add the Hurd entry explicitly (as dist-gnumach-tree does for mach.info and
	@# dist-hurd-nix for the nix path) or the merged index loses "* Hurd: (hurd)".
	@[ -e $(DIST_HURD)/share/info/hurd.info ] && install-info --quiet --info-dir=$(DIST_HURD)/share/info $(DIST_HURD)/share/info/hurd.info || true
	@$(call _fp_write,dist-hurd-tree)
	@$(call _dist_finalize,$(EPOCH_HURD))
	@$(call _assert_file,$(DIST_HURD)/hurd/ext2fs,hurd/ext2fs)
	@$(call _dist_done,$@)
endif  # HURD_IN_TREE - opted-out `hurd`/`dist-hurd-tree` stubs are top-level (above)

# ---- dist-hurd ----
# Public target: dispatch in-tree-vs-nix like dist-glibc.
.PHONY: dist-hurd dist-hurd-tree dist-hurd-nix
dist-hurd: $(if $(HURD_IN_TREE),dist-hurd-tree,dist-hurd-nix)

# Ship the NIX-built userland into the dist tree (non-opt-in half).  Resolved
# per-$(_TC_ARCH) - CPU-ABI-keyed, shared across xen/non-xen (i686 == i686-xen).
# Store-path-stamped; share/info/dir stashed/restored + hurd.info merged (see dist-glibc).
dist-hurd-nix: $(DIST_HURD_NIX_STAMP)

$(DIST_HURD_NIX_STAMP): $(if $(call _fp_stale,dist-hurd-nix),_FORCE)
	$(call _dist_nix_copy,dist-hurd-nix,$(DIST_HURD),hurd-$(_TC_ARCH),$(DIST_HURD_NIX_STAMP),hurd/ext2fs,hurd.info)
	@$(call _dist_finalize,$(EPOCH_HURD))

# ---- check ----
#   check-gnumach : gnumach's 'make check' - kernel tests run inside QEMU.  Upstream
#                wiring is i386/x86_64-multiboot; aarch64 may need plumbing in tests/.
#   check      : alias for check-gnumach.
# MIG's own test-suite has no make target - it runs inline via doCheck=true on every
# `nix build .#mig-<arch>`, transitively triggered by `make dist-gnumach`/`dist`.
# No _MARK/_SDEPS entries - a test suite isn't idempotent, always dispatch.

# Xen variants self-skip via gnumach's tests/Makefrag.am (`if !PLATFORM_xen`).
# Darwin can't host check-gnumach: the harness needs a real bootloader nixpkgs can't
# build on darwin.
#   - x86_64 / i686: grub-mkrescue / xorriso / mtools - grub2's meta.platforms is
#     linux-only; upstream GRUB doesn't compile cleanly on darwin.
#   - aarch64:       u-boot.bin + mkimage - ubootQemuAarch64 / ubootTools are
#     linux-only, and upstream u-boot's envtools/scripts_dtc collide with darwin's
#     <sys/types.h> (ino_t conflict).
# Fail early rather than dying mid-pipeline at `<tool>: command not found`.
ifeq ($(shell uname -s),Darwin)
check-gnumach:
	@echo "==> check-gnumach ($(ARCH)): ERROR - darwin host is not supported." >&2
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
# `make run ARCH=<arch> SCENARIO=<name>` - ad-hoc qemu launch against the built
# kernel.  SCENARIO selects what to do with it:
#   boot          bare kernel via qemu -kernel (all arches)
#   hurd-debian   Debian Hurd userland (x86_64/i686, direct-inject)
#   hurd-gentoo   Gentoo Hurd userland (x86_64/i686, hybrid-extract)
#   hurd-guix     Guix childhurd       (x86_64/i686, hybrid-extract)
# Modifier flags:
#   RUN_VANILLA=1       boot the distro's bundled kernel (Hurd only)
#   RUN_ACCEL=1         -accel hvf/kvm when host arch matches ARCH
#   RUN_KEEP_OVERLAY=1  reuse the per-run qcow2 overlay across runs
#   RUN_ARGS="..."      extra flags appended to qemu (e.g. "-s -S")
#
# Prereqs depend on (SCENARIO, RUN_VANILLA).  dispatch.sh rejects RUN_VANILLA=1 + boot
# upfront, so the only kernel-less case is RUN_VANILLA=1 + hurd-*.
#   gnumach    - all non-vanilla scenarios.
#   sidekick   - ANY hurd-* (regenerates the qcow2's grub.cfg for serial boot under
#                -nographic; non-vanilla also overlays our kernel).  Also boot +
#                ARCH=x86_64 (qemu's -kernel rejects 64-bit ELFs, D18; routes through
#                GRUB-on-ISO via mkiso).
# Cells (evaluated at parse time):
#   RUN_VANILLA=1 + hurd-*    -> sidekick      boot + i686/aarch64  -> gnumach
#   RUN_VANILLA=1 + boot      -> (rejected)    boot + x86_64        -> gnumach sidekick
#   non-vanilla hurd-*        -> gnumach sidekick
_RUN_PREREQS := \
  $(if $(filter 1,$(RUN_VANILLA)), \
    $(if $(filter hurd-debian hurd-gentoo hurd-guix,$(SCENARIO)),sidekick), \
    gnumach \
    $(if $(filter hurd-debian hurd-gentoo hurd-guix,$(SCENARIO)),sidekick, \
      $(if $(and $(filter x86_64,$(ARCH)),$(filter boot,$(SCENARIO))),sidekick)))

# Each run is NOT idempotent, so no _MARK entry - every invocation re-enters dispatch
# and re-checks `gnumach` (skipped if fresh).
run: $(_RUN_PREREQS)
	@set -a; . ./flakes/run/lib/distro-urls.sh; set +a; \
	 GNUMACH_KERNEL="$(GNUMACH_KERNEL)" \
	 ARCH="$(ARCH)" \
	 WORK="$(WORK)" \
	 RUN_VANILLA="$(RUN_VANILLA)" \
	 RUN_ACCEL="$(RUN_ACCEL)" \
	 RUN_KEEP_OVERLAY="$(RUN_KEEP_OVERLAY)" \
	 RUN_REFRESH="$(RUN_REFRESH)" \
	 SIDEKICK_KERNEL="$(SIDEKICK_KERNEL)" \
	 SIDEKICK_INITRD="$(SIDEKICK_INITRD)" \
	 ./flakes/run/dispatch.sh "$(SCENARIO)" $(RUN_ARGS)

# `run-help` has no prereqs - dispatch.sh handles --help before env validation, so
# it works from a clean checkout without a built kernel.
run-help:
	@./flakes/run/dispatch.sh --help

endif # NEED_DISPATCH

endif # _SHORTCIRCUIT

endif # _BUILD_GOALS not empty
