# glibc ABI gate — the run-once check that the WORKING glibc keeps the
# exported ABI gcc's prebuilt libgcc_s/libstdc++ (and all userland) bind
# to, relative to the REFERENCE glibc.  See TOOLCHAIN-LIBC-DECOUPLING.md
# (the gate's tiers/probes) and SIDEKICK-DISPATCHER.md (how the Linux-only
# analysers run).
#
# The DWARF-free probes (Tier-1 + cheap/Hurd Tier-3) run host-side with the
# cross binutils/gcc — uniform on every host.  The DWARF analysers
# (abidiff, pahole) are Linux-only in nixpkgs, so instead of depending on
# them there we dispatch them into the Debian **sidekick** VM: the gate
# boots the sidekick once (warm `serve`), puts transparent `abidiff`/`pahole`
# shims on PATH that ship the call into the VM (with /nix/store 9p-mounted
# so the glibc .so path args resolve verbatim), runs the FULL probe suite,
# and tears the VM down.  So the full gate runs on EVERY host — no darwin
# skip, no nixpkgs libabigail/pahole dependency.
#
# Entry points (both take the sidekick image + dispatch scripts, threaded
# from packages.nix):
#   mkAbiChecked … { working, reference, … }   the in-build gate wired into
#     provider.working; on pass re-exports the real working glibc (the gated sysroot).
#   mkAbiReport  … { working, reference, level } the explicit `make
#     check-glibc[-full]` report; same dispatch, emits a report at $out.

{ nixpkgs, mkHurdCrossPkgs }:

let
  lib = nixpkgs.lib;

  abiArchOf = target:
    let cpu = lib.head (lib.splitString "-" target.migTarget);
    in if cpu == "i686" || cpu == "i386" then "i386" else cpu;

  # Env + inputs shared by both entry points.  No libabigail/pahole here —
  # they live in the sidekick; we add qemu to boot it + the cross tools the
  # host-side probes use.  REF/WORK are the real glibcs (built dontStrip, so
  # they carry the DWARF abidiff/pahole need — no throwaway unstripped twins).
  mkGateEnv = system: target: { working, reference, sidekick, glibcSrc ? null }:
    let
      pkgs      = nixpkgs.legacyPackages.${system};
      crossPkgs = mkHurdCrossPkgs system target;
      binu      = crossPkgs.buildPackages.binutils-unwrapped;
      cc        = crossPkgs.buildPackages.gccWithoutTargetLibc;
      tp        = target.migTarget;
    in {
      inherit pkgs;
      nativeBuildInputs = with pkgs; [ bash gawk gnused gnugrep diffutils coreutils qemu ];
      env = {
        REF             = reference;
        WORK            = working;
        TP              = tp;
        ARCH            = abiArchOf target;
        CROSS_CC        = "${cc}/bin/${tp}-gcc";
        CROSS_OBJDUMP   = "${binu}/bin/${tp}-objdump";
        CROSS_READELF   = "${binu}/bin/${tp}-readelf";
        CROSS_NM        = "${binu}/bin/${tp}-nm";
        ABILIST         = "";
        ABIGNORE        = "${./abi-check/libc.abignore}";
        ABI_DIR         = "${./abi-check}";
        GLIBC_SRC       = if glibcSrc != null then "${glibcSrc}" else "";
        SIDEKICK_KERNEL = "${sidekick}/vmlinuz";
        SIDEKICK_INITRD = "${sidekick}/initramfs.cpio.gz";
      };
    };

  # Shell prelude/teardown that boots the warm sidekick, installs the
  # abidiff/pahole shims, runs the runner at $level, and stops the VM.
  # `dispatchLib`/`sendScript` are the host-side sidekick scripts.
  sidekickRun = { dispatchLib, sendScript, level }: ''
    export SK_CTL="$TMPDIR/sk"; mkdir -p "$SK_CTL/q"
    cp ${sendScript} "$TMPDIR/sidekick-send"; chmod +x "$TMPDIR/sidekick-send"
    . ${dispatchLib}
    # Generous keepalive: the build owns the VM's lifetime (we stop it
    # explicitly below); the timer is just a backstop against a hung build.
    sk_serve_start "$SK_CTL" 3600 || { echo "ABI gate: sidekick serve VM failed to start" >&2; exit 1; }

    # Transparent shims: the probes call `abidiff`/`pahole` normally; these
    # ship the call into the VM (store-path args resolve via its /nix/store
    # 9p mount).  SK_CTL is inherited from the env above.
    mkdir -p "$TMPDIR/bin"
    for t in abidiff pahole; do
      printf '#!/bin/sh\nexec %s %s "$@"\n' "$TMPDIR/sidekick-send" "$t" > "$TMPDIR/bin/$t"
      chmod +x "$TMPDIR/bin/$t"
    done
    export PATH="$TMPDIR/bin:$PATH"
    export PROBES_DIR="$ABI_DIR/probes" ABI_LEVEL="${level}"

    if bash "$ABI_DIR/runner.sh" 2>&1 | tee "$TMPDIR/abi-report.txt"; then _abi_rc=0; else _abi_rc=''${PIPESTATUS[0]}; fi
    sk_serve_stop "$SK_CTL"
  '';
in
{
  inherit abiArchOf;

  # The in-build gate (provider.working).  Runs the FULL suite via sidekick
  # on every host; keyed on (working, reference) so it runs once per
  # working-glibc change and caches.  On pass, re-exports the real
  # working glibc as a drop-in sysroot (symlink farm).
  mkAbiChecked = system: target: { working, reference, sidekick, dispatchLib, sendScript, glibcSrc ? null }:
    let g = mkGateEnv system target { inherit working reference sidekick glibcSrc; };
    in g.pkgs.runCommand "glibc-hurd-${target.migTarget}-abi-checked"
      ({ inherit (g) nativeBuildInputs; } // g.env)
      ''
        ${sidekickRun { inherit dispatchLib sendScript; level = "full"; }}
        [ "$_abi_rc" -eq 0 ] || { echo "ABI gate FAILED (rc=$_abi_rc)"; exit "$_abi_rc"; }
        # Gate passed — re-export the real working glibc as the gated sysroot.
        mkdir -p "$out"
        cp -as "${working}"/. "$out"/
      '';

  # The explicit deep/full report (`make check-glibc[-full]`).  Same sidekick
  # dispatch; emits the report at $out, fails the derivation on a probe fail.
  mkAbiReport = system: target: { working, reference, sidekick, dispatchLib, sendScript, level ? "full", glibcSrc ? null }:
    let g = mkGateEnv system target { inherit working reference sidekick glibcSrc; };
    in g.pkgs.runCommand "glibc-hurd-${target.migTarget}-abi-report-${level}"
      ({ inherit (g) nativeBuildInputs; } // g.env)
      ''
        ${sidekickRun { inherit dispatchLib sendScript level; }}
        mkdir -p "$out"; cp "$TMPDIR/abi-report.txt" "$out/abi-report-${level}.txt"
        [ "$_abi_rc" -eq 0 ] || { echo "ABI report FAILED (rc=$_abi_rc)"; exit "$_abi_rc"; }
      '';
}
