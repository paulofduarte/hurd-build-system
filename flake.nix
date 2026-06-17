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
    # ONE pin set serves the whole chain (the former *-ref-src twins are gone):
    # pinned to upstream RELEASE TAGS, so `nix flake update` leaves them put and
    # a pin bump is a DELIBERATE event - it rebuilds the full toolchain (glibc
    # is cross-gcc's libcCross).  Real hacking happens in-tree via the
    # *-dev-src alias overrides below, which can never reach the pin-side
    # consumers.  The savannah tags carry their resolved `rev`: it makes the
    # lock resolvable from a local cache when savannah is unreachable (it is
    # flaky; sourceware is reliable, so glibc stays tag-only).  mig is pinned
    # to a COMMIT: its latest release tag (2023) predates the x86_64 support
    # and the test-harness fixes the checked build needs - upstream just
    # hasn't tagged since.
    gnumach-src = {
      type  = "git";
      url   = "https://git.savannah.gnu.org/git/hurd/gnumach.git";
      ref   = "refs/tags/v1.8+git20260224";
      rev   = "004116a3a862e872df005e8f6af0d4ea87d506fe";
      flake = false;
    };
    mig-src = {
      type  = "git";
      url   = "https://git.savannah.gnu.org/git/hurd/mig.git";
      ref   = "master";
      rev   = "cb48044b30fcfe10529ecc1129dd68e93ed73835";
      flake = false;
    };
    hurd-src = {
      type  = "git";
      url   = "https://git.savannah.gnu.org/git/hurd/hurd.git";
      ref   = "refs/tags/v0.9.git20260527";
      rev   = "d6a94f56ef421ca92f3cd573262f6a096191b240";
      flake = false;
    };
    # GNU libc for the Hurd cross-toolchain AND the shipped libc (one glibc;
    # x86_64-gnu support landed in 2.40, the active hurd-amd64 patch set lives
    # in 2.40+).  Sourced from upstream sourceware (authoritative for glibc).
    # The toolchain trio (binutils + gcc + glibc, in build order) is pinned from
    # upstream RELEASE TARBALLS, not git: the tarball IS the release artifact
    # (lighter than cloning gcc/glibc history or binutils-gdb's gdb), and each has
    # its own from-source derivation (binutils.nix / gcc.nix / glibc.nix).  All
    # `toolchainOnly` in flakes/sources (nix-only, never cloned into src/); version
    # = edit the url.  gcc/binutils track latest stable; glibc stays 2.43 (the
    # Hurd x86_64 support).
    binutils-src = {
      type  = "tarball";
      url   = "https://ftp.gnu.org/gnu/binutils/binutils-2.46.1.tar.xz";
      flake = false;
    };
    gcc-src = {
      type  = "tarball";
      url   = "https://ftp.gnu.org/gnu/gcc/gcc-16.1.0/gcc-16.1.0.tar.xz";
      flake = false;
    };
    glibc-src = {
      type  = "tarball";
      url   = "https://ftp.gnu.org/gnu/glibc/glibc-2.43.tar.xz";
      flake = false;
    };

    # Overridable ALIASES of the pins - what the Makefile's in-tree overrides
    # rebind (--override-input <m>-dev-src src/<m>).  `follows` keeps them OUT
    # of the lock (no second pin to maintain) and, unoverridden, they resolve
    # to the very same source - the pin-side and alias-side instantiations
    # then produce IDENTICAL drvs.  The explicit `flake = false` is required:
    # follows does not inherit it, and overriding an alias without it makes
    # nix demand a flake.nix in the override path.
    gnumach-dev-src = { follows = "gnumach-src"; flake = false; };
    mig-dev-src     = { follows = "mig-src";     flake = false; };
    hurd-dev-src    = { follows = "hurd-src";    flake = false; };

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

  };

  outputs = inputs@{ self, nixpkgs, gnumach-src, mig-src, hurd-src
                   , binutils-src, gcc-src, glibc-src
                   , gnumach-dev-src, mig-dev-src, hurd-dev-src
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

      # The cross-toolchain barrel: the dev shell (in-tree builds) + the
      # host-system -> default-target map.  The `<cpu>-gnu` Hurd toolchain itself
      # (binutils/gcc/glibc) is built from source in packages.nix.  See
      # flakes/cross-toolchain.
      crossToolchain = import ./flakes/cross-toolchain { inherit nixpkgs; };

      # packages.<system> + apps.<system> wiring.  Extracted to ./packages.nix
      # so adding a sub-flake doesn't touch flake.nix / target-archs.nix and
      # thus doesn't retrigger the toolchain-cache CI.
      pkgOutputs = import ./packages.nix {
        inherit nixpkgs self forAllSystems targets crossToolchain buildRevToken
                gnumach-src mig-src hurd-src binutils-src gcc-src glibc-src
                gnumach-dev-src mig-dev-src hurd-dev-src;
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
                # The from-source unwrapped toolchain (cross-gcc + cross-binutils),
                # the glibc-hurd sysroot it bakes, and the bootstrap-gcc (subtracted
                # from PATH).  Keyed by the CPU sibling so a xen variant reuses it.
                cc           = pkgsFor."cross-gcc-${tcName}";
                binutils     = pkgsFor."cross-binutils-${tcName}";
                sysroot      = pkgsFor."glibc-hurd-${tcName}";
                bootstrapGcc = pkgsFor."bootstrap-gcc-${tcName}";
                gnumach      = pkgsFor."gnumach-${name}";
                # mig keyed by the CPU sibling: a xen variant's shell reuses mig-<cpu>
                # - the same tool either way (the kernels build with the sibling's
                # checked mig), so the xen-keyed raw mig would only add a pointless build.
                mig          = pkgsFor."mig-${tcName}";
                headers      = pkgsFor."gnumach-headers-${name}";
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
