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

{ nixpkgs, self, forAllSystems, targets, crossToolchain, buildRevToken ? null
, gnumach-src, mig-src, hurd-src, glibc-src
, gnumach-dev-src, mig-dev-src, hurd-dev-src }:

let
  inherit (nixpkgs) lib;
  inherit (crossToolchain) mkCrossPkgs mkAll mkCompiler mkRuntimeBase mkRuntimeLib wrappedToolchain;
  # Fork-id metadata (owner/repo/ref) from the `*-src` inputs via flake.lock;
  # feeds the version string's fork field.  See flakes/sources.
  sourcesLib  = import ./flakes/sources { inherit lib; };
  gnumachInfo = sourcesLib.info self "gnumach-src" gnumach-src;
  migInfo     = sourcesLib.info self "mig-src" mig-src;
  hurdInfo    = sourcesLib.info self "hurd-src" hurd-src;

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
      # The ALIAS-side chain is content-addressed (headers, mig, glibc, the
      # rt libs, gnumach, hurd): a change that leaves a package's output
      # byte-identical stops the rebuild cascade right there (early cutoff).
      # These read the overridable *-dev-src aliases.  The bootstrap-side
      # instances below stay input-addressed - their pins are frozen, so CA
      # would only add resolution overhead.
      gnumachHeaders = import ./flakes/gnumach-headers {
        inherit nixpkgs system targets mkCrossPkgs;
        srcInput = gnumach-dev-src;
        contentAddressed = true;
        includeOnly = true;
      };
      mig = import ./flakes/mig {
        inherit nixpkgs system targets gnumachHeaders mkCrossPkgs;
        srcInput = mig-dev-src;
        forkUrl = migInfo.forkUrl;
        contentAddressed = true;
      };
      hurdHeaders = import ./flakes/hurd-headers {
        inherit nixpkgs system targets mig;
        srcInput = hurd-dev-src;
        forkUrl = hurdInfo.forkUrl;
        contentAddressed = true;
        includeOnly = true;
      };
      sidekick = import ./flakes/sidekick { inherit nixpkgs system; };

      # Pre-libc cross-toolchain stages: per-target `cross-binutils-<arch>` +
      # `bootstrap-gcc-<arch>` (the libc-free cc that builds gnumach-headers
      # / mig / glibc-hurd).  See flakes/cross-toolchain/toolchain.nix.
      toolchainStagePkgs = mkAll system targets;

      # ----------------------------------------------------------------------
      # The toolchain chain: bootstrap-gcc -> bootstrap glibc -> cross-gcc ->
      # glibc.  The nolibc cc builds the bootstrap glibc directly (a nolibc gcc
      # builds glibc fine); cross-gcc binds the bootstrap glibc's ABI, not its
      # bytes, so the dist stays byte-identical with no separate complete-gcc
      # pass.  Bootstrap and shipped glibc share the same pins (the *-ref-src
      # twins are gone) - they differ only in which gcc builds them; the
      # stub-split (design doc phase 4) collapses them to one.
      # ----------------------------------------------------------------------

      # Bootstrap-side instances: the SAME pins, consumed via the pin inputs
      # (never the overridable aliases), feeding the bootstrap glibc and hence
      # cross-gcc.  Unoverridden they are drv-identical to the alias-side
      # instances above; an in-tree override moves ONLY the alias side.
      # Internal bindings - no exposed attrs (a no-override build of the plain
      # attr IS the pin side).
      gnumachHeadersBootstrap = import ./flakes/gnumach-headers {
        inherit nixpkgs system targets mkCrossPkgs;
        srcInput = gnumach-src;
      };
      migBootstrap = import ./flakes/mig {
        inherit nixpkgs system targets mkCrossPkgs;
        gnumachHeaders = gnumachHeadersBootstrap;
        srcInput = mig-src;
        forkUrl = migInfo.forkUrl;
      };
      hurdHeadersBootstrap = import ./flakes/hurd-headers {
        inherit nixpkgs system targets;
        mig = migBootstrap;
        srcInput = hurd-src;
        forkUrl = hurdInfo.forkUrl;
      };

      # Bootstrap glibc - the ABI baseline cross-gcc binds (libcCross).  Built
      # directly by bootstrap-gcc (glibc.nix's default buildCC).  Never shipped
      # or run; collapses into THE glibc at the stub-split (design doc phase 4).
      glibcBootstrap = import ./flakes/cross-toolchain/glibc.nix {
        inherit nixpkgs system targets;
        mig = migBootstrap;
        gnumachHeaders = gnumachHeadersBootstrap;
        hurdHeaders = hurdHeadersBootstrap;
        inherit (crossToolchain) mkCrossPkgs;
        srcInput = glibc-src;
      };

      # glibc-hurd (SHIPPED): the Hurd C library the wrapped cc + userland bind,
      # from `glibc-src` + the alias headers/mig.  Built by CROSS-GCC, the same
      # compiler the in-tree build uses, so nix and in-tree glibc match
      # byte-for-byte.
      glibcHurd = import ./flakes/cross-toolchain/glibc.nix {
        inherit nixpkgs system targets mig gnumachHeaders hurdHeaders;
        inherit (crossToolchain) mkCrossPkgs;
        srcInput = glibc-src;
        contentAddressed = true;
        # cross-gcc wrapped around the bootstrap glibc (configure link-tests
        # need crt/libc; the bootstrap drv differs from this one -> no cycle).
        buildCC = name: target: wrappedToolchain system target {
          cc      = newCompilerByName.${name};
          working = glibcBootstrap."glibc-hurd-${name}";
        };
      };

      # The bare-name glibc the wrapped cc + userland LINK against.  NO ABI gate:
      # the wrapper flip (user code + the runtime compile against THIS glibc) makes
      # the bootstrap-vs-shipped ABI consistent by construction, so there is nothing to gate.  We
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
      # bootstrap glibc's include with a headers-only derivation (no bootstrap libc binaries).
      newCompilerByName = lib.mapAttrs (name: target:
        mkCompiler system target glibcBootstrap."glibc-hurd-${name}") hurdTargets;
      # Per-lib target-runtime derivations (built against the shipped glibc, no xgcc
      # rebuild).  libgcc is standalone - the toolchain -B's it, so splitting it out
      # bounds the toolchain's glibc-hack rebuild to libgcc alone.  The rest -B the
      # per-arch libgcc and build on demand (dist + the C++ toolchain variant).
      # The shared runtime-build base (partial gcc tree + libgcc.mvars glue), built
      # once per arch; every cross-gcc-rt-<lib> copies it instead of re-doing it.
      rtBaseByName = lib.mapAttrs (name: target:
        mkRuntimeBase system target {
          compiler = newCompilerByName.${name};
          working  = bareGlibcHurd."glibc-hurd-${name}";
        }) hurdTargets;
      libgccByName = lib.mapAttrs (name: target:
        mkRuntimeLib system target {
          compiler = newCompilerByName.${name};
          working  = bareGlibcHurd."glibc-hurd-${name}";
          base     = rtBaseByName.${name};
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
          base       = rtBaseByName.${name};
          inherit libName;
          extraFlags = flags;
          libgccDrv  = libgccByName.${name};
        };

      # `cross-gcc-<arch>` = the cross compiler; `cross-gcc-rt-<lib>-<arch>` = each split
      # runtime lib (libgcc + the on-demand rest); `toolchain-<arch>` = THE toolchain
      # (dev shell, kernel, userland, cache): cross-gcc wrapped around the bare working
      # glibc, -B'd to link the shipped libgcc.
      hurdFinalPkgs = lib.listToAttrs (lib.concatLists (lib.mapAttrsToList (name: target:
        [
          { name = "cross-gcc-${name}";           value = newCompilerByName.${name}; }
          { name = "cross-gcc-rt-base-${name}";   value = rtBaseByName.${name}; }
          { name = "cross-gcc-rt-libgcc-${name}"; value = libgccByName.${name}; }
          { name = "toolchain-${name}"; value = wrappedToolchain system target {
              cc      = newCompilerByName.${name};
              working = bareGlibcHurd."glibc-hurd-${name}";
              # Link the shipped libgcc (the split libgcc derivation) into every build,
              # not cc's bootstrap-built copy - the runtime is actually consumed + ABI-consistent.
              libgcc  = libgccByName.${name};
            }; }
        ] ++ lib.mapAttrsToList (libName: flags:
          { name  = "cross-gcc-rt-${libName}-${name}";
            value = mkOtherRuntimeLib name target libName flags; }) otherRuntimeSpecs
      ) hurdTargets));

      # The wrapped cross-cc a given target's gnumach kernel builds with.  Xen
      # variants reuse their CPU sibling's (same `<cpu>-gnu` ABI - the kernel
      # links -nostdlib, so the shipped glibc-hurd sysroot is moot).
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
        inherit nixpkgs system targets self toolchainFor buildRevToken;
        mig = checkedMigFor;   # downstream of glibc -> the validated mig
        srcInput = gnumach-src;
        forkUrl = gnumachInfo.forkUrl;
      };

      # The Hurd userland (core servers + libraries), built with the
      # wrapped toolchain + mig + the ABI-gated glibc-hurd sysroot.
      hurd = import ./flakes/hurd {
        inherit nixpkgs system targets self buildRevToken;
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
