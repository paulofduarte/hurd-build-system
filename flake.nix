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
    # Branch-tracking nixpkgs for the dev shell's runtime/dev tools (qemu, git, the
    # lint bundle, ...) - the stuff a `nix flake update` is allowed to refresh.
    nixpkgs.url = "github:nixos/nixpkgs/nixos-26.05";

    # Frozen nixpkgs that builds the from-source toolchain AND every tool that feeds a
    # cached build (the modules' autoreconf/bison/flex/perl/texinfo/python/gettext/...,
    # the native stdenv).  Pinning it means `nix flake update` advances the branch above
    # WITHOUT rebuilding binutils/gcc/glibc/cross-gcc or breaking in-tree==nix
    # determinism - a toolchain-stdenv bump becomes a deliberate edit of this rev (like
    # the source tags).  Pinned to the rev the working toolchain was last built on; both
    # inputs currently resolve to it, so introducing the split rebuilds nothing.
    nixpkgs-toolchain.url = "github:nixos/nixpkgs/e8210c649915deed7080033cdbabcc19e40bb899";

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
    # flaky; sourceware is reliable, so glibc stays tag-only).  mig, like
    # gnumach/hurd, rides its latest release tag (v1.8+git20231217, 2023):
    # upstream just hasn't tagged since, and that tag predates the x86_64
    # support + test-harness fixes the checked build needs - but our patch
    # set backfills exactly those, so the tagged source + patches give a
    # reproducible pin without tracking a moving branch.
    gnumach-src = {
      type = "git";
      url = "https://git.savannah.gnu.org/git/hurd/gnumach.git";
      ref = "refs/tags/v1.8+git20260224";
      rev = "004116a3a862e872df005e8f6af0d4ea87d506fe";
      flake = false;
    };
    mig-src = {
      type = "git";
      url = "https://git.savannah.gnu.org/git/hurd/mig.git";
      ref = "refs/tags/v1.8+git20231217";
      rev = "3b1fcb2b83bb26d43dc912884499345f561d0b6a";
      flake = false;
    };
    hurd-src = {
      type = "git";
      url = "https://git.savannah.gnu.org/git/hurd/hurd.git";
      ref = "refs/tags/v0.9.git20260527";
      rev = "d6a94f56ef421ca92f3cd573262f6a096191b240";
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
      type = "tarball";
      url = "https://ftp.gnu.org/gnu/binutils/binutils-2.46.1.tar.xz";
      flake = false;
    };
    gcc-src = {
      type = "tarball";
      url = "https://ftp.gnu.org/gnu/gcc/gcc-16.1.0/gcc-16.1.0.tar.xz";
      flake = false;
    };
    # NOTE: building glibc REQUIRES a case-sensitive /nix/store (case-sensitive
    # APFS volume on macOS; any Linux fs is fine).  glibc's build emits per-subdir
    # stamp.os (shared) and stamp.oS (static-nonshared) sentinels that differ only
    # in case, so a case-insensitive store collapses them and corrupts the build.
    # Bumping this URL re-runs glibc from source, so it hits that requirement -
    # keep your store case-sensitive when updating.  (Only BUILDING glibc needs
    # this; the shipped buildtree is canonicalised collision-free, so consuming the
    # toolchain - incl. hurd-stubs RPC regen - works on a case-insensitive store.)
    glibc-src = {
      type = "tarball";
      url = "https://ftp.gnu.org/gnu/glibc/glibc-2.43.tar.xz";
      flake = false;
    };

    # Overridable ALIASES of the pins - what the Makefile's in-tree overrides
    # rebind (--override-input <m>-dev-src src/<m>).  Each tracks upstream
    # master on savannah, so plain in-tree dev work and `make src` follow the
    # latest source - typically AHEAD of the frozen *-src tag nix builds from,
    # so the alias-side drv legitimately differs from the pin-side (that's the
    # point: dev against HEAD, ship from the tag).  The explicit `flake = false`
    # is required: overriding an alias without it makes nix demand a flake.nix
    # in the override path.
    gnumach-dev-src = {
      type = "git";
      url = "https://git.savannah.gnu.org/git/hurd/gnumach.git";
      ref = "master";
      flake = false;
    };
    mig-dev-src = {
      type = "git";
      url = "https://git.savannah.gnu.org/git/hurd/mig.git";
      ref = "master";
      flake = false;
    };
    hurd-dev-src = {
      type = "git";
      url = "https://git.savannah.gnu.org/git/hurd/hurd.git";
      ref = "master";
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
      url = "path:.build-rev";
      flake = false;
    };

    # Sidekick microVM builder (darwin-only Linux-tool runner).  microvm.nix is
    # used only to BUILD the guest (erofs store image + kernel + initrd +
    # kernelParams); we drive vfkit ourselves (flakes/sidekick).  Follows the
    # branch nixpkgs so the guest's tools track the same set as the dev shell.
    # The guest is kept OUT of the dist/toolchain closures (determinism firewall).
    microvm = {
      url = "github:microvm-nix/microvm.nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

  };

  outputs =
    inputs@{
      self,
      nixpkgs,
      nixpkgs-toolchain,
      gnumach-src,
      mig-src,
      hurd-src,
      binutils-src,
      gcc-src,
      glibc-src,
      gnumach-dev-src,
      mig-dev-src,
      hurd-dev-src,
      build-rev,
      microvm,
      ...
    }:
    let
      # The real build rev when the Makefile overrides `build-rev`; null when the
      # committed "unknown" fallback is in place (composeVersion then uses self).
      buildRevToken =
        let
          raw = nixpkgs.lib.removeSuffix "\n" (builtins.readFile "${build-rev}/rev");
        in
        if raw != "unknown" then raw else null;
      # Host systems this flake supports - the four we actually build/cache on
      # (the CI matrices in cache-toolchains / toolchain-sanity-check mirror these).
      # The build target is cross-compiled and chosen via `nix develop .#<target>`,
      # independent of host.
      supportedSystems = [
        "aarch64-darwin"
        "x86_64-darwin"
        "aarch64-linux"
        "x86_64-linux"
      ];
      forAllSystems = f: nixpkgs.lib.genAttrs supportedSystems f;

      # Cross targets we know how to build for (see ./target-archs.nix).
      targets = import ./target-archs.nix;

      # The cross-toolchain barrel: the dev shell (in-tree builds) + the
      # host-system -> default-target map.  The `<cpu>-gnu` Hurd toolchain itself
      # (binutils/gcc/glibc) is built from source in packages.nix.  See
      # flakes/cross-toolchain.
      crossToolchain = import ./flakes/cross-toolchain { inherit nixpkgs nixpkgs-toolchain; };

      # packages.<system> + apps.<system> wiring.  Extracted to ./packages.nix
      # so adding a sub-flake doesn't touch flake.nix / target-archs.nix and
      # thus doesn't retrigger the toolchain-cache CI.
      pkgOutputs = import ./packages.nix {
        inherit
          nixpkgs
          nixpkgs-toolchain
          self
          forAllSystems
          targets
          crossToolchain
          buildRevToken
          gnumach-src
          mig-src
          hurd-src
          binutils-src
          gcc-src
          glibc-src
          gnumach-dev-src
          mig-dev-src
          hurd-dev-src
          ;
      };

      # --- Sidekick: a darwin-only microVM that transparently runs the Linux-only
      # build tools (localedef/abidiff/pahole/grub-mkrescue/...).  microvm.nix
      # builds the guest for the host's NATIVE Linux arch; our launcher drives
      # vfkit.  Entirely outside the dist/toolchain closures.  See flakes/sidekick.
      sidekickGuests = {
        "aarch64-linux" = "Image"; # host's linuxTarget (kernel image name)
        "x86_64-linux" = "bzImage";
      };
      sidekickConfigs = nixpkgs.lib.mapAttrs (
        guestSystem: _:
        nixpkgs.lib.nixosSystem {
          system = guestSystem;
          # x86_64 grub2 supplies the i386-pc (x86 BIOS) modules for grub-mkrescue;
          # the guest's own grub tools are cross-capable. Same package on x86_64.
          specialArgs.sidekickI386Grub = nixpkgs.legacyPackages.x86_64-linux.grub2;
          modules = [
            microvm.nixosModules.microvm
            ./flakes/sidekick/guest.nix
          ];
        }
      ) sidekickGuests;
      # host darwin system -> guest linux system
      sidekickGuestFor = {
        "aarch64-darwin" = "aarch64-linux";
        "x86_64-darwin" = "x86_64-linux";
      };
      mkSidekickHost =
        system: guestSystem:
        import ./flakes/sidekick/host.nix {
          inherit (nixpkgs) lib;
          hostPkgs = nixpkgs.legacyPackages.${system};
          guestPkgs = nixpkgs.legacyPackages.${guestSystem};
          guestConfig = sidekickConfigs.${guestSystem}.config;
          linuxTarget = sidekickGuests.${guestSystem};
        };
    in
    {
      # NixOS guests (built on Linux/CI, substituted on darwin from cachix).
      nixosConfigurations = nixpkgs.lib.mapAttrs' (
        guestSystem: cfg: nixpkgs.lib.nameValuePair "sidekick-${guestSystem}" cfg
      ) sidekickConfigs;

      # `default` picks the target whose CPU matches the host, so `nix develop`
      # without an explicit `.#<name>` works out of the box. Override with
      # `nix develop .#x86_64` (or whichever) for a deliberate cross-target.
      devShells = forAllSystems (
        system:
        let
          pkgsFor = self.packages.${system};
          # crossTarget (`<cpu>-gnu`) -> userland target name, so each shell
          # (incl. the xen variants, which share a crossTarget with their CPU
          # sibling) picks the right `toolchain-<arch>`.
          toolchainNameByCrossTarget = nixpkgs.lib.listToAttrs (
            nixpkgs.lib.mapAttrsToList (n: t: nixpkgs.lib.nameValuePair t.crossTarget n) (
              nixpkgs.lib.filterAttrs (_: t: (t.platform or null) != "xen") targets
            )
          );
          # One shell per target.  Pass the wrapped toolchain + each target's
          # own derivations so the shell wires CC/binutils and infers its
          # build tools from them (see mkDevShell) instead of re-listing.
          shells = nixpkgs.lib.mapAttrs (
            name: target:
            let
              tcName = toolchainNameByCrossTarget.${target.crossTarget};
            in
            crossToolchain.mkDevShell system name target {
              # The from-source unwrapped toolchain (cross-gcc + cross-binutils),
              # the glibc-hurd sysroot it bakes, and the bootstrap-gcc (subtracted
              # from PATH).  Keyed by the CPU sibling so a xen variant reuses it.
              cc = pkgsFor."cross-gcc-${tcName}";
              binutils = pkgsFor."cross-binutils-${tcName}";
              sysroot = pkgsFor."glibc-hurd-${tcName}";
              bootstrapGcc = pkgsFor."bootstrap-gcc-${tcName}";
              gnumach = pkgsFor."gnumach-${name}";
              # mig keyed by the CPU sibling: a xen variant's shell reuses mig-<cpu>
              # - the same tool either way (the kernels build with the sibling's
              # checked mig), so the xen-keyed raw mig would only add a pointless build.
              mig = pkgsFor."mig-${tcName}";
              headers = pkgsFor."gnumach-headers-${name}";
              # Sidekick dispatcher (darwin only) — the shell shims the Linux-only
              # tools to it; null on Linux (those tools run natively there).
              sidekickRun =
                if sidekickGuestFor ? ${system} then
                  (mkSidekickHost system sidekickGuestFor.${system}).sidekick-run
                else
                  null;
            }
          ) targets;
        in
        shells // { default = shells.${crossToolchain.defaultTargetName system targets}; }
      );

      # packages.<system> and apps.<system> (`nix run .#<arch>`) - mostly defined
      # in ./packages.nix.  We add `lint-tools`: a symlinkJoin of the pinned lint/
      # format tools (flakes/lint/tools.nix) that `make lint`/`fmt`, the pre-commit
      # hook, and the lint CI resolve as ONE store path - so a contributor outside a
      # dev shell gets the exact same tools.
      packages = forAllSystems (
        system:
        pkgOutputs.packages.${system}
        // {
          lint-tools = nixpkgs.legacyPackages.${system}.symlinkJoin {
            name = "lint-tools";
            paths = import ./flakes/lint/tools.nix nixpkgs.legacyPackages.${system};
          };
        }
        # Sidekick: every system exposes `sidekick-guest` (linux hosts build their
        # own arch's guest for CI/cache; darwin substitutes the matching arch).
        # `sidekick-run` (the dispatcher) is darwin-only — Linux runs tools natively.
        // (
          let
            isDarwin = sidekickGuestFor ? ${system};
            guestSystem =
              if isDarwin then
                sidekickGuestFor.${system}
              else if sidekickGuests ? ${system} then
                system
              else
                null;
          in
          nixpkgs.lib.optionalAttrs (guestSystem != null) (
            let
              sk = mkSidekickHost system guestSystem;
            in
            {
              inherit (sk) sidekick-guest;
            }
            // nixpkgs.lib.optionalAttrs isDarwin { inherit (sk) sidekick-run; }
          )
        )
      );
      inherit (pkgOutputs) apps;

      # Source pins (owner/repo/ref/rev/url) from the inputs via flake.lock.  `srcs`
      # = the frozen `*-src` pins (what `make pin-src` bumps / `make show-src-pins`
      # reports); `devSrcs` = the `*-dev-src` aliases that in-tree overrides rebind, so
      # `make src` clones the source the in-tree build actually uses.  See flakes/sources.
      srcs = (import ./flakes/sources { inherit (nixpkgs) lib; }).all self inputs;
      devSrcs = (import ./flakes/sources { inherit (nixpkgs) lib; }).allDev self inputs;
    };
}
