# `nix run` apps — one per cross-arch.
#
# Returned API: an attrset suitable for `flake.apps.<system>`:
#
#   default       → boot scenario for the host's best-matching cross
#                    arch (via crossToolchain.defaultTargetName)
#   aarch64       → boot scenario for aarch64
#   i686          → boot scenario for i686
#   x86_64        → boot scenario for x86_64
#
# Each app is a wrapper that parses scenario + flags, sets the env the
# harness expects, and exec's ./dispatch.sh (sibling file).  Same dispatch
# code path that `make run` uses — same scenario scripts, same behaviour
# — just the kernel comes from the nix-built `gnumach-<arch>` package
# instead of the in-tree work/ build.
#
# Cache for distro images lives at
# `$XDG_CACHE_HOME/hurd-build-system/test-images/` (defaulting to
# `~/.cache/...`), independent from the Makefile's `work/test-images/`.
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

{ nixpkgs, system, targets, packages, crossToolchain }:

let
  pkgs = nixpkgs.legacyPackages.${system};
  lib = nixpkgs.lib;
  # Which arches we expose as `nix run` targets.  Xen variants don't boot
  # under qemu (gnumach disables tests + the boot harness on them) so
  # they're intentionally skipped here.
  archs = [ "aarch64" "i686" "x86_64" ];

  mkApp = arch:
    let
      gnumach = packages."gnumach-${arch}";
      sidekick = packages.sidekick;

      runScript = pkgs.writeShellApplication {
        name = "hurd-run-${arch}";
        runtimeInputs = with pkgs; [
          qemu      # qemu-system-* + qemu-img
          curl      # distro image fetch
          coreutils # mkdir / mv / cp / sha512sum
          gnused gnugrep gawk
          gnutar gzip
        ];
        # Tiny nix-interpolated prelude — sets the env vars + paths
        # ./app.sh references; the body itself stays pure shell.
        text = ''
          export ARCH=${arch}
          export GNUMACH_KERNEL=${gnumach}/boot/gnumach
          export SIDEKICK_KERNEL=${sidekick}/vmlinuz
          export SIDEKICK_INITRD=${sidekick}/initramfs.cpio.gz
          DISTRO_URLS_FILE=${./lib/distro-urls.sh}
          DISPATCH_SCRIPT=${./.}/dispatch.sh
        '' + builtins.readFile ./app.sh;
      };
    in
    {
      type = "app";
      program = "${runScript}/bin/hurd-run-${arch}";
    };

  apps' = lib.listToAttrs (map (a: lib.nameValuePair a (mkApp a)) archs);

  # `nix run .` picks the arch closest to the host CPU.  Hosts whose CPU
  # doesn't match any of our supported arches fall through to aarch64
  # (per crossToolchain.defaultTargetName), which won't accel on x86 hosts
  # but will still boot under TCG.
  defaultArch = crossToolchain.defaultTargetName system;
in
apps' // { default = apps'.${defaultArch} or apps'.aarch64; }
