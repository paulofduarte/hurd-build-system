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

    # Parallel flake inputs pointing at the same submodule worktrees.
    # We DON'T use these as `src` (the submodule via self.submodules
    # above is the source of truth for build content) — we only read
    # their `.rev` / `.shortRev` / `.lastModifiedDate` for the version
    # string composed in PACKAGE_VERSION.  nix flakes don't vendor
    # `.git` directories under any `submodules=1` setting, so this
    # was the only way to expose submodule commit metadata to pure
    # eval.  `flake.lock` pins the rev to whatever the submodule HEAD
    # was at the last `nix flake update` — keep it in sync with the
    # actual submodule via `make update-srcs` (see Makefile).
    gnumach-src = {
      url = "git+file:./src/gnumach";
      flake = false;
    };
    mig-src = {
      url = "git+file:./src/mig";
      flake = false;
    };
  };

  outputs = { self, nixpkgs, gnumach-src, mig-src, ... }:
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

      # Cross targets we know how to build for (see ./target-archs.nix).
      targets = import ./target-archs.nix;

      # Cross-toolchain dev-shell builder.  See flakes/cross-toolchain for
      # the mkDevShell function, the x86_64-darwin config.sub overlay, the
      # gas-determinism patch, and the host-system → default-target mapping.
      crossToolchain = import ./flakes/cross-toolchain { inherit nixpkgs; };

      # packages.<system> + apps.<system> wiring (kernel, headers, mig,
      # sidekick + `nix run` apps).  Extracted to ./packages.nix so adding a
      # sub-flake (e.g. hurd) doesn't touch flake.nix / target-archs.nix and
      # thus doesn't retrigger the toolchain-cache CI.
      pkgOutputs = import ./packages.nix {
        inherit nixpkgs self forAllSystems targets crossToolchain
                gnumach-src mig-src;
      };
    in
    {
      # `default` picks the target whose CPU matches the host, so `nix develop`
      # without an explicit `.#<name>` works out of the box. Override with
      # `nix develop .#x86_64` (or whichever) for a deliberate cross-target.
      devShells = forAllSystems (system:
        let
          pkgsFor = self.packages.${system};
          # Pass each target's own derivations so the dev shell infers its
          # build tools from them (see mkDevShell) instead of re-listing.
          shells = nixpkgs.lib.mapAttrs
            (name: target: crossToolchain.mkDevShell system name target {
              gnumach = pkgsFor."gnumach-${name}";
              mig     = pkgsFor."mig-${name}";
              headers = pkgsFor."gnumach-headers-${name}";
            })
            targets;
        in
        shells // { default = shells.${crossToolchain.defaultTargetName system}; }
      );

      # packages.<system> (gnumach-<t>, gnumach-headers-<t>, mig-<t>,
      # sidekick) and apps.<system> (`nix run .#<arch>`) — both defined in
      # ./packages.nix.
      inherit (pkgOutputs) packages apps;
    };
}
