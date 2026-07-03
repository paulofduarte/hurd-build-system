# SPDX-FileCopyrightText: 2026 Paulo Duarte <paulofernandobd@gmail.com>
# SPDX-License-Identifier: GPL-3.0-or-later
# Own from-source cross binutils - the target-prefixed as/ld/ar/nm/... for the
# Hurd targets, built from the pinned upstream release tarball (binutils-toolchain-src),
# replacing nixpkgs' binutils-unwrapped.  Stage 1 of the from-source toolchain;
# stage 2 (gcc.nix) configures the from-source gcc with `--with-as`/`--with-ld`
# pointing here, and downstream consumers invoke `<triple>-as`/`-ld` UNWRAPPED
# (no nix bintools-wrapper - the from-source gcc bakes its own search paths).
#
# Determinism: `--enable-deterministic-archives` + the gas obstack-chunksize
# patch (shared with the nixpkgs overlay in pkgs.nix) keep the as/ld OUTPUT
# byte-identical.  The binutils BINARIES are build-host tools - never shipped to
# the target dist - so their own (host-varying) bytes don't need canon-mapping.

{
  nixpkgs,
  system,
  targets,
  binutils-toolchain-src,
}:

let
  pkgs = nixpkgs.legacyPackages.${system};
  inherit (nixpkgs) lib;
  buildFlags = import ./build-flags.nix { inherit lib; };

  # Version lives in bfd/version.m4 as `m4_define([BFD_VERSION], [2.46.1])` - parse
  # it so a tarball bump in flake.nix is the only edit needed (matches gcc.nix /
  # glibc.nix; the `.` regex spans newlines in nix's POSIX matcher).
  version =
    let
      m = builtins.match ".*BFD_VERSION], \\[([0-9.]+)].*" (
        builtins.readFile (binutils-toolchain-src + "/bfd/version.m4")
      );
    in
    if m == null then "unknown" else builtins.head m;

  mkOne =
    _name: target:
    let
      tp = target.crossTarget;
    in
    pkgs.stdenv.mkDerivation (
      {
        pname = "cross-binutils-${tp}";
        inherit version;
        src = binutils-toolchain-src;

        # Build the HOST binaries without debug info (-O2, no -g; configure's default
        # is -g -O2).  They are build-host tools - never shipped to the target dist -
        # and the embedded DWARF otherwise bloats the toolchain + its cachix closure by
        # ~GB.  binutils has NO target runtime libs, so there is nothing to keep debug
        # for: this is a clean, full debug-off.
        CFLAGS = "-O2";
        CXXFLAGS = "-O2";

        # Deterministic gas chunk size (shared patch, also applied to the nixpkgs
        # binutils via the overlay in pkgs.nix): gas otherwise embeds a host-varying
        # obstack chunk size, breaking cross-host reproducibility of its output.
        patches = [ ./patches/binutils-gas-deterministic-chunksize.patch ];

        nativeBuildInputs =
          (with pkgs; [
            bison
            flex
            texinfo
            perl
            gettext
          ])
          ++ buildFlags.commonNativeBuildInputs pkgs;
        buildInputs = with pkgs; [ zlib ];

        # --target is the only thing that makes this a cross binutils; stdenv's
        # default configurePhase supplies the native --build/--host.
        configureFlags = [
          "--target=${tp}"
          "--enable-deterministic-archives" # determinism: zeroed ar timestamps/uid/gid
          "--with-system-zlib"
          "--disable-multilib"
          # No --disable-nls (nls on, vanilla; gettext supplies msgfmt), no
          # --disable-werror (release default is no -Werror), no --disable-gprofng
          # (gprofng is target-gated to *-linux in configure.ac, so it auto-skips for
          # our *-gnu target on any host).
        ];

        meta = with lib; {
          description = "GNU binutils cross-tools for ${tp} (from-source pin)";
          platforms = platforms.all;
        };
      }
      // buildFlags.commonAttrs
    );
in
lib.mapAttrs' (name: target: lib.nameValuePair "cross-binutils-${name}" (mkOne name target)) targets
