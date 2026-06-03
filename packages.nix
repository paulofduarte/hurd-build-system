# `packages.<system>` and `apps.<system>` outputs (kernel, headers, mig,
# glibc-hurd, the cross-toolchain, sidekick + the `nix run` apps).
#
# Kept out of flake.nix so adding a new sub-flake (e.g. hurd) touches only
# this module — flake.nix and target-archs.nix stay untouched, so the
# toolchain-cache CI (which path-filters on those + flakes/cross-toolchain)
# does not retrigger.  See .github/workflows.
#
# Each sub-flake instantiates its own `pkgs`/`lib` (from `nixpkgs` + `system`)
# and imports its own `flakes/lib` helpers — the root only threads the
# flake-level values a sub-flake can't derive itself:
#   nixpkgs, system        — to instantiate the package set;
#   self                   — build-rev + .gitmodules for PACKAGE_VERSION;
#   targets                — the per-target loop;
#   crossToolchain         — the merged `<cpu>-gnu` cross-toolchain
#                            (mkCrossPkgs / mkAll / mkFinal / the ABI gate);
#   srcInput               — the gnumach-src / mig-src / … flake inputs
#                            (pinned github fork rev; see flakes/sources).

{ nixpkgs, self, forAllSystems, targets, crossToolchain, gnumach-src, mig-src, hurd-src, glibc-src
, gnumach-ref-src, mig-ref-src, hurd-ref-src, glibc-ref-src }:

let
  inherit (nixpkgs) lib;
  inherit (crossToolchain) mkCrossPkgs mkAll mkFinal mkAbiChecked mkAbiReport mkAbiReportHost;
  # Fork-id metadata (owner/repo/ref) derived from the `*-src` inputs via
  # flake.lock — see flakes/sources.  Feeds the version string's fork field.
  sourcesLib  = import ./flakes/sources { inherit lib; };
  gnumachInfo = sourcesLib.info self "gnumach-src" gnumach-src;
  migInfo     = sourcesLib.info self "mig-src" mig-src;
  hurdInfo    = sourcesLib.info self "hurd-src" hurd-src;
  glibcInfo   = sourcesLib.info self "glibc-src" glibc-src;

  # Userland targets (those that get a full toolchain): the non-xen ones,
  # i686 + x86_64.  The xen variants are kernel-only.
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

      # Pre-libc cross-toolchain stages: per-userland-target
      # `cross-binutils-<arch>` + `cross-gcc-stage1-<arch>` (the libc-free
      # cc that builds gnumach-headers / mig / glibc-hurd).  Defined in
      # flakes/cross-toolchain/toolchain.nix.
      toolchainStagePkgs = mkAll system targets;

      # glibc-hurd (WORKING): per-target Hurd C library from the working
      # glibc-src + the working headers/mig.  Feeds the wrapped cc's libc and
      # the userland link.  Its own module (flakes/cross-toolchain/glibc.nix)
      # so the Mach + Hurd headers + mig get cleanly threaded.
      glibcHurd = import ./flakes/cross-toolchain/glibc.nix {
        inherit nixpkgs system targets mig gnumachHeaders hurdHeaders;
        inherit (crossToolchain) mkCrossPkgs;
        srcInput = glibc-src;
        forkUrl  = glibcInfo.forkUrl;
        deployPrefix = true;
      };

      # Reference chain (Part 2): the frozen release-tag toolchain inputs that
      # gcc's libgcc_s/libstdc++ are built against.  Same modules as the
      # working chain, fed the *-ref-src inputs (+ the matching reference
      # headers/mig).  Distinct store paths from the working chain (the ref
      # tags trail the working branch tips), so this is the stable baseline
      # gcc binds — hacking the working chain leaves it, and hence gcc,
      # untouched.  See .claude/docs/build/TOOLCHAIN-LIBC-DECOUPLING.md.
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
      glibcRefHurd = import ./flakes/cross-toolchain/glibc.nix {
        inherit nixpkgs system targets;
        mig = migRef;
        gnumachHeaders = gnumachHeadersRef;
        hurdHeaders = hurdHeadersRef;
        inherit (crossToolchain) mkCrossPkgs;
        srcInput = glibc-ref-src;
        forkUrl  = glibcInfo.forkUrl;
        # Reference glibc is also --prefix=/ so the gcc runtime libs it links
        # (libgcc_s/libstdc++) carry /lib-rooted paths, not /nix/store.  This
        # makes gcc build libgcc_s/libstdc++ against a /lib GROUP `libc.so`; the
        # resulting link wall is handled in toolchain.nix (mechanism #2:
        # --sysroot=${ref} via NIX_LDFLAGS_BEFORE).
        deployPrefix = true;
      };
      # Expose the reference glibc as `glibc-ref-hurd-<arch>` (the working one
      # is `glibc-hurd-<arch>`) — for the ABI gate + `nix build` debugging.
      glibcRefHurdPkgs = lib.mapAttrs'
        (n: v: lib.nameValuePair
          (lib.replaceStrings [ "glibc-hurd-" ] [ "glibc-ref-hurd-" ] n) v)
        glibcRefHurd;

      # The ABI gate dispatches its Linux-only analysers (abidiff/pahole)
      # into the Debian sidekick VM, so it runs on every host (no darwin
      # skip, no nixpkgs libabigail/pahole dep).  Thread the sidekick image
      # + the host-side dispatch scripts to the gate.  See
      # SIDEKICK-DISPATCHER.md.
      sidekickArgs = {
        sidekick    = sidekick.sidekick;
        dispatchLib = ./flakes/sidekick/sidekick-dispatch.sh;
        sendScript  = ./flakes/sidekick/sidekick-send.sh;
      };

      # The ABI-gated working glibc — what the wrapped cc + userland bind.
      # Per target: if the working and reference glibc resolve to the same
      # store path (ref pin == working tip → the collapse property) the
      # gate is a no-op and we pass the working glibc straight through; once
      # they diverge (hacking src/, or the ref pinned to an older release
      # tag) the gate runs the FULL probe suite (via sidekick) and re-exports
      # the working glibc on pass.  gcc is unaffected either way — it binds
      # the reference glibc (ungated), so the gate never rebuilds gcc.
      gatedGlibcHurd = lib.mapAttrs' (name: target:
        let
          w = glibcHurd."glibc-hurd-${name}";
          r = glibcRefHurd."glibc-hurd-${name}";
        in lib.nameValuePair "glibc-hurd-${name}"
          (if w.drvPath == r.drvPath
           then w
           else mkAbiChecked system target ({ working = w; reference = r; glibcSrc = glibc-src; } // sidekickArgs)))
        hurdTargets;

      # Final cross-gcc + wrapped toolchain per userland target: gcc binds
      # the reference glibc, the wrapped cc points at the ABI-gated working
      # one.  Outputs `cross-gcc-<arch>` + `toolchain-<arch>` (THE toolchain
      # — what the dev shell, the gnumach kernel, the Hurd userland, and the
      # cache workflow all use).
      hurdFinalPkgs = mkFinal system targets {
        reference = glibcRefHurd;
        working   = gatedGlibcHurd;
      };

      # The wrapped cross-cc a given target's gnumach kernel builds with.
      # Userland targets use their own `toolchain-<arch>`; the xen kernel
      # variants reuse their CPU sibling's (same `<cpu>-gnu` ABI — the
      # kernel links -nostdlib, so the working glibc-hurd sysroot is moot).
      toolchainFor = target: hurdFinalPkgs."toolchain-${toolchainNameByCrossTarget.${target.crossTarget}}";

      # CHECKED mig — the validated mig.  Built with the wrapped cc (which
      # carries glibc-hurd's <string.h> etc.), so its `make check` can
      # compile the generated stubs; byte-identical to the bootstrap `mig`
      # (migcom is native-host-cc, cpu.h is -ffreestanding in both), so a
      # green check proves the bootstrap mig that built glibc is sound.
      # Sits downstream of glibc (via the wrapped cc) → built AFTER
      # hurdFinalPkgs here, no cycle.  Outputs `mig-checked-<arch>` for the
      # non-xen userland targets.
      migChecked = import ./flakes/mig {
        inherit nixpkgs system targets gnumachHeaders mkCrossPkgs;
        srcInput = mig-src;
        forkUrl = migInfo.forkUrl;
        checkToolchains = hurdFinalPkgs;
      };

      # Consumer-facing mig: every target (incl. the xen kernel variants)
      # mapped to the CHECKED mig of its crossTarget sibling, re-keyed to the
      # plain `mig-<name>` the gnumach/hurd modules look up.  This routes
      # glibc's DOWNSTREAM consumers (kernel + userland) through the validated
      # mig — so `nix build .#gnumach-<arch>` / `.#hurd-<arch>` can't succeed
      # unless the mig test suite passed.  The unchecked bootstrap `mig` stays
      # only on the pre-glibc path (hurd-headers, glibc), where no libc exists
      # yet to run the tests.
      checkedMigFor = lib.listToAttrs (lib.mapAttrsToList (name: target:
        lib.nameValuePair "mig-${name}"
          migChecked."mig-checked-${toolchainNameByCrossTarget.${target.crossTarget}}")
        targets);

      # `make check-glibc` / `check-glibc-full` back-ends: the explicit
      # report (`deep` = Tier-1/2 + headers; `full` adds the heavy probes).
      # Dispatches abidiff/pahole via the sidekick like the in-build gate, so
      # it runs on EVERY host now (the old darwin-only `meta.platforms` skip
      # is gone).  Compares the RAW working glibc against the reference.
      abiReportPkgs = lib.listToAttrs (lib.concatLists (lib.mapAttrsToList (name: target:
        let
          w = glibcHurd."glibc-hurd-${name}";
          r = glibcRefHurd."glibc-hurd-${name}";
          mk = level: mkAbiReport system target ({ working = w; reference = r; inherit level; glibcSrc = glibc-src; } // sidekickArgs);
        in [
          { name = "abi-check-${name}";      value = mk "deep"; }
          { name = "abi-check-full-${name}"; value = mk "full"; }
          # Host-side runner for the in-tree glibc (`make check-glibc[-full]`
          # when GLIBC_IN_TREE): takes the in-tree sysroot as a runtime arg,
          # compares it against the frozen reference `r` via the sidekick.
          { name = "abi-report-host-${name}";
            value = mkAbiReportHost system target ({ reference = r; } // sidekickArgs); }
        ]) hurdTargets));

      # GNU Mach kernel — built with the wrapped cross-cc (freestanding,
      # -nostdlib).  `toolchainFor` resolves each target (incl. the xen
      # variants) onto the right `toolchain-<arch>`.
      gnumach = import ./flakes/gnumach {
        inherit nixpkgs system targets self toolchainFor;
        mig = checkedMigFor;   # downstream of glibc → the validated mig
        srcInput = gnumach-src;
        forkUrl = gnumachInfo.forkUrl;
      };

      # The Hurd userland (core servers + libraries), built with the
      # wrapped toolchain + mig + the ABI-gated glibc-hurd sysroot.
      hurd = import ./flakes/hurd {
        inherit nixpkgs system targets self;
        mig = checkedMigFor;   # downstream of glibc → the validated mig
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
    // abiReportPkgs);

  apps = forAllSystems (system: import ./flakes/run {
    inherit nixpkgs system targets crossToolchain;
    packages = self.packages.${system};
  });
}
