#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Paulo Duarte <paulofernandobd@gmail.com>
# SPDX-License-Identifier: GPL-3.0-or-later
# Print the current source pins (.#srcs, derived from flake.lock) as a
# human-skimmable table.  Read-only; no network, no git side effects.
set -euo pipefail
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# src<TAB>remote<TAB>ref<TAB>short_rev<TAB>date, one line per source.
_expr=$(
  cat <<'NIXEXPR'
  srcs: builtins.concatStringsSep "\n" (map (n:
    let s = srcs.${n};
    in builtins.concatStringsSep "\t"
         [ n s.name s.ref (builtins.substring 0 7 s.rev) s.date ])
    (builtins.attrNames srcs))
NIXEXPR
)
lines=$(nix --extra-experimental-features 'nix-command flakes' eval --raw .#srcs --apply "$_expr")

printf '%-10s  %-32s  %-12s  %-7s  %s\n' "SRC" "REMOTE" "REF" "REV" "DATE"
while IFS=$'\t' read -r src remote ref short_rev date; do
  [ -n "${src:-}" ] || continue
  printf '%-10s  %-32s  ref=%-8s  %-7s  %s\n' "$src" "$remote" "$ref" "$short_rev" "$date"
done <<<"$lines"
