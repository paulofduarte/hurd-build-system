# SPDX-FileCopyrightText: 2026 Paulo Duarte <paulofernandobd@gmail.com>
# SPDX-License-Identifier: GPL-3.0-or-later
# `packages.<system>` and `apps.<system>` outputs (kernel, headers, mig,
# glibc-hurd, the cross-toolchain + the `nix run` apps).  The sidekick guest +
# run-script live in flake.nix (sidekick-guest / sidekick-run).
#
# Kept out of flake.nix so adding a sub-flake doesn't touch flake.nix /
# target-archs.nix and thus doesn't retrigger the toolchain-cache CI (which
# path-filters on those + flakes/cross-toolchain).
#
# The root threads only the flake-level values a sub-flake can't derive itself
# (nixpkgs, system, self, targets, crossToolchain, the `*-src` inputs); each
# sub-flake instantiates its own pkgs/lib and imports its own flakes/lib.

{
  nixpkgs, # branch-tracking: runtime/data only (the `nix run` apps' qemu, tzdata).
  nixpkgs-toolchain, # frozen: the whole toolchain + every cached build (incl. build tools).
  self,
  forAllSystems,
  targets,
  crossToolchain,
  buildRevToken ? null,
  gnumach-toolchain-src,
  mig-toolchain-src,
  hurd-toolchain-src,
  binutils-toolchain-src,
  gcc-toolchain-src,
  glibc-toolchain-src,
  zlib-dep-src,
  libpciaccess-dep-src,
  libacpica-dep-src,
  rumpkernel-src,
  gnumach-src,
  mig-src,
  hurd-src,
}:

let
  inherit (nixpkgs-toolchain) lib;
  # Fork-id metadata (owner/repo/ref) from the `*-src` inputs via flake.lock;
  # feeds the version string's fork field.  See flakes/sources.
  sourcesLib = import ./flakes/sources { inherit lib; };
  gnumachInfo = sourcesLib.info self "gnumach-toolchain-src" gnumach-toolchain-src;
  migInfo = sourcesLib.info self "mig-toolchain-src" mig-toolchain-src;
  hurdInfo = sourcesLib.info self "hurd-toolchain-src" hurd-toolchain-src;
  rumpkernelInfo = sourcesLib.info self "rumpkernel-src" rumpkernel-src;

  # Userland targets (those that get a full toolchain): the non-xen ones.
  # The xen variants are kernel-only.
  hurdTargets = lib.filterAttrs (_: t: (t.platform or null) != "xen") targets;
  # crossTarget (`<cpu>-gnu`) -> userland target name.  A xen variant shares
  # its CPU sibling's crossTarget, so it maps onto that sibling's toolchain.
  toolchainNameByCrossTarget = lib.listToAttrs (
    lib.mapAttrsToList (n: t: lib.nameValuePair t.crossTarget n) hurdTargets
  );
in
{
  packages = forAllSystems (
    system:
    let
      # The ALIAS-side headers (gnumach-headers, hurd-headers) read the overridable
      # *-dev-src aliases and build against the shared post-glibc `mig` defined far
      # below; the bootstrap-side instances further down read the frozen pins.
      # All input-addressed (CA was dropped project-wide - cachix can't serve the
      # realisations endpoint CA substitution needs).
      gnumachHeaders = import ./flakes/gnumach-headers {
        nixpkgs = nixpkgs-toolchain;
        inherit system targets;
        bootstrapGcc = bootstrapGccByName;
        # Post-glibc: run configure's cc-check against the CACHED cross-gcc, not the
        # uncached bootstrap-gcc seed - else these alias headers (a build input to mig,
        # gnumach, hurd, hurd-stubs, the dev shell and dist) drag bootstrap-gcc's ~1.2 GB
        # build into every one of those.  install-data compiles nothing, so the headers
        # are byte-identical either way; this only swaps the build-closure cc.
        # gnumachHeadersBootstrap (below) keeps the default bootstrap-gcc - it feeds
        # glibc, built before cross-gcc exists, so glibc's hash stays put.
        # crossGccByName is keyed by CPU name only (a xen variant shares its CPU
        # sibling's cross-gcc), so map crossTarget -> sibling name first, exactly as
        # bootstrapGccByName does for the default path.
        buildCC = _name: target: crossGccByName.${toolchainNameByCrossTarget.${target.crossTarget}};
        srcInput = gnumach-src;
        includeOnly = true;
      };
      hurdHeaders = import ./flakes/hurd-headers {
        nixpkgs = nixpkgs-toolchain;
        inherit
          system
          targets
          mig
          ;
        srcInput = hurd-src;
        inherit (hurdInfo) forkUrl;
        includeOnly = true;
      };
      # From-source cross binutils (stage 1 of the own toolchain), built from the
      # pinned release tarball.  Exposes `cross-binutils-<arch>`.
      ownBinutils = import ./flakes/cross-toolchain/binutils.nix {
        nixpkgs = nixpkgs-toolchain;
        inherit
          system
          targets
          binutils-toolchain-src
          ;
      };

      # From-source cross gcc (stage 2), built from the pinned release tarball,
      # unwrapped, against ownBinutils.  `.bootstrap` is the libc-free stage-1 cc
      # (`bootstrap-gcc-<arch>`); `mkFull` is the full compiler + merged target
      # runtime (`cross-gcc-<arch>`, assembled in crossGccByName below).
      ownGcc = import ./flakes/cross-toolchain/gcc.nix {
        nixpkgs = nixpkgs-toolchain;
        inherit
          system
          targets
          gcc-toolchain-src
          ownBinutils
          ;
      };

      # bootstrap-gcc keyed by EVERY target name (incl. the xen variants).
      # ownGcc.bootstrap only builds the non-xen names (one cc per crossTarget);
      # a xen variant shares its CPU sibling's crossTarget, so it reuses that
      # sibling's bootstrap-gcc.  gnumach-headers + mig map over ALL targets (a
      # xen kernel / codegen tool is a distinct platform=xen build but uses the
      # same cc), so they index THIS map - not ownGcc.bootstrap directly, which
      # has no xen keys.
      bootstrapGccByName = lib.listToAttrs (
        lib.mapAttrsToList (
          name: target:
          lib.nameValuePair "bootstrap-gcc-${name}"
            ownGcc.bootstrap."bootstrap-gcc-${toolchainNameByCrossTarget.${target.crossTarget}}"
        ) targets
      );

      # ----------------------------------------------------------------------
      # The toolchain chain: bootstrap-gcc -> bootstrap glibc -> cross-gcc ->
      # glibc.  The nolibc cc builds the bootstrap glibc directly (a nolibc gcc
      # builds glibc fine); cross-gcc binds the bootstrap glibc's ABI, not its
      # bytes, so the dist stays byte-identical with no separate complete-gcc
      # pass.  Bootstrap and shipped glibc share the same pins (the *-ref-src
      # twins are gone) - they differ only in which gcc builds them; the
      # stub-split (design doc phase 4) collapses them to one.
      # ----------------------------------------------------------------------

      # Bootstrap-side instances: the SAME pins, consumed via the pin inputs
      # (never the overridable aliases), feeding the bootstrap glibc and hence
      # cross-gcc.  Unoverridden they are drv-identical to the alias-side
      # instances above; an in-tree override moves ONLY the alias side.
      # Internal bindings - no exposed attrs (a no-override build of the plain
      # attr IS the pin side).
      gnumachHeadersBootstrap = import ./flakes/gnumach-headers {
        nixpkgs = nixpkgs-toolchain;
        inherit system targets;
        bootstrapGcc = bootstrapGccByName;
        srcInput = gnumach-toolchain-src;
        # Match the alias instance's includeOnly (line ~62): without it the pin
        # headers keep $out/share and the alias drops it, so the two chains diverge
        # by input hash and produce two byte-identical-but-distinct migs.  With it
        # they are genuinely drv-identical unoverridden, so the alias mig and the
        # bootstrap mig collapse to ONE store path.  Safe: glibc consumes only
        # gnumach-headers/include (never /share), and the alias chain already builds
        # the whole stub path against includeOnly headers.
        includeOnly = true;
      };
      bootstrapMig = import ./flakes/mig {
        nixpkgs = nixpkgs-toolchain;
        inherit system targets;
        bootstrapGcc = bootstrapGccByName;
        gnumachHeaders = gnumachHeadersBootstrap;
        srcInput = mig-toolchain-src;
        inherit (migInfo) forkUrl;
      };
      hurdHeadersBootstrap = import ./flakes/hurd-headers {
        nixpkgs = nixpkgs-toolchain;
        inherit system targets;
        mig = bootstrapMig;
        srcInput = hurd-toolchain-src;
        inherit (hurdInfo) forkUrl;
      };

      # THE single glibc (design doc phase 4): ONE derivation, built by
      # bootstrap-gcc against the PIN headers, serving as cross-gcc's libcCross,
      # the shipped libc, AND (via its `buildtree` output) the stub base that
      # hurd-stubs re-links from.  Binds pin headers -> never rebuilt on an in-tree
      # RPC hack (only hurd-stubs floats).  The installed glibc ships the PIN RPC
      # stub libs (libmachuser/libhurduser); hurd-stubs produces the FLOATING ones
      # that `make dist` overlays when in-tree RPC headers change.
      glibc = import ./flakes/cross-toolchain/glibc.nix {
        nixpkgs = nixpkgs-toolchain;
        inherit system targets;
        mig = bootstrapMig;
        gnumachHeaders = gnumachHeadersBootstrap;
        hurdHeaders = hurdHeadersBootstrap;
        binutils = ownBinutils;
        bootstrapGcc = ownGcc.bootstrap;
        srcInput = glibc-toolchain-src;
      };
      hurdStubs = import ./flakes/cross-toolchain/hurd-stubs.nix {
        nixpkgs = nixpkgs-toolchain;
        inherit
          system
          targets
          mig
          gnumachHeaders
          hurdHeaders
          ;
        binutils = ownBinutils;
        # The post-glibc cross-gcc - bootstrap-gcc is glibc-only; nothing downstream
        # (these stubs are overlaid into the dist by dist-glibc) may pull the seed.
        buildCC = name: _: crossGccByName.${name};
        base = glibc;
        srcInput = glibc-toolchain-src;
      };
      # IR-emitting variant (hurd-stubs-ir-<arch>) for the rpc-wire-drift gate: same
      # stub build, plus the stub TUs as one LLVM-IR module (all.ll) for the
      # wire-fact manifest.  Built only by the gate (pin-mig vs alias-mig); off by
      # default so the shipped hurd-stubs pays no harvest cost.
      hurdStubsIR = import ./flakes/cross-toolchain/hurd-stubs.nix {
        nixpkgs = nixpkgs-toolchain;
        inherit
          system
          targets
          mig
          gnumachHeaders
          hurdHeaders
          ;
        binutils = ownBinutils;
        buildCC = name: _: crossGccByName.${name};
        base = glibc;
        srcInput = glibc-toolchain-src;
        emitIR = true;
      };
      # The rpc-wire-drift gate's comparator (the wire-fact manifest tool, an LLVM-API
      # extractor) AND its clang-tidy lint, from one shared clang/LLVM env so the
      # compile flags live in a single place - see flakes/tools.  The Makefile gate
      # resolves `.tool`; `make lint-cpp` / CI build `.lint`.
      tools = import ./flakes/tools { pkgs = nixpkgs-toolchain.legacyPackages.${system}; };

      # From-source FINAL cross-gcc (stage 2c): c+c++, bound to glibc-hurd via
      # --with-sysroot, UNWRAPPED (no cc/bintools wrapper), with the full target
      # runtime MERGED in (libgcc + libstdc++/libatomic/...).  This is THE
      # `cross-gcc-<arch>` - the dev shell, the kernel, and the userland all build
      # with it; the dist ships its runtime libs (Makefile dist-gcc).
      crossGccByName = lib.mapAttrs (
        name: target: ownGcc.mkFull name target glibc."glibc-hurd-${name}"
      ) hurdTargets;
      crossGccFull = lib.mapAttrs' (
        name: _target: lib.nameValuePair "cross-gcc-${name}" crossGccByName.${name}
      ) hurdTargets;

      # The from-source toolchain a given target's gnumach kernel builds with:
      # { cc = cross-gcc-<arch>; binutils = cross-binutils-<arch>; } - both unwrapped,
      # added to the kernel build's PATH.  Xen variants reuse their CPU sibling's (same
      # `<cpu>-gnu` ABI - the kernel links -nostdlib, so the glibc sysroot is moot).
      toolchainFor =
        target:
        let
          n = toolchainNameByCrossTarget.${target.crossTarget};
        in
        {
          cc = crossGccByName.${n};
          binutils = ownBinutils."cross-binutils-${n}";
          # The glibc-hurd the cross-gcc bakes as --with-sysroot.  Consumers that
          # include glibc headers (hurd) map this IA path out of their DWARF.
          sysroot = glibc."glibc-hurd-${n}";
        };

      # THE mig everything downstream uses - built post-glibc with the from-source
      # cross-gcc (its --with-sysroot=glibc-hurd carries <string.h>) and doCheck=true,
      # so `make check` compiles+runs the generated stubs and every consumer is gated
      # on the mig tests by construction (no separate "checked" artifact, no marker).
      # Byte-identical to the bootstrap mig (migcom is native-host-cc, cpu.h
      # -ffreestanding in both), so a green check also proves the bootstrap mig that
      # built glibc is sound.  Overridable (mig-src) so `make src-mig` reaches the
      # whole post-glibc surface (dev shell, hurd-stubs, gnumach, hurd).  Per-
      # crossTarget; re-keyed to every target (incl. xen) just below.
      migChecked = import ./flakes/mig {
        nixpkgs = nixpkgs-toolchain;
        inherit
          system
          targets
          gnumachHeaders
          self
          buildRevToken
          ;
        bootstrapGcc = ownGcc.bootstrap; # unused when checkCC is set (CHECKED path)
        srcInput = mig-src;
        inherit (migInfo) forkUrl;
        checkCC = crossGccByName; # CHECKED -> full +build.g<rev> version tag
      };

      # THE consumer-facing `mig`: the per-crossTarget checked mig re-keyed to every
      # target name (xen reuses its CPU sibling's mig).  This is the `mig-<name>` the
      # dev shell, alias hurd-headers, hurd-stubs and the gnumach/hurd modules all
      # look up - one overridable, checked, post-glibc mig.  The bootstrap mig
      # (bootstrapMig, above) stays on the pre-glibc path: it builds glibc, where no
      # libc exists yet to run the tests.
      mig = lib.listToAttrs (
        lib.mapAttrsToList (
          name: target:
          lib.nameValuePair "mig-${name}" migChecked."mig-${toolchainNameByCrossTarget.${target.crossTarget}}"
        ) targets
      );

      # Public output only: the bootstrap mig under bootstrap-mig-<arch> (parallels
      # bootstrap-gcc-<arch>).  Its store path is already bootstrap-mig-...; consumers
      # (glibc, bootstrap hurd-headers) look it up by the uniform mig-<name> key so
      # glibc.nix stays generic, hence the re-key here purely to expose it without
      # clashing with the mig-<arch> outputs.
      bootstrapMigExposed = lib.mapAttrs' (n: v: lib.nameValuePair ("bootstrap-" + n) v) bootstrapMig;

      # GNU Mach kernel - built with the wrapped cross-cc (freestanding,
      # -nostdlib).  `toolchainFor` resolves each target onto its `toolchain-<arch>`.
      gnumach = import ./flakes/gnumach {
        nixpkgs = nixpkgs-toolchain;
        inherit
          system
          targets
          self
          toolchainFor
          buildRevToken
          ;
        inherit mig; # the one post-glibc, checked mig everything downstream shares
        # Work side (like migChecked's mig-src): the shipped kernel tracks the
        # overridable alias, so `make src-gnumach` reaches it and the in-tree==nix
        # matrix compares like-for-like.  The bootstrap twin (gnumachHeadersBootstrap)
        # stays on gnumach-toolchain-src to pin glibc's sysroot headers - no toolchain rebuild.
        srcInput = gnumach-src;
        inherit (gnumachInfo) forkUrl;
      };

      # Rump-stack target libraries (RUMP-STACK-FEASIBILITY round-2): cross
      # zlib (rumpdisk links -lz; libpciaccess reads gzip'd pci.ids) and
      # libpciaccess (pci-arbiter/acpi/rumpkernel dep, static too for the
      # .static boot servers).  Frozen tarball pins; per-userland-target.
      zlib = import ./flakes/zlib {
        nixpkgs = nixpkgs-toolchain;
        inherit system targets toolchainFor;
        srcInput = zlib-dep-src;
      };
      libpciaccess = import ./flakes/libpciaccess {
        nixpkgs = nixpkgs-toolchain;
        inherit
          system
          targets
          toolchainFor
          zlib
          ;
        srcInput = libpciaccess-dep-src;
      };
      # hurd's libirqhelp as a standalone lib-only pre-pass (Guix-style),
      # breaking the hurd <-> rumpkernel circular dep.  WORK pin (hurd-src),
      # like the full hurd build: only the glibc -> cross-gcc chain is frozen;
      # everything else tracks the work pins so in-tree hacking reaches its
      # consumers (rumpkernel, libacpica).  See flakes/libirqhelp.
      libirqhelp = import ./flakes/libirqhelp {
        nixpkgs = nixpkgs-toolchain;
        inherit
          system
          targets
          mig
          self
          toolchainFor
          buildRevToken
          ;
        srcInput = hurd-src;
        inherit (hurdInfo) forkUrl;
      };
      # Intel ACPICA as a library (Debian hurd-team repackaging) - the acpi
      # translator's backend + rumpdisk boot-chain dep.  Links our cross
      # libpciaccess + the libirqhelp pre-pass.  See flakes/libacpica.
      libacpica = import ./flakes/libacpica {
        nixpkgs = nixpkgs-toolchain;
        inherit
          system
          targets
          toolchainFor
          libpciaccess
          libirqhelp
          ;
        srcInput = libacpica-dep-src;
      };
      # NetBSD rumpkernel (WORK pin) - the librump* set hurd's rumpdisk/
      # rumpnet link.  Debian rules driven through NetBSD build.sh with the
      # Guix-proven cross deltas; consumes our cross mig + libpciaccess +
      # the libirqhelp pre-pass.  See flakes/rumpkernel.
      rumpkernel = import ./flakes/rumpkernel {
        nixpkgs = nixpkgs-toolchain;
        inherit
          system
          targets
          toolchainFor
          mig
          libpciaccess
          libirqhelp
          self
          buildRevToken
          ;
        srcInput = rumpkernel-src;
        inherit (rumpkernelInfo) forkUrl;
      };

      # The Hurd userland (core servers + libraries), built with the
      # wrapped toolchain + mig + the ABI-gated glibc-hurd sysroot.
      hurd = import ./flakes/hurd {
        nixpkgs = nixpkgs-toolchain;
        inherit
          system
          targets
          self
          buildRevToken
          toolchainFor
          ;
        inherit mig; # the one post-glibc, checked mig everything downstream shares
        # Work side (mirrors gnumach + migChecked): shipped userland tracks the alias
        # so `make src-hurd` reaches it and in-tree==nix compares like-for-like; the
        # bootstrap twin (hurdHeadersBootstrap) stays on hurd-toolchain-src for glibc's sysroot.
        srcInput = hurd-src;
        inherit (hurdInfo) forkUrl;
      };
    in
    gnumach
    // gnumachHeaders
    // mig # mig-<arch>: the one post-glibc, checked, overridable mig
    // hurdHeaders
    // hurd
    // zlib # zlib-<arch>: cross target zlib (rump-stack dep)
    // libpciaccess # libpciaccess-<arch>: pci-arbiter/acpi/rumpkernel dep
    // libirqhelp # libirqhelp-<arch>: hurd lib pre-pass (rumpkernel/libacpica dep)
    // libacpica # libacpica-<arch>: ACPICA library (acpi translator/rumpdisk chain dep)
    // rumpkernel # rumpkernel-<arch>: NetBSD librump* set (rumpdisk/rumpnet dep)
    // ownBinutils # cross-binutils-<arch>
    // ownGcc.bootstrap # bootstrap-gcc-<arch> (libc-free stage-1 cc)
    // glibc
    // hurdStubs
    // hurdStubsIR
    // {
      mig-wire-manifest = tools.manifest;
      mig-wire-manifest-tidy = tools.lint;
    }
    // crossGccFull # the merged from-source cross-gcc-<arch> (compiler + runtime)
    // bootstrapMigExposed # bootstrap-mig-<arch> (builds glibc only; not a downstream dep)
    # Timezone database for the dist (dist-tzdata copies its share/zoneinfo).
    # arch-independent zic-compiled data, byte-identical cross-host; one package
    # serves every target.
    // {
      tzdata = nixpkgs.legacyPackages.${system}.tzdata;
    }
  );

  apps = forAllSystems (
    system:
    import ./flakes/run {
      # Runtime launchers (qemu) - ride the branch nixpkgs so `nix flake update`
      # refreshes qemu without touching the cached kernel/toolchain (`packages`).
      inherit
        nixpkgs
        system
        targets
        crossToolchain
        ;
      packages = self.packages.${system};
    }
  );
}
