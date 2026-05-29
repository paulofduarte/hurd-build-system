# Cross-toolchain dev-shell builder.
#
# Builds one development shell per (host system, cross target).  This is
# the only place in the flake that imports nixpkgs with `crossSystem` set;
# everything else (gnumach-headers, mig, sidekick) works with the
# host-side `legacyPackages.<system>` only.
#
# Returned API (`{ mkDevShell, mkCrossPkgs, mkToolchain, defaultTargetName }`):
#
#   mkDevShell : system -> name -> target -> derivation
#       `system` is a host-side system identifier ("aarch64-darwin", …).
#       `name` is the project's internal target slug ("aarch64", "i686-xen", …).
#       `target` is one entry from the `targets` attrset in the root flake;
#       its `crossSystem`, `migTarget`, and `platform` fields drive both
#       the toolchain selection and the shellHook env vars.
#
#   mkCrossPkgs : system -> target -> pkgs
#       Single source of truth for "import nixpkgs with the right cross
#       config + the darwin overlays".  All sub-flakes consume it so the
#       cross-pkgs construction (and its patches) is identical everywhere.
#
#   mkToolchain : system -> target -> derivation
#       The cross-toolchain as a standalone, buildable derivation (the wrapped
#       cross `cc`, with the patched binutils + newlib in its closure).  The
#       single definition of "the toolchain" — exposed as
#       `packages.<sys>.toolchain-<arch>` so the cache workflow + cache-hit
#       planner reference that output rather than reaching into `stdenv.cc`.
#
#   defaultTargetName : system -> name
#       Maps a host system to the project target whose ABI is closest to
#       it.  Used by the root flake to expose
#       `devShells.<system>.default`.

{ nixpkgs }:

let
  inherit (nixpkgs) lib;

  mkCrossPkgs = system: target:
    let
      # Probe nixpkgs once with no overlays + no crossSystem to discover
      # the current default gcc attribute name ("gcc14" today, "gcc15"
      # tomorrow).  The gnuConfigOverlay below overrides that attribute
      # by name; reading it dynamically keeps a nixpkgs bump from
      # silently breaking this flake.
      probePkgs = import nixpkgs { localSystem = { inherit system; }; };
      gccAttr   = "gcc${lib.versions.major probePkgs.gcc.version}";

      # x86_64-darwin's stdenv is the only one missing
      # `updateAutotoolsGnuConfigScriptsHook` (26.05 is the last nixpkgs
      # release to support x86_64-darwin, so it won't be fixed upstream).
      # Without the hook, the affected derivations keep their bundled
      # 2021-vintage config.sub, which rejects `*-unknown-none-elf` with
      # "Kernel `none' not known to work with OS `elf'" (fixed only in
      # nixpkgs' replacement config.sub).  Add the hook to the three
      # bootstrap derivations that need it: the final cross-GCC
      # (${gccAttr}), the stage-1 gccWithoutTargetLibc, and newlib.  The
      # GCCs are wrapped — re-route via `.override { cc = …; }` so the
      # wrap-time args survive; newlib is plain, so `.overrideAttrs`.
      gnuConfigOverlay = final: prev:
        let
          hook = prev.buildPackages.updateAutotoolsGnuConfigScriptsHook;
          addHookAttrs = drv: drv.overrideAttrs (old: {
            nativeBuildInputs = (old.nativeBuildInputs or []) ++ [ hook ];
          });
          addHookToCc = wrapped: wrapped.override {
            cc = addHookAttrs wrapped.cc;
          };
        in {
          "${gccAttr}"         = addHookToCc prev.${gccAttr};
          gccWithoutTargetLibc = addHookToCc prev.gccWithoutTargetLibc;
          newlib               = addHookAttrs prev.newlib;
        };

      # gas left at chunksize=0 takes the obstack library's *default* chunk
      # size, which differs between glibc's and libiberty's obstack.  That
      # shifts frag_grow's chunk-exhaustion split points, flipping the
      # `.debug_line` encoding (DW_LNE_set_address vs a relative advance) for
      # identical input — so the same source assembled to byte-different `.o`
      # across build hosts.  This patch pins chunksize.
      #
      # Scoped via `hostPlatform.config != targetPlatform.config` so it
      # patches only the cross-targeting binutils.  That also rebuilds the
      # cross-gcc against the patched `as`, making its bundled libgcc (linked
      # into every kernel) deterministic too — while leaving the native
      # toolchain untouched (a global overlay would cascade a native rebuild
      # on Linux).
      chunksizeOverlay = final: prev:
        lib.optionalAttrs
          (prev.stdenv.hostPlatform.config != prev.stdenv.targetPlatform.config)
          {
            binutils-unwrapped = prev.binutils-unwrapped.overrideAttrs (old: {
              patches = (old.patches or [])
                ++ [ ./patches/binutils-2.44-gas-deterministic-chunksize.patch ];
            });
          };
    in
    import nixpkgs {
      localSystem = { inherit system; };
      crossSystem = target.crossSystem;
      overlays = [ chunksizeOverlay ]
        ++ lib.optional (system == "x86_64-darwin") gnuConfigOverlay;
    };

  # The cross-toolchain as a standalone derivation — the wrapped cross `cc`,
  # whose closure is exactly our custom toolchain (gcc + the chunksize-patched
  # binutils + newlib).  Single definition of "the toolchain"; callers use the
  # `packages.<sys>.toolchain-<arch>` output rather than reaching into stdenv.
  mkToolchain = system: target: (mkCrossPkgs system target).stdenv.cc;

  # `targetPkgs` is { gnumach, mig, headers } — this target's three nix
  # derivations, passed in from the root flake's devShells.
  mkDevShell = system: name: target: targetPkgs:
    let
      pkgs = nixpkgs.legacyPackages.${system};

      # GNU Mach is a freestanding microkernel — no libc, no hosted OS.
      # Use a bare-metal cross-toolchain for the chosen target.
      crossPkgs = mkCrossPkgs system target;

      # The cross-toolchain's binary prefix (e.g. "aarch64-unknown-none-elf-").
      # Includes the trailing "-".
      toolPrefix = crossPkgs.stdenv.cc.targetPrefix;

      # Build-tool deps are INFERRED from this target's own derivations
      # (gnumach + mig + gnumach-headers) rather than duplicated here: add a
      # tool to a package's nativeBuildInputs and the dev shell picks it up.
      # Subtract our own built packages so crossMig (a gnumach nativeBuildInput)
      # isn't pulled in — the dev shell builds mig in-tree, and depending on
      # the nix-built mig would force a nix build of it just to ENTER the
      # shell, defeating in-tree mig iteration.
      ownDrvs = lib.attrValues targetPkgs;
      inferredBuildInputs = lib.subtractLists ownDrvs
        (lib.unique (lib.concatMap (d: d.nativeBuildInputs) ownDrvs));
    in
    crossPkgs.mkShell {
      # Inferred build tools (autoreconfHook + bison/flex/perl/texinfo + the
      # cross cc) come via inferredBuildInputs.  Here we add only the
      # dev/run-only extras the packages don't need.  gnumake + awk +
      # coreutils/sed/grep/tar/gzip come from stdenv (present in `nix develop`
      # too), so they're not listed.
      nativeBuildInputs =
        inferredBuildInputs
      ++ (with pkgs; [
        gcc              # native compiler for in-tree `make mig` (host tool)
        git              # read-only ops + `git clean -fdX` for mrproper
        nix              # so the Makefile can re-dispatch into a different target shell
        qemu             # qemu-system-* (incl. qemu-img) for running the kernel
        curl             # flakes/run/hurd-*.sh fetches distro images over HTTPS
        which            # gnumach's run-qemu.sh test runner uses `which` to gate tests
      ])
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

        # Target identity for the top-level Makefile.  MIG itself is a
        # *built* artefact (from `make mig` or `nix build .#mig-<arch>`)
        # — the Makefile derives its absolute path from MIG_TARGET when
        # it needs it, so the dev shell doesn't put MIG on PATH or
        # export a bare-name `MIG=` (which would resolve to nothing).
        # When you need the wrapper interactively, point at
        # ./work/mig/$ARCH/install/bin/$MIG_TARGET-mig (in-tree) or
        # the nix-built result-$ARCH symlink under flakes/mig/.
        export ARCH=${name}
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
  inherit mkDevShell mkCrossPkgs mkToolchain defaultTargetName;
}
