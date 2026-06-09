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

{ nixpkgs, self, forAllSystems, targets, crossToolchain, gnumach-src, mig-src, hurd-src, glibc-src
, gnumach-ref-src, mig-ref-src, hurd-ref-src, glibc-ref-src }:

let
  inherit (nixpkgs) lib;
  inherit (crossToolchain) mkCrossPkgs mkAll mkGcc mkCompiler mkRuntime wrappedToolchain mkAbiChecked mkAbiReport mkAbiReportHost;
  # Fork-id metadata (owner/repo/ref) from the `*-src` inputs via flake.lock;
  # feeds the version string's fork field.  See flakes/sources.
  sourcesLib  = import ./flakes/sources { inherit lib; };
  gnumachInfo = sourcesLib.info self "gnumach-src" gnumach-src;
  migInfo     = sourcesLib.info self "mig-src" mig-src;
  hurdInfo    = sourcesLib.info self "hurd-src" hurd-src;
  glibcInfo   = sourcesLib.info self "glibc-src" glibc-src;

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
      gnumachHeaders = import ./flakes/gnumach-headers {
        inherit nixpkgs system targets mkCrossPkgs;
        srcInput = gnumach-src;
      };
      mig = import ./flakes/mig {
        inherit nixpkgs system targets gnumachHeaders mkCrossPkgs;
        srcInput = mig-src;
        forkUrl = migInfo.forkUrl;
      };
      hurdHeaders = import ./flakes/hurd-headers {
        inherit nixpkgs system targets mig;
        srcInput = hurd-src;
        forkUrl = hurdInfo.forkUrl;
      };
      sidekick = import ./flakes/sidekick { inherit nixpkgs system; };

      # Pre-libc cross-toolchain stages: per-target `cross-binutils-<arch>` +
      # `cross-gcc-stage1-<arch>` (the libc-free cc that builds gnumach-headers
      # / mig / glibc-hurd).  See flakes/cross-toolchain/toolchain.nix.
      toolchainStagePkgs = mkAll system targets;

      # ----------------------------------------------------------------------
      # 2-pass bootstrap.  Chain: stage-1 nolibc gcc -> ref glibc -> final gcc ->
      # work glibc.  The nolibc cc builds the reference glibc directly (a nolibc
      # gcc builds glibc fine); the final gcc binds the ref glibc's ABI, not its
      # bytes, so the dist stays byte-identical with no separate complete-gcc pass.
      # ----------------------------------------------------------------------

      # Reference toolchain inputs: frozen release-tag headers/mig the REFERENCE
      # glibc consumes.  Distinct, stable pins - a `glibc-ref-src` bump does NOT
      # touch these.  See TOOLCHAIN-LIBC-DECOUPLING.md.
      gnumachHeadersRef = import ./flakes/gnumach-headers {
        inherit nixpkgs system targets mkCrossPkgs;
        srcInput = gnumach-ref-src;
      };
      migRef = import ./flakes/mig {
        inherit nixpkgs system targets mkCrossPkgs;
        gnumachHeaders = gnumachHeadersRef;
        srcInput = mig-ref-src;
        forkUrl = migInfo.forkUrl;
      };
      hurdHeadersRef = import ./flakes/hurd-headers {
        inherit nixpkgs system targets;
        mig = migRef;
        srcInput = hurd-ref-src;
        forkUrl = hurdInfo.forkUrl;
      };

      # Reference glibc - the ABI baseline the final gcc's runtime binds against.
      # Built directly by the nolibc stage-1 cc (glibc.nix's default buildCC).
      # Never shipped or run: the final gcc binds its ABI/headers, not its bytes.
      glibcRefHurd = import ./flakes/cross-toolchain/glibc.nix {
        inherit nixpkgs system targets;
        mig = migRef;
        gnumachHeaders = gnumachHeadersRef;
        hurdHeaders = hurdHeadersRef;
        inherit (crossToolchain) mkCrossPkgs;
        srcInput = glibc-ref-src;
        forkUrl  = glibcInfo.forkUrl;
      };
      # Expose the reference glibc as `glibc-ref-hurd-<arch>` - for the ABI gate
      # + `nix build` debugging.
      glibcRefHurdPkgs = lib.mapAttrs'
        (n: v: lib.nameValuePair
          (lib.replaceStrings [ "glibc-hurd-" ] [ "glibc-ref-hurd-" ] n) v)
        glibcRefHurd;

      # Final gcc - the userland cc.  libgcc_s/libstdc++ built vs the reference
      # glibc, so it rebuilds only on a ref bump, never on a working-glibc hack.
      finalGccByName = lib.mapAttrs (name: target:
        mkGcc system target (glibcRefHurd."glibc-hurd-${name}")) hurdTargets;

      # glibc-hurd (WORKING): the Hurd C library the wrapped cc + userland bind,
      # from the working `glibc-src` + working headers/mig.  Built by the FINAL
      # gcc, so the nix and in-tree working glibc share one compiler.
      glibcHurd = import ./flakes/cross-toolchain/glibc.nix {
        inherit nixpkgs system targets mig gnumachHeaders hurdHeaders;
        inherit (crossToolchain) mkCrossPkgs;
        srcInput = glibc-src;
        forkUrl  = glibcInfo.forkUrl;
        # Built by the final gcc wrapped around the reference glibc (configure
        # link-tests need crt/libc; work != ref -> no cycle).  Same gcc the in-tree
        # working glibc uses, so nix-work and in-tree-work match.
        buildCC = name: target: wrappedToolchain system target {
          cc      = finalGccByName.${name};
          working = glibcRefHurd."glibc-hurd-${name}";
        };
      };

      # The ABI gate dispatches its Linux-only analysers (abidiff/pahole) into
      # the Debian sidekick VM, so it runs on every host (no darwin skip, no
      # nixpkgs libabigail/pahole dep).  See SIDEKICK-DISPATCHER.md.
      sidekickArgs = {
        sidekick    = sidekick.sidekick;
        dispatchLib = ./flakes/sidekick/sidekick-dispatch.sh;
        sendScript  = ./flakes/sidekick/sidekick-send.sh;
      };

      # The ABI-gated working glibc - what the wrapped cc + userland bind.  Per
      # target: if working and reference resolve to the same store path the gate
      # is a no-op (pass the working glibc through); once they diverge the gate
      # runs the FULL probe suite (via sidekick) and re-exports on pass.  gcc
      # binds the reference glibc (ungated), so the gate never rebuilds gcc.
      gatedGlibcHurd = lib.mapAttrs' (name: target:
        let
          w = glibcHurd."glibc-hurd-${name}";
          r = glibcRefHurd."glibc-hurd-${name}";
        in lib.nameValuePair "glibc-hurd-${name}"
          (if w.drvPath == r.drvPath
           then w
           else mkAbiChecked system target ({ working = w; reference = r; glibcSrc = glibc-src; } // sidekickArgs)))
        hurdTargets;

      # The single nolibc C++ compiler (no target-glibc input) - the one
      # `cross-gcc-<arch>` going forward.
      newCompilerByName = lib.mapAttrs (name: target: mkCompiler system target) hurdTargets;
      # SPIKE: the split-out target runtime libs, built against the WORKING glibc
      # from that compiler (no xgcc rebuild).
      gccRuntimeByName = lib.mapAttrs (name: target:
        mkRuntime system target {
          compiler = newCompilerByName.${name};
          # The gated glibc's libc.so GROUP is bare-named (resolves via -L); the raw
          # one's is absolute /lib/... and this ld has no --sysroot support.
          working  = gatedGlibcHurd."glibc-hurd-${name}";
        }) hurdTargets;

      # `cross-gcc-<arch>` = the nolibc C++ compiler; `cross-gcc-runtime-<arch>` =
      # the split-out target runtime; `toolchain-<arch>` wraps the (transitional)
      # final gcc around the ABI-gated working glibc (THE toolchain - dev shell,
      # kernel, userland, cache).  `cross-gcc-final-<arch>` keeps the old final gcc
      # reachable for dist-libgcc until cross-gcc-runtime replaces it.
      hurdFinalPkgs = lib.listToAttrs (lib.concatLists (lib.mapAttrsToList (name: target: [
        { name = "cross-gcc-${name}";         value = newCompilerByName.${name}; }
        { name = "cross-gcc-runtime-${name}"; value = gccRuntimeByName.${name}; }
        { name = "cross-gcc-final-${name}";   value = finalGccByName.${name}; }
        { name = "toolchain-${name}"; value = wrappedToolchain system target {
            cc      = finalGccByName.${name};
            working = gatedGlibcHurd."glibc-hurd-${name}";
          }; }
      ]) hurdTargets));

      # The wrapped cross-cc a given target's gnumach kernel builds with.  Xen
      # variants reuse their CPU sibling's (same `<cpu>-gnu` ABI - the kernel
      # links -nostdlib, so the working glibc-hurd sysroot is moot).
      toolchainFor = target: hurdFinalPkgs."toolchain-${toolchainNameByCrossTarget.${target.crossTarget}}";

      # CHECKED mig - built with the wrapped cc (carries glibc-hurd's <string.h>)
      # so `make check` can compile the generated stubs.  Byte-identical to the
      # bootstrap `mig` (migcom is native-host-cc, cpu.h -ffreestanding in both),
      # so a green check proves the bootstrap mig that built glibc is sound.  Sits
      # downstream of glibc -> built AFTER hurdFinalPkgs, no cycle.
      migChecked = import ./flakes/mig {
        inherit nixpkgs system targets gnumachHeaders mkCrossPkgs;
        srcInput = mig-src;
        forkUrl = migInfo.forkUrl;
        checkToolchains = hurdFinalPkgs;
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

      # `make check-glibc` / `check-glibc-full` back-ends: the explicit report
      # (`deep` = Tier-1/2 + headers; `full` adds the heavy probes).  Dispatches
      # abidiff/pahole via the sidekick like the in-build gate, so it runs on
      # every host.  Compares the RAW working glibc against the reference.
      abiReportPkgs = lib.listToAttrs (lib.concatLists (lib.mapAttrsToList (name: target:
        let
          w = glibcHurd."glibc-hurd-${name}";
          r = glibcRefHurd."glibc-hurd-${name}";
          mk = level: mkAbiReport system target ({ working = w; reference = r; inherit level; glibcSrc = glibc-src; } // sidekickArgs);
        in [
          { name = "abi-check-${name}";      value = mk "deep"; }
          { name = "abi-check-full-${name}"; value = mk "full"; }
          # Host-side runner for the in-tree glibc: takes the in-tree sysroot as
          # a runtime arg, compares it against the frozen reference `r` via the
          # sidekick.
          { name = "abi-report-host-${name}";
            value = mkAbiReportHost system target ({ reference = r; } // sidekickArgs); }
        ]) hurdTargets));

      # GNU Mach kernel - built with the wrapped cross-cc (freestanding,
      # -nostdlib).  `toolchainFor` resolves each target onto its `toolchain-<arch>`.
      gnumach = import ./flakes/gnumach {
        inherit nixpkgs system targets self toolchainFor;
        mig = checkedMigFor;   # downstream of glibc -> the validated mig
        srcInput = gnumach-src;
        forkUrl = gnumachInfo.forkUrl;
      };

      # The Hurd userland (core servers + libraries), built with the
      # wrapped toolchain + mig + the ABI-gated glibc-hurd sysroot.
      hurd = import ./flakes/hurd {
        inherit nixpkgs system targets self;
        mig = checkedMigFor;   # downstream of glibc -> the validated mig
        glibcHurd = gatedGlibcHurd;
        hurdToolchain = hurdFinalPkgs;
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
    // toolchainStagePkgs
    // glibcHurd
    // glibcRefHurdPkgs
    // hurdFinalPkgs
    // migChecked
    // abiReportPkgs
    # Timezone database for the dist (dist-tzdata copies its share/zoneinfo).
    # arch-independent zic-compiled data, byte-identical cross-host; one package
    # serves every target.
    // { tzdata = nixpkgs.legacyPackages.${system}.tzdata; });

  apps = forAllSystems (system: import ./flakes/run {
    inherit nixpkgs system targets crossToolchain;
    packages = self.packages.${system};
  });
}
