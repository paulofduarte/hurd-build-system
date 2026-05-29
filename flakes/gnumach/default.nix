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
# Output layout:
#   $out/boot/gnumach              bootable kernel — raw binary
#                                  (objcopy -O binary) on aarch64 so
#                                  qemu's -kernel accepts it, ELF
#                                  with debug info on i386/x86_64
#                                  (qemu's -kernel handles ELF there).
#   $out/boot/gnumach.elf          unstripped ELF with DWARF — only on
#                                  aarch64, copied from the build dir
#                                  in postInstall.  Pair to the raw
#                                  binary above for gdb / addr2line.
#                                  No need on i386/x86_64 since
#                                  boot/gnumach is already the ELF.
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

{ pkgs, lib, system, targets, mig, mkCrossPkgs, self, helpers, srcInput }:

let
  # Upstream version parsed from version.m4 (AC_PACKAGE_VERSION).  If
  # upstream bumps the m4 file, the parser picks it up automatically.
  upstreamVersion = helpers.parseM4Version ../../src/gnumach/version.m4;

  # 5-component PACKAGE_VERSION composed at eval time — fully pure.
  # Format: <upstream>+<date>+<fork-id>+<src-hash>+build+<build-hash>.
  # See flakes/lib/default.nix for the data-source breakdown.
  fullVersion = helpers.composeVersion {
    inherit upstreamVersion srcInput self;
    submodulePath = "src/gnumach";
  };

  mkOne = name: target:
    let
      crossMig = mig."mig-${name}";
      crossPkgs = mkCrossPkgs system target;
      cc = crossPkgs.stdenv.cc;
      pname = "gnumach-${target.migTarget}";
    in
    crossPkgs.stdenv.mkDerivation ({
      inherit pname;

      # Drives both the store path suffix and (via the sed below) the
      # binary's PACKAGE_VERSION — same string, traceable on both sides.
      version = fullVersion;

      # Use the locked flake input rather than the path-relative
      # `../../src/gnumach`.  The latter would happily vendor any
      # uncommitted edits to the submodule worktree, making the
      # built binary and the metadata-derived version string disagree
      # (verified empirically — see commit history).  This way the
      # built bytes always match what `srcInput.shortRev` claims.
      src = srcInput;

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
      #
      # `-fdebug-prefix-map` entries rewrite the host-specific
      # cross-toolchain /nix/store paths embedded in DWARF (header
      # file refs from <stdarg.h> etc., comp dirs, file tables) to
      # stable names.  Without them the same source compiled by the
      # "same" cross-gcc 14.3.0 on different hosts produces byte-
      # different `.debug_info` sections, because the cross-gcc is
      # bootstrapped from a host-specific native compiler and its
      # store hash leaks into every translation unit.
      #
      # The map values (`/cross-gcc`, `/cross-cc-wrapper`, ...) are
      # arbitrary; what matters is that they're the same strings on
      # every host.  `${cc}`/`${cc.cc}`/`${cc.bintools}` resolve at
      # derivation-eval time, so each host's specific hash gets
      # normalized away.
      #
      # NB this leaves the debug info itself intact — just paths
      # change.  Stripping is still avoided so dist/ stays useful
      # for gdb / addr2line.
      CFLAGS = lib.concatStringsSep " " [
        "-std=gnu17"
        "-g"
        "-O2"
        "-fdebug-prefix-map=${cc}=/cross-cc-wrapper"
        "-fdebug-prefix-map=${cc.cc}=/cross-gcc"
        "-fdebug-prefix-map=${cc.bintools}=/cross-binutils-wrapper"
      ];

      # Splice the eval-time-composed version into version.m4 before
      # autoreconf.  ${fullVersion} is the 5-component string composed
      # from upstream-m4 + submodule input metadata + .gitmodules +
      # self — all known at flake eval time.
      preConfigure = ''
        rm -f configure aclocal.m4
        sed -i.bak \
          -e 's|m4_define(\[AC_PACKAGE_VERSION\],\[[^]]*\])|m4_define([AC_PACKAGE_VERSION],[${fullVersion}])|' \
          version.m4
        rm version.m4.bak
        grep AC_PACKAGE_VERSION version.m4
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

      # `make install` produces $out/boot/gnumach plus the public
      # headers + .defs.  stdenv's default buildPhase ("make")
      # handles the kernel link.
      installPhase = ''
        runHook preInstall
        make install
        runHook postInstall
      '';

      # On aarch64, gnumach's `make install` ships only $out/boot/gnumach
      # — a raw binary (objcopy -O binary, no ELF header) so qemu's
      # -kernel accepts it.  The link intermediate `gnumach.elf` is the
      # unstripped ELF with full DWARF, sitting in the build dir but
      # not picked up by `make install`.  Copy it alongside so gdb /
      # addr2line have something to work with, AND so the cross-host
      # hash comparison in the toolchain-sanity-check workflow has a
      # debug-info-bearing artefact to compare on aarch64 (the raw
      # binary alone strips the DWARF where most legitimate cross-host
      # determinism work happens via -fdebug-prefix-map above).
      #
      # On i386/x86_64 there is no gnumach.elf intermediate ($out/boot/
      # gnumach is already the unstripped ELF), so the `[ -f ]` guard
      # makes this a no-op there.
      postInstall = ''
        if [ -f gnumach.elf ] && [ ! -e $out/boot/gnumach.elf ]; then
          install -m 0644 gnumach.elf $out/boot/gnumach.elf
        fi
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
    } // helpers.mkReproAttrs { inherit pname; version = fullVersion; });
in
lib.mapAttrs' (name: target: lib.nameValuePair "gnumach-${name}" (mkOne name target)) targets
