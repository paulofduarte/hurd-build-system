# `packages.<system>` and `apps.<system>` outputs (kernel, headers, mig,
# glibc-hurd, the cross-toolchain, sidekick + the `nix run` apps).
#
# Kept out of flake.nix so adding a new sub-flake (e.g. hurd) touches only
# this module — flake.nix and target-archs.nix stay untouched, so the
# toolchain-cache CI (which path-filters on those + flakes/cross-toolchain)
# does not retrigger.  See .github/workflows.
#
# Each sub-flake instantiates its own `pkgs`/`lib` (from `nixpkgs` + `system`)
# and imports its own `flakes/lib` helpers — the root only threads the
# flake-level values a sub-flake can't derive itself:
#   nixpkgs, system        — to instantiate the package set;
#   self                   — build-rev + .gitmodules for PACKAGE_VERSION;
#   targets                — the per-target loop;
#   crossToolchain         — the merged `<cpu>-gnu` cross-toolchain
#                            (mkCrossPkgs / mkAll / mkGcc / wrappedToolchain /
#                            the ABI gate);
#   srcInput               — the gnumach-src / mig-src / … flake inputs
#                            (pinned github fork rev; see flakes/sources).

{ nixpkgs, self, forAllSystems, targets, crossToolchain, gnumach-src, mig-src, hurd-src, glibc-src
, gnumach-ref-src, mig-ref-src, hurd-ref-src, glibc-ref-src
, glibc-bootstrap-src, gnumach-bootstrap-src, mig-bootstrap-src, hurd-bootstrap-src }:

let
  inherit (nixpkgs) lib;
  inherit (crossToolchain) mkCrossPkgs mkAll mkGcc wrappedToolchain mkAbiChecked mkAbiReport mkAbiReportHost;
  # Fork-id metadata (owner/repo/ref) derived from the `*-src` inputs via
  # flake.lock — see flakes/sources.  Feeds the version string's fork field.
  sourcesLib  = import ./flakes/sources { inherit lib; };
  gnumachInfo = sourcesLib.info self "gnumach-src" gnumach-src;
  migInfo     = sourcesLib.info self "mig-src" mig-src;
  hurdInfo    = sourcesLib.info self "hurd-src" hurd-src;
  glibcInfo   = sourcesLib.info self "glibc-src" glibc-src;

  # Userland targets (those that get a full toolchain): the non-xen ones,
  # i686 + x86_64.  The xen variants are kernel-only.
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

      # Pre-libc cross-toolchain stages: per-userland-target
      # `cross-binutils-<arch>` + `cross-gcc-stage1-<arch>` (the libc-free
      # cc that builds gnumach-headers / mig / glibc-hurd).  Defined in
      # flakes/cross-toolchain/toolchain.nix.
      toolchainStagePkgs = mkAll system targets;

      # ──────────────────────────────────────────────────────────────────────
      # 3-stage bootstrap (PHASE-2-3STAGE-BOOTSTRAP.md).  The nolibc stage-1 cc
      # is a bootstrap-only seed: it builds ONLY the throwaway bootstrap glibc,
      # which produces a COMPLETE stage-2 gcc; that builds the reference glibc;
      # which produces the final gcc; which builds the working glibc.  Every
      # glibc is `--prefix=/` and built by a complete gcc except the bootstrap
      # one (built by stage-1).  Chain is strictly linear:
      #   bootstrap glibc → stage-2 gcc → ref glibc → final gcc → work glibc.
      # ──────────────────────────────────────────────────────────────────────

      # Reference toolchain inputs (Part 2): frozen release-tag headers/mig that
      # the reference AND bootstrap glibcs consume.  Distinct, stable pins — a
      # `glibc-ref-src` bump does NOT touch these, so the stage-2 gcc (built
      # against the bootstrap glibc, which uses these) stays cached across ref
      # bumps.  See TOOLCHAIN-LIBC-DECOUPLING.md.
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

      # Bootstrap glibc — THROWAWAY seed built by the nolibc stage-1 cc (the
      # default buildCC) from the independently-pinned `glibc-bootstrap-src`,
      # against the reference headers/mig.  Its only purpose is to give the
      # stage-2 gcc a target libc; never shipped, never cached.
      bootstrapGlibc = import ./flakes/cross-toolchain/glibc.nix {
        inherit nixpkgs system targets;
        mig = migRef;
        gnumachHeaders = gnumachHeadersRef;
        hurdHeaders = hurdHeadersRef;
        inherit (crossToolchain) mkCrossPkgs;
        srcInput = glibc-bootstrap-src;
        forkUrl  = glibcInfo.forkUrl;
        deployPrefix = true;
      };

      # Stage-2 gcc — the COMPLETE seed compiler (libgcc_s/libstdc++ vs the
      # bootstrap glibc).  Cached/pinned; rebuilds only on a bootstrap-pin or
      # nixpkgs-gcc change, NOT on a `glibc-ref-src` bump.  Builds the ref glibc.
      # Not a standalone output: `make push-cache` walks the toolchain's full
      # build closure, so this (and every other bootstrap intermediate) is cached
      # by store path without a dedicated `cross-gcc-stage2-<arch>` attribute.
      stage2GccByName = lib.mapAttrs (name: target:
        mkGcc system target (bootstrapGlibc."glibc-hurd-${name}")) hurdTargets;

      # Reference glibc — the ABI baseline gcc's runtime binds.  Built by the
      # complete stage-2 gcc (normal build conditions, not the nolibc cc).
      glibcRefHurd = import ./flakes/cross-toolchain/glibc.nix {
        inherit nixpkgs system targets;
        mig = migRef;
        gnumachHeaders = gnumachHeadersRef;
        hurdHeaders = hurdHeadersRef;
        inherit (crossToolchain) mkCrossPkgs;
        srcInput = glibc-ref-src;
        forkUrl  = glibcInfo.forkUrl;
        deployPrefix = true;
        # Build with the COMPLETE stage-2 gcc wrapped around its own libc (the
        # bootstrap glibc) — glibc's configure link-tests (e.g. "PDE load
        # address") need crt1.o/libc on the path, which the raw complete cc
        # lacks; the wrapper supplies them + mechanism #2 --sysroot so the
        # bootstrap glibc's /lib GROUP resolves.  ref ≠ bootstrap → no cycle.
        buildCC = name: target: wrappedToolchain system target {
          cc      = stage2GccByName.${name};
          working = bootstrapGlibc."glibc-hurd-${name}";
        };
      };
      # Expose the reference glibc as `glibc-ref-hurd-<arch>` (the working one
      # is `glibc-hurd-<arch>`) — for the ABI gate + `nix build` debugging.
      glibcRefHurdPkgs = lib.mapAttrs'
        (n: v: lib.nameValuePair
          (lib.replaceStrings [ "glibc-hurd-" ] [ "glibc-ref-hurd-" ] n) v)
        glibcRefHurd;

      # Final gcc — the userland cc.  libgcc_s/libstdc++ vs the reference glibc
      # (the POSIX wall: ABI-stable against the working glibc).  Rebuilds only
      # on a ref bump, never on a working-glibc hack.  Builds the working glibc.
      finalGccByName = lib.mapAttrs (name: target:
        mkGcc system target (glibcRefHurd."glibc-hurd-${name}")) hurdTargets;

      # glibc-hurd (WORKING): the Hurd C library the wrapped cc + userland bind,
      # from the working `glibc-src` + working headers/mig.  Built by the FINAL
      # gcc — so the nix working glibc and the in-tree working glibc share one
      # compiler (consistency), and the nolibc cc never touches a real glibc.
      glibcHurd = import ./flakes/cross-toolchain/glibc.nix {
        inherit nixpkgs system targets mig gnumachHeaders hurdHeaders;
        inherit (crossToolchain) mkCrossPkgs;
        srcInput = glibc-src;
        forkUrl  = glibcInfo.forkUrl;
        deployPrefix = true;
        # Built by the COMPLETE final gcc wrapped around the reference glibc (its
        # own libc) — same reason as the ref glibc above (configure link-tests
        # need crt/libc).  work ≠ ref → no cycle.  This is also the gcc the
        # in-tree working glibc will use, so nix-work and in-tree-work match.
        buildCC = name: target: wrappedToolchain system target {
          cc      = finalGccByName.${name};
          working = glibcRefHurd."glibc-hurd-${name}";
        };
      };

      # The ABI gate dispatches its Linux-only analysers (abidiff/pahole)
      # into the Debian sidekick VM, so it runs on every host (no darwin
      # skip, no nixpkgs libabigail/pahole dep).  Thread the sidekick image
      # + the host-side dispatch scripts to the gate.  See
      # SIDEKICK-DISPATCHER.md.
      sidekickArgs = {
        sidekick    = sidekick.sidekick;
        dispatchLib = ./flakes/sidekick/sidekick-dispatch.sh;
        sendScript  = ./flakes/sidekick/sidekick-send.sh;
      };

      # The ABI-gated working glibc — what the wrapped cc + userland bind.
      # Per target: if the working and reference glibc resolve to the same
      # store path the gate is a no-op and we pass the working glibc straight
      # through; once they diverge (hacking src/, or the ref pinned to an older
      # release tag) the gate runs the FULL probe suite (via sidekick) and
      # re-exports the working glibc on pass.  gcc is unaffected either way — it
      # binds the reference glibc (ungated), so the gate never rebuilds gcc.
      gatedGlibcHurd = lib.mapAttrs' (name: target:
        let
          w = glibcHurd."glibc-hurd-${name}";
          r = glibcRefHurd."glibc-hurd-${name}";
        in lib.nameValuePair "glibc-hurd-${name}"
          (if w.drvPath == r.drvPath
           then w
           else mkAbiChecked system target ({ working = w; reference = r; glibcSrc = glibc-src; } // sidekickArgs)))
        hurdTargets;

      # Final cross-gcc + wrapped toolchain per userland target.  `cross-gcc-
      # <arch>` is the final gcc; `toolchain-<arch>` wraps it around the ABI-
      # gated working glibc (THE toolchain — dev shell, kernel, userland, cache).
      hurdFinalPkgs = lib.listToAttrs (lib.concatLists (lib.mapAttrsToList (name: target: [
        { name = "cross-gcc-${name}"; value = finalGccByName.${name}; }
        { name = "toolchain-${name}"; value = wrappedToolchain system target {
            cc      = finalGccByName.${name};
            working = gatedGlibcHurd."glibc-hurd-${name}";
          }; }
      ]) hurdTargets));

      # The wrapped cross-cc a given target's gnumach kernel builds with.
      # Userland targets use their own `toolchain-<arch>`; the xen kernel
      # variants reuse their CPU sibling's (same `<cpu>-gnu` ABI — the
      # kernel links -nostdlib, so the working glibc-hurd sysroot is moot).
      toolchainFor = target: hurdFinalPkgs."toolchain-${toolchainNameByCrossTarget.${target.crossTarget}}";

      # CHECKED mig — the validated mig.  Built with the wrapped cc (which
      # carries glibc-hurd's <string.h> etc.), so its `make check` can
      # compile the generated stubs; byte-identical to the bootstrap `mig`
      # (migcom is native-host-cc, cpu.h is -ffreestanding in both), so a
      # green check proves the bootstrap mig that built glibc is sound.
      # Sits downstream of glibc (via the wrapped cc) → built AFTER
      # hurdFinalPkgs here, no cycle.  Outputs `mig-checked-<arch>` for the
      # non-xen userland targets.
      migChecked = import ./flakes/mig {
        inherit nixpkgs system targets gnumachHeaders mkCrossPkgs;
        srcInput = mig-src;
        forkUrl = migInfo.forkUrl;
        checkToolchains = hurdFinalPkgs;
      };

      # Consumer-facing mig: every target (incl. the xen kernel variants)
      # mapped to the CHECKED mig of its crossTarget sibling, re-keyed to the
      # plain `mig-<name>` the gnumach/hurd modules look up.  This routes
      # glibc's DOWNSTREAM consumers (kernel + userland) through the validated
      # mig — so `nix build .#gnumach-<arch>` / `.#hurd-<arch>` can't succeed
      # unless the mig test suite passed.  The unchecked bootstrap `mig` stays
      # only on the pre-glibc path (hurd-headers, glibc), where no libc exists
      # yet to run the tests.
      checkedMigFor = lib.listToAttrs (lib.mapAttrsToList (name: target:
        lib.nameValuePair "mig-${name}"
          migChecked."mig-checked-${toolchainNameByCrossTarget.${target.crossTarget}}")
        targets);

      # `make check-glibc` / `check-glibc-full` back-ends: the explicit
      # report (`deep` = Tier-1/2 + headers; `full` adds the heavy probes).
      # Dispatches abidiff/pahole via the sidekick like the in-build gate, so
      # it runs on EVERY host now (the old darwin-only `meta.platforms` skip
      # is gone).  Compares the RAW working glibc against the reference.
      abiReportPkgs = lib.listToAttrs (lib.concatLists (lib.mapAttrsToList (name: target:
        let
          w = glibcHurd."glibc-hurd-${name}";
          r = glibcRefHurd."glibc-hurd-${name}";
          mk = level: mkAbiReport system target ({ working = w; reference = r; inherit level; glibcSrc = glibc-src; } // sidekickArgs);
        in [
          { name = "abi-check-${name}";      value = mk "deep"; }
          { name = "abi-check-full-${name}"; value = mk "full"; }
          # Host-side runner for the in-tree glibc (`make check-glibc[-full]`
          # when GLIBC_IN_TREE): takes the in-tree sysroot as a runtime arg,
          # compares it against the frozen reference `r` via the sidekick.
          { name = "abi-report-host-${name}";
            value = mkAbiReportHost system target ({ reference = r; } // sidekickArgs); }
        ]) hurdTargets));

      # GNU Mach kernel — built with the wrapped cross-cc (freestanding,
      # -nostdlib).  `toolchainFor` resolves each target (incl. the xen
      # variants) onto the right `toolchain-<arch>`.
      gnumach = import ./flakes/gnumach {
        inherit nixpkgs system targets self toolchainFor;
        mig = checkedMigFor;   # downstream of glibc → the validated mig
        srcInput = gnumach-src;
        forkUrl = gnumachInfo.forkUrl;
      };

      # The Hurd userland (core servers + libraries), built with the
      # wrapped toolchain + mig + the ABI-gated glibc-hurd sysroot.
      hurd = import ./flakes/hurd {
        inherit nixpkgs system targets self;
        mig = checkedMigFor;   # downstream of glibc → the validated mig
        glibcHurd = gatedGlibcHurd;
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
    // abiReportPkgs);

  apps = forAllSystems (system: import ./flakes/run {
    inherit nixpkgs system targets crossToolchain;
    packages = self.packages.${system};
  });
}
