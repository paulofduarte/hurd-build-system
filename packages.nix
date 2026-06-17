# SPDX-FileCopyrightText: 2026 Paulo Duarte <paulofernandobd@gmail.com>
# SPDX-License-Identifier: GPL-3.0-or-later
# `packages.<system>` and `apps.<system>` outputs (kernel, headers, mig,
# glibc-hurd, the cross-toolchain, sidekick + the `nix run` apps).
#
# Kept out of flake.nix so adding a sub-flake doesn't touch flake.nix /
# target-archs.nix and thus doesn't retrigger the toolchain-cache CI (which
# path-filters on those + flakes/cross-toolchain).
#
# The root threads only the flake-level values a sub-flake can't derive itself
# (nixpkgs, system, self, targets, crossToolchain, the `*-src` inputs); each
# sub-flake instantiates its own pkgs/lib and imports its own flakes/lib.

{ nixpkgs, self, forAllSystems, targets, crossToolchain, buildRevToken ? null
, gnumach-src, mig-src, hurd-src, binutils-src, gcc-src, glibc-src
, gnumach-dev-src, mig-dev-src, hurd-dev-src }:

let
  inherit (nixpkgs) lib;
  # Fork-id metadata (owner/repo/ref) from the `*-src` inputs via flake.lock;
  # feeds the version string's fork field.  See flakes/sources.
  sourcesLib  = import ./flakes/sources { inherit lib; };
  gnumachInfo = sourcesLib.info self "gnumach-src" gnumach-src;
  migInfo     = sourcesLib.info self "mig-src" mig-src;
  hurdInfo    = sourcesLib.info self "hurd-src" hurd-src;

  # Userland targets (those that get a full toolchain): the non-xen ones.
  # The xen variants are kernel-only.
  hurdTargets = lib.filterAttrs (_: t: (t.platform or null) != "xen") targets;
  # crossTarget (`<cpu>-gnu`) -> userland target name.  A xen variant shares
  # its CPU sibling's crossTarget, so it maps onto that sibling's toolchain.
  toolchainNameByCrossTarget = lib.listToAttrs
    (lib.mapAttrsToList (n: t: lib.nameValuePair t.crossTarget n) hurdTargets);
in
{
  packages = forAllSystems (system:
    let
      # The ALIAS-side chain (headers, mig, glibc, ...) reads the overridable
      # *-dev-src aliases; the bootstrap-side instances below read the frozen pins.
      # All input-addressed (CA was dropped project-wide - cachix can't serve the
      # realisations endpoint CA substitution needs).
      gnumachHeaders = import ./flakes/gnumach-headers {
        inherit nixpkgs system targets;
        bootstrapGcc = bootstrapGccByName;
        srcInput = gnumach-dev-src;
        includeOnly = true;
      };
      mig = import ./flakes/mig {
        inherit nixpkgs system targets gnumachHeaders;
        bootstrapGcc = bootstrapGccByName;
        srcInput = mig-dev-src;
        forkUrl = migInfo.forkUrl;
      };
      hurdHeaders = import ./flakes/hurd-headers {
        inherit nixpkgs system targets mig;
        srcInput = hurd-dev-src;
        forkUrl = hurdInfo.forkUrl;
        includeOnly = true;
      };
      sidekick = import ./flakes/sidekick { inherit nixpkgs system; };

      # From-source cross binutils (stage 1 of the own toolchain), built from the
      # pinned release tarball.  Exposes `cross-binutils-<arch>`.
      ownBinutils = import ./flakes/cross-toolchain/binutils.nix {
        inherit nixpkgs system targets binutils-src;
      };

      # From-source cross gcc (stage 2), built from the pinned release tarball,
      # unwrapped, against ownBinutils.  `.bootstrap` is the libc-free stage-1 cc
      # (`bootstrap-gcc-<arch>`); `mkFull` is the full compiler + merged target
      # runtime (`cross-gcc-<arch>`, assembled in crossGccByName below).
      ownGcc = import ./flakes/cross-toolchain/gcc.nix {
        inherit nixpkgs system targets gcc-src ownBinutils;
      };

      # bootstrap-gcc keyed by EVERY target name (incl. the xen variants).
      # ownGcc.bootstrap only builds the non-xen names (one cc per crossTarget);
      # a xen variant shares its CPU sibling's crossTarget, so it reuses that
      # sibling's bootstrap-gcc.  gnumach-headers + mig map over ALL targets (a
      # xen kernel / codegen tool is a distinct platform=xen build but uses the
      # same cc), so they index THIS map - not ownGcc.bootstrap directly, which
      # has no xen keys.
      bootstrapGccByName = lib.listToAttrs (lib.mapAttrsToList (name: target:
        lib.nameValuePair "bootstrap-gcc-${name}"
          ownGcc.bootstrap."bootstrap-gcc-${toolchainNameByCrossTarget.${target.crossTarget}}")
        targets);

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
        inherit nixpkgs system targets;
        bootstrapGcc = bootstrapGccByName;
        srcInput = gnumach-src;
      };
      migBootstrap = import ./flakes/mig {
        inherit nixpkgs system targets;
        bootstrapGcc = bootstrapGccByName;
        gnumachHeaders = gnumachHeadersBootstrap;
        srcInput = mig-src;
        forkUrl = migInfo.forkUrl;
      };
      hurdHeadersBootstrap = import ./flakes/hurd-headers {
        inherit nixpkgs system targets;
        mig = migBootstrap;
        srcInput = hurd-src;
        forkUrl = hurdInfo.forkUrl;
      };

      # THE single glibc (design doc phase 4): ONE derivation, built by
      # bootstrap-gcc against the PIN headers, serving as cross-gcc's libcCross,
      # the shipped libc, AND (via buildTree) the stub base.  Binds pin headers
      # -> never rebuilt on an in-tree RPC hack (only hurd-stubs floats).
      # shipStubs=false: the RPC stub libs come from hurd-stubs, not glibc.
      glibc = import ./flakes/cross-toolchain/glibc.nix {
        inherit nixpkgs system targets;
        mig = migBootstrap;
        gnumachHeaders = gnumachHeadersBootstrap;
        hurdHeaders = hurdHeadersBootstrap;
        binutils = ownBinutils;
        bootstrapGcc = ownGcc.bootstrap;
        srcInput = glibc-src;
      };
      # The stub base: the SAME glibc build, shipping the build tree so hurd-stubs
      # can rebuild just the RPC stubs.  Same pin headers + bootstrap-gcc builder.
      glibcStubBase = import ./flakes/cross-toolchain/glibc.nix {
        inherit nixpkgs system targets;
        mig = migBootstrap;
        gnumachHeaders = gnumachHeadersBootstrap;
        hurdHeaders = hurdHeadersBootstrap;
        binutils = ownBinutils;
        bootstrapGcc = ownGcc.bootstrap;
        srcInput = glibc-src;
        buildTree = true;
      };
      hurdStubs = import ./flakes/cross-toolchain/hurd-stubs.nix {
        inherit nixpkgs system targets mig gnumachHeaders hurdHeaders;
        binutils = ownBinutils;
        bootstrapGcc = ownGcc.bootstrap;
        base = glibcStubBase;
      };
      # IR-emitting variant (hurd-stubs-ir-<arch>) for the rpc-wire-drift gate: same
      # stub build, plus the stub TUs as one LLVM-IR module (all.ll) for the
      # wire-fact manifest.  Built only by the gate (pin-mig vs alias-mig); off by
      # default so the shipped hurd-stubs pays no harvest cost.
      hurdStubsIR = import ./flakes/cross-toolchain/hurd-stubs.nix {
        inherit nixpkgs system targets mig gnumachHeaders hurdHeaders;
        binutils = ownBinutils;
        bootstrapGcc = ownGcc.bootstrap;
        base = glibcStubBase;
        emitIR = true;
      };
      # The rpc-wire-drift gate's comparator: the wire-fact manifest tool, an LLVM-API
      # extractor (robust GEP offsets, def-expression + memcpy facts) built against
      # the pin's default llvmPackages - the SAME LLVM that hurd-stubs' emitIR uses
      # to harvest the .ll, so emitter and reader always match.  One source of truth
      # (flakes/tools); the Makefile gate just resolves + calls it.
      migWireManifest = let p = nixpkgs.legacyPackages.${system}; in
        p.runCommand "mig-wire-manifest"
          { nativeBuildInputs = with p.llvmPackages; [ clang llvm.dev ]; }
          ''
            mkdir -p $out/bin
            clang++ $(llvm-config --cxxflags) ${./flakes/tools/mig-wire-manifest.cpp} \
              $(llvm-config --ldflags --libs irreader --system-libs) \
              -Wl,-rpath,$(llvm-config --libdir) \
              -o $out/bin/mig-wire-manifest
          '';

      # From-source FINAL cross-gcc (stage 2c): c+c++, bound to glibc-hurd via
      # --with-sysroot, UNWRAPPED (no cc/bintools wrapper), with the full target
      # runtime MERGED in (libgcc + libstdc++/libatomic/...).  This is THE
      # `cross-gcc-<arch>` - the dev shell, the kernel, and the userland all build
      # with it; the dist ships its runtime libs (Makefile dist-gcc).
      crossGccByName = lib.mapAttrs (name: target:
        ownGcc.mkFull name target glibc."glibc-hurd-${name}") hurdTargets;
      crossGccFull = lib.mapAttrs' (name: target:
        lib.nameValuePair "cross-gcc-${name}" crossGccByName.${name}) hurdTargets;

      # The from-source toolchain a given target's gnumach kernel builds with:
      # { cc = cross-gcc-<arch>; binutils = cross-binutils-<arch>; } - both unwrapped,
      # added to the kernel build's PATH.  Xen variants reuse their CPU sibling's (same
      # `<cpu>-gnu` ABI - the kernel links -nostdlib, so the glibc sysroot is moot).
      toolchainFor = target:
        let n = toolchainNameByCrossTarget.${target.crossTarget}; in
        { cc = crossGccByName.${n}; binutils = ownBinutils."cross-binutils-${n}";
          # The glibc-hurd the cross-gcc bakes as --with-sysroot.  Consumers that
          # include glibc headers (hurd) map this IA path out of their DWARF.
          sysroot = glibc."glibc-hurd-${n}"; };

      # CHECKED mig - built with the from-source cross-gcc (its --with-sysroot=glibc-hurd
      # carries <string.h>) so `make check` can compile the generated stubs.  Byte-
      # identical to the bootstrap `mig` (migcom is native-host-cc, cpu.h -ffreestanding
      # in both), so a green check proves the bootstrap mig that built glibc is sound.
      # Sits downstream of glibc.  crossGccByName is the in-tree (alias-glibc-bound)
      # cross-gcc - the kernel that consumes the checked mig rides the same cc.
      migChecked = import ./flakes/mig {
        inherit nixpkgs system targets gnumachHeaders;
        bootstrapGcc = ownGcc.bootstrap;   # unused when checkCC is set (CHECKED path)
        srcInput = mig-src;
        forkUrl = migInfo.forkUrl;
        checkCC = crossGccByName;
      };

      # Consumer-facing mig: every target mapped to the CHECKED mig of its
      # crossTarget sibling, re-keyed to the plain `mig-<name>` the gnumach/hurd
      # modules look up.  Routes glibc's downstream consumers (kernel + userland)
      # through the validated mig, so they can't build unless the mig tests
      # passed.  The unchecked bootstrap `mig` stays on the pre-glibc path
      # (hurd-headers, glibc), where no libc exists yet to run the tests.
      checkedMigFor = lib.listToAttrs (lib.mapAttrsToList (name: target:
        lib.nameValuePair "mig-${name}"
          migChecked."mig-checked-${toolchainNameByCrossTarget.${target.crossTarget}}")
        targets);

      # GNU Mach kernel - built with the wrapped cross-cc (freestanding,
      # -nostdlib).  `toolchainFor` resolves each target onto its `toolchain-<arch>`.
      gnumach = import ./flakes/gnumach {
        inherit nixpkgs system targets self toolchainFor buildRevToken;
        mig = checkedMigFor;   # downstream of glibc -> the validated mig
        srcInput = gnumach-src;
        forkUrl = gnumachInfo.forkUrl;
      };

      # The Hurd userland (core servers + libraries), built with the
      # wrapped toolchain + mig + the ABI-gated glibc-hurd sysroot.
      hurd = import ./flakes/hurd {
        inherit nixpkgs system targets self buildRevToken toolchainFor;
        mig = checkedMigFor;   # downstream of glibc -> the validated mig
        srcInput = hurd-src;
        forkUrl = hurdInfo.forkUrl;
      };
    in
    gnumach
    // gnumachHeaders
    // mig
    // hurdHeaders
    // hurd
    // sidekick
    // ownBinutils       # cross-binutils-<arch>
    // ownGcc.bootstrap  # bootstrap-gcc-<arch> (libc-free stage-1 cc)
    // glibc
    // hurdStubs
    // hurdStubsIR
    // { mig-wire-manifest = migWireManifest; }
    // crossGccFull      # the merged from-source cross-gcc-<arch> (compiler + runtime)
    // migChecked
    # Timezone database for the dist (dist-tzdata copies its share/zoneinfo).
    # arch-independent zic-compiled data, byte-identical cross-host; one package
    # serves every target.
    // { tzdata = nixpkgs.legacyPackages.${system}.tzdata; });

  apps = forAllSystems (system: import ./flakes/run {
    inherit nixpkgs system targets crossToolchain;
    packages = self.packages.${system};
  });
}
