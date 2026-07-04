# SPDX-FileCopyrightText: 2026 Paulo Duarte <paulofernandobd@gmail.com>
# SPDX-License-Identifier: GPL-3.0-or-later
# Cross-built GNU bash - per-userland-target derivations (phase-2 base
# userland).  The self-built system cannot reach a prompt without a shell:
# hurd's runsystem/rc are shell scripts and login spawns one - so bash is
# /bin/sh AND /bin/bash (a `sh` symlink is installed alongside, Debian-style).
#
# Cross specifics (glibc-hurd sysroot, --host=<cpu>-gnu):
#   - --without-bash-malloc: bash's legacy allocator predates glibc's; every
#     glibc distro builds with glibc malloc (Debian/Guix parity).
#   - bundled readline + bundled termcap: the sysroot carries no ncurses, and
#     bash's configure falls back to ./lib/{readline,termcap} - zero new deps
#     for serial-console line editing.
#   - bash_cv_* presets: configure's run-tests can't execute target programs,
#     and their cross defaults are pessimistic ("missing" DISABLES job
#     control!).  Preset the answers a native Hurd configure gives - all
#     glibc/Hurd facts, identical on every build host (determinism: no
#     host-probed variance).
#
# Layout mirrors the deploy-prefix policy: --prefix=/usr, install via
# DESTDIR=$out, every baked path deployable.  Source = the pinned
# `bash-dep-src` release tarball.

{
  nixpkgs,
  system,
  targets,
  toolchainFor,
  srcInput,
}:

let
  pkgs = nixpkgs.legacyPackages.${system};
  inherit (nixpkgs) lib;
  buildFlags = import ../cross-toolchain/build-flags.nix { inherit lib; };

  # bash's AC_INIT version is the m4 symbol `bashvers-relstatus`; the real
  # number lives in `define(bashvers, 5.3)` a few lines up.  Bounded substring
  # (builtins.match is a recursive std::regex - see flakes/libacpica).
  version =
    let
      match = builtins.match ".*define[(]bashvers,[[:space:]]*([0-9.]+)[)].*" (
        builtins.substring 0 2048 (builtins.readFile (srcInput + "/configure.ac"))
      );
    in
    if match == null then "unknown" else builtins.head match;

  userlandTargets = lib.filterAttrs (_: t: (t.platform or null) != "xen") targets;

  mkOne =
    _name: target:
    let
      tp = target.crossTarget; # e.g. i686-gnu
      tc = toolchainFor target;
      inherit (tc) cc;
      binu = tc.binutils;
    in
    pkgs.stdenv.mkDerivation {
      pname = "bash-${tp}";
      inherit version;
      src = srcInput;

      # Shipped configure (release tarball) - no autoreconf.  patchelf:
      # darwin's audit-tmpdir fixup (same as flakes/hurd).
      nativeBuildInputs = [
        cc
        binu
        pkgs.patchelf
      ];

      preConfigure = ''
        export CC=${tp}-gcc
        export AR=${tp}-ar
        export RANLIB=${tp}-ranlib
        # Cross builds compile the BUILD-host helper tools (mkbuiltins,
        # mksignames, mksyntax, man2html) with CC_FOR_BUILD - whose default
        # is a literal `gcc`, absent from the sandbox (darwin's stdenv cc is
        # clang).  Point it at the stdenv cc.
        export CC_FOR_BUILD=cc
        srcdir=$PWD
        ${buildFlags.detCppflagsUnwrapped {
          gcc = cc;
          binutils = binu;
          canonBuild = "/bash-build";
          inherit (tc) sysroot;
        }}
        configureFlagsArray+=("CFLAGS=${buildFlags.baseCflags}")
      '';

      # The bash_cv_* presets (see header): job control, named pipes and
      # /dev/{fd,stdin} exist on the Hurd (MAKEDEV creates fd via /hurd/magic
      # --directory), glibc's getcwd mallocs, sigsetjmp and printf %a are
      # glibc; the cross defaults would answer "missing"/"absent" for all of
      # them.
      configureFlags = [
        "--host=${tp}"
        "--prefix=/usr"
        "--without-bash-malloc"
        "bash_cv_job_control_missing=present"
        "bash_cv_sys_named_pipes=present"
        "bash_cv_dev_fd=standard"
        "bash_cv_dev_stdin=present"
        "bash_cv_getcwd_malloc=yes"
        "bash_cv_func_sigsetjmp=present"
        "bash_cv_printf_a_format=yes"
      ];
      dontAddPrefix = true;

      enableParallelBuilding = true;

      installPhase = ''
        runHook preInstall
        make install DESTDIR=$out
        runHook postInstall
      '';

      # bashbug is a build-report script with the compile line (host store
      # paths) baked in - a determinism leak and useless on the target.  The
      # `sh` symlink makes bash the POSIX shell (runsystem/rc shebangs).
      postInstall = ''
        rm -f $out/usr/bin/bashbug $out/usr/share/man/man1/bashbug.1
        ln -s bash $out/usr/bin/sh
      '';

      # Same output-hygiene set as the hurd userland: keep DWARF for the dist
      # dbg split, no rpath shrinking, no store-path shebangs.
      dontPatchELF = true;
      dontStrip = true;
      dontPatchShebangs = true;

      passthru = { inherit target; };
      meta = with lib; {
        description = "GNU bash for ${tp} (self-built system shell)";
        platforms = platforms.all;
        license = licenses.gpl3Plus;
      };
    };
in
lib.mapAttrs' (name: target: lib.nameValuePair "bash-${name}" (mkOne name target)) userlandTargets
