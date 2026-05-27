#!/usr/bin/env bash
# Entry point for `make run`. Validates env, exec's the scenario script.
set -euo pipefail
. "$(dirname "$0")/lib/common.sh"   # provides die()

scenarios_dir="$(dirname "$0")"

# --help must work without the Makefile's env-var context (the
# `run-help` Make target invokes dispatch.sh without the env exports
# that `run` does). Handle it before env validation.
if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
  cat <<EOF
Usage: make run [TARGET=<arch>] [SCENARIO=<name>] [opts]

Options (all env-style; default in parens):
  TARGET=<arch>        aarch64|x86_64|i686 (host arch)
  SCENARIO=<name>      boot|hurd-debian|hurd-gentoo|hurd-guix (boot)
  RUN_VANILLA=1        boot the distro's bundled kernel (Hurd scenarios only)
  RUN_ACCEL=1          enable -accel hvf/kvm when host arch matches TARGET
  RUN_KEEP_OVERLAY=1   reuse the per-run qcow2 overlay across invocations
  RUN_ARGS="..."       extra flags appended to the qemu invocation

Available scenarios:
EOF
  find "$scenarios_dir" -maxdepth 1 -name '*.sh' -not -name 'dispatch.sh' \
    | sed 's|.*/||; s|\.sh$||' | sort | sed 's/^/  /'
  exit 0
fi

: "${TARGET:?TARGET required (set by Makefile)}"
: "${GNUMACH_KERNEL:?GNUMACH_KERNEL required (set by Makefile)}"
: "${WORK:?WORK required (set by Makefile)}"

scenario="${1:-boot}"
shift || true

script="$scenarios_dir/${scenario}.sh"

if [ ! -x "$script" ]; then
  echo "unknown scenario: $scenario" >&2
  echo "available scenarios:" >&2
  find "$scenarios_dir" -maxdepth 1 -name '*.sh' -not -name 'dispatch.sh' \
    | sed 's|.*/||; s|\.sh$||' | sort | sed 's/^/  /' >&2
  exit 2
fi

# Per-scenario TARGET validation happens inside each scenario via
# scenario_check_target "<scenario_name>" "<supported_targets>"
# (defined in lib/common.sh; calls die on mismatch).

exec "$script" "$@"
