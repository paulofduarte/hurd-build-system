# `nix run` apps — one per cross-arch.
#
# Returned API: an attrset suitable for `flake.apps.<system>`:
#
#   default       → boot scenario for the host's best-matching cross
#                    arch (via crossGcc.defaultTargetName)
#   aarch64       → boot scenario for aarch64
#   i686          → boot scenario for i686
#   x86_64        → boot scenario for x86_64
#
# Each app is a wrapper that parses scenario + flags, sets the env
# the harness expects, and exec's ./dispatch.sh (sibling file).
# Same dispatch code path that `make run` uses — same scenario
# scripts, same behaviour — just the kernel comes from the
# nix-built `gnumach-<arch>` package instead of the in-tree work/
# build.
#
# Cache for distro images lives at
# `$XDG_CACHE_HOME/hurd-build-system/test-images/` (defaulting to
# `~/.cache/...`), independent from the Makefile's
# `work/test-images/`.
#
# Args passed by the user (everything after `nix run .#<arch>`) are
# interpreted by the inner script:
#
#   <scenario>      one positional, default "boot"
#   --vanilla       distro's bundled kernel (hurd-* only)
#   --accel         -accel hvf/kvm
#   --keep-overlay  reuse the qcow2 overlay across invocations
#   --refresh       wipe the scenario's cached distro image
#   --help, -h      usage
#   -- ARGS         everything after `--` passes through to qemu

{ pkgs, lib, system, targets, packages, crossGcc }:

let
  # Which arches we expose as `nix run` targets.  Xen variants don't
  # boot under qemu (gnumach disables tests + the boot harness on
  # them) so they're intentionally skipped here.
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
        text = ''
          show_help() {
            cat <<'EOF'
          Usage: nix run .#${arch} [SCENARIO] [FLAGS] [-- QEMU_ARGS...]

          Boot the nix-built GNU Mach kernel for ${arch} under qemu.

          Positional:
            SCENARIO         boot (default), hurd-debian, hurd-gentoo, hurd-guix

          Flags:
            --vanilla        boot the distro's bundled kernel instead of ours
                             (hurd-* scenarios only)
            --accel          use -accel hvf/kvm; host arch must match target
            --keep-overlay   reuse the per-run qcow2 overlay across invocations
            --refresh        wipe the scenario's cached distro image and re-fetch
            --help, -h       show this help

          Anything after a literal '--' is appended to qemu's command line
          (e.g., -- -s -S, -- -monitor stdio, -- -d int,cpu_reset).

          Examples:
            nix run .#${arch}
            nix run .#${arch} hurd-debian --accel
            nix run .#${arch} hurd-debian --vanilla
            nix run .#${arch} boot --refresh
            nix run .#${arch} boot -- -s -S
          EOF
          }

          SCENARIO=""
          qemu_args=()

          while [[ $# -gt 0 ]]; do
            case "$1" in
              --help|-h)      show_help; exit 0 ;;
              --vanilla)      export RUN_VANILLA=1; shift ;;
              --accel)        export RUN_ACCEL=1; shift ;;
              --keep-overlay) export RUN_KEEP_OVERLAY=1; shift ;;
              --refresh)      export RUN_REFRESH=1; shift ;;
              --)             shift; qemu_args+=("$@"); break ;;
              --*)
                echo "unknown flag: $1" >&2
                echo "(use '--' to pass extra args through to qemu, or --help)" >&2
                exit 2
                ;;
              *)
                if [[ -z "$SCENARIO" ]]; then
                  SCENARIO="$1"
                else
                  echo "unexpected positional: $1" >&2
                  echo "(only one positional allowed; use '--' before qemu args)" >&2
                  exit 2
                fi
                shift
                ;;
            esac
          done

          SCENARIO="''${SCENARIO:-boot}"

          # Substituted at flake-eval time — nix-built artefacts.
          export ARCH=${arch}
          export GNUMACH_KERNEL=${gnumach}/boot/gnumach
          export SIDEKICK_KERNEL=${sidekick}/vmlinuz
          export SIDEKICK_INITRD=${sidekick}/initramfs.cpio.gz

          # Cache for distro images — XDG-friendly default,
          # overridable via $WORK (matches the Makefile knob).
          export WORK="''${WORK:-''${XDG_CACHE_HOME:-$HOME/.cache}/hurd-build-system}"
          mkdir -p "$WORK"

          # Distro URLs from the shared source-of-truth — same file
          # the Makefile's `run:` recipe sources.
          # shellcheck source=/dev/null
          . ${./lib/distro-urls.sh}
          export HURD_DEBIAN_X86_64_URL HURD_DEBIAN_I686_URL \
                 HURD_GENTOO_X86_64_URL HURD_GENTOO_I686_URL \
                 HURD_GUIX_I686_URL HURD_GUIX_X86_64_URL

          # dispatch.sh + its sibling scenarios + lib/ all live in
          # this directory.  Copy as a single store path so the
          # dispatch script's $(dirname "$0")/lib/... resolves
          # correctly when invoked from /nix/store.
          exec ${./.}/dispatch.sh "$SCENARIO" ''${qemu_args[@]+"''${qemu_args[@]}"}
        '';
      };
    in
    {
      type = "app";
      program = "${runScript}/bin/hurd-run-${arch}";
    };

  apps' = lib.listToAttrs (map (a: lib.nameValuePair a (mkApp a)) archs);

  # `nix run .` picks the arch closest to the host CPU.  Hosts whose
  # CPU doesn't match any of our supported arches fall through to
  # aarch64 (per crossGcc.defaultTargetName), which won't accel on
  # x86 hosts but will still boot under TCG.
  defaultArch = crossGcc.defaultTargetName system;
in
apps' // { default = apps'.${defaultArch} or apps'.aarch64; }
