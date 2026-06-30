# SPDX-FileCopyrightText: 2026 Paulo Duarte <paulofernandobd@gmail.com>
# SPDX-License-Identifier: GPL-3.0-or-later
# `nix run` apps - one per cross-arch.
#
# Returned API: an attrset suitable for `flake.apps.<system>`:
#
#   default       -> boot scenario for the host's best-matching cross
#                    arch (via crossToolchain.defaultTargetName)
#   aarch64       -> boot scenario for aarch64
#   i686          -> boot scenario for i686
#   x86_64        -> boot scenario for x86_64
#
# Each app is a wrapper that parses scenario + flags, sets the env the
# harness expects, and exec's ./dispatch.sh (sibling file).  Same dispatch
# code path that `make run` uses - same scenario scripts, same behaviour
# - just the kernel comes from the nix-built `gnumach-<arch>` package
# instead of the in-tree work/ build.
#
# Cache for distro images: `<project>/work/` - the same location `make run` uses,
# on both OSes (falls back to `$XDG_CACHE_HOME/hurd-build-system/` only for a
# remote-flake run outside any repo).  Split per build-host/variant via RUN_VARIANT
# when MULTI_HOST_BUILDS / ALT_BUILD are set (mirrors the Makefile's _VARIANT),
# overridable via $WORK.
#
# Args passed by the user (everything after `nix run .#<arch>`) are
# interpreted by ./app.sh:
#
#   <scenario>          one positional, default "boot"
#   --vanilla           distro's bundled kernel (hurd-* only)
#   --accel             -accel hvf/kvm
#   --keep-overlay[=N]  keep + reuse overlay slot N (default 1) across runs
#   --refresh           wipe the scenario's cached distro image
#   --help, -h          usage
#   -- ARGS             everything after `--` passes through to qemu

{
  nixpkgs,
  system,
  targets,
  packages,
  crossToolchain,
}:

let
  pkgs = nixpkgs.legacyPackages.${system};
  inherit (nixpkgs) lib;

  # The sidekick ISO tools (sidekick-imgcp / sidekick-mkrescue) on the app's PATH:
  # native on Linux (+ the fuse qemu-storage-daemon, sfdisk, debugfs/grub/xorriso/
  # mtools they need), sidekick-run shims on darwin.  Same logic as the dev shell.
  sidekickIsoTools =
    if lib.hasSuffix "-darwin" system then
      [ packages.sidekick-run ]
      ++
        map (t: pkgs.writeShellScriptBin t ''exec ${packages.sidekick-run}/bin/sidekick-run ${t} "$@"'')
          [
            "sidekick-imgcp"
            "sidekick-mkrescue"
          ]
    else
      (
        let
          st = import ../sidekick/tools.nix {
            inherit pkgs;
            i386Grub = nixpkgs.legacyPackages.x86_64-linux.grub2;
          };
        in
        [
          st.sidekick-imgcp
          st.sidekick-mkrescue
          (import ../lib/qemu-storage-daemon.nix pkgs)
        ]
        ++ (with pkgs; [
          grub2
          xorriso
          mtools
          e2fsprogs
          # sfdisk only (avoid util-linux's non-setuid mount shadowing the host's)
          (runCommand "sidekick-sfdisk" { } ''
            mkdir -p $out/bin
            ln -s ${util-linux}/bin/sfdisk $out/bin/sfdisk
          '')
        ])
      );
  # Which arches we expose as `nix run` targets - the non-xen userland targets
  # that have a bootable `gnumach-<arch>`.  Xen variants don't boot under qemu
  # (gnumach disables tests + the boot harness on them); aarch64-gnu isn't a
  # target yet (no upstream Hurd port) - an aarch64 host runs the x86_64 image
  # under TCG via the defaultArch fallback below.
  archs = [
    "i686"
    "x86_64"
  ];

  mkApp =
    arch:
    let
      gnumach = packages."gnumach-${arch}";

      runScript = pkgs.writeShellApplication {
        name = "hurd-run-${arch}";
        runtimeInputs =
          (with pkgs; [
            qemu # qemu-system-* + qemu-img (stock; from cache.nixos.org)
            curl # distro image fetch
            coreutils # mkdir / mv / cp / sha512sum
            gnused
            gnugrep
            gawk
            gnutar
            gzip
          ])
          ++ sidekickIsoTools; # sidekick-imgcp / sidekick-mkrescue (native | shim)
        # Tiny nix-interpolated prelude - sets the env vars + paths
        # ./app.sh references; the body itself stays pure shell.
        text = ''
          export ARCH=${arch}
          export GNUMACH_KERNEL=${gnumach}/boot/gnumach
          DISTRO_URLS_FILE=${./lib/distro-urls.sh}
          DISPATCH_SCRIPT=${./.}/dispatch.sh
        ''
        + builtins.readFile ./app.sh;
      };
    in
    {
      type = "app";
      program = "${runScript}/bin/hurd-run-${arch}";
    };

  apps' = lib.listToAttrs (map (a: lib.nameValuePair a (mkApp a)) archs);

  # `nix run .` picks the arch closest to the host CPU.  Hosts whose CPU
  # doesn't match any of our supported arches fall through to x86_64
  # (per crossToolchain.defaultTargetName), which won't accel on aarch64
  # hosts but will still boot under TCG.
  defaultArch = crossToolchain.defaultTargetName system targets;
in
apps' // { default = apps'.${defaultArch} or apps'.x86_64; }
