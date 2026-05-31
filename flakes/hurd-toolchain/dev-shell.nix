# Per-target GNU Hurd userland dev shell — `nix develop .#hurd-<arch>`.
#
# The environment for the in-tree `make hurd` build (Makefile): the
# wrapped Hurd cross-cc + cross binutils (i686-gnu-gcc / -ar / -ranlib /
# -nm …), the cross mig, and the autotools/build helpers hurd's build
# needs (autoconf, automake, perl, texinfo, pkg-config).  Distinct from
# the kernel dev shell (flakes/cross-toolchain) which is the bare-metal
# *-elf toolchain.
#
# The shellHook exports the cross tools by their prefixed names (so
# configure + recursive sub-makes pick them up over any host tools the
# stdenv puts on PATH) and HURD_CONFIGURE_FLAGS — the same flag set the
# nix build uses (hurd-config.nix), so the in-tree and nix builds stay
# in lockstep.

{ nixpkgs }:

let
  lib = nixpkgs.lib;
  hurdConfig = import ./hurd-config.nix;
in

{
  # mkHurdDevShell : system -> name -> target -> { toolchain, mig } -> shell
  # `toolchain` is the wrapped cc (hurd-toolchain-<name>); `mig` the
  # cross mig (mig-<name>).
  mkHurdDevShell = system: name: target: { toolchain, mig }:
    let
      pkgs = nixpkgs.legacyPackages.${system};
      tp = target.migTarget;
      coreFlags = lib.concatStringsSep " " hurdConfig.coreFlags;
    in
    pkgs.mkShell {
      # The toolchain bin/ carries i686-gnu-gcc + the cross binutils
      # (ar/ranlib/nm/…); mig carries i686-gnu-mig.  autoconf/automake/
      # libtool/m4 regenerate configure; perl/texinfo/pkg-config/gawk are
      # build-time needs; git for the in-tree source ops.
      nativeBuildInputs =
        [ toolchain mig ]
        ++ (with pkgs; [
          autoconf automake libtool m4
          perl texinfo pkg-config gnumake gawk git
        ]);

      shellHook = ''
        export ARCH=${name}
        export MIG_TARGET=${tp}
        # Cross tools pinned by prefixed name so they win over the host
        # gcc/binutils the stdenv puts on PATH.
        export CC=${tp}-gcc
        export CXX=${tp}-g++
        export AR=${tp}-ar
        export RANLIB=${tp}-ranlib
        export NM=${tp}-nm
        export OBJCOPY=${tp}-objcopy
        export STRIP=${tp}-strip
        export MIG=${tp}-mig
        export USER_MIG=${tp}-mig
        # hurd predates gcc's -fno-common default; empty PKG_CONFIG_PATH
        # keeps the optional PKG_CHECK probes finding nothing.
        export CFLAGS="-fcommon -g -O2"
        export PKG_CONFIG_PATH=
        # Same configure flags as the nix build (hurd-config.nix).
        export HURD_CONFIGURE_FLAGS="--host=${tp} ${coreFlags}"
      '';
    };
}
