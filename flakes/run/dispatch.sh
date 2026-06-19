#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Paulo Duarte <paulofernandobd@gmail.com>
# SPDX-License-Identifier: GPL-3.0-or-later
# Entry point for `make run`. Validates env, exec's the scenario script.
set -euo pipefail
# shellcheck source=lib/common.sh
. "$(dirname "$0")/lib/common.sh" # provides die()

scenarios_dir="$(dirname "$0")"

# --help must work without the Makefile's env-var context (the
# `run-help` Make target invokes dispatch.sh without the env exports
# that `run` does). Handle it before env validation.
if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
  cat <<EOF
Usage: make run [ARCH=<arch>] [SCENARIO=<name>] [opts]

Options (all env-style; default in parens):
  ARCH=<arch>        aarch64|x86_64|i686 (host arch)
  SCENARIO=<name>      boot|hurd-debian|hurd-gentoo|hurd-guix (boot)
  RUN_VANILLA=1        boot the distro's bundled kernel (Hurd scenarios only)
  RUN_ACCEL=1          enable -accel hvf/kvm when host arch matches ARCH
  RUN_KEEP_OVERLAY=1   reuse the per-run qcow2 overlay across invocations
  RUN_REFRESH=1        wipe the scenario's cached distro image and re-fetch
  RUN_ARGS="..."       extra flags appended to the qemu invocation

Available scenarios:
EOF
  find "$scenarios_dir" -maxdepth 1 -name '*.sh' -not -name 'dispatch.sh' |
    sed 's|.*/||; s|\.sh$||' | sort | sed 's/^/  /'
  exit 0
fi

: "${ARCH:?ARCH required (set by Makefile)}"
: "${GNUMACH_KERNEL:?GNUMACH_KERNEL required (set by Makefile)}"
: "${WORK:?WORK required (set by Makefile)}"

scenario="${1:-boot}"
shift || true

script="$scenarios_dir/${scenario}.sh"

if [ ! -x "$script" ]; then
  echo "unknown scenario: $scenario" >&2
  echo "available scenarios:" >&2
  find "$scenarios_dir" -maxdepth 1 -name '*.sh' -not -name 'dispatch.sh' |
    sed 's|.*/||; s|\.sh$||' | sort | sed 's/^/  /' >&2
  exit 2
fi

# Cross-scenario sanity: RUN_VANILLA only applies to hurd-* scenarios
# (it swaps our kernel out for the distro's bundled one).  With
# SCENARIO=boot there's no distro kernel to fall back to - boot mode
# is defined as "qemu -kernel <ours>".  Reject the combination loudly
# so users don't accidentally think the flag did something.
if [ "$scenario" = "boot" ] && [ "${RUN_VANILLA:-}" = "1" ]; then
  echo "RUN_VANILLA=1 / --vanilla has no effect with SCENARIO=boot." >&2
  echo "boot mode uses our kernel directly (qemu -kernel) - there's no" >&2
  echo "distro kernel to fall back to.  Either pick a Hurd scenario" >&2
  echo "(hurd-debian / hurd-gentoo / hurd-guix) or drop the flag." >&2
  exit 2
fi

# Per-scenario ARCH validation happens inside each scenario via
# scenario_check_target "<scenario_name>" "<supported_targets>"
# (defined in lib/common.sh; calls die on mismatch).

exec "$script" "$@"
