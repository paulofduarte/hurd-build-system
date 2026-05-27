# GNU Mach kernel — per-target derivations.
#
# Replaces the previous Makefile dance:
#     autoreconf -i  +  USER_MIG=<wrapper> ./configure
#                       --host=<crossSystem> --prefix=<DIST>
#                       [--enable-platform=<at|xen>]
#                    +  make
#                    +  make install
# with one nix derivation per target whose output is the bootable
# kernel image + companion install tree.
#
# Output layout (whatever gnumach's `make install` produces, which
# at minimum is):
#   $out/boot/gnumach              bootable kernel (stripped binary on
#                                  aarch64; ELF on i386/x86_64 — qemu's
#                                  -kernel accepts the ELF directly).
#   $out/boot/gnumach.elf          un-stripped ELF with debug symbols
#                                  (for gdb / addr2line; qemu silently
#                                  hangs if fed this on aarch64).
#   $out/include/mach/...          public headers (same as the headers
#                                  sub-flake produces).
#   $out/share/...                 .defs + .msgids.
#
# Returned shape — one attribute per entry in `targets`, named
# `gnumach-<name>`.  The root flake merges what comes back into
# `packages.<system>`.
#
# Per-target attrset fields (mirrors flake.nix):
#   crossSystem : nixpkgs cross-system identifier — drives the cross
#                 toolchain that compiles + links the kernel.
#   migTarget   : MIG-flavor triple — used to compose the output pname
#                 + look up the matching cross-MIG sibling derivation.
#   platform    : "at" / "xen" / null — fed to gnumach's
#                 --enable-platform= flag.  Null means the option is
#                 omitted (aarch64 has no platform).
#
# Source comes from ../../src/gnumach (the git submodule).  The root
# flake's `inputs.self.submodules = true;` is what makes the submodule
# content visible to the nix store at fingerprint time.
#
# `mig` is the attrset returned by flakes/mig (the sibling sub-flake).
# We look up "mig-<name>" for the matching target and add its derivation
# to nativeBuildInputs; nixpkgs' cross-stdenv puts the wrapper's bin/
# on PATH automatically.  gnumach's configure runs `AC_CHECK_TOOL([MIG],
# [mig])` and `AC_CHECK_PROG([USER_MIG], [<migTarget>-mig])` — the mig
# sub-flake ships both the primary `<migTarget>-mig` binary AND a
# `<crossPrefix>mig` symlink alias, so both checks self-discover via
# PATH with no `MIG=` override needed here.
#
# Tests are intentionally disabled (doCheck = false) until the kernel
# test-suite is wired up to run inside the nix sandbox — the existing
# `make check-mach` harness assumes the in-repo work/ tree and a host
# qemu, neither of which the sandbox provides.  Until then, kernel
# tests stay under the parent Makefile's `check-mach` target.

{ pkgs, lib, system, targets, mig, mkCrossPkgs }:

let
  mkOne = name: target:
    let
      crossMig = mig."mig-${name}";
      crossPkgs = mkCrossPkgs system target;
    in
    crossPkgs.stdenv.mkDerivation {
      pname   = "gnumach-${target.migTarget}";
      version = "src";

      src = ../../src/gnumach;

      # Native build tools (autoreconf + the MIG wrapper).  Cross-stdenv
      # already supplies the target compiler + binutils that the kernel
      # build needs for compile + link.
      nativeBuildInputs = with pkgs; [
        autoconf
        automake
        gnum4
        perl
        bison
        flex
        texinfo
        gawk
      ] ++ [ crossMig ];

      # Same gnu17 pin as the dev shell — keeps nix-built and
      # Makefile-driven kernels bit-identical when nothing else differs.
      CFLAGS = "-std=gnu17 -g -O2";

      preConfigure = ''
        rm -f configure aclocal.m4
        autoreconf -i
      '';

      # --host and --prefix are injected by the cross-stdenv's
      # configurePhase (from $crossConfig and $prefix=$out).
      #
      # --enable-dependency-tracking overrides the nix cross-stdenv
      # default of --disable-dependency-tracking.  Without it,
      # automake skips generating per-object .Po files that record
      # `mach_port.o depends on mach_port.server.h` (etc.) — and the
      # first build then compiles mach_port.c before MIG generates
      # mach_port.server.h, failing on a missing include.  gnumach
      # doesn't ship explicit BUILT_SOURCES, so dep tracking is the
      # only mechanism teaching make about the .defs → .server.h →
      # .o cascade.
      configureFlags =
        [ "--enable-dependency-tracking" ]
        ++ lib.optional (target.platform != null) "--enable-platform=${target.platform}";

      # `make install` produces $out/boot/{gnumach,gnumach.elf} plus
      # the public headers + .defs.  stdenv's default buildPhase
      # ("make") handles the kernel link.
      installPhase = ''
        runHook preInstall
        make install
        runHook postInstall
      '';

      # Kernel tests (`make check-mach`) need qemu + grub-mkrescue +
      # u-boot etc. on the build host, and they execute the kernel
      # under qemu — neither fits the nix sandbox.  Keep tests under
      # the parent Makefile's check-mach target until the sandbox
      # story is sorted.  TODO: revisit.
      doCheck = false;

      passthru = { inherit target; };

      meta = with lib; {
        description = "GNU Mach microkernel for ${target.migTarget}";
        platforms = platforms.all;
      };
    };
in
lib.mapAttrs' (name: target: lib.nameValuePair "gnumach-${name}" (mkOne name target)) targets
