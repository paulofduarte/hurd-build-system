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

{ nixpkgs, mkCrossPkgs }:

let
  lib = nixpkgs.lib;

  abiArchOf = target:
    let cpu = lib.head (lib.splitString "-" target.crossTarget);
    in if cpu == "i686" || cpu == "i386" then "i386" else cpu;

  # Env + inputs shared by both entry points.  No libabigail/pahole here —
  # they live in the sidekick; we add qemu to boot it + the cross tools the
  # host-side probes use.  REF/WORK are the real glibcs (built dontStrip, so
  # they carry the DWARF abidiff/pahole need — no throwaway unstripped twins).
  mkGateEnv = system: target: { working, reference, sidekick, glibcSrc ? null }:
    let
      pkgs      = nixpkgs.legacyPackages.${system};
      crossPkgs = mkCrossPkgs system target;
      binu      = crossPkgs.buildPackages.binutils-unwrapped;
      cc        = crossPkgs.buildPackages.gccWithoutTargetLibc;
      tp        = target.crossTarget;
    in {
      inherit pkgs;
      # `cc` (the cross cc-wrapper) is in nativeBuildInputs — not just referenced
      # by path via CROSS_CC — so its setup hook runs and activates the salted
      # wrapper env (role/suffixSalt).  Without the hook, the NIX_LDFLAGS_BEFORE_
      # <salt> we set below for the deployable-glibc --sysroot is NOT honored by
      # the ld-wrapper (the probe links can't resolve the /lib GROUP in-sandbox).
      nativeBuildInputs = (with pkgs; [ bash gawk gnused gnugrep diffutils coreutils qemu ]) ++ [ cc ];
      env = {
        REF             = reference;
        WORK            = working;
        TP              = tp;
        ARCH            = abiArchOf target;
        CROSS_CC        = "${cc}/bin/${tp}-gcc";
        CROSS_OBJDUMP   = "${binu}/bin/${tp}-objdump";
        CROSS_READELF   = "${binu}/bin/${tp}-readelf";
        CROSS_NM        = "${binu}/bin/${tp}-nm";
        # The deployable working glibc has a /lib-rooted libc.so GROUP, so probes
        # that link `-lc` (16, 19) need --sysroot for ld to resolve /lib/... under
        # $WORK.  A command-line --sysroot is STRIPPED by the ld-wrapper under
        # NIX_ENFORCE_PURITY (the gate links in a sandbox); injecting via the
        # SALTED NIX_LDFLAGS_BEFORE survives — the ld-wrapper applies it after its
        # strip loop, and only filterRpathFlags (rpath-only) touches it.  Salt =
        # the cc/bintools wrapper's suffixSalt (e.g. x86_64_gnu).  Harmless on a
        # $out-prefix reference glibc (absolute GROUP needs no sysroot).
        "NIX_LDFLAGS_BEFORE_${cc.suffixSalt}" = "--sysroot=${working}";
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
    # Tear the sidekick VM down on ANY exit — pass, probe fail, or an error
    # that trips the builder's `set -e` mid-run.  Without this, a non-clean
    # exit skips the explicit sk_serve_stop below and the builder blocks
    # until the VM's keepalive timer fires (the ~1-min idle hang before a
    # gate failure surfaces); the trap makes teardown immediate and
    # unconditional.  sk_serve_stop is idempotent (kill … || true), so the
    # explicit call below is harmless.  Registered AFTER the dispatch lib is
    # sourced so sk_serve_stop is defined; guarded so it no-ops before the
    # VM starts.
    _sk_started=0
    trap '[ "$_sk_started" = 1 ] && sk_serve_stop "$SK_CTL" || true' EXIT
    # Keepalive is only a backstop: the build owns the VM's lifetime and stops
    # it via the EXIT trap above (and the explicit call below) the instant the
    # runner returns.  60s comfortably covers the gap between dispatched
    # abidiff/pahole calls while host-side probes run; if the build itself
    # wedged for a full minute with no dispatch, letting the idle VM self-stop
    # is the right backstop.  (Each sk_send raises it per the highest request,
    # but the gate never needs more than the default.)
    sk_serve_start "$SK_CTL" 60 || { echo "ABI gate: sidekick serve VM failed to start" >&2; exit 1; }
    _sk_started=1

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
    in g.pkgs.runCommand "glibc-hurd-${target.crossTarget}-abi-checked"
      ({ inherit (g) nativeBuildInputs; } // g.env)
      ''
        ${sidekickRun { inherit dispatchLib sendScript; level = "full"; }}
        [ "$_abi_rc" -eq 0 ] || { echo "ABI gate FAILED (rc=$_abi_rc)"; exit "$_abi_rc"; }
        # Gate passed — re-export the real working glibc as the gated sysroot.
        mkdir -p "$out"
        cp -as "${working}"/. "$out"/
        # The toolchain --sysroots into this farm.  GNU ld only sysroot-prefixes
        # a libc.so GROUP's absolute members (/lib/libc.so.0.3, /lib/libhurduser.so…)
        # when the GROUP *script itself* resolves to a path INSIDE the sysroot.
        # cp -as leaves lib/libc.so a symlink to the raw glibc (outside this
        # farm), so ld sees the script outside, declines to prefix, and the
        # deployable /lib members go unresolved.  Materialize the GROUP scripts
        # as real files in the farm (members stay symlinks — ld follows them on
        # open); a few hundred bytes each, far cheaper than dereferencing the farm.
        chmod u+w "$out/lib"   # cp -as cloned the source's read-only store perms
        for so in "$out"/lib/*.so; do
          [ -L "$so" ] && grep -q '^GROUP' "$so" 2>/dev/null || continue
          tgt="$(readlink -f "$so")"; rm -f "$so"; cp "$tgt" "$so"; chmod u+w "$so"
        done
      '';

  # The explicit deep/full report (`make check-glibc[-full]`).  Same sidekick
  # dispatch; emits the report at $out, fails the derivation on a probe fail.
  mkAbiReport = system: target: { working, reference, sidekick, dispatchLib, sendScript, level ? "full", glibcSrc ? null }:
    let g = mkGateEnv system target { inherit working reference sidekick glibcSrc; };
    in g.pkgs.runCommand "glibc-hurd-${target.crossTarget}-abi-report-${level}"
      ({ inherit (g) nativeBuildInputs; } // g.env)
      ''
        ${sidekickRun { inherit dispatchLib sendScript level; }}
        mkdir -p "$out"; cp "$TMPDIR/abi-report.txt" "$out/abi-report-${level}.txt"
        [ "$_abi_rc" -eq 0 ] || { echo "ABI report FAILED (rc=$_abi_rc)"; exit "$_abi_rc"; }
      '';

  # The HOST-SIDE report — `make check-glibc[-full]` for the IN-TREE glibc.
  # Same sidekick dispatch + probes as mkAbiReport, but WORK is a RUNTIME arg
  # (the in-tree build sysroot, e.g. work/sysroot/<arch> — a host path NOT in the
  # nix store) instead of a baked store path; the reference + all tooling are
  # baked.  Lets a hacker compare their in-tree glibc against the frozen
  # reference without a nix rebuild.  Built as a plain script (writeShellScriptBin
  # — no shellcheck/wrapper) that prepends its runtime deps to PATH and runs the
  # same orchestration host-side.  The salted NIX_LDFLAGS_BEFORE --sysroot=$WORK
  # lets the link probes resolve the in-tree /lib GROUP (cc is on PATH so its
  # wrapper honours the salt).
  mkAbiReportHost = system: target: { reference, sidekick, dispatchLib, sendScript }:
    let
      pkgs      = nixpkgs.legacyPackages.${system};
      crossPkgs = mkCrossPkgs system target;
      binu      = crossPkgs.buildPackages.binutils-unwrapped;
      cc        = crossPkgs.buildPackages.gccWithoutTargetLibc;
      tp        = target.crossTarget;
    in pkgs.writeShellScriptBin "abi-report-host-${tp}" ''
      # pipefail is load-bearing: sidekickRun's `runner.sh | tee` captures the
      # runner's exit via the `if`, which without pipefail sees only tee's 0 and
      # masks a probe FAIL (the nix gates get pipefail from the stdenv builder;
      # this standalone script must set it itself).
      set -uo pipefail
      WORK_SRC="''${1:?usage: abi-report-host-${tp} <in-tree-sysroot-dir> [deep|full]}"
      ABI_LEVEL="''${2:-deep}"
      [ -e "$WORK_SRC/lib/libc.so.0.3" ] || { echo "abi-report-host: $WORK_SRC/lib/libc.so.0.3 not found — run 'make work-glibc' first" >&2; exit 1; }
      export PATH="${lib.makeBinPath (with pkgs; [ bash gawk gnused gnugrep diffutils coreutils qemu cc binu ])}:$PATH"
      # Own scratch dir — the inherited TMPDIR may be a sandbox dir we can't write.
      TMPDIR="$(mktemp -d /tmp/abi-report-host.XXXXXX)"; export TMPDIR
      trap 'rm -rf "$TMPDIR"' EXIT
      # Stage the in-tree sysroot into /nix/store so the sidekick VM — which only
      # 9p-mounts /nix/store — can read it for the abidiff/pahole probes that run
      # INSIDE the VM (a host path outside /nix/store is invisible there).  This
      # copies the exact in-tree bytes (NOT a rebuild) into the store.
      WORK="$(nix-store --add "$WORK_SRC")"
      export REF="${reference}" WORK ABI_LEVEL TP="${tp}" ARCH="${abiArchOf target}"
      export CROSS_CC="${cc}/bin/${tp}-gcc" CROSS_OBJDUMP="${binu}/bin/${tp}-objdump"
      export CROSS_READELF="${binu}/bin/${tp}-readelf" CROSS_NM="${binu}/bin/${tp}-nm"
      export "NIX_LDFLAGS_BEFORE_${cc.suffixSalt}"="--sysroot=$WORK"
      export ABILIST="" ABIGNORE="${./abi-check/libc.abignore}" ABI_DIR="${./abi-check}"
      export SIDEKICK_KERNEL="${sidekick}/vmlinuz" SIDEKICK_INITRD="${sidekick}/initramfs.cpio.gz"
      ${sidekickRun { inherit dispatchLib sendScript; level = "$ABI_LEVEL"; }}
      exit "$_abi_rc"
    '';
}
