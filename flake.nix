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
    nixpkgs.url = "github:nixos/nixpkgs/nixos-26.05";

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

    # Reference pins for the cross-toolchain (Part 2 of the libc decoupling,
    # see .claude/docs/build/TOOLCHAIN-LIBC-DECOUPLING.md).  gcc's libgcc_s /
    # libstdc++ are built against the REFERENCE glibc, which is built from
    # these *-ref-src trees (+ the headers / mig they consume).  The working
    # *-src inputs above feed the wrapped cc + the userland.
    #
    # Pinned to upstream RELEASE TAGS — gcc binds released versions, a stable
    # baseline.  `nix flake update` moves the working branches but leaves the
    # tags put, so gcc rebuilds only on a deliberate rebaseline (bump a tag).
    # The tags trail the working branch tips, so the reference and working
    # chains are distinct builds (no collapse): the reference is the frozen
    # baseline, the working chain is what you hack.  mig's latest release tag
    # predates our test-harness fixes, so the reference mig picks them up via
    # the date-guarded patches in flakes/mig/default.nix.
    #
    # The savannah tags carry their resolved `rev` too: the tag is the
    # human-readable pin; the rev makes the lock reproducible and resolvable
    # from a local cache when savannah is unreachable (it is flaky — sourceware
    # is reliable, so glibc-ref stays tag-only).
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

    # Bootstrap-seed glibc for the 3-stage bootstrap (Phase 2): the nolibc
    # stage-1 gcc builds this THROWAWAY glibc, which produces the complete
    # stage-2 gcc that then builds the real reference glibc.  Pinned to a STABLE
    # tag, deliberately independent of glibc-ref-src, so the cached stage-2 gcc
    # survives a reference bump (a ref-src bump must NOT invalidate the seed).
    # Not a reference version — advance only to refresh the bootstrap itself.
    # Seeded equal to the reference today; the cache win materialises once the
    # reference tag advances past this seed.
    glibc-bootstrap-src = {
      type  = "git";
      url   = "https://sourceware.org/git/glibc.git";
      ref   = "refs/tags/glibc-2.43";
      flake = false;
    };

    # Bootstrap-seed headers/mig (Phase 2, full 3-stage): the bootstrap glibc +
    # the headers/mig that feed it are built by the nolibc stage-1 cc and pinned
    # independently of the reference, so a rebaseline (bumping the *-ref-src
    # pins) leaves the bootstrap chain — and hence the cached stage-2 gcc —
    # untouched.  Seeded equal to the reference pins today; they diverge only
    # when the bootstrap seed is deliberately refreshed.
    gnumach-bootstrap-src = {
      type  = "git";
      url   = "https://git.savannah.gnu.org/git/hurd/gnumach.git";
      ref   = "refs/tags/v1.8+git20260224";
      rev   = "004116a3a862e872df005e8f6af0d4ea87d506fe";
      flake = false;
    };
    mig-bootstrap-src = {
      type  = "git";
      url   = "https://git.savannah.gnu.org/git/hurd/mig.git";
      ref   = "refs/tags/v1.8+git20231217";
      rev   = "3b1fcb2b83bb26d43dc912884499345f561d0b6a";
      flake = false;
    };
    hurd-bootstrap-src = {
      type  = "git";
      url   = "https://git.savannah.gnu.org/git/hurd/hurd.git";
      ref   = "refs/tags/v0.9.git20260527";
      rev   = "d6a94f56ef421ca92f3cd573262f6a096191b240";
      flake = false;
    };
  };

  outputs = inputs@{ self, nixpkgs, gnumach-src, mig-src, hurd-src, glibc-src
                   , gnumach-ref-src, mig-ref-src, hurd-ref-src, glibc-ref-src
                   , glibc-bootstrap-src, gnumach-bootstrap-src, mig-bootstrap-src
                   , hurd-bootstrap-src, ... }:
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

      # The lib/systems patch that teaches nixpkgs to PARSE the `<cpu>-gnu`
      # Hurd triplet (flakes/lib-systems-hurd) — consumed by the
      # cross-toolchain's mkCrossPkgs.
      libHurd = import ./flakes/lib-systems-hurd { inherit nixpkgs; };

      # The cross-toolchain: THE `<cpu>-gnu` Hurd toolchain that builds the
      # gnumach kernel, MIG, glibc-hurd, and the Hurd userland — plus the
      # single dev shell, the ABI gate, the gas-determinism patch, and the
      # host-system → default-target map.  See flakes/cross-toolchain.
      crossToolchain = import ./flakes/cross-toolchain { inherit nixpkgs libHurd; };

      # packages.<system> + apps.<system> wiring (kernel, headers, mig,
      # sidekick + `nix run` apps).  Extracted to ./packages.nix so adding a
      # sub-flake (e.g. hurd) doesn't touch flake.nix / target-archs.nix and
      # thus doesn't retrigger the toolchain-cache CI.
      pkgOutputs = import ./packages.nix {
        inherit nixpkgs self forAllSystems targets crossToolchain
                gnumach-src mig-src hurd-src glibc-src
                gnumach-ref-src mig-ref-src hurd-ref-src glibc-ref-src
                glibc-bootstrap-src gnumach-bootstrap-src mig-bootstrap-src
                hurd-bootstrap-src;
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
          # (incl. the xen kernel variants, which share a crossTarget with
          # their CPU sibling) picks the right `toolchain-<arch>` (the single
          # wrapped cross-cc).
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
                # The in-tree `make glibc` compiler: the complete final gcc
                # (cross-gcc-<arch>) wrapped against the REFERENCE glibc — built
                # via the same wrappedToolchain helper as the nix working
                # glibc's build cc, so nix-work and in-tree-work glibc match.
                # (cross-gcc / glibc-ref-hurd are existing outputs — no new one.)
                glibcCC = crossToolchain.wrappedToolchain system target {
                  cc      = pkgsFor."cross-gcc-${tcName}";
                  working = pkgsFor."glibc-ref-hurd-${tcName}";
                };
                gnumach   = pkgsFor."gnumach-${name}";
                mig       = pkgsFor."mig-${name}";
                headers   = pkgsFor."gnumach-headers-${name}";
              })
            targets;
        in
        shells // { default = shells.${crossToolchain.defaultTargetName system targets}; }
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
