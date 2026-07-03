# SPDX-FileCopyrightText: 2026 Paulo Duarte <paulofernandobd@gmail.com>
# SPDX-License-Identifier: GPL-3.0-or-later
# hurd's libirqhelp, built standalone - per-userland-target (rump-stack dep).
#
# Why it exists (RUMP-STACK-FEASIBILITY round-2): rumpkernel's
# pci-userspace/src-gnu calls irqhelp_init/irqhelp_install_interrupt_handler
# and libacpica links -lirqhelp, but libirqhelp lives INSIDE the hurd tree -
# a circular dep once hurd itself links the rump libs.  Guix breaks the cycle
# with a lib-only hurd pre-pass; this is that pre-pass: configure the hurd
# tree with the usual cross env, then build + install ONLY libirqhelp/
# (HURDLIBS is empty - it needs just pthread + a MIG-generated acpi user stub,
# so no other hurd lib has to exist).
#
# Builds from `hurd-src` (the WORK pin), like the full hurd build and every
# other hurd-derived component: only the glibc -> cross-gcc chain rides the
# frozen toolchain pins - everything else tracks the work pins so in-tree
# kernel/userland hacking flows through (an irqhelp change must reach
# rumpkernel/libacpica, not be masked by a stale frozen twin).  The cost is
# that a hurd pin bump re-derives this lib and hence its consumers (incl. the
# large rumpkernel build) - accepted; hackability wins.
#
# Output (usr-merged, deployable): $out/usr/lib/libirqhelp.{a,so*,_pic.a} +
# $out/usr/include/hurd/irqhelp.h.

{
  nixpkgs,
  system,
  targets,
  mig,
  toolchainFor,
  self,
  srcInput,
  forkUrl,
  buildRevToken ? null,
}:

let
  pkgs = nixpkgs.legacyPackages.${system};
  inherit (nixpkgs) lib;
  helpers = import ../lib { inherit lib; };
  hurdConfig = import ../cross-toolchain/hurd-config.nix;
  buildFlags = import ../cross-toolchain/build-flags.nix { inherit lib; };

  # Same version composition as flakes/hurd (work-pin side, +build.g<rev>).
  upstreamVersion = helpers.parseAcInitVersion (srcInput + "/configure.ac");
  fullVersion = helpers.composeVersion {
    inherit
      upstreamVersion
      srcInput
      self
      forkUrl
      buildRevToken
      ;
  };

  userlandTargets = lib.filterAttrs (_: t: (t.platform or null) != "xen") targets;

  mkOne =
    name: target:
    let
      tp = target.crossTarget; # e.g. i686-gnu
      tc = toolchainFor target;
      inherit (tc) cc;
      binu = tc.binutils;
      crossMig = mig."mig-${name}";
      pname = "libirqhelp-${tp}";
    in
    pkgs.stdenv.mkDerivation {
      inherit pname;
      version = fullVersion;
      src = srcInput;

      # Same build env as flakes/hurd (autoreconf + the cross cc/binutils/mig);
      # patchelf for darwin's audit-tmpdir fixup on the shared lib.
      nativeBuildInputs = [
        pkgs.autoreconfHook
      ]
      ++ (with pkgs; [
        texinfo
        perl
        patchelf
      ])
      ++ [
        cc
        binu
        crossMig
      ];

      postPatch = ''
        sed -i.bak \
          -e 's|^AC_INIT(\[GNU Hurd\], \[[^]]*\],|AC_INIT([GNU Hurd], [${fullVersion}],|' \
          configure.ac
        rm configure.ac.bak
        grep "^AC_INIT" configure.ac
      '';

      # Verbatim from flakes/hurd: pin the cross tools past autoreconfHook's
      # host-gcc setup hook, CFLAGS via configureFlagsArray (embedded space),
      # determinism maps via CPPFLAGS (raw cross-gcc has no wrapper channel).
      preConfigure = ''
        export PKG_CONFIG_PATH=
        export CC=${tp}-gcc
        export MIG=${tp}-mig
        export USER_MIG=${tp}-mig
        configureFlagsArray+=("CFLAGS=${buildFlags.hurdExtraCflags} ${buildFlags.baseCflags}")
        ${helpers.crossPkg.outOfTreePreConfigure}
        ${buildFlags.detCppflagsUnwrapped {
          gcc = cc;
          binutils = binu;
          canonBuild = buildFlags.hurdCanonBuild;
          inherit (tc) sysroot;
        }}
      '';

      # Same cross archiver pinning as flakes/hurd (Makeconf's archive rule
      # reads $(AR)/$(RANLIB) from make's built-ins otherwise).
      makeFlags = [
        "AR=${tp}-ar"
        "RANLIB=${tp}-ranlib"
        "NM=${tp}-nm"
      ];

      # Same flag set as the full hurd build so config.make comes out
      # identical - libirqhelp must compile exactly as it does inside hurd.
      configureFlags = [
        "--host=${tp}"
      ]
      ++ hurdConfig.deployFlags
      ++ hurdConfig.coreFlags;
      dontAddPrefix = true;

      # ONLY libirqhelp: HURDLIBS is empty, so nothing else in the tree has to
      # build first (MIG generates the acpi user stub in-place).
      buildPhase = ''
        runHook preBuild
        make -C libirqhelp -j''${NIX_BUILD_CORES:-1} $makeFlags
        runHook postBuild
      '';

      installPhase = ''
        runHook preInstall
        make -C libirqhelp install DESTDIR=$out $makeFlags
        runHook postInstall
      '';

      # Same output-hygiene set as flakes/hurd.
      dontPatchELF = true;
      dontStrip = true;
      dontPatchShebangs = true;

      passthru = { inherit target; };
      meta = with lib; {
        description = "hurd libirqhelp for ${tp} (rumpkernel/libacpica dep)";
        platforms = platforms.all;
        license = licenses.gpl2Plus;
      };
    };
in
lib.mapAttrs' (
  name: target: lib.nameValuePair "libirqhelp-${name}" (mkOne name target)
) userlandTargets
