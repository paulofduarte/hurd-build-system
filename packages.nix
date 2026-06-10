# SPDX-FileCopyrightText: 2026 Paulo Duarte <paulofernandobd@gmail.com>
# SPDX-License-Identifier: GPL-3.0-or-later
# `packages.<system>` and `apps.<system>` outputs (kernel, headers, mig,
# glibc-hurd, the cross-toolchain, sidekick + the `nix run` apps).
#
# Kept out of flake.nix so adding a sub-flake doesn't touch flake.nix /
# target-archs.nix and thus doesn't retrigger the toolchain-cache CI (which
# path-filters on those + flakes/cross-toolchain).
#
# The root threads only the flake-level values a sub-flake can't derive itself
# (nixpkgs, system, self, targets, crossToolchain, the `*-src` inputs); each
# sub-flake instantiates its own pkgs/lib and imports its own flakes/lib.

{ nixpkgs, self, forAllSystems, targets, crossToolchain, gnumach-src, mig-src, hurd-src, glibc-src
, gnumach-ref-src, mig-ref-src, hurd-ref-src, glibc-ref-src }:

let
  inherit (nixpkgs) lib;
  inherit (crossToolchain) mkCrossPkgs mkAll mkCompiler mkRuntimeLib wrappedToolchain;
  # Fork-id metadata (owner/repo/ref) from the `*-src` inputs via flake.lock;
  # feeds the version string's fork field.  See flakes/sources.
  sourcesLib  = import ./flakes/sources { inherit lib; };
  gnumachInfo = sourcesLib.info self "gnumach-src" gnumach-src;
  migInfo     = sourcesLib.info self "mig-src" mig-src;
  hurdInfo    = sourcesLib.info self "hurd-src" hurd-src;
  glibcInfo   = sourcesLib.info self "glibc-src" glibc-src;

  # Userland targets (those that get a full toolchain): the non-xen ones.
  # The xen variants are kernel-only.
  hurdTargets = lib.filterAttrs (_: t: (t.platform or null) != "xen") targets;
  # crossTarget (`<cpu>-gnu`) -> userland target name.  A xen variant shares
  # its CPU sibling's crossTarget, so it maps onto that sibling's toolchain.
  toolchainNameByCrossTarget = lib.listToAttrs
    (lib.mapAttrsToList (n: t: lib.nameValuePair t.crossTarget n) hurdTargets);
in
{
  packages = forAllSystems (system:
    let
      gnumachHeaders = import ./flakes/gnumach-headers {
        inherit nixpkgs system targets mkCrossPkgs;
        srcInput = gnumach-src;
      };
      mig = import ./flakes/mig {
        inherit nixpkgs system targets gnumachHeaders mkCrossPkgs;
        srcInput = mig-src;
        forkUrl = migInfo.forkUrl;
      };
      hurdHeaders = import ./flakes/hurd-headers {
        inherit nixpkgs system targets mig;
        srcInput = hurd-src;
        forkUrl = hurdInfo.forkUrl;
      };
      sidekick = import ./flakes/sidekick { inherit nixpkgs system; };

      # Pre-libc cross-toolchain stages: per-target `cross-binutils-<arch>` +
      # `cross-gcc-stage1-<arch>` (the libc-free cc that builds gnumach-headers
      # / mig / glibc-hurd).  See flakes/cross-toolchain/toolchain.nix.
      toolchainStagePkgs = mkAll system targets;

      # ----------------------------------------------------------------------
      # 2-pass bootstrap.  Chain: stage-1 nolibc gcc -> ref glibc -> final gcc ->
      # work glibc.  The nolibc cc builds the reference glibc directly (a nolibc
      # gcc builds glibc fine); the final gcc binds the ref glibc's ABI, not its
      # bytes, so the dist stays byte-identical with no separate complete-gcc pass.
      # ----------------------------------------------------------------------

      # Reference toolchain inputs: frozen release-tag headers/mig the REFERENCE
      # glibc consumes.  Distinct, stable pins - a `glibc-ref-src` bump does NOT
      # touch these.  See TOOLCHAIN-LIBC-DECOUPLING.md.
      gnumachHeadersRef = import ./flakes/gnumach-headers {
        inherit nixpkgs system targets mkCrossPkgs;
        srcInput = gnumach-ref-src;
      };
      migRef = import ./flakes/mig {
        inherit nixpkgs system targets mkCrossPkgs;
        gnumachHeaders = gnumachHeadersRef;
        srcInput = mig-ref-src;
        forkUrl = migInfo.forkUrl;
      };
      hurdHeadersRef = import ./flakes/hurd-headers {
        inherit nixpkgs system targets;
        mig = migRef;
        srcInput = hurd-ref-src;
        forkUrl = hurdInfo.forkUrl;
      };

      # Reference glibc - the ABI baseline the final gcc's runtime binds against.
      # Built directly by the nolibc stage-1 cc (glibc.nix's default buildCC).
      # Never shipped or run: the final gcc binds its ABI/headers, not its bytes.
      glibcRefHurd = import ./flakes/cross-toolchain/glibc.nix {
        inherit nixpkgs system targets;
        mig = migRef;
        gnumachHeaders = gnumachHeadersRef;
        hurdHeaders = hurdHeadersRef;
        inherit (crossToolchain) mkCrossPkgs;
        srcInput = glibc-ref-src;
        forkUrl  = glibcInfo.forkUrl;
      };
      # Expose the reference glibc as `glibc-ref-hurd-<arch>` - for the ABI gate
      # + `nix build` debugging.
      glibcRefHurdPkgs = lib.mapAttrs'
        (n: v: lib.nameValuePair
          (lib.replaceStrings [ "glibc-hurd-" ] [ "glibc-ref-hurd-" ] n) v)
        glibcRefHurd;

      # glibc-hurd (WORKING): the Hurd C library the wrapped cc + userland bind,
      # from the working `glibc-src` + working headers/mig.  Built by CROSS-GCC,
      # the same compiler the in-tree working glibc uses (flake.nix glibcCC), so
      # nix-work and in-tree-work glibc match byte-for-byte.
      glibcHurd = import ./flakes/cross-toolchain/glibc.nix {
        inherit nixpkgs system targets mig gnumachHeaders hurdHeaders;
        inherit (crossToolchain) mkCrossPkgs;
        srcInput = glibc-src;
        forkUrl  = glibcInfo.forkUrl;
        # cross-gcc wrapped around the reference glibc (configure link-tests need
        # crt/libc; work != ref -> no cycle).
        buildCC = name: target: wrappedToolchain system target {
          cc      = newCompilerByName.${name};
          working = glibcRefHurd."glibc-hurd-${name}";
        };
      };

      # The bare-name working glibc the wrapped cc + userland LINK against.  NO ABI gate:
      # the wrapper flip (user code + the runtime compile against THIS working glibc) makes
      # the ref-vs-work ABI consistent by construction, so there is nothing to gate.  We
      # only rewrite the deployable libc.so GROUP to BARE NAMES (libc.so.0.3, libmachuser.so,
      # ...) so the cross link resolves them via the wrapper's -L (this ld has no --sysroot
      # for the absolute /lib GROUP).  The SHIPPED glibc (glibc-hurd-<arch> = glibcHurd)
      # keeps its absolute /lib GROUP; this bare farm is the cross-LINK sysroot only.
      bareGlibcHurd = lib.mapAttrs' (name: target:
        lib.nameValuePair "glibc-hurd-${name}"
          (nixpkgs.legacyPackages.${system}.runCommand "glibc-hurd-${name}-bare" { } ''
            mkdir -p "$out"
            cp -as "${glibcHurd."glibc-hurd-${name}"}"/. "$out"/
            chmod u+w "$out/lib"
            for so in "$out"/lib/*.so; do
              [ -L "$so" ] && grep -q '^GROUP' "$so" 2>/dev/null || continue
              tgt="$(readlink -f "$so")"; rm -f "$so"
              sed 's@ /lib/@ @g' "$tgt" > "$so"; chmod u+w "$so"
            done
          ''))
        hurdTargets;

      # The single nolibc C++ compiler - the one `cross-gcc-<arch>` going forward.
      # Binds the PINNED reference Hurd headers (gnumach+hurd+mig+glibc) for its posix
      # thread model only; never rebuilt on a working-glibc hack.  TODO: replace the full
      # ref glibc's include with a headers-only derivation (no ref libc binaries).
      newCompilerByName = lib.mapAttrs (name: target:
        mkCompiler system target glibcRefHurd."glibc-hurd-${name}") hurdTargets;
      # Per-lib target-runtime derivations (built against the WORKING glibc, no xgcc
      # rebuild).  libgcc is standalone - the toolchain -B's it, so splitting it out
      # bounds the toolchain's glibc-hack rebuild to libgcc alone.  The rest -B the
      # per-arch libgcc and build on demand (dist + the C++ toolchain variant).
      libgccByName = lib.mapAttrs (name: target:
        mkRuntimeLib system target {
          compiler = newCompilerByName.${name};
          working  = bareGlibcHurd."glibc-hurd-${name}";
          libName  = "libgcc";
        }) hurdTargets;
      # name -> configure flags for the remaining runtime libs.  (libstdc++ maps to
      # gcc's historical libstdc++-v3 source dir inside mkRuntimeLib.)
      otherRuntimeSpecs = {
        "libstdc++"   = "--enable-shared";
        "libatomic"   = "--enable-shared";
        "libitm"      = "--enable-shared";
        "libquadmath" = "--enable-shared";
        "libssp"      = "--enable-shared";
        "libgomp"     = "--enable-shared --disable-werror";
      };
      mkOtherRuntimeLib = name: target: libName: flags:
        mkRuntimeLib system target {
          compiler   = newCompilerByName.${name};
          working    = bareGlibcHurd."glibc-hurd-${name}";
          inherit libName;
          extraFlags = flags;
          libgccDrv  = libgccByName.${name};
        };

      # `cross-gcc-<arch>` = the cross compiler; `cross-gcc-rt-<lib>-<arch>` = each split
      # runtime lib (libgcc + the on-demand rest); `toolchain-<arch>` = THE toolchain
      # (dev shell, kernel, userland, cache): cross-gcc wrapped around the bare working
      # glibc, -B'd to link the work-built libgcc.
      hurdFinalPkgs = lib.listToAttrs (lib.concatLists (lib.mapAttrsToList (name: target:
        [
          { name = "cross-gcc-${name}";           value = newCompilerByName.${name}; }
          { name = "cross-gcc-rt-libgcc-${name}"; value = libgccByName.${name}; }
          { name = "toolchain-${name}"; value = wrappedToolchain system target {
              cc      = newCompilerByName.${name};
              working = bareGlibcHurd."glibc-hurd-${name}";
              # Link the WORK-built libgcc (the split libgcc derivation) into every build,
              # not cc's ref-built copy - the runtime is actually consumed + ABI-consistent.
              libgcc  = libgccByName.${name};
            }; }
        ] ++ lib.mapAttrsToList (libName: flags:
          { name  = "cross-gcc-rt-${libName}-${name}";
            value = mkOtherRuntimeLib name target libName flags; }) otherRuntimeSpecs
      ) hurdTargets));

      # The wrapped cross-cc a given target's gnumach kernel builds with.  Xen
      # variants reuse their CPU sibling's (same `<cpu>-gnu` ABI - the kernel
      # links -nostdlib, so the working glibc-hurd sysroot is moot).
      toolchainFor = target: hurdFinalPkgs."toolchain-${toolchainNameByCrossTarget.${target.crossTarget}}";

      # CHECKED mig - built with the wrapped cc (carries glibc-hurd's <string.h>)
      # so `make check` can compile the generated stubs.  Byte-identical to the
      # bootstrap `mig` (migcom is native-host-cc, cpu.h -ffreestanding in both),
      # so a green check proves the bootstrap mig that built glibc is sound.  Sits
      # downstream of glibc -> built AFTER hurdFinalPkgs, no cycle.
      migChecked = import ./flakes/mig {
        inherit nixpkgs system targets gnumachHeaders mkCrossPkgs;
        srcInput = mig-src;
        forkUrl = migInfo.forkUrl;
        checkToolchains = hurdFinalPkgs;
      };

      # Consumer-facing mig: every target mapped to the CHECKED mig of its
      # crossTarget sibling, re-keyed to the plain `mig-<name>` the gnumach/hurd
      # modules look up.  Routes glibc's downstream consumers (kernel + userland)
      # through the validated mig, so they can't build unless the mig tests
      # passed.  The unchecked bootstrap `mig` stays on the pre-glibc path
      # (hurd-headers, glibc), where no libc exists yet to run the tests.
      checkedMigFor = lib.listToAttrs (lib.mapAttrsToList (name: target:
        lib.nameValuePair "mig-${name}"
          migChecked."mig-checked-${toolchainNameByCrossTarget.${target.crossTarget}}")
        targets);

      # GNU Mach kernel - built with the wrapped cross-cc (freestanding,
      # -nostdlib).  `toolchainFor` resolves each target onto its `toolchain-<arch>`.
      gnumach = import ./flakes/gnumach {
        inherit nixpkgs system targets self toolchainFor;
        mig = checkedMigFor;   # downstream of glibc -> the validated mig
        srcInput = gnumach-src;
        forkUrl = gnumachInfo.forkUrl;
      };

      # The Hurd userland (core servers + libraries), built with the
      # wrapped toolchain + mig + the ABI-gated glibc-hurd sysroot.
      hurd = import ./flakes/hurd {
        inherit nixpkgs system targets self;
        mig = checkedMigFor;   # downstream of glibc -> the validated mig
        glibcHurd = bareGlibcHurd;
        hurdToolchain = hurdFinalPkgs;
        srcInput = hurd-src;
        forkUrl = hurdInfo.forkUrl;
      };
    in
    gnumach
    // gnumachHeaders
    // mig
    // hurdHeaders
    // hurd
    // sidekick
    // toolchainStagePkgs
    // glibcHurd
    // glibcRefHurdPkgs
    // hurdFinalPkgs
    // migChecked
    # Timezone database for the dist (dist-tzdata copies its share/zoneinfo).
    # arch-independent zic-compiled data, byte-identical cross-host; one package
    # serves every target.
    // { tzdata = nixpkgs.legacyPackages.${system}.tzdata; });

  apps = forAllSystems (system: import ./flakes/run {
    inherit nixpkgs system targets crossToolchain;
    packages = self.packages.${system};
  });
}
