#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Paulo Duarte <paulofernandobd@gmail.com>
# SPDX-License-Identifier: GPL-3.0-or-later
# Body of the `nix run .#<arch>` app - wrapped by writeShellApplication in
# flakes/run/default.nix.  That file prepends a tiny nix-interpolated
# prelude (ARCH, GNUMACH_KERNEL, DISTRO_URLS_FILE, DISPATCH_SCRIPT) so this
# file stays pure shell, editable + diffable on its own.

show_help() {
  cat <<EOF
Usage: nix run .#$ARCH [SCENARIO] [FLAGS] [-- QEMU_ARGS...]

Boot the nix-built GNU Mach kernel for $ARCH under qemu.

Positional:
  SCENARIO         boot (default), hurd-debian, hurd-gentoo, hurd-guix

Flags:
  --vanilla        boot the distro's bundled kernel instead of ours
                   (hurd-* scenarios only)
  --accel          use -accel hvf/kvm; host arch must match target
  --keep-overlay[=N]
                   keep + reuse qcow2 overlay slot N across runs so
                   guest state persists (hurd-* scenarios; N an
                   integer >= 1, default 1 -> overlay-N.qcow2).
                   Without the flag each run starts from a fresh
                   overlay (overlay.qcow2, discarded each run).
  --refresh        wipe the scenario's cached distro image and re-fetch
  --help, -h       show this help

Anything after a literal '--' is appended to qemu's command line
(e.g., -- -s -S, -- -monitor stdio, -- -d int,cpu_reset).

Examples:
  nix run .#$ARCH
  nix run .#$ARCH hurd-debian --accel
  nix run .#$ARCH hurd-debian --vanilla
  nix run .#$ARCH boot --refresh
  nix run .#$ARCH boot -- -s -S
EOF
}

SCENARIO=""
qemu_args=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --help | -h)
      show_help
      exit 0
      ;;
    --vanilla)
      export RUN_VANILLA=1
      shift
      ;;
    --accel)
      export RUN_ACCEL=1
      shift
      ;;
    --keep-overlay=*)
      # `--keep-overlay=N`; empty (`--keep-overlay=`) defaults to 1.
      RUN_KEEP_OVERLAY="${1#*=}"
      export RUN_KEEP_OVERLAY="${RUN_KEEP_OVERLAY:-1}"
      shift
      ;;
    --keep-overlay)
      # Bare flag -> slot 1.  `--keep-overlay N` consumes N only when
      # numeric, so `--keep-overlay hurd-debian` still parses the
      # scenario.  The value is validated downstream.
      if [[ "${2:-}" =~ ^[0-9]+$ ]]; then
        export RUN_KEEP_OVERLAY="$2"
        shift 2
      else
        export RUN_KEEP_OVERLAY=1
        shift
      fi
      ;;
    --refresh)
      export RUN_REFRESH=1
      shift
      ;;
    --)
      shift
      qemu_args+=("$@")
      break
      ;;
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

SCENARIO="${SCENARIO:-boot}"

# ARCH / GNUMACH_KERNEL exported by the prelude - make sure they reach
# dispatch.sh's environment.  The sidekick ISO tools (sidekick-imgcp /
# sidekick-mkrescue) come in via runtimeInputs on PATH, not the env.
export ARCH GNUMACH_KERNEL

# Cache for distro images + ISO staging, overridable via $WORK.  On darwin the
# sidekick guest only sees the project virtiofs share, so the cache MUST live
# under the project for sidekick-mkrescue/imgcp to reach it - use <project>/work
# (shared with `make run`).  On Linux the tools run natively (no VM), so keep the
# XDG-friendly cache.
if [ -z "${WORK:-}" ]; then
  if [ "$(uname)" = Darwin ]; then
    WORK="$(git rev-parse --show-toplevel 2>/dev/null)/work"
    [ "$WORK" = /work ] && {
      echo "nix run on darwin must run inside the repo - the sidekick mounts the project" >&2
      exit 1
    }
  else
    WORK="${XDG_CACHE_HOME:-$HOME/.cache}/hurd-build-system"
  fi
fi
export WORK
mkdir -p "$WORK"

# Build-isolation infix, mirroring the Makefile's _VARIANT (see its
# MULTI_HOST_BUILDS / ALT_BUILD docs): keep the run cache split per build-host
# and/or variant tag so a matrix sharing ONE checkout doesn't collide.  Honoured
# by hurd_cache_dir + boot.sh as test-images/${RUN_VARIANT}<distro>/<arch>.
if [ -z "${RUN_VARIANT:-}" ]; then
  _rv=""
  case "$(printf '%s' "${MULTI_HOST_BUILDS:-}" | tr '[:upper:]' '[:lower:]')" in
    1 | true | yes | on)
      _rv="$(uname -m | sed s/arm64/aarch64/)-$(uname -s | tr '[:upper:]' '[:lower:]')/"
      ;;
  esac
  [ -n "${ALT_BUILD:-}" ] && _rv="${_rv}${ALT_BUILD}/"
  RUN_VARIANT="$_rv"
fi
export RUN_VARIANT

# Distro URLs from the shared source-of-truth - same file the Makefile's
# `run:` recipe sources.
# shellcheck source=/dev/null
. "$DISTRO_URLS_FILE"
export HURD_DEBIAN_X86_64_URL HURD_DEBIAN_I686_URL \
  HURD_GENTOO_X86_64_URL HURD_GENTOO_I686_URL \
  HURD_GUIX_I686_URL HURD_GUIX_X86_64_URL

exec "$DISPATCH_SCRIPT" "$SCENARIO" ${qemu_args[@]+"${qemu_args[@]}"}
