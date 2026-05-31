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

    # Source repos for the kernel + MIG.  These pin exactly what nix builds
    # (locked in flake.lock); their `.rev` / `.shortRev` / `.lastModifiedDate`
    # also feed PACKAGE_VERSION.  The local working clones under src/ are a
    # separate dev convenience populated by `make srcs` — nix never reads them.
    #
    # Standard form is the attribute set (`type` + scheme fields directly), so
    # any supported input type works (github, gitlab, sourcehut, git, …) without
    # depending on built-in URL short schemes.  `make pin-srcs` bumps the pin
    # (flake.lock only — your format choice in this block is preserved).
    gnumach-src = {
      type  = "git";
      url   = "https://git.savannah.gnu.org/git/hurd/gnumach.git";
      ref   = "master";
      flake = false;
    };
    mig-src = {
      type  = "git";
      url   = "https://git.savannah.gnu.org/git/hurd/mig.git";
      ref   = "master";
      flake = false;
    };
    hurd-src = {
      type  = "git";
      url   = "https://git.savannah.gnu.org/git/hurd/hurd.git";
      ref   = "master";
      flake = false;
    };
    # GNU libc for the Hurd cross-toolchain.  Pinned to the 2.43
    # release branch — x86_64-gnu support landed in 2.40 (July 2024)
    # and the active hurd-amd64 patch set lives in 2.40+.  The
    # release/2.43/master branch is the stable tip with all backports.
    # Source comes from upstream sourceware, mirroring the convention
    # used by the other *-src inputs (savannah for the Hurd projects,
    # sourceware for glibc — both authoritative for their respective
    # codebases).
    glibc-src = {
      type  = "git";
      url   = "https://sourceware.org/git/glibc.git";
      ref   = "release/2.43/master";
      flake = false;
    };
  };

  outputs = inputs@{ self, nixpkgs, gnumach-src, mig-src, hurd-src, glibc-src, ... }:
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

      # Hurd userland cross-toolchain.  Distinct from crossToolchain
      # (bare-metal *-elf for the gnumach kernel).  Uses the lib.systems
      # patch from flakes/lib-systems-hurd to make the *-gnu triplet
      # parse, then produces hurd-binutils-<arch> + hurd-gcc-stage1-<arch>
      # per target.
      libHurd = import ./flakes/lib-systems-hurd { inherit nixpkgs; };
      hurdToolchain = import ./flakes/hurd-toolchain { inherit nixpkgs libHurd; };

      # packages.<system> + apps.<system> wiring (kernel, headers, mig,
      # sidekick + `nix run` apps).  Extracted to ./packages.nix so adding a
      # sub-flake (e.g. hurd) doesn't touch flake.nix / target-archs.nix and
      # thus doesn't retrigger the toolchain-cache CI.
      pkgOutputs = import ./packages.nix {
        inherit nixpkgs self forAllSystems targets crossToolchain hurdToolchain
                gnumach-src mig-src hurd-src glibc-src;
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
          # Hurd userland dev shells (`nix develop .#hurd-<arch>`) for the
          # in-tree `make hurd` build — only for targets with a Hurd
          # toolchain (those carrying hurdCrossSystem).
          hurdShells = nixpkgs.lib.mapAttrs'
            (name: target: nixpkgs.lib.nameValuePair "hurd-${name}"
              (hurdToolchain.mkHurdDevShell system name target {
                toolchain = pkgsFor."hurd-toolchain-${name}";
                mig       = pkgsFor."mig-${name}";
              }))
            (nixpkgs.lib.filterAttrs (_: t: t ? hurdCrossSystem) targets);
        in
        shells // hurdShells // { default = shells.${crossToolchain.defaultTargetName system}; }
      );

      # packages.<system> (gnumach-<t>, gnumach-headers-<t>, mig-<t>,
      # sidekick) and apps.<system> (`nix run .#<arch>`) — both defined in
      # ./packages.nix.
      inherit (pkgOutputs) packages apps;

      # Source pins (owner/repo/ref/rev/url) derived from the `*-src` inputs
      # via flake.lock — consumed by `make srcs` to populate the src/ working
      # clones.  See flakes/sources.
      srcs = (import ./flakes/sources { inherit (nixpkgs) lib; }).all self inputs;
    };
}
