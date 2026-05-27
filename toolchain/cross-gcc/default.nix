# Cross-toolchain dev-shell builder.
#
# Builds one development shell per (host system, cross target).  This is
# the only place in the flake that imports nixpkgs with `crossSystem` set;
# everything else (gnumach-headers, mig, sidekick) works with the
# host-side `legacyPackages.<system>` only.
#
# Returned API (`{ mkDevShell, defaultTargetName, overlay }`):
#
#   mkDevShell : system -> name -> target -> derivation
#       `system` is a host-side system identifier ("aarch64-darwin", …).
#       `name` is the project's internal target slug ("aarch64", "i686-xen", …).
#       `target` is one entry from the `targets` attrset in the root flake;
#       its `crossSystem`, `migTarget`, and `platform` fields drive both
#       the toolchain selection and the shellHook env vars.
#
#   defaultTargetName : system -> name
#       Maps a host system to the project target whose ABI is closest to
#       it.  Used by the root flake to expose
#       `devShells.<system>.default`.
#
#   overlay : final: prev: { … }
#       The x86_64-darwin config.sub fix (see comment on `overlay` below).
#       mkDevShell already applies it internally when the host is
#       x86_64-darwin; exposed in case an external caller wants to import
#       nixpkgs themselves with the same fix.

{ nixpkgs }:

let
  inherit (nixpkgs) lib;

  # x86_64-darwin's stdenv is the only one missing
  # `updateAutotoolsGnuConfigScriptsHook` from defaultNativeBuildInputs
  # (verified on master + nixos-unstable as of 2026-05-27 — and 26.05 is
  # the last nixpkgs release to support x86_64-darwin, so this won't be
  # fixed upstream).  Without that hook, GCC 14's bundled 2021-vintage
  # config.sub stays in the source tree, and it rejects the cross triple
  # `aarch64-unknown-none-elf` with "Kernel `none' not known to work with
  # OS `elf'" — the Aug-2023 gnu-config patch that added that case is
  # only in nixpkgs' replacement config.sub (`gnu-config-2024-01-01`),
  # not in GCC's bundled one.
  #
  # Two cross-GCC derivations participate in the bootstrap: the final
  # `gcc14` and the stage-1 `gccWithoutTargetLibc` (built first, used to
  # compile newlib).  Both share the same broken bundled config.sub and
  # need the hook.  Override `.cc` via the wrapper's own `.override` so
  # the wrap-time args (`bintools`, `libc`, `withoutTargetLibc`) stay
  # intact.
  overlay = final: prev:
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
    };

  mkDevShell = system: name: target:
    let
      pkgs = nixpkgs.legacyPackages.${system};

      # GNU Mach is a freestanding microkernel — no libc, no hosted OS.
      # Use a bare-metal cross-toolchain for the chosen target.
      crossPkgs = import nixpkgs {
        localSystem = { inherit system; };
        crossSystem = target.crossSystem;
        overlays = lib.optionals (system == "x86_64-darwin") [ overlay ];
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
      ++ lib.optionals
           ((target.crossSystem == "x86_64-elf" || target.crossSystem == "i686-elf")
            && lib.hasSuffix "-linux" system)
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
      ++ lib.optionals
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

  # Pick the cross-target whose ABI is closest to the host CPU.
  # Hosts without a matching cross-target (armv6l/armv7l/riscv64/
  # powerpc64le) fall through to aarch64 — the most generic 64-bit
  # default. Override with `nix develop .#<target>` for anything else.
  defaultTargetName = system:
    if lib.hasPrefix "aarch64-" system then "aarch64"
    else if lib.hasPrefix "x86_64-" system then "x86_64"
    else if lib.hasPrefix "i686-" system then "i686"
    else "aarch64";

in {
  inherit mkDevShell defaultTargetName overlay;
}
