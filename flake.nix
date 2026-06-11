# SPDX-FileCopyrightText: 2026 Paulo Duarte <paulofernandobd@gmail.com>
# SPDX-License-Identifier: GPL-3.0-or-later
{
  description = "Cross-compilation environment for GNU Mach";

  # Project-scoped binary cache for built artefacts.  Offered as an additional
  # substituter (one-shot trust prompt); non-interactive consumers (CI) pass
  # `--accept-flake-config` or set `accept-flake-config = true` in nix.conf.
  nixConfig = {
    extra-substituters = [
      "https://hurd-build-system.cachix.org"
    ];
    extra-trusted-public-keys = [
      "hurd-build-system.cachix.org-1:dJ/avTKQFMBKT8halHXN+hN/4Dg5oP++Uz/goz4fZSE="
    ];
  };

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-26.05";

    # Source repos for the kernel + MIG.  These pin exactly what nix builds
    # (locked in flake.lock); their `.rev` / `.shortRev` / `.lastModifiedDate`
    # also feed PACKAGE_VERSION.  The local clones under src/ are a separate dev
    # convenience populated by `make src` - nix never reads them.  `make
    # pin-src` bumps the pin (flake.lock only - your format here is preserved).
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
    # GNU libc for the Hurd cross-toolchain.  Pinned to the release/2.43/master
    # branch (stable tip with all backports) - x86_64-gnu support landed in 2.40
    # and the active hurd-amd64 patch set lives in 2.40+.  Sourced from upstream
    # sourceware (authoritative for glibc).
    glibc-src = {
      type  = "git";
      url   = "https://sourceware.org/git/glibc.git";
      ref   = "release/2.43/master";
      flake = false;
    };

    # The build-system rev token for the `+build.g<rev>` version field.  Any
    # `--override-input` unmatches the committed lock and nix drops BOTH
    # self.shortRev and self.dirtyShortRev on a CLEAN tree - so override-resolved
    # nix builds baked `+build.gunknown` while everything else baked the real rev
    # (caught by the 32-combo matrix: only the override-resolved corners diverged).
    # The Makefile overrides this input with the real `<short>[-dirty]` token
    # whenever it passes module overrides; the committed fallback stays "unknown"
    # and composeVersion then falls back to self (correct for plain `nix build`).
    build-rev = {
      url   = "path:.build-rev";
      flake = false;
    };

    # Reference pins for the cross-toolchain.  gcc's libgcc_s / libstdc++ bind
    # the REFERENCE glibc, built from these *-ref-src trees (+ their headers /
    # mig).  See .claude/docs/build/TOOLCHAIN-LIBC-DECOUPLING.md.
    #
    # Pinned to upstream RELEASE TAGS: `nix flake update` moves the working
    # branches but leaves the tags put, so gcc rebuilds only on a deliberate
    # rebaseline.  mig's latest release tag predates our test-harness fixes, so
    # the reference mig picks them up via the date-guarded patches in
    # flakes/mig/default.nix.
    #
    # The savannah tags carry their resolved `rev` too: it makes the lock
    # resolvable from a local cache when savannah is unreachable (it is flaky;
    # sourceware is reliable, so glibc-ref stays tag-only).
    gnumach-ref-src = {
      type  = "git";
      url   = "https://git.savannah.gnu.org/git/hurd/gnumach.git";
      ref   = "refs/tags/v1.8+git20260224";
      rev   = "004116a3a862e872df005e8f6af0d4ea87d506fe";
      flake = false;
    };
    mig-ref-src = {
      type  = "git";
      url   = "https://git.savannah.gnu.org/git/hurd/mig.git";
      ref   = "refs/tags/v1.8+git20231217";
      rev   = "3b1fcb2b83bb26d43dc912884499345f561d0b6a";
      flake = false;
    };
    hurd-ref-src = {
      type  = "git";
      url   = "https://git.savannah.gnu.org/git/hurd/hurd.git";
      ref   = "refs/tags/v0.9.git20260527";
      rev   = "d6a94f56ef421ca92f3cd573262f6a096191b240";
      flake = false;
    };
    glibc-ref-src = {
      type  = "git";
      url   = "https://sourceware.org/git/glibc.git";
      ref   = "refs/tags/glibc-2.43";
      flake = false;
    };

  };

  outputs = inputs@{ self, nixpkgs, gnumach-src, mig-src, hurd-src, glibc-src
                   , gnumach-ref-src, mig-ref-src, hurd-ref-src, glibc-ref-src
                   , build-rev, ... }:
    let
      # The real build rev when the Makefile overrides `build-rev`; null when the
      # committed "unknown" fallback is in place (composeVersion then uses self).
      buildRevToken =
        let raw = nixpkgs.lib.removeSuffix "\n" (builtins.readFile "${build-rev}/rev");
        in if raw != "unknown" then raw else null;
      # Host systems this flake supports. The build target is cross-compiled
      # and chosen via `nix develop .#<target>` - independent of host.
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

      # The lib/systems patch that teaches nixpkgs to PARSE the `<cpu>-gnu`
      # Hurd triplet - consumed by the cross-toolchain's mkCrossPkgs.
      libHurd = import ./flakes/lib-systems-hurd { inherit nixpkgs; };

      # The cross-toolchain: THE `<cpu>-gnu` Hurd toolchain that builds the
      # gnumach kernel, MIG, glibc-hurd, and the Hurd userland - plus the dev
      # shell, the ABI gate, the gas-determinism patch, and the host-system ->
      # default-target map.  See flakes/cross-toolchain.
      crossToolchain = import ./flakes/cross-toolchain { inherit nixpkgs libHurd; };

      # packages.<system> + apps.<system> wiring.  Extracted to ./packages.nix
      # so adding a sub-flake doesn't touch flake.nix / target-archs.nix and
      # thus doesn't retrigger the toolchain-cache CI.
      pkgOutputs = import ./packages.nix {
        inherit nixpkgs self forAllSystems targets crossToolchain buildRevToken
                gnumach-src mig-src hurd-src glibc-src
                gnumach-ref-src mig-ref-src hurd-ref-src glibc-ref-src;
      };
    in
    {
      # `default` picks the target whose CPU matches the host, so `nix develop`
      # without an explicit `.#<name>` works out of the box. Override with
      # `nix develop .#x86_64` (or whichever) for a deliberate cross-target.
      devShells = forAllSystems (system:
        let
          pkgsFor = self.packages.${system};
          # crossTarget (`<cpu>-gnu`) -> userland target name, so each shell
          # (incl. the xen variants, which share a crossTarget with their CPU
          # sibling) picks the right `toolchain-<arch>`.
          toolchainNameByCrossTarget = nixpkgs.lib.listToAttrs
            (nixpkgs.lib.mapAttrsToList (n: t: nixpkgs.lib.nameValuePair t.crossTarget n)
              (nixpkgs.lib.filterAttrs (_: t: (t.platform or null) != "xen") targets));
          # One shell per target.  Pass the wrapped toolchain + each target's
          # own derivations so the shell wires CC/binutils and infers its
          # build tools from them (see mkDevShell) instead of re-listing.
          shells = nixpkgs.lib.mapAttrs
            (name: target:
              let tcName = toolchainNameByCrossTarget.${target.crossTarget}; in
              crossToolchain.mkDevShell system name target {
                toolchain = pkgsFor."toolchain-${tcName}";
                gnumach   = pkgsFor."gnumach-${name}";
                # mig keyed by the CPU sibling (like the toolchain): a xen variant's
                # shell reuses mig-<cpu> - mig is the same tool either way (the nix
                # kernels already build with the sibling's checked mig), and the
                # xen-keyed raw mig would only add a pointless extra build.
                mig       = pkgsFor."mig-${tcName}";
                headers   = pkgsFor."gnumach-headers-${name}";
              })
            targets;
        in
        shells // { default = shells.${crossToolchain.defaultTargetName system targets}; }
      );

      # packages.<system> and apps.<system> (`nix run .#<arch>`) - both defined
      # in ./packages.nix.
      inherit (pkgOutputs) packages apps;

      # Source pins (owner/repo/ref/rev/url) from the `*-src` inputs via
      # flake.lock - consumed by `make src` to populate the src/ clones.  See
      # flakes/sources.
      srcs = (import ./flakes/sources { inherit (nixpkgs) lib; }).all self inputs;
    };
}
