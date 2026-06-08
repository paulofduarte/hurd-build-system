# glibc ABI gate — the run-once check that the WORKING glibc keeps the
# exported ABI gcc's prebuilt libgcc_s/libstdc++ (and all userland) bind
# to, relative to the REFERENCE glibc.  See TOOLCHAIN-LIBC-DECOUPLING.md
# (the gate's tiers/probes) and SIDEKICK-DISPATCHER.md (how the Linux-only
# analysers run).
#
# The DWARF-free probes (Tier-1 + cheap/Hurd Tier-3) run host-side with the cross
# binutils/gcc — uniform on every host.  The DWARF analysers (abidiff, pahole) are
# Linux-only in nixpkgs, so the gate dispatches them into the Debian **sidekick**
# VM: boot the sidekick once (warm `serve`), put transparent `abidiff`/`pahole`
# shims on PATH that ship the call into the VM (with /nix/store 9p-mounted so the
# glibc .so path args resolve verbatim), run the FULL probe suite, tear it down.
# So the full gate runs on EVERY host — no darwin skip, no nixpkgs libabigail/
# pahole dependency.
#
# Entry points (both take the sidekick image + dispatch scripts, threaded from
# packages.nix):
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

  # Env + inputs shared by both entry points.  No libabigail/pahole here (they
  # live in the sidekick); add qemu to boot it + the cross tools the host-side
  # probes use.  REF/WORK are the real glibcs (built dontStrip, so they carry the
  # DWARF abidiff/pahole need — no unstripped twins).
  mkGateEnv = system: target: { working, reference, sidekick, glibcSrc ? null }:
    let
      pkgs      = nixpkgs.legacyPackages.${system};
      crossPkgs = mkCrossPkgs system target;
      binu      = crossPkgs.buildPackages.binutils-unwrapped;
      cc        = crossPkgs.buildPackages.gccWithoutTargetLibc;
      tp        = target.crossTarget;
    in {
      inherit pkgs;
      # `cc` is reached by absolute path via CROSS_CC; a build input too.  The link
      # probes resolve the deployable /lib GROUP via sidekickRun's WORK_LINK
      # bare-name libc.so (members found on the -L path), not a --sysroot (which the
      # ld-wrapper strips under purity in a Linux sandbox).
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
        ABILIST         = "";
        ABIGNORE        = "${./abi-check/libc.abignore}";
        ABI_DIR         = "${./abi-check}";
        GLIBC_SRC       = if glibcSrc != null then "${glibcSrc}" else "";
        SIDEKICK_KERNEL = "${sidekick}/vmlinuz";
        SIDEKICK_INITRD = "${sidekick}/initramfs.cpio.gz";
      };
    };

  # Shell prelude/teardown that boots the warm sidekick, installs the abidiff/pahole
  # shims, runs the runner at $level, and stops the VM.  `dispatchLib`/`sendScript`
  # are the host-side sidekick scripts.
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
    # 9p mount).  SK_CTL is inherited from the env above.  Invoke sidekick-send
    # through `bash` explicitly (it is on PATH via nativeBuildInputs) rather than
    # letting its `#!/usr/bin/env bash` shebang resolve: a real (Linux) nix
    # sandbox provides only /bin/sh=busybox — no /usr/bin/env — so an exec of the
    # script direct would fail "not found" on the missing interpreter (darwin's
    # sandbox=false hides this, resolving env from the host FS).
    mkdir -p "$TMPDIR/bin"
    for t in abidiff pahole; do
      printf '#!/bin/sh\nexec bash %s %s "$@"\n' "$TMPDIR/sidekick-send" "$t" > "$TMPDIR/bin/$t"
      chmod +x "$TMPDIR/bin/$t"
    done
    export PATH="$TMPDIR/bin:$PATH"
    export PROBES_DIR="$ABI_DIR/probes" ABI_LEVEL="${level}"

    # Bare-name GROUP for the LINK probes (16/19).  The deployable working
    # glibc's libc.so GROUP lists /lib/... members ld resolves only via --sysroot
    # — which the nix ld-wrapper strips under purity, so the gate's cc-driven probe
    # link works on darwin but NOT in a Linux sandbox.  Materialize a probe-only
    # libc.so whose members are BARE NAMES (libc.so.0.3, libmachuser.so, …): ld
    # resolves them via the -L search path (-L"$WORK/lib"), so the link needs no
    # --sysroot and is --sysroot-indifferent — host-uniform, never doubled.  The
    # analysis probes (25 etc.) keep reading the real /lib-rooted $WORK/lib/libc.so.
    # Only libc.so is rewritten; the named members live in $WORK/lib already.
    export WORK_LINK="$TMPDIR/linkroot"
    mkdir -p "$WORK_LINK/lib"
    if [ -f "$WORK/lib/libc.so" ] && grep -q '^GROUP' "$WORK/lib/libc.so" 2>/dev/null; then
      sed 's@ /lib/@ @g' "$WORK/lib/libc.so" > "$WORK_LINK/lib/libc.so"
    fi

    if bash "$ABI_DIR/runner.sh" 2>&1 | tee "$TMPDIR/abi-report.txt"; then _abi_rc=0; else _abi_rc=''${PIPESTATUS[0]}; fi
    sk_serve_stop "$SK_CTL"
  '';
in
{
  inherit abiArchOf;

  # The in-build gate (provider.working).  Runs the FULL suite via sidekick on
  # every host; keyed on (working, reference) so it runs once per working-glibc
  # change and caches.  On pass, re-exports the real working glibc as a drop-in
  # sysroot (symlink farm).
  mkAbiChecked = system: target: { working, reference, sidekick, dispatchLib, sendScript, glibcSrc ? null }:
    let g = mkGateEnv system target { inherit working reference sidekick glibcSrc; };
    in g.pkgs.runCommand "glibc-hurd-${target.crossTarget}-abi-checked"
      ({ inherit (g) nativeBuildInputs; } // g.env)
      ''
        ${sidekickRun { inherit dispatchLib sendScript; level = "full"; }}
        [ "$_abi_rc" -eq 0 ] || { echo "ABI gate FAILED (rc=$_abi_rc)"; exit "$_abi_rc"; }
        # Gate passed — re-export the real working glibc as the gated sysroot the
        # wrapped toolchain links the userland against.  The deployable working
        # glibc's libc.so GROUP lists /lib/... members ld resolves only via
        # --sysroot — which the nix ld-wrapper strips under purity, so the
        # wrapped-cc userland link FAILS in a Linux sandbox (works on darwin only).
        # Fix (b-split, bare edition): materialize each GROUP script as a real file
        # in the farm with BARE-NAME members (libc.so.0.3, libmachuser.so, …); ld
        # resolves them via the wrapper's -L"$out/lib" search path, so the link
        # needs NO --sysroot — host-uniform and never doubled (a bare name has no
        # path to prepend a sysroot to).  This is the CROSS-LINK sysroot only: the
        # SHIPPED glibc (glibc-hurd-<arch> = the raw glibcHurd) keeps its absolute
        # /lib GROUP (standard, link-time-secure native form), and userland binaries
        # record NEEDED sonames (libc.so.0.3 …), not these GROUP paths — so neither
        # the bare names nor any store path reach a shipped artifact.
        mkdir -p "$out"
        cp -as "${working}"/. "$out"/
        chmod u+w "$out/lib"   # cp -as cloned the source's read-only store perms
        for so in "$out"/lib/*.so; do
          [ -L "$so" ] && grep -q '^GROUP' "$so" 2>/dev/null || continue
          tgt="$(readlink -f "$so")"; rm -f "$so"
          sed 's@ /lib/@ @g' "$tgt" > "$so"; chmod u+w "$so"
        done
      '';

  # The explicit deep/full report (`make check-glibc[-full]`).  Same sidekick
  # dispatch; emits the report at $out, fails on a probe fail.
  mkAbiReport = system: target: { working, reference, sidekick, dispatchLib, sendScript, level ? "full", glibcSrc ? null }:
    let g = mkGateEnv system target { inherit working reference sidekick glibcSrc; };
    in g.pkgs.runCommand "glibc-hurd-${target.crossTarget}-abi-report-${level}"
      ({ inherit (g) nativeBuildInputs; } // g.env)
      ''
        ${sidekickRun { inherit dispatchLib sendScript level; }}
        mkdir -p "$out"; cp "$TMPDIR/abi-report.txt" "$out/abi-report-${level}.txt"
        [ "$_abi_rc" -eq 0 ] || { echo "ABI report FAILED (rc=$_abi_rc)"; exit "$_abi_rc"; }
      '';

  # The HOST-SIDE report — `make check-glibc[-full]` for the IN-TREE glibc.  Same
  # sidekick dispatch + probes as mkAbiReport, but WORK is a RUNTIME arg (the
  # in-tree build sysroot, a host path NOT in the nix store); the reference + all
  # tooling are baked.  Lets a hacker compare their in-tree glibc against the
  # frozen reference without a nix rebuild.  A plain writeShellScriptBin that
  # prepends its runtime deps to PATH and runs the same orchestration host-side.
  # The link probes resolve the in-tree /lib GROUP via sidekickRun's WORK_LINK
  # (bare-name members on the -L path), so no --sysroot needed (stripped under
  # purity).
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
      export ABILIST="" ABIGNORE="${./abi-check/libc.abignore}" ABI_DIR="${./abi-check}"
      export SIDEKICK_KERNEL="${sidekick}/vmlinuz" SIDEKICK_INITRD="${sidekick}/initramfs.cpio.gz"
      ${sidekickRun { inherit dispatchLib sendScript; level = "$ABI_LEVEL"; }}
      exit "$_abi_rc"
    '';
}
