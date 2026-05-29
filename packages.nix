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
#   srcInput               — the gnumach-src / mig-src submodule input.

{ nixpkgs, self, forAllSystems, targets, crossToolchain, gnumach-src, mig-src }:

let
  inherit (crossToolchain) mkCrossPkgs;
in
{
  packages = forAllSystems (system:
    let
      gnumach = import ./flakes/gnumach {
        inherit nixpkgs system targets mig self mkCrossPkgs;
        srcInput = gnumach-src;
      };
      gnumachHeaders = import ./flakes/gnumach-headers {
        inherit nixpkgs system targets mkCrossPkgs;
        srcInput = gnumach-src;
      };
      mig = import ./flakes/mig {
        inherit nixpkgs system targets gnumachHeaders self mkCrossPkgs;
        srcInput = mig-src;
      };
      sidekick = import ./flakes/sidekick { inherit nixpkgs system; };
    in
    gnumach
    // gnumachHeaders
    // mig
    // sidekick);

  apps = forAllSystems (system: import ./flakes/run {
    inherit nixpkgs system targets crossToolchain;
    packages = self.packages.${system};
  });
}
