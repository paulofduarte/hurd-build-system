#!/usr/bin/env bash
# Print the current source pins (.#srcs, derived from flake.lock) as a
# human-skimmable table.  Read-only; no network, no git side effects.
set -euo pipefail
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# src<TAB>remote<TAB>ref<TAB>short_rev<TAB>date, one line per source.
lines=$(nix --extra-experimental-features 'nix-command flakes' eval --raw .#srcs --apply '
  srcs: builtins.concatStringsSep "\n" (map (n:
    let s = srcs.${n};
    in builtins.concatStringsSep "\t"
         [ n s.name s.ref (builtins.substring 0 7 s.rev) s.date ])
    (builtins.attrNames srcs))')

header_fmt='%-10s  %-32s  %-12s  %-7s  %s\n'
row_fmt='%-10s  %-32s  ref=%-8s  %-7s  %s\n'
# shellcheck disable=SC2059
printf "$header_fmt" "SRC" "REMOTE" "REF" "REV" "DATE"
while IFS=$'\t' read -r src remote ref short_rev date; do
  [ -n "${src:-}" ] || continue
  # shellcheck disable=SC2059
  printf "$row_fmt" "$src" "$remote" "$ref" "$short_rev" "$date"
done <<< "$lines"
