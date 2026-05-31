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

{ nixpkgs, self, forAllSystems, targets, crossToolchain, hurdToolchain, gnumach-src, mig-src, hurd-src, glibc-src }:

let
  inherit (nixpkgs) lib;
  inherit (crossToolchain) mkCrossPkgs mkToolchain;
  inherit (hurdToolchain) mkAll;
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
        inherit nixpkgs system targets gnumachHeaders self mkCrossPkgs;
        srcInput = mig-src;
        forkUrl = migInfo.forkUrl;
      };
      hurdHeaders = import ./flakes/hurd-headers {
        inherit nixpkgs system targets mig self;
        srcInput = hurd-src;
        forkUrl = hurdInfo.forkUrl;
      };
      # SKELETON — see flakes/hurd/default.nix.  Outputs are marked
      # `meta.broken = true` until the Hurd cross-toolchain is wired up.
      hurd = import ./flakes/hurd {
        inherit nixpkgs system targets mig gnumachHeaders self mkCrossPkgs;
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

      # glibc-hurd: per-target Hurd C library, built from vanilla
      # upstream glibc via the stage-1 cross-toolchain.  Its own module
      # (flakes/hurd-toolchain/glibc.nix) so the Mach + Hurd headers +
      # mig get cleanly threaded.
      glibcHurd = import ./flakes/hurd-toolchain/glibc.nix {
        inherit nixpkgs system targets mig gnumachHeaders hurdHeaders self;
        inherit (hurdToolchain) mkHurdCrossPkgs;
        srcInput = glibc-src;
        forkUrl  = glibcInfo.forkUrl;
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
    // glibcHurd);

  apps = forAllSystems (system: import ./flakes/run {
    inherit nixpkgs system targets crossToolchain;
    packages = self.packages.${system};
  });
}
