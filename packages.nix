# `packages.<system>` and `apps.<system>` outputs (kernel, headers, mig,
# sidekick + the `nix run` apps).
#
# Kept out of flake.nix so adding a new sub-flake (e.g. hurd) touches only
# this module — flake.nix and target-archs.nix stay untouched, so the
# toolchain-cache CI (which path-filters on those + flakes/cross-toolchain)
# does not retrigger.  See .github/workflows.
#
# Each sub-flake owns its per-target loop + source path and returns an
# attrset; we merge them.  `inputs.self.submodules = true` (flake.nix) is
# what makes the submodule content visible in the store.
#
# `crossToolchain.mkCrossPkgs` is the single "import nixpkgs with cross +
# x86_64-darwin overlay + the gas-determinism patch" entry point, passed
# down so all sub-flakes share one cross-pkgs construction.  Without it,
# `nix build .#mig-<arch>` / `.#gnumach-headers-<arch>` would skip the
# overlay and fail on x86_64-darwin with the bundled-config.sub bug.
#
# `self` is passed down so sub-flakes derive their build-rev / build-date
# and read .gitmodules for the PACKAGE_VERSION string.  `helpers`
# (flakes/lib) is the shared version + reproducibility library.

{ nixpkgs, self, forAllSystems, targets, crossToolchain, gnumach-src, mig-src }:

{
  packages = forAllSystems (system:
    let
      pkgs = nixpkgs.legacyPackages.${system};

      # Bindings are alphabetical; `let` is lazy, so order is cosmetic.
      gnumach = import ./flakes/gnumach {
        inherit pkgs system targets mig self helpers;
        lib = nixpkgs.lib;
        mkCrossPkgs = crossToolchain.mkCrossPkgs;
        srcInput = gnumach-src;
      };
      gnumachHeaders = import ./flakes/gnumach-headers {
        inherit pkgs system targets;
        lib = nixpkgs.lib;
        mkCrossPkgs = crossToolchain.mkCrossPkgs;
        srcInput = gnumach-src;
      };
      helpers = import ./flakes/lib { lib = nixpkgs.lib; };
      mig = import ./flakes/mig {
        inherit pkgs system targets gnumachHeaders self helpers;
        lib = nixpkgs.lib;
        mkCrossPkgs = crossToolchain.mkCrossPkgs;
        srcInput = mig-src;
      };
      sidekick = import ./flakes/sidekick { inherit pkgs; };
    in
    gnumach
    // gnumachHeaders
    // mig
    // sidekick);

  # `nix run` apps — one per cross arch; each parses scenario + flags and
  # exec's flakes/run/dispatch.sh.  The kernel comes from the nix-built
  # `gnumach-<arch>` package (cachix-cached), so this needs no make build.
  apps = forAllSystems (system: import ./flakes/run {
    inherit (nixpkgs) lib;
    pkgs = nixpkgs.legacyPackages.${system};
    inherit system targets crossToolchain;
    packages = self.packages.${system};
  });
}
