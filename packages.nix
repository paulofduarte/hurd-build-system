# `packages.<system>` and `apps.<system>` outputs (kernel, headers, mig,
# sidekick + the `nix run` apps).
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
#   mkCrossPkgs            — the one shared cross-pkgs construction (import
#                            nixpkgs with cross + x86_64-darwin overlay + the
#                            gas-determinism patch); without it standalone
#                            `nix build .#mig-<arch>` / `.#gnumach-headers-…`
#                            would miss the overlay and fail on x86_64-darwin;
#   srcInput               — the gnumach-src / mig-src flake input (pinned
#                            github fork rev; see flakes/sources).

{ nixpkgs, self, forAllSystems, targets, crossToolchain, hurdToolchain, gnumach-src, mig-src, hurd-src, glibc-src
, gnumach-ref-src, mig-ref-src, hurd-ref-src, glibc-ref-src }:

let
  inherit (nixpkgs) lib;
  inherit (crossToolchain) mkCrossPkgs mkToolchain;
  inherit (hurdToolchain) mkAll mkFinal mkAbiChecked mkAbiReport;
  # Fork-id metadata (owner/repo/ref) derived from the `*-src` inputs via
  # flake.lock — see flakes/sources.  Feeds the version string's fork field.
  sourcesLib  = import ./flakes/sources { inherit lib; };
  gnumachInfo = sourcesLib.info self "gnumach-src" gnumach-src;
  migInfo     = sourcesLib.info self "mig-src" mig-src;
  hurdInfo    = sourcesLib.info self "hurd-src" hurd-src;
  glibcInfo   = sourcesLib.info self "glibc-src" glibc-src;
in
{
  packages = forAllSystems (system:
    let
      gnumach = import ./flakes/gnumach {
        inherit nixpkgs system targets mig self mkCrossPkgs;
        srcInput = gnumach-src;
        forkUrl = gnumachInfo.forkUrl;
      };
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

      # The cross-toolchain per target as a first-class output:
      # `packages.<system>.toolchain-<arch>`.  The cache workflow builds these
      # and the cache-hit planner probes their store paths — one reference
      # point for "the toolchain" (defined in flakes/cross-toolchain).
      toolchains = lib.mapAttrs'
        (name: target: lib.nameValuePair "toolchain-${name}" (mkToolchain system target))
        targets;

      # Hurd cross-toolchain components: per-target
      # `hurd-binutils-<arch>` + `hurd-gcc-stage1-<arch>`, filtered to
      # targets with a `hurdCrossSystem` field (i686, x86_64 today —
      # see target-archs.nix).  Uses the patched nixpkgs from
      # flakes/lib-systems-hurd so the *-gnu triplet parses.
      hurdToolchainPkgs = mkAll system targets;

      # glibc-hurd (WORKING): per-target Hurd C library from the working
      # glibc-src + the working headers/mig.  Feeds the wrapped cc's libc and
      # the userland link.  Its own module (flakes/hurd-toolchain/glibc.nix)
      # so the Mach + Hurd headers + mig get cleanly threaded.
      glibcHurd = import ./flakes/hurd-toolchain/glibc.nix {
        inherit nixpkgs system targets mig gnumachHeaders hurdHeaders;
        inherit (hurdToolchain) mkHurdCrossPkgs;
        srcInput = glibc-src;
        forkUrl  = glibcInfo.forkUrl;
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
      glibcRefHurd = import ./flakes/hurd-toolchain/glibc.nix {
        inherit nixpkgs system targets;
        mig = migRef;
        gnumachHeaders = gnumachHeadersRef;
        hurdHeaders = hurdHeadersRef;
        inherit (hurdToolchain) mkHurdCrossPkgs;
        srcInput = glibc-ref-src;
        forkUrl  = glibcInfo.forkUrl;
      };
      # Expose the reference glibc as `glibc-ref-hurd-<arch>` (the working one
      # is `glibc-hurd-<arch>`) — for the ABI gate + `nix build` debugging.
      glibcRefHurdPkgs = lib.mapAttrs'
        (n: v: lib.nameValuePair
          (lib.replaceStrings [ "glibc-hurd-" ] [ "glibc-ref-hurd-" ] n) v)
        glibcRefHurd;

      hurdTargets = lib.filterAttrs (_: t: t ? hurdCrossSystem) targets;

      # The ABI-gated working glibc — what the wrapped cc + userland bind.
      # Per target: if the working and reference glibc resolve to the same
      # store path (ref pin == working tip → the collapse property) the
      # gate is a no-op and we pass the working glibc straight through; once
      # they diverge (hacking src/, or the ref pinned to an older release
      # tag) the gate derivation runs the auto probe set and re-exports the
      # working glibc on pass.  gcc is unaffected either way — it binds the
      # reference glibc (ungated), so the gate never triggers a gcc rebuild.
      gatedGlibcHurd = lib.mapAttrs' (name: target:
        let
          w = glibcHurd."glibc-hurd-${name}";
          r = glibcRefHurd."glibc-hurd-${name}";
        in lib.nameValuePair "glibc-hurd-${name}"
          (if w.drvPath == r.drvPath
           then w
           else mkAbiChecked system target { working = w; reference = r; glibcSrc = glibc-src; }))
        hurdTargets;

      # Final cross-gcc + wrapped toolchain per target: gcc binds the
      # reference glibc, the wrapped cc points at the ABI-gated working one.
      hurdFinalPkgs = mkFinal system targets {
        reference = glibcRefHurd;
        working   = gatedGlibcHurd;
      };

      # `make check-glibc` / `check-glibc-full` back-ends: the explicit deep
      # report (Tier-2 abidiff on unstripped variants + the heavy probes).
      # Compares the RAW working glibc against the reference, so it reflects
      # the unhacked or hacked src/ as-is.
      #
      # Linux-only: the deep/full tier needs libabigail (abidiff) + pahole,
      # which nixpkgs packages for Linux only.  Exposed only on `*-linux`
      # systems so darwin eval / `nix flake show` never trips their
      # `meta.platforms` gate; `make check-glibc` skips on darwin and runs on
      # a Linux host (e.g. orb).  The automatic gate (mkAbiChecked) is
      # DWARF-free and stays on every host.  A future sidekick-backed shim
      # will make these uniform across hosts (see TOOLCHAIN-LIBC-DECOUPLING).
      abiReportPkgs = lib.optionalAttrs (lib.hasSuffix "-linux" system)
        (lib.listToAttrs (lib.concatLists (lib.mapAttrsToList (name: target:
          let
            w = glibcHurd."glibc-hurd-${name}";
            r = glibcRefHurd."glibc-hurd-${name}";
          in [
            { name = "abi-check-${name}";      value = mkAbiReport system target { working = w; reference = r; level = "deep"; glibcSrc = glibc-src; }; }
            { name = "abi-check-full-${name}"; value = mkAbiReport system target { working = w; reference = r; level = "full"; glibcSrc = glibc-src; }; }
          ]) hurdTargets)));

      # The Hurd userland (core servers + libraries), built with the
      # wrapped toolchain + mig + the ABI-gated glibc-hurd sysroot.
      hurd = import ./flakes/hurd {
        inherit nixpkgs system targets mig self;
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
    // toolchains
    // hurdToolchainPkgs
    // glibcHurd
    // glibcRefHurdPkgs
    // hurdFinalPkgs
    // abiReportPkgs);

  apps = forAllSystems (system: import ./flakes/run {
    inherit nixpkgs system targets crossToolchain;
    packages = self.packages.${system};
  });
}
