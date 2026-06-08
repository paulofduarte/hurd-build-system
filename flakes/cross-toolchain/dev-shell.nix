# The single per-(host, target) development shell — `nix develop .#<arch>`.
#
# One shell drives every in-tree build: `make mach` (freestanding gnumach
# kernel), `make mig` (host-side MIG codegen tool), `make hurd` (userland
# servers).  All use the SAME wrapped `<cpu>-gnu` cross-cc (toolchain.nix →
# `toolchain-<arch>`): the kernel builds freestanding (gnumach's configure forces
# `-ffreestanding -nostdlib`), the userland hosted against glibc-hurd.
#
# Build TOOLS (autoreconf, bison/flex, perl, texinfo, …) are INFERRED from this
# target's own derivations (gnumach + mig + gnumach-headers) — add a tool to a
# package's nativeBuildInputs and the shell picks it up.  The nix-built working
# mig is added + exported as $MIG / $USER_MIG so mig is always available without a
# `make mig`; `make src-mig` opts into an in-tree mig the Makefile builds instead.
# The libc-free stage-1 cc is SUBTRACTED so its prefixed gcc can't shadow the
# wrapped cc on PATH.
#
# The cross compiler + binutils are wired by ABSOLUTE path in the shellHook
# (CC/CXX from the wrapped toolchain; LD/AR/NM/… from the unwrapped cross
# binutils) so configure + sub-makes resolve to exactly these regardless of PATH
# ordering.  HURD_CONFIGURE_FLAGS carries the same flag set the nix Hurd build
# uses (hurd-config.nix); the Makefile's hurd recipe adds `CFLAGS=-fcommon` at
# configure time, scoping -fcommon to the userland — the kernel never sees it.

{ nixpkgs, mkCrossPkgs }:

let
  lib = nixpkgs.lib;
  hurdConfig = import ./hurd-config.nix;
  glibcConfig = import ./glibc-config.nix;
  toolchainPaths = import ./toolchain-paths.nix { inherit nixpkgs mkCrossPkgs; };
  buildFlags = import ./build-flags.nix { inherit lib; };
in

{
  # mkDevShell : system -> name -> target -> { toolchain, glibcCC, gnumach, mig,
  #              headers } -> shell.  `toolchain` is the wrapped cc (toolchain-<arch>,
  #              or the CPU sibling's for a xen variant); `glibcCC` is the COMPLETE
  #              final gcc wrapped against the REFERENCE glibc (the cc the nix working
  #              glibc is built with) — what the opt-in `make glibc` uses, so in-tree
  #              and nix work-glibc are built by the same compiler.  gnumach/mig/
  #              headers are this target's derivations, for build-tool inference (and
  #              subtraction).
  mkDevShell = system: name: target: { toolchain, glibcCC, gnumach, mig, headers }:
    let
      pkgs      = nixpkgs.legacyPackages.${system};
      crossPkgs = mkCrossPkgs system target;

      # Patched install-info (deterministic dir), shared with glibc.nix — see
      # texinfo-det.nix.  Replaces EVERY texinfo on PATH below so whichever
      # install-info glibc/hurd's `make install` picks is deterministic — no
      # post-dist dir regen.
      texinfoDet = import ./texinfo-det.nix { inherit pkgs; };

      # Unwrapped cross binutils — absolute source of the prefixed
      # ld/ar/nm/ranlib/strip/objcopy.  The wrapped `toolchain` supplies cc/c++;
      # the unwrapped binutils for the rest sidesteps any ambiguity about what the
      # cc-wrapper re-exports.
      tcPaths = toolchainPaths system target;
      binu  = tcPaths.binutils;
      # The wrapped cc's target prefix ("i686-gnu-") — drives both the toolchain
      # bin names and binu's (same crossSystem).
      tp    = toolchain.targetPrefix;
      # The cc-wrapper suffix salt (NIX_*_<salt>), matching wrapCCWith's.
      salt  = "_" + lib.replaceStrings [ "-" "." ] [ "_" "_" ] target.crossTarget;
      coreFlags = lib.concatStringsSep " " hurdConfig.coreFlags;
      hurdDeployFlags = lib.concatStringsSep " " hurdConfig.deployFlags;
      deployFlags = lib.concatStringsSep " " glibcConfig.deployFlags;
      glibcCoreFlags = lib.concatStringsSep " " glibcConfig.coreFlags;
      # DWARF store-path maps for every cc the in-tree build invokes: the
      # working-wrapped `toolchain` (mach + hurd) and the ref-wrapped `glibcCC`
      # (opt-in `make glibc`).  `toolchain.cc == glibcCC.cc` (both wrap the same
      # final gcc), so lib.unique drops the duplicate gcc map.  Shared with the nix
      # builds via build-flags.nix.
      detPrefixMap = lib.concatStringsSep " "
        (lib.unique (buildFlags.debugPrefixMap toolchain ++ buildFlags.debugPrefixMap glibcCC));

      # Build-tool deps inferred from this target's own derivations.  Subtract the
      # own packages AND the libc-free stage-1 cc: mig is subtracted so a mig pulled
      # in via gnumach's build inputs doesn't sneak onto PATH through inference (the
      # shell's mig is the `mig` arg, added + exported below).  The stage-1 cc comes
      # in via gnumach-headers' nativeBuildInputs but isn't the build cc here, and
      # its prefixed gcc must not shadow the wrapped cc on PATH — so subtracted.
      stage1 = crossPkgs.buildPackages.gccWithoutTargetLibc;
      ownDrvs = [ gnumach mig headers toolchain stage1 ];
      inferredBuildInputs = lib.subtractLists ownDrvs
        (lib.unique (lib.concatMap (d: d.nativeBuildInputs or []) [ gnumach mig headers ]));
    in
    pkgs.mkShell {
      # Inferred tools (autoreconfHook + bison/flex/perl/texinfo) come via
      # inferredBuildInputs.  Here we add the toolchain + binutils (for PATH) and
      # the dev/run-only extras the packages don't declare:
      #   gcc        native compiler for in-tree `make mig` (a host tool)
      #   pkg-config hurd's optional PKG_CHECK probes
      #   git/nix    source ops + Makefile re-dispatch into a target shell
      #   qemu       qemu-system-* (+ qemu-img) for `make run`
      #   curl/which run scenarios + gnumach's run-qemu.sh test gate
      #   fakeroot   `make dist-hurd`: hurd installs some programs -o root -m 4755
      #              (setuid); fakeroot fakes the chown/setuid for a non-root install.
      #   python3/gettext/gawk/bison/perl/texinfo  glibc's host build tools, for the
      #              opt-in `make glibc` (mirrors glibc.nix); the dedup handles the
      #              overlap with inferredBuildInputs.
      # gnumake + awk + coreutils come from stdenv.  `lib.remove pkgs.texinfo` strips
      # the unpatched texinfo wherever it appears, then texinfoDet is added once — so
      # the only install-info on PATH is the deterministic one.
      nativeBuildInputs =
        lib.remove pkgs.texinfo (
          [ toolchain binu mig ]
          ++ inferredBuildInputs
          ++ (with pkgs; [ gcc pkg-config git nix qemu curl which fakeroot
                           python3 jq gettext gawk bison perl texinfo ])
          # gnumach's x86 `make check` builds a multiboot ISO with grub-mkrescue
          # (needs xorriso + mtools); nixpkgs' grub2 is linux-only, so gate on
          # x86 + linux hosts.
          ++ lib.optionals
               ((lib.hasPrefix "x86_64-" target.crossTarget || lib.hasPrefix "i686-" target.crossTarget)
                && lib.hasSuffix "-linux" system)
               [ pkgs.grub2 pkgs.xorriso pkgs.mtools ]
        )
        ++ [ texinfoDet ];

      shellHook = ''
        export ARCH=${name}
        export GNUMACH_HOST=${tcPaths.hostTriple}
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

        # Build env for the opt-in raw in-tree `make glibc` (mirrors glibc.nix).
        # GLIBC_CC is the COMPLETE final gcc wrapped against the REFERENCE glibc
        # — the SAME cc the nix working glibc is built with, so in-tree-work and
        # nix-work glibc are byte-comparable.  NOT the nolibc stage-1 cc (it's a
        # bootstrap-only seed) and NOT the wrapped `toolchain` cc above (which
        # embeds the WORKING glibc → circular).  The ref wrapper supplies
        # crt/libc + mechanism-#2 --sysroot for glibc's configure link-tests.
        # The extra binutils tools (as/objdump/readelf) + native BUILD_CC + the
        # build triple + binutils bin dir are what glibc's configure consumes.
        export GLIBC_CC=${glibcCC}/bin/${tp}gcc
        export GLIBC_CXX=${glibcCC}/bin/${tp}g++
        export AS=${binu}/bin/${tp}as
        export OBJDUMP=${binu}/bin/${tp}objdump
        export READELF=${binu}/bin/${tp}readelf
        export BUILD_CC=${pkgs.stdenv.cc}/bin/cc
        export BINUTILS_BIN=${tcPaths.binutilsBin}
        export BUILD_TRIPLE=${tcPaths.buildTriple}

        # Empty so hurd's optional PKG_CHECK probes find nothing (matches
        # the nix build).  No global CFLAGS: the kernel takes autoconf's
        # `-g -O2` default (+ its own -ffreestanding -nostdlib); the hurd
        # recipe adds -fcommon at configure time.
        export PKG_CONFIG_PATH=

        # Cross-host determinism for the in-tree build (mach/hurd/glibc),
        # applied through NIX_CFLAGS_COMPILE so EVERY in-tree compile inherits
        # it — the Makefile recipes need not redefine it.  Three host-varying
        # inputs would otherwise leak (see build-flags.nix):
        #   - gcc's -frandom-seed: nixpkgs' reproducible-builds setup hook
        #     derives it from $out, which differs per host for this dev shell
        #     (its toolchain input's store hash differs per host), perturbing
        #     seed-sensitive codegen.  Strip the hook's seed and pin our own.
        #   - the cross-toolchain's own /nix/store paths in DWARF: map them to
        #     stable names (detPrefixMap), shared with the nix builds.
        #   - host build-tool `-isystem <dev>/include` dirs: mkShell dumps every
        #     nativeBuildInput's include dir into the shared NIX_CFLAGS_COMPILE,
        #     which the cross-cc also reads.  On darwin that puts the HOST libiconv
        #     (propagated by gettext) ahead of the target glibc, so console/pc_kbd
        #     compile against the wrong iconv.h (host `__tag_iconv_t`, not glibc's
        #     `iconv_t`) and leak the host store path into DWARF — diverging from
        #     Linux (glibc has iconv built-in, no host libiconv).  A cross-compile
        #     must resolve system headers only from its own sysroot (the wrapper's
        #     -idirafter glibc) + the Makefile -I, never host `-isystem`, so strip
        #     them all; native `make mig` needs none of these lib headers.
        export NIX_CFLAGS_COMPILE="$(printf '%s' "''${NIX_CFLAGS_COMPILE:-}" \
          | sed -E '${buildFlags.isystemStripSed}') -frandom-seed=${buildFlags.randomSeed} ${detPrefixMap}"

        # Canonical glibc roots (build-flags.nix) for the in-tree glibc build to
        # -ffile-prefix-map its $(GLIBC_SRC)/$(GLIBC_BUILDDIR)/$(SYSROOT) to — the
        # SAME names glibc.nix maps the nix build's roots to, so the in-tree and nix
        # glibc come out byte-identical.  Passed via env so the Makefile stays DRY.
        export GLIBC_CANON_SRC=${buildFlags.glibcCanonSrc}
        export GLIBC_CANON_BUILD=${buildFlags.glibcCanonBuild}
        export GLIBC_CANON_SYSROOT=${buildFlags.glibcCanonSysroot}
        # Same for the in-tree gnumach + hurd builds (see build-flags.nix) — the
        # SAME single canonical gnumach/default.nix + hurd/default.nix map their
        # nix build's $PWD to, so in-tree == nix for those modules too.
        export GNUMACH_CANON_BUILD=${buildFlags.gnumachCanonBuild}
        export HURD_CANON_BUILD=${buildFlags.hurdCanonBuild}

        # Base compile flags (build-flags.nix) — the SAME -g -O2 (+ hurd's -fcommon)
        # the nix derivations use.  The in-tree gnumach/hurd configure CFLAGS read
        # these so the flags live in ONE place (nix), never duplicated in the Makefile.
        export BASE_CFLAGS="${buildFlags.baseCflags}"
        export HURD_EXTRA_CFLAGS="${buildFlags.hurdExtraCflags}"

        # No store RUNPATH leak in the shipped dist.  On Linux the cross
        # ld-wrapper bakes a DT_RUNPATH into EVERY in-tree binary; darwin's
        # stdenv never does.  The extra RUNPATH string enlarges .dynstr and
        # shifts every address (.text/.symtab/.dynsym cascade), so the dist
        # diverges cross-host AND leaks a build path.  Two distinct sources, two
        # mechanisms — make every host match darwin (deployable dist resolves via
        # the target's own /lib + DT_NEEDED, no rpath wanted):
        #
        #  (a) auto-derived rpath from the wrapped cc's OWN -L<store> dirs (the
        #      abi-checked working glibc + gcc libdir, injected on every link).
        #      NIX_DONT_SET_RPATH gates exactly this.  It must be a REAL env var,
        #      not the wrapped bintools' add-local-ldflags-before.sh: gcc links
        #      through its --with-ld bintools (the stage-1 wrapper), which never
        #      sources the working wrapper's suppression — same trap glibc.nix /
        #      mkGcc hit, fixed the same way (a salted env var the real ld honours).
        export NIX_DONT_SET_RPATH${salt}=1
        #
        #  (b) the EXPLICIT `-rpath $out/lib` that `nix develop` injects into
        #      NIX_LDFLAGS (the dev shell's own-output rpath).  NIX_DONT_SET_RPATH
        #      does NOT cover an explicit -rpath flag (verified on Linux), so sed
        #      it out of NIX_LDFLAGS directly.
        [ -n "''${out:-}" ] && export NIX_LDFLAGS="$(printf '%s' "''${NIX_LDFLAGS:-}" | sed "s@-rpath $out/lib@@g")"
        # Same configure flag set as the nix Hurd build (hurd-config.nix).
        export HURD_CONFIGURE_FLAGS="--host=${target.crossTarget} ${coreFlags}"
        # Root-relative install dirs the nix Hurd uses (hurd-config.deployFlags).
        export HURD_DEPLOY_FLAGS="${hurdDeployFlags}"
        # Deployable-prefix dirs + libc_cv_* the nix glibc uses (glibc-config.nix),
        # so the in-tree glibc configure stays in lockstep (single source).
        export GLIBC_DEPLOY_FLAGS="${deployFlags}"
        export GLIBC_CORE_FLAGS="${glibcCoreFlags}"
      '';
    };
}
