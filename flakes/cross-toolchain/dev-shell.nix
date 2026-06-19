# SPDX-FileCopyrightText: 2026 Paulo Duarte <paulofernandobd@gmail.com>
# SPDX-License-Identifier: GPL-3.0-or-later
# The single per-(host, target) development shell - `nix develop .#<arch>`.
#
# One shell drives every in-tree build: `make mach` (freestanding gnumach
# kernel), `make mig` (host-side MIG codegen tool), `make hurd` (userland
# servers).  All use the SAME from-source UNWRAPPED `<cpu>-gnu` cross-gcc +
# cross-binutils (the same `cross-gcc-<arch>` / `cross-binutils-<arch>` the nix
# builds use): the kernel builds freestanding (gnumach's configure forces
# `-ffreestanding -nostdlib`), the userland hosted against the cross-gcc's
# `--with-sysroot` glibc-hurd.
#
# Build TOOLS (autoreconf, bison/flex, perl, texinfo, ...) are INFERRED from this
# target's own derivations (gnumach + mig + gnumach-headers) - add a tool to a
# package's nativeBuildInputs and the shell picks it up.  The nix-built working
# mig is added + exported as $MIG / $USER_MIG so mig is always available without a
# `make mig`; `make src-mig` opts into an in-tree mig the Makefile builds instead.
# The libc-free bootstrap-gcc (pulled in via gnumach-headers) is SUBTRACTED so its
# prefixed gcc can't shadow the cross-gcc on PATH.
#
# The cross compiler + binutils are wired by ABSOLUTE path in the shellHook
# (CC/CXX from the cross-gcc; LD/AR/NM/... from the cross-binutils) so configure +
# sub-makes resolve to exactly these regardless of PATH ordering.  Determinism: the
# raw cross-gcc ignores the cc-wrapper's NIX_CFLAGS_COMPILE, so the DWARF maps ride
# CPPFLAGS (the Makefile recipes append the per-build $srcdir/$PWD->canon maps to
# it); no -frandom-seed, no host -isystem strip, no NIX_DONT_SET_RPATH dance - all
# wrapper artifacts the unwrapped toolchain doesn't need.

{ nixpkgs }:

let
  inherit (nixpkgs) lib;
  hurdConfig = import ./hurd-config.nix;
  buildFlags = import ./build-flags.nix { inherit lib; };
in

{
  # mkDevShell : system -> name -> target ->
  #   { cc, binutils, sysroot, bootstrapGcc, gnumach, mig, headers } -> shell.
  #     cc           cross-gcc-<arch>      (unwrapped; provides ${tp}-gcc/-g++ + sysroot)
  #     binutils     cross-binutils-<arch> (unwrapped; ${tp}-ld/-ar/-nm/...)
  #     sysroot      glibc-hurd-<arch>     (the cc's --with-sysroot; mapped out of the
  #                                         userland's DWARF; inert for the -nostdlib kernel)
  #     bootstrapGcc bootstrap-gcc-<arch>  (SUBTRACTED from PATH - its ${tp}-gcc must not
  #                                         shadow the cross-gcc)
  #     gnumach/mig/headers  this target's derivations, for build-tool inference.
  #   For a xen variant, cc/binutils/sysroot/etc. are the CPU sibling's.  glibc is
  #   nix-only - no in-tree glibc build env.
  mkDevShell =
    system: name: target:
    {
      cc,
      binutils,
      sysroot,
      bootstrapGcc,
      gnumach,
      mig,
      headers,
    }:
    let
      pkgs = nixpkgs.legacyPackages.${system};

      # Patched install-info (deterministic dir), shared with glibc.nix - see
      # texinfo-det.nix.  Replaces EVERY texinfo on PATH below so whichever
      # install-info glibc/hurd's `make install` picks is deterministic.
      texinfoDet = import ./texinfo-det.nix { inherit pkgs; };

      # Headless qemu (no GUI/audio backends) - `make run` only ever boots
      # -nographic; see flakes/lib/qemu-headless.nix.
      qemuHeadless = import ../lib/qemu-headless.nix pkgs;

      tp = "${target.crossTarget}-"; # raw prefix (the unwrapped cc has no .targetPrefix)
      buildTriple = pkgs.stdenv.hostPlatform.config;
      coreFlags = lib.concatStringsSep " " hurdConfig.coreFlags;
      hurdDeployFlags = lib.concatStringsSep " " hurdConfig.deployFlags;

      # Fixed toolchain DWARF maps for the in-tree builds (the SAME maps the nix
      # gnumach/hurd builds apply): the cross-gcc + cross-binutils store paths, plus the
      # glibc sysroot (needed by the userland, inert for the -nostdlib kernel).  The
      # Makefile gnumach/hurd recipes append the per-build $srcdir/$PWD->canon maps.
      detCppMaps =
        buildFlags.debugPrefixMapUnwrappedStr {
          gcc = cc;
          inherit binutils;
        }
        + " -ffile-prefix-map=${sysroot}=${buildFlags.glibcCanonSysroot}";

      # Build-tool deps inferred from this target's own derivations.  Subtract the own
      # packages AND the libc-free bootstrap-gcc (pulled in via gnumach-headers): its
      # prefixed gcc must not shadow the cross-gcc on PATH.
      ownDrvs = [
        gnumach
        mig
        headers
        cc
        binutils
        bootstrapGcc
      ];
      inferredBuildInputs = lib.subtractLists ownDrvs (
        lib.unique (
          lib.concatMap (d: d.nativeBuildInputs or [ ]) [
            gnumach
            mig
            headers
          ]
        )
      );
    in
    pkgs.mkShell {
      # Inferred tools (autoreconfHook + bison/flex/perl/texinfo) come via
      # inferredBuildInputs.  Here we add the cross-gcc + cross-binutils + mig (for PATH)
      # and the dev/run-only extras the packages don't declare:
      #   gcc        native compiler for in-tree `make mig` (a host tool)
      #   pkg-config hurd's optional PKG_CHECK probes
      #   git/nix    source ops + Makefile re-dispatch into a target shell
      #   qemuHeadless  qemu-system-* (+ qemu-img) for `make run`, GUI/audio stripped
      #   curl/which run scenarios + gnumach's run-qemu.sh test gate
      #   fakeroot   `make dist-hurd`: hurd installs some programs -o root -m 4755
      #              (setuid); fakeroot fakes the chown/setuid for a non-root install.
      #   python3/gettext/gawk/bison/perl/texinfo  glibc's host build tools, for the
      #              opt-in `make glibc` (mirrors glibc.nix); the dedup handles the
      #              overlap with inferredBuildInputs.
      #   lint/format tools (nixfmt, statix, deadnix, clang-tools, shfmt, shellcheck,
      #              mdformat, yamlfmt, yamllint, reuse) come from flakes/lint/tools.nix
      #              - the SAME set the `lint-tools` package / `make lint` / the
      #              pre-commit hook use - so in-shell linting matches CI exactly.
      # gnumake + awk + coreutils come from stdenv.  `lib.remove pkgs.texinfo` strips
      # the unpatched texinfo wherever it appears, then texinfoDet is added once - so
      # the only install-info on PATH is the deterministic one.
      nativeBuildInputs =
        lib.remove pkgs.texinfo (
          [
            cc
            binutils
            mig
          ]
          ++ inferredBuildInputs
          ++ (with pkgs; [
            gcc
            pkg-config
            git
            nix
            qemuHeadless
            curl
            which
            fakeroot
            python3
            jq
            gettext
            gawk
            bison
            perl
            texinfo
          ])
          ++ import ../lint/tools.nix pkgs
          # gnumach's x86 `make check` builds a multiboot ISO with grub-mkrescue
          # (needs xorriso + mtools); nixpkgs' grub2 is linux-only, so gate on
          # x86 + linux hosts.
          ++
            lib.optionals
              (
                (lib.hasPrefix "x86_64-" target.crossTarget || lib.hasPrefix "i686-" target.crossTarget)
                && lib.hasSuffix "-linux" system
              )
              [
                pkgs.grub2
                pkgs.xorriso
                pkgs.mtools
              ]
        )
        ++ [ texinfoDet ];

      shellHook = ''
        export ARCH=${name}
        export GNUMACH_HOST=${target.crossTarget}
        export MIG_TARGET=${target.crossTarget}
        ${
          if target.platform != null then
            "export GNUMACH_PLATFORM=${target.platform}"
          else
            "unset GNUMACH_PLATFORM"
        }

        # Cross tools by ABSOLUTE path so configure + sub-makes use exactly these
        # (never a host tool, never bootstrap-gcc).  CC/CXX/TARGET_CC from the cross-gcc;
        # LD/AR/... from the cross-binutils.  TARGET_CC is what MIG's cpu.symc uses.
        export CC=${cc}/bin/${tp}gcc
        export CXX=${cc}/bin/${tp}g++
        export TARGET_CC=${cc}/bin/${tp}gcc
        export LD=${binutils}/bin/${tp}ld
        export AR=${binutils}/bin/${tp}ar
        export NM=${binutils}/bin/${tp}nm
        export RANLIB=${binutils}/bin/${tp}ranlib
        export STRIP=${binutils}/bin/${tp}strip
        export OBJCOPY=${binutils}/bin/${tp}objcopy
        export AS=${binutils}/bin/${tp}as
        export OBJDUMP=${binutils}/bin/${tp}objdump
        export READELF=${binutils}/bin/${tp}readelf

        # The nix-built working mig - always available so mach/hurd build with no
        # `make mig`.  The Makefile uses $MIG unless an in-tree src/mig opts in.
        export MIG=${mig}/bin/${tp}mig
        export USER_MIG=${mig}/bin/${tp}mig

        export BUILD_CC=${pkgs.stdenv.cc}/bin/cc
        export BINUTILS_BIN=${binutils}/bin
        export BUILD_TRIPLE=${buildTriple}

        # Empty so hurd's optional PKG_CHECK probes find nothing (matches the nix
        # build).  No global CFLAGS: the kernel takes autoconf's `-g -O2` default
        # (+ its own -ffreestanding -nostdlib); the hurd recipe adds -fcommon.
        export PKG_CONFIG_PATH=

        # Cross-host determinism for the in-tree build, via CPPFLAGS (the raw cross-gcc
        # ignores the cc-wrapper's NIX_CFLAGS_COMPILE).  These are the FIXED toolchain
        # DWARF maps (cross-gcc + cross-binutils store paths + the glibc sysroot); the
        # Makefile gnumach/hurd recipes append the per-build $srcdir/$PWD->canon maps.
        # No -frandom-seed (the raw cc's default seed is deterministic) and no host
        # -isystem strip (the cross-gcc resolves system headers only from its sysroot,
        # never the native stdenv's host -isystem, which it never reads).
        export CPPFLAGS="${detCppMaps} ''${CPPFLAGS:-}"

        # Canonical roots for the in-tree gnumach + hurd builds (build-flags.nix) - the
        # SAME single canonical gnumach/default.nix + hurd/default.nix map their nix
        # build's $srcdir/$PWD to, so in-tree == nix for those modules.
        export GNUMACH_CANON_BUILD=${buildFlags.gnumachCanonBuild}
        export HURD_CANON_BUILD=${buildFlags.hurdCanonBuild}

        # Base compile flags (build-flags.nix) - the SAME -g -O2 (+ hurd's -fcommon) the
        # nix derivations use, read by the in-tree configure CFLAGS (flags live in ONE
        # place).
        export BASE_CFLAGS="${buildFlags.baseCflags}"
        export HURD_EXTRA_CFLAGS="${buildFlags.hurdExtraCflags}"

        # No NIX_DONT_SET_RPATH / NIX_LDFLAGS rpath-strip: the raw cross-binutils ld
        # bakes no /nix/store DT_RUNPATH (the wrapped ld-wrapper did), so the dist
        # binaries resolve from the target /lib via the loader - Debian-Hurd parity, for
        # free.

        # Same configure flag set as the nix Hurd build (hurd-config.nix).
        export HURD_CONFIGURE_FLAGS="--host=${target.crossTarget} ${coreFlags}"
        # Root-relative install dirs the nix Hurd uses (hurd-config.deployFlags).
        export HURD_DEPLOY_FLAGS="${hurdDeployFlags}"
      '';
    };
}
