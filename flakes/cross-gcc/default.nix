# Cross-toolchain dev-shell builder.
#
# Builds one development shell per (host system, cross target).  This is
# the only place in the flake that imports nixpkgs with `crossSystem` set;
# everything else (gnumach-headers, mig, sidekick) works with the
# host-side `legacyPackages.<system>` only.
#
# Returned API (`{ mkDevShell, mkCrossPkgs, defaultTargetName }`):
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
#       config + every darwin overlay applied".  All sub-flakes consume
#       this so they share one cross-pkgs construction — without it,
#       only the cross-gcc dev shell got the overlays and standalone
#       `nix build .#{mig,gnumach-headers,gnumach}-<arch>` on darwin
#       would fall back to the un-patched cross-toolchain.
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
      # `updateAutotoolsGnuConfigScriptsHook` from defaultNativeBuildInputs
      # (verified on master + nixos-unstable as of 2026-05-27 — and 26.05
      # is the last nixpkgs release to support x86_64-darwin, so this
      # won't be fixed upstream).  Without that hook, the affected
      # derivations' own bundled 2021-vintage config.sub stays in the
      # source tree, and it rejects the cross triples
      # `{aarch64,x86_64,i686}-unknown-none-elf` with "Kernel `none' not
      # known to work with OS `elf'" — the Aug-2023 gnu-config patch that
      # added that case is only in nixpkgs' replacement config.sub
      # (`gnu-config-2024-01-01`), not in the bundled ones.
      #
      # Three derivations in the cross-toolchain bootstrap need the hook
      # added explicitly:
      #
      #   ${gccAttr}           — final cross-GCC.
      #   gccWithoutTargetLibc — stage-1 GCC, used to compile newlib.
      #   newlib               — the bare-metal libc; cross-GCC builds
      #                          depend on it.
      #
      # The two GCCs are wrapped-CC derivations: re-route via the
      # wrapper's `.override { cc = ... }` so the wrap-time args
      # (`bintools`, `libc`, `withoutTargetLibc`) stay intact.  newlib
      # is a plain derivation, so `.overrideAttrs` adds the hook to its
      # nativeBuildInputs directly.
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

      # Import the cross package set.  The only overlay here is the
      # x86_64-darwin config.sub hook fix; the gas reproducibility patch
      # is applied as a scoped derivation override below — deliberately
      # NOT a global overlay (see crossCC).
      # gas leaves its obstack chunk size at 0, which makes the obstack
      # library pick an implementation-defined default (`4096 - extra`,
      # where `extra` differs between glibc's and libiberty's obstack).
      # That makes `frag_grow`'s chunk-exhaustion split points depend on
      # which libc gas was built against, which perturbs the `.debug_line`
      # program (DW_LNE_set_address vs a relative advance) for identical
      # input — so the SAME kernel source produced byte-different `.o` on
      # a darwin-host cross-as vs a linux-host one.  The patch pins
      # chunksize to a fixed value so split points are host-independent.
      # See .claude/docs/debug-line-cross-host-determinism.md for the full
      # root-cause writeup.
      #
      # Apply as a CROSS-SCOPED overlay.  The guard
      # `hostPlatform.config != targetPlatform.config` matches only the
      # binutils instances that *target* the cross arch (the host->target
      # `as`), never the native build==host==target binutils.  This is
      # load-bearing in two ways:
      #
      #   1. It rebuilds the cross-gcc against the patched `as`, so the
      #      bundled libgcc (linked into every kernel) is itself assembled
      #      with the deterministic `as`.  A post-hoc rewrap of only the
      #      kernel compiler leaves libgcc vanilla-assembled, and that
      #      libgcc alone reintroduces the cross-host `.debug_line` drift.
      #   2. The native host binutils/gcc/glibc are NOT touched (they are a
      #      different derivation — aarch64->aarch64, not aarch64->i686 —
      #      and nothing native depends on the cross toolchain).  Verified
      #      via dry-run: only `i686-*` (cross) derivations rebuild; no
      #      native cascade.  A global (unguarded) overlay would clobber
      #      the native binutils and trigger a full native rebuild on Linux.
      #
      # Applied on every host so all emit the same canonical encoding.
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

  mkDevShell = system: name: target:
    let
      pkgs = nixpkgs.legacyPackages.${system};

      # GNU Mach is a freestanding microkernel — no libc, no hosted OS.
      # Use a bare-metal cross-toolchain for the chosen target.
      crossPkgs = mkCrossPkgs system target;

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
        pkgs.curl          # flakes/run/hurd-*.sh fetches distro images over HTTPS
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
  inherit mkDevShell mkCrossPkgs defaultTargetName;
}
