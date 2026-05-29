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

{ nixpkgs, self, forAllSystems, targets, crossToolchain, gnumach-src, mig-src }:

let
  inherit (nixpkgs) lib;
  inherit (crossToolchain) mkCrossPkgs mkToolchain;
  # Fork-id metadata (owner/repo/ref) derived from the `*-src` inputs via
  # flake.lock — see flakes/sources.  Feeds the version string's fork field.
  sourcesLib  = import ./flakes/sources { inherit lib; };
  gnumachInfo = sourcesLib.info self "gnumach-src";
  migInfo     = sourcesLib.info self "mig-src";
in
{
  packages = forAllSystems (system:
    let
      gnumach = import ./flakes/gnumach {
        inherit nixpkgs system targets mig self mkCrossPkgs;
        srcInput = gnumach-src;
        forkUrl = gnumachInfo.forkUrl;
        forkBranch = gnumachInfo.ref;
      };
      gnumachHeaders = import ./flakes/gnumach-headers {
        inherit nixpkgs system targets mkCrossPkgs;
        srcInput = gnumach-src;
      };
      mig = import ./flakes/mig {
        inherit nixpkgs system targets gnumachHeaders self mkCrossPkgs;
        srcInput = mig-src;
        forkUrl = migInfo.forkUrl;
        forkBranch = migInfo.ref;
      };
      sidekick = import ./flakes/sidekick { inherit nixpkgs system; };

      # The cross-toolchain per target as a first-class output:
      # `packages.<system>.toolchain-<arch>`.  The cache workflow builds these
      # and the cache-hit planner probes their store paths — one reference
      # point for "the toolchain" (defined in flakes/cross-toolchain).
      toolchains = lib.mapAttrs'
        (name: target: lib.nameValuePair "toolchain-${name}" (mkToolchain system target))
        targets;
    in
    gnumach
    // gnumachHeaders
    // mig
    // sidekick
    // toolchains);

  apps = forAllSystems (system: import ./flakes/run {
    inherit nixpkgs system targets crossToolchain;
    packages = self.packages.${system};
  });
}
