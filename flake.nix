{
  description = "Cross-compilation environment for GNU Mach";

  # Project-scoped binary cache for built artefacts (cross-toolchains,
  # mig-<arch>, gnumach-headers-<arch>, dev-shell closures).  Anyone who
  # uses this flake is offered the cache as an additional substituter;
  # first-time users see a one-shot trust prompt from nix.  For non-
  # interactive consumers (CI), pass `--accept-flake-config` or set
  # `accept-flake-config = true` in nix.conf.
  nixConfig = {
    extra-substituters = [
      "https://hurd-build-system.cachix.org"
    ];
    extra-trusted-public-keys = [
      "hurd-build-system.cachix.org-1:dJ/avTKQFMBKT8halHXN+hN/4Dg5oP++Uz/goz4fZSE="
    ];
  };

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-25.11";

    # src/gnumach and src/mig are git submodules.  Without this, the
    # flake's self-fetch only sees gitlinks (a parent-tracked SHA, no
    # working-tree content) and any derivation that reads ./src/* fails
    # with "Path 'src/<repo>' in the repository ... is not tracked by
    # Git."  Available since nix 2.27 (Feb 2025).
    self.submodules = true;
  };

  outputs = { self, nixpkgs }:
    let
      # Host systems this flake supports. The build target is cross-compiled
      # and chosen via `nix develop .#<target>` — independent of host.
      supportedSystems = [
        "aarch64-darwin"
        "x86_64-darwin"
        "aarch64-linux"
        "x86_64-linux"
        "i686-linux"
        "armv6l-linux"
        "armv7l-linux"
        "riscv64-linux"
        "powerpc64le-linux"
      ];
      forAllSystems = f: nixpkgs.lib.genAttrs supportedSystems (system: f system);

      # Cross targets we know how to build for. Add an entry here to support
      # a new target; cross-gcc, gnumach-headers, and mig all consume from
      # this attrset.
      #
      #   crossSystem : nixpkgs cross-system identifier (drives the toolchain)
      #   migTarget   : the triple passed to MIG's --target= flag (CPU ABI;
      #                 Xen variants share this with their non-Xen siblings)
      #   platform    : value for gnumach's --enable-platform= ("at" / "xen"
      #                 on x86; null where the option doesn't apply, e.g.
      #                 aarch64)
      targets = {
        aarch64 = {
          crossSystem = "aarch64-none-elf";
          migTarget   = "aarch64-gnu";
          platform    = null;
        };
        x86_64 = {
          crossSystem = "x86_64-elf";
          migTarget   = "x86_64-gnu";
          platform    = "at";
        };
        x86_64-xen = {
          crossSystem = "x86_64-elf";
          migTarget   = "x86_64-gnu";
          platform    = "xen";
        };
        i686 = {
          crossSystem = "i686-elf";
          migTarget   = "i686-gnu";
          platform    = "at";
        };
        i686-xen = {
          crossSystem = "i686-elf";
          migTarget   = "i686-gnu";
          platform    = "xen";
        };
      };

      # Cross-toolchain dev-shell builder.  See flakes/cross-gcc for the
      # mkDevShell function, the x86_64-darwin config.sub overlay, and the
      # host-system → default-target mapping.
      crossGcc = import ./flakes/cross-gcc { inherit nixpkgs; };
    in
    {
      # `default` picks the target whose CPU matches the host, so `nix develop`
      # without an explicit `.#<name>` works out of the box. Override with
      # `nix develop .#x86_64` (or whichever) for a deliberate cross-target.
      devShells = forAllSystems (system:
        let
          shells = nixpkgs.lib.mapAttrs
            (name: target: crossGcc.mkDevShell system name target)
            targets;
        in
        shells // { default = shells.${crossGcc.defaultTargetName system}; }
      );

      # Packages exposed for `nix build .#<name>`:
      #
      #   sidekick                       — x86_64 Linux helper VM (always-on,
      #                                    arch-independent, prebuilt-Alpine).
      #   gnumach-headers-<target>       — public Mach headers for one MIG
      #                                    target (i686 / x86_64 / aarch64
      #                                    and the -xen variants).  Output:
      #                                    $out/include/...
      #   mig-<target>                   — cross-MIG binary for one target,
      #                                    built against gnumach-headers-
      #                                    <target>.  Output:
      #                                    $out/bin/<migTarget>-mig +
      #                                    $out/libexec/<migTarget>-migcom.
      #                                    `doCheck = true` runs MIG's own
      #                                    make check (12 tests) inside the
      #                                    sandbox.
      #
      # Source for each per-target derivation is the local git checkout
      # (`./src/gnumach`, `./src/mig`) — passed as a path, so the
      # /nix/store entry tracks the working-tree branch.  Switch branches
      # in src/<repo> and the next `nix build` will rebuild.
      packages = forAllSystems (system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
          # Each sub-flake owns its per-target loop + source path
          # (../../src/<repo>) and returns the full attrset.  Root just
          # passes in the shared target spec and merges what comes back.
          # `inputs.self.submodules = true` (top of file) is what makes
          # the submodule content visible in the store.
          gnumachHeaders = import ./flakes/gnumach-headers {
            inherit pkgs system targets;
            lib = nixpkgs.lib;
          };
          migs = import ./flakes/mig {
            inherit pkgs system targets gnumachHeaders;
            lib = nixpkgs.lib;
          };
        in
        {
          sidekick = import ./flakes/sidekick/default.nix { inherit pkgs; };
        } // gnumachHeaders // migs);
    };
}
