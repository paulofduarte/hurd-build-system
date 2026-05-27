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
      # a new target; everything in mkDevShell consumes from this attrset.
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

      # Build one dev shell for (host system, target).
      mkDevShell = system: name: target:
        let
          pkgs = nixpkgs.legacyPackages.${system};

          # GNU Mach is a freestanding microkernel — no libc, no hosted OS.
          # Use a bare-metal cross-toolchain for the chosen target.
          crossPkgs = import nixpkgs {
            localSystem = { inherit system; };
            crossSystem = target.crossSystem;
            # x86_64-darwin's stdenv is the only one missing
            # `updateAutotoolsGnuConfigScriptsHook` from defaultNativeBuildInputs
            # (verified on master + nixos-unstable as of 2026-05-27 — and 26.05
            # is the last nixpkgs release to support x86_64-darwin, so this
            # won't be fixed upstream).  Without that hook, GCC 14's bundled
            # 2021-vintage config.sub stays in the source tree, and it rejects
            # the cross triple `aarch64-unknown-none-elf` with "Kernel `none'
            # not known to work with OS `elf'" — the Aug-2023 gnu-config patch
            # that added that case is only in nixpkgs' replacement config.sub
            # (`gnu-config-2024-01-01`), not in GCC's bundled one.
            #
            # Two cross-GCC derivations participate in the bootstrap: the
            # final `gcc14` and the stage-1 `gccWithoutTargetLibc` (built
            # first, used to compile newlib).  Both share the same broken
            # bundled config.sub and need the hook.  Override `.cc` via the
            # wrapper's own `.override` so the wrap-time args (`bintools`,
            # `libc`, `withoutTargetLibc`) stay intact.
            overlays = nixpkgs.lib.optionals (system == "x86_64-darwin") [
              (final: prev:
                let
                  withConfigSubHook = wrapped: wrapped.override {
                    cc = wrapped.cc.overrideAttrs (old: {
                      nativeBuildInputs = (old.nativeBuildInputs or [])
                        ++ [ prev.buildPackages.updateAutotoolsGnuConfigScriptsHook ];
                    });
                  };
                in {
                  gcc14                = withConfigSubHook prev.gcc14;
                  gccWithoutTargetLibc = withConfigSubHook prev.gccWithoutTargetLibc;
                })
            ];
          };

          # The cross-toolchain's binary prefix (e.g. "aarch64-unknown-none-elf-").
          # Includes the trailing "-".
          toolPrefix = crossPkgs.stdenv.cc.targetPrefix;
        in
        crossPkgs.mkShell {
          nativeBuildInputs = [
            crossPkgs.stdenv.cc      # cross-toolchain (kernel)
            pkgs.gcc                 # native compiler for host tools (MIG)
            pkgs.autoconf
            pkgs.automake
            pkgs.gnumake
            pkgs.bison
            pkgs.flex
            pkgs.gawk          # MIG's cpu.sym is generated via awk
            pkgs.gnum4         # MIG's autoreconf needs m4
            pkgs.perl          # MIG's wrapper script uses perl at runtime
            pkgs.texinfo
            pkgs.git           # read-only ops + `git clean -fdX` for mrproper
            pkgs.nix           # so the Makefile can re-dispatch into a different target shell
            pkgs.qemu          # provides qemu-system-* (incl. qemu-img) for running the kernel
            pkgs.curl          # tools/run/hurd-*.sh fetches distro images over HTTPS
            pkgs.which         # gnumach's run-qemu.sh test runner uses `which` to gate test execution
          ]
          # gnumach's kernel-side `make check` on x86 builds a multiboot
          # ISO with grub-mkrescue (which itself needs xorriso + mtools)
          # and boots it under qemu-system-{i386,x86_64} -cdrom.  Pull
          # those tools in only for x86 targets and only on Linux hosts —
          # nixpkgs's grub2 has meta.platforms = linux-only (GRUB doesn't
          # compile cleanly on darwin).
          ++ nixpkgs.lib.optionals
               ((target.crossSystem == "x86_64-elf" || target.crossSystem == "i686-elf")
                && nixpkgs.lib.hasSuffix "-linux" system)
               [ pkgs.grub2 pkgs.xorriso pkgs.mtools ]
          # aarch64 tests build a FAT image per test (gnumach + module
          # + u-boot boot.scr) and boot it through u-boot running under
          # qemu-system-aarch64, which then does the `fdt mknod` dance
          # from aarch64/BOOTING.  u-boot's bootflow scanner expects a
          # partitioned disk, so we add an MBR via sfdisk (util-linux)
          # and create the FAT inside the partition via mtools' @@<off>
          # notation.  Pull in u-boot, mkimage, sfdisk, mkfs.vfat, and
          # mcopy only on aarch64-linux hosts: nixpkgs's ubootQemuAarch64
          # has `meta.platforms = ["aarch64-linux"]` (the others are
          # linux-generic, but the constraint is aarch64-linux-or-bust),
          # so x86_64-linux hosts must skip the whole block.  Those
          # hosts can still cross-build the aarch64 kernel itself —
          # only the in-tree `make check-mach` test harness is gated.
          ++ nixpkgs.lib.optionals
               (target.crossSystem == "aarch64-none-elf"
                && system == "aarch64-linux")
               [ pkgs.ubootQemuAarch64 pkgs.ubootTools
                 pkgs.util-linux pkgs.dosfstools pkgs.mtools ];

          shellHook = ''
            # GCC 15+ defaults to C23 mode, which is stricter about function
            # types — `(*)()` no longer means "K&R unspecified" but `(void)`,
            # so older Mach code (parts of upstream + Bugaev's wip-aarch64)
            # fails to compile. Pin gnu17 globally so every target builds.
            export CFLAGS="-std=gnu17 -g -O2"

            # pkgs.gcc's setup-hook puts native binutils on PATH, whose
            # unprefixed `ld`/`ar`/`nm` shadow the cross ones. gnumach's
            # configure tries the host-triple prefix first, then falls back
            # to bare names — which would pick up the wrong (host) tools.
            # Pin every cross tool by absolute name so configure uses what
            # we actually want.
            export CC=${toolPrefix}gcc
            export LD=${toolPrefix}ld
            export AR=${toolPrefix}ar
            export NM=${toolPrefix}nm
            export RANLIB=${toolPrefix}ranlib
            export STRIP=${toolPrefix}strip
            export OBJCOPY=${toolPrefix}objcopy

            # Cross-target compiler MIG's configure picks up for the cpu.sym
            # build step.
            export TARGET_CC=${toolPrefix}gcc

            # Pin MIG so AC_CHECK_TOOL respects it instead of falling back to
            # bare `mig` (which doesn't exist).
            export MIG=${target.migTarget}-mig

            # Target identity for the top-level Makefile.
            export TARGET=${name}
            export GNUMACH_HOST=${target.crossSystem}
            export MIG_TARGET=${target.migTarget}
            ${if target.platform != null
              then "export GNUMACH_PLATFORM=${target.platform}"
              else "unset GNUMACH_PLATFORM"}

            # aarch64 tests need an explicit u-boot binary path because
            # qemu's -bios is resolved against qemu's own data dir, not
            # the dev shell's PATH.  Point at nixpkgs's
            # ubootQemuAarch64 output explicitly.  Same aarch64-linux-
            # only constraint as the nativeBuildInputs block above —
            # ubootQemuAarch64's meta.platforms is ["aarch64-linux"].
            ${if target.crossSystem == "aarch64-none-elf"
                && system == "aarch64-linux"
              then "export UBOOT_BIN=${pkgs.ubootQemuAarch64}/u-boot.bin"
              else "unset UBOOT_BIN"}

            # Local toolchain — anything installed here (MIG, etc.) becomes
            # visible to the next configure run. Enter the dev shell from
            # the project root for this to resolve correctly.
            export PATH="$PWD/toolchain/bin:$PATH"
          '';
        };
    in
    {
      # `default` picks the target whose CPU matches the host, so `nix develop`
      # without an explicit `.#<name>` works out of the box. Override with
      # `nix develop .#x86_64` (or whichever) for a deliberate cross-target.
      devShells = forAllSystems (system:
        let
          shells = nixpkgs.lib.mapAttrs (name: target: mkDevShell system name target) targets;
          # Pick the cross-target whose ABI is closest to the host CPU.
          # Hosts without a matching cross-target (armv6l/armv7l/riscv64/
          # powerpc64le) fall through to aarch64 — the most generic 64-bit
          # default. Override with `nix develop .#<target>` for anything else.
          defaultName =
            if nixpkgs.lib.hasPrefix "aarch64-" system then "aarch64"
            else if nixpkgs.lib.hasPrefix "x86_64-" system then "x86_64"
            else if nixpkgs.lib.hasPrefix "i686-" system then "i686"
            else "aarch64";
        in
        shells // { default = shells.${defaultName}; }
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
          gnumachHeaders = import ./toolchain/gnumach-headers {
            inherit pkgs system targets;
            lib = nixpkgs.lib;
          };
          migs = import ./toolchain/mig {
            inherit pkgs system targets gnumachHeaders;
            lib = nixpkgs.lib;
          };
        in
        {
          sidekick = import ./tools/sidekick/default.nix { inherit pkgs; };
        } // gnumachHeaders // migs);
    };
}
