# glibc ABI gate — the run-once check that the WORKING glibc keeps the
# exported ABI gcc's prebuilt libgcc_s/libstdc++ (and all userland) bind
# to, relative to the REFERENCE glibc.  See TOOLCHAIN-LIBC-DECOUPLING.md
# ("ABI gate") for the why and the tier/probe catalogue.
#
# Two entry points:
#
#   mkAbiChecked system target { working, reference }
#     The automatic gate, wired into provider.working in packages.nix.
#     Runs the DWARF-free `auto` probe set (Tier-1 + cheap/Hurd Tier-3,
#     probes 00 + 10-19) against the STRIPPED working+reference glibc,
#     and on success re-exports `working` as a drop-in sysroot (a symlink
#     farm, so $out/lib, $out/include, crt and the libc.so GROUP script
#     all resolve).  Keyed on (working, reference) — nix builds it once
#     and caches it; it re-runs only when the working glibc changes.
#     Every consumer (wrapped cc libc, userland) takes the gated output,
#     so the gate is enforced on every build whose working ≠ reference.
#
#   mkAbiReport system target { working, reference, level }
#     The explicit deep check behind `make check-glibc` (level "deep":
#     adds Tier-2 abidiff + check-installed-headers) and
#     `make check-glibc-full` (level "full": adds the heavy Tier-3
#     probes 20-24).  Tier-2 needs DWARF, so it rebuilds unstripped
#     ref+working variants on demand (overrideAttrs dontStrip) purely for
#     the compare — the toolchain's own glibc stays stripped.  Produces a
#     report at $out; does NOT re-export a sysroot (it's a check, not a
#     build input).

{ nixpkgs, mkHurdCrossPkgs }:

let
  lib = nixpkgs.lib;

  # glibc's abilist lives under sysdeps/mach/hurd/<abiArch>/ — i386 for
  # the 32-bit x86 Hurd, x86_64 for the 64-bit one.  Maps the CPU half of
  # the migTarget (i686-gnu → i386, x86_64-gnu → x86_64).
  abiArchOf = target:
    let cpu = lib.head (lib.splitString "-" target.migTarget);
    in if cpu == "i686" || cpu == "i386" then "i386" else cpu;

  # Shared environment + probe payload for a runner invocation.
  # `extraInputs` adds level-specific deps (libabigail/pahole/acc for
  # deep/full); `glibcSrc` (deep/full only) lets probes reach glibc's own
  # conform/ data.  The auto gate passes neither, staying lean.
  mkGateEnv = system: target: { working, reference, extraInputs ? [ ], glibcSrc ? null }:
    let
      pkgs      = nixpkgs.legacyPackages.${system};
      crossPkgs = mkHurdCrossPkgs system target;
      binu      = crossPkgs.buildPackages.binutils-unwrapped;
      cc        = crossPkgs.buildPackages.gccWithoutTargetLibc;
      tp        = target.migTarget;
    in {
      inherit pkgs;
      nativeBuildInputs = [ pkgs.bash pkgs.gawk pkgs.gnused pkgs.gnugrep pkgs.diffutils pkgs.coreutils ] ++ extraInputs;
      env = {
        REF           = reference;
        WORK          = working;
        TP            = tp;
        ARCH          = abiArchOf target;
        CROSS_CC      = "${cc}/bin/${tp}-gcc";
        CROSS_OBJDUMP = "${binu}/bin/${tp}-objdump";
        CROSS_READELF = "${binu}/bin/${tp}-readelf";
        CROSS_NM      = "${binu}/bin/${tp}-nm";
        # abilist cross-check is review-only; left empty so the gate stays
        # self-contained (no glibc source in its closure).  Tier-2's deep
        # path has full DWARF info anyway.
        ABILIST       = "";
        ABIGNORE      = "${./abi-check/libc.abignore}";
        ABI_DIR       = "${./abi-check}";
        GLIBC_SRC     = if glibcSrc != null then "${glibcSrc}" else "";
      };
    };

  runProbes = ''
    export PROBES_DIR="$ABI_DIR/probes"
    bash "$ABI_DIR/runner.sh"
  '';
in
{
  inherit abiArchOf;

  # The in-build gate — wired into provider.working, so every toolchain /
  # userland nix build flows through it.  Runs the FULL probe suite: a nix
  # toolchain build is a release and is validated in full, not just the
  # DWARF-free subset.  Keyed on (working, reference), so it runs once per
  # working-glibc change and caches — the cost lands exactly when the ABI
  # could have moved (hacking glibc/headers/mig), never on an unrelated
  # rebuild.
  #
  # The DWARF probes (Tier-2 abidiff, pahole 20/24) need debug info + the
  # Linux-only tools (libabigail/pahole/acc).  Where they're available —
  # every `*-linux` host today, every host once the sidekick shim lands —
  # the gate compares throwaway UNSTRIPPED variants and pulls the tools in;
  # elsewhere (darwin, pre-sidekick) it runs the DWARF-free probes against
  # the stripped glibc and the DWARF ones SKIP.  Either way it re-exports
  # the real STRIPPED working glibc, so the shipped sysroot never carries
  # debug info.
  mkAbiChecked = system: target: { working, reference, glibcSrc ? null }:
    let
      pkgs       = nixpkgs.legacyPackages.${system};
      dwarf      = lib.hasSuffix "-linux" system;   # tools+DWARF available here
      unstripped = drv: drv.overrideAttrs (_: { dontStrip = true; separateDebugInfo = false; });
      g = mkGateEnv system target {
        working     = if dwarf then unstripped working   else working;
        reference   = if dwarf then unstripped reference else reference;
        inherit glibcSrc;
        extraInputs = lib.optionals dwarf
          (with pkgs; [ libabigail pahole abi-compliance-checker abi-dumper ]);
      };
    in g.pkgs.runCommand "glibc-hurd-${target.migTarget}-abi-checked"
      ({ inherit (g) nativeBuildInputs; ABI_LEVEL = "full"; } // g.env)
      ''
        ${runProbes}

        # Gate passed — re-export the real (stripped) working glibc as a
        # drop-in sysroot.  The unstripped variants above (when built) are
        # throwaway, used only for the DWARF probes' comparison.  cp -as =
        # symlink farm: $out mirrors working's tree with symlinks, so lib/
        # (incl. the libc.so GROUP script's absolute refs into the working
        # store path), include/, crt objects all resolve, at near zero
        # closure cost.
        mkdir -p "$out"
        cp -as "${working}"/. "$out"/
      '';

  # The explicit deep/full report: build unstripped variants for Tier-2,
  # run the requested set, emit a report.  Not a sysroot.  `glibcSrc` is
  # the working glibc source (for the conform probe's data).
  mkAbiReport = system: target: { working, reference, level ? "deep", glibcSrc ? null }:
    let
      unstripped = drv: drv.overrideAttrs (_: { dontStrip = true; separateDebugInfo = false; });
      g = mkGateEnv system target {
        working    = unstripped working;
        reference  = unstripped reference;
        inherit glibcSrc;
        extraInputs =
          [ nixpkgs.legacyPackages.${system}.libabigail ]
          ++ lib.optionals (level == "full")
             (with nixpkgs.legacyPackages.${system}; [ pahole abi-compliance-checker abi-dumper ]);
      };
    in g.pkgs.runCommand "glibc-hurd-${target.migTarget}-abi-report-${level}"
      ({ inherit (g) nativeBuildInputs; ABI_LEVEL = level; } // g.env)
      ''
        mkdir -p "$out"
        # Tee the runner so the report is captured even on a pass; with
        # pipefail the pipeline's status is the runner's, so the
        # derivation still fails when a probe fails.
        set -o pipefail
        export PROBES_DIR="$ABI_DIR/probes"
        bash "$ABI_DIR/runner.sh" 2>&1 | tee "$out/abi-report-${level}.txt"
      '';
}
