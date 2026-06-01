# The single per-(host, target) development shell — `nix develop .#<arch>`.
#
# One shell drives every in-tree build: `make mach` (the freestanding
# gnumach kernel), `make mig` (the host-side MIG codegen tool), and
# `make hurd` (the userland servers).  They all use the SAME wrapped
# `<cpu>-gnu` cross-cc (cross-toolchain/toolchain.nix → `toolchain-<arch>`):
# the kernel builds freestanding (gnumach's configure forces
# `-ffreestanding -nostdlib`), the userland builds hosted against
# glibc-hurd.
#
# Build TOOLS (autoreconf, bison/flex, perl, texinfo, …) are INFERRED from
# this target's own derivations (gnumach + mig + gnumach-headers) — add a
# tool to a package's nativeBuildInputs and the shell picks it up.  The
# nix-built working mig IS added to the shell (and exported as $MIG / $USER_MIG)
# so mig is always available without a `make mig`; running `make src-mig` to
# populate src/mig opts into an in-tree mig that the Makefile builds and uses
# instead.  The libc-free stage-1 cc is SUBTRACTED so its prefixed gcc can't
# shadow the wrapped cc on PATH.
#
# The cross compiler + binutils are wired by ABSOLUTE path in the shellHook
# (CC/CXX from the wrapped toolchain; LD/AR/NM/… from the unwrapped cross
# binutils) so configure + recursive sub-makes resolve to exactly these,
# regardless of PATH ordering.  HURD_CONFIGURE_FLAGS carries the same flag
# set the nix Hurd build uses (hurd-config.nix); the Makefile's hurd recipe
# adds `CFLAGS=-fcommon` at configure time (hurd predates gcc's -fno-common
# default), so -fcommon stays scoped to the userland — the kernel never
# sees it.

{ nixpkgs, mkCrossPkgs }:

let
  lib = nixpkgs.lib;
  hurdConfig = import ./hurd-config.nix;
in

{
  # mkDevShell : system -> name -> target -> { toolchain, gnumach, mig,
  #              headers } -> shell.  `toolchain` is the wrapped cc
  #              (toolchain-<arch>, or the CPU sibling's for a xen variant);
  #              gnumach/mig/headers are this target's derivations, used for
  #              build-tool inference (and mig/headers/gnumach for subtraction).
  mkDevShell = system: name: target: { toolchain, gnumach, mig, headers }:
    let
      pkgs      = nixpkgs.legacyPackages.${system};
      crossPkgs = mkCrossPkgs system target;

      # Unwrapped cross binutils — absolute source of the prefixed
      # ld/ar/nm/ranlib/strip/objcopy.  The wrapped `toolchain` supplies
      # cc/c++; using the unwrapped binutils for the rest sidesteps any
      # ambiguity about what the cc-wrapper re-exports.
      binu  = crossPkgs.buildPackages.binutils-unwrapped;
      # The wrapped cc's target prefix ("i686-gnu-") — drives both the
      # toolchain bin names and binu's (same crossSystem).
      tp    = toolchain.targetPrefix;
      coreFlags = lib.concatStringsSep " " hurdConfig.coreFlags;

      # Build-tool deps inferred from this target's own derivations rather
      # than re-listed.  Subtract the own packages AND the libc-free stage-1
      # cc: mig is subtracted HERE so a mig pulled in via gnumach's build
      # inputs doesn't sneak onto PATH through inference — the shell's mig is
      # instead the `mig` arg, added explicitly + exported below.  The stage-1
      # cc must not land on PATH where its prefixed gcc could shadow the
      # wrapped cc.
      stage1 = crossPkgs.buildPackages.gccWithoutTargetLibc;
      ownDrvs = [ gnumach mig headers toolchain stage1 ];
      inferredBuildInputs = lib.subtractLists ownDrvs
        (lib.unique (lib.concatMap (d: d.nativeBuildInputs or []) [ gnumach mig headers ]));
    in
    pkgs.mkShell {
      # Inferred tools (autoreconfHook + bison/flex/perl/texinfo) come via
      # inferredBuildInputs.  Here we add the toolchain + binutils (for
      # PATH) and the dev/run-only extras the packages don't declare:
      #   gcc        native compiler for in-tree `make mig` (a host tool)
      #   pkg-config hurd's optional PKG_CHECK probes
      #   git/nix    source ops + Makefile re-dispatch into a target shell
      #   qemu       qemu-system-* (+ qemu-img) for `make run`
      #   curl/which run scenarios + gnumach's run-qemu.sh test gate
      #   fakeroot   `make dist-hurd` install: hurd's daemons/utils install
      #              some programs -o root -m 4755 (setuid); fakeroot fakes
      #              the chown/setuid so a non-root install completes.
      # gnumake + awk + coreutils come from stdenv.
      nativeBuildInputs =
        [ toolchain binu mig ]
        ++ inferredBuildInputs
        ++ (with pkgs; [ gcc pkg-config git nix qemu curl which fakeroot ])
        # gnumach's x86 `make check` builds a multiboot ISO with
        # grub-mkrescue (needs xorriso + mtools) and the run scenarios
        # build/boot images; nixpkgs' grub2 is linux-only, so gate on
        # x86 + linux hosts.
        ++ lib.optionals
             ((lib.hasPrefix "x86_64-" target.crossTarget || lib.hasPrefix "i686-" target.crossTarget)
              && lib.hasSuffix "-linux" system)
             [ pkgs.grub2 pkgs.xorriso pkgs.mtools ];

      shellHook = ''
        export ARCH=${name}
        export GNUMACH_HOST=${target.crossTarget}
        export MIG_TARGET=${target.crossTarget}
        ${if target.platform != null
          then "export GNUMACH_PLATFORM=${target.platform}"
          else "unset GNUMACH_PLATFORM"}

        # Cross tools by ABSOLUTE path so configure + sub-makes use exactly
        # these (never a host tool, never the stage-1 cc).  CC/CXX come from
        # the wrapped toolchain; the binutils from the unwrapped cross
        # binutils.  TARGET_CC is what MIG's cpu.symc compile uses.
        export CC=${toolchain}/bin/${tp}gcc
        export CXX=${toolchain}/bin/${tp}g++
        export TARGET_CC=${toolchain}/bin/${tp}gcc
        export LD=${binu}/bin/${tp}ld
        export AR=${binu}/bin/${tp}ar
        export NM=${binu}/bin/${tp}nm
        export RANLIB=${binu}/bin/${tp}ranlib
        export STRIP=${binu}/bin/${tp}strip
        export OBJCOPY=${binu}/bin/${tp}objcopy

        # The nix-built working mig — always available so mach/hurd build with
        # no `make mig`.  The Makefile uses $MIG unless an in-tree src/mig opts
        # in (`make src-mig`), in which case it builds + uses that instead.
        export MIG=${mig}/bin/${tp}mig
        export USER_MIG=${mig}/bin/${tp}mig

        # Empty so hurd's optional PKG_CHECK probes find nothing (matches
        # the nix build).  No global CFLAGS: the kernel takes autoconf's
        # `-g -O2` default (+ its own -ffreestanding -nostdlib); the hurd
        # recipe adds -fcommon at configure time.
        export PKG_CONFIG_PATH=
        # Same configure flag set as the nix Hurd build (hurd-config.nix).
        export HURD_CONFIGURE_FLAGS="--host=${target.crossTarget} ${coreFlags}"
      '';
    };
}
