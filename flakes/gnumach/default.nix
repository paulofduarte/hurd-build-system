# GNU Mach kernel — per-target derivations.
#
# One nix derivation per target (autoreconf + configure + make +
# make install) producing the bootable kernel image + install tree.
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
# Source comes from the pinned `gnumach-src` flake input (a github fork rev
# locked in flake.lock; see flake.nix + flakes/sources), NOT the local
# src/gnumach working clone — that is a dev convenience populated by `make
# srcs`.
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

{ nixpkgs, system, targets, mig, mkCrossPkgs, self, srcInput, forkUrl }:

let
  pkgs = nixpkgs.legacyPackages.${system};
  lib = nixpkgs.lib;
  helpers = import ../lib { inherit lib; };

  # Upstream version parsed from version.m4 (AC_PACKAGE_VERSION).  If
  # upstream bumps the m4 file, the parser picks it up automatically.
  upstreamVersion = helpers.parseM4Version (srcInput + "/version.m4");

  # PACKAGE_VERSION composed at eval time — fully pure.
  # See flakes/lib/default.nix (composeVersion) for the format.
  fullVersion = helpers.composeVersion {
    inherit upstreamVersion srcInput self forkUrl;
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

      # The pinned `gnumach-src` input (a github fork rev locked in
      # flake.lock).  nix builds exactly that — never the local src/gnumach
      # working clone — so the built bytes always match the version string's
      # `srcInput.shortRev`.
      src = srcInput;

      # Native build tools (autoreconf + the MIG wrapper).  Cross-stdenv
      # already supplies the target compiler + binutils that the kernel
      # build needs for compile + link.
      # autoreconfHook supplies autoconf/automake/libtool/m4 + runs autoreconf.
      # texinfo: the kernel build runs makeinfo (mach.info).  perl: the MIG
      # wrapper shells out to perl when generating stubs.  awk comes from
      # stdenv.  crossMig: the matching cross-MIG for this target.
      nativeBuildInputs =
        [ pkgs.autoreconfHook ]
        ++ (with pkgs; [ texinfo perl ])
        ++ [ crossMig ];

      # gnu17 pin matches the dev shell.  The `-fdebug-prefix-map` entries
      # rewrite the host-specific cross-toolchain /nix/store paths that leak
      # into DWARF (header refs, comp dirs, file tables) to stable names, so
      # the same source yields byte-identical `.debug_info` on every host.
      # The map values are arbitrary — only their stability matters; `${cc}`
      # etc. resolve at eval time, normalising each host's hash away.  Debug
      # info is preserved (paths only), so dist/ stays usable for gdb.
      CFLAGS = lib.concatStringsSep " " [
        "-std=gnu17"
        "-g"
        "-O2"
        "-fdebug-prefix-map=${cc}=/cross-cc-wrapper"
        "-fdebug-prefix-map=${cc.cc}=/cross-gcc"
        "-fdebug-prefix-map=${cc.bintools}=/cross-binutils-wrapper"
      ];

      # Splice the eval-time-composed version into version.m4 before the
      # autoreconfHook regenerates configure.  ${fullVersion} is composed
      # from upstream-m4 + the gnumach-src input + flake.lock fork-id + self.
      postPatch = ''
        sed -i.bak \
          -e 's|m4_define(\[AC_PACKAGE_VERSION\],\[[^]]*\])|m4_define([AC_PACKAGE_VERSION],[${fullVersion}])|' \
          version.m4
        rm version.m4.bak
        grep AC_PACKAGE_VERSION version.m4
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
