#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Paulo Duarte <paulofernandobd@gmail.com>
# SPDX-License-Identifier: GPL-3.0-or-later
# Bump the *-src flake input pins to their tracked refs' current HEAD on the
# remote, then print a concise before->after summary of what moved (so PR
# reviewers see the rev change in stdout, not just in the flake.lock diff).
#
# Discovers which inputs to update from .#srcs (every `*-src` flake input
# auto-appears there), so adding a new source doesn't require editing this.
set -euo pipefail
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# src<TAB>remote<TAB>short_rev<TAB>date, one line per source.
pins() {
  nix --extra-experimental-features 'nix-command flakes' eval --raw .#srcs --apply '
    srcs: builtins.concatStringsSep "\n" (map (n:
      let s = srcs.${n};
      in builtins.concatStringsSep "\t"
           [ n s.name (builtins.substring 0 7 s.rev) s.date ])
      (builtins.attrNames srcs))'
}

before=$(pins)

# Optional positional args restrict the bump to the named source(s); with none
# we bump every source (the `make pin-srcs` behaviour).  `make pin-src-<name>`
# passes a single name.  An unknown name aborts before any flake.lock change.
want_all=1; wanted=" "
if [ "$#" -gt 0 ]; then
  want_all=0
  known=$(printf '%s\n' "$before" | cut -f1)
  for w in "$@"; do
    printf '%s\n' "$known" | grep -qx -- "$w" || {
      echo "pin-srcs: unknown source '$w'. Known:" $known >&2; exit 1; }
    wanted+="$w "
  done
fi
wanted_src() {
  [ "$want_all" = 1 ] && return 0
  case "$wanted" in *" $1 "*) return 0;; *) return 1;; esac
}

# Derive *-src input names from .#srcs keys (e.g. gnumach -> gnumach-src),
# restricted to the requested source(s).
src_inputs=()
while IFS=$'\t' read -r src _; do
  [ -n "${src:-}" ] || continue
  wanted_src "$src" && src_inputs+=("${src}-src")
done <<< "$before"

echo "==> nix flake update ${src_inputs[*]}"
nix --extra-experimental-features 'nix-command flakes' flake update "${src_inputs[@]}"

after=$(pins)

# Print the move (or "unchanged") for each source, matched by name.
fmt_unchanged='%-10s  %-32s  %-7s  %s   unchanged\n'
fmt_moved='%-10s  %-32s  %-7s (%s)  ->  %s (%s)\n'
echo
while IFS=$'\t' read -r src remote b_rev b_date; do
  [ -n "${src:-}" ] || continue
  wanted_src "$src" || continue
  IFS=$'\t' read -r _ _ a_rev a_date \
    <<< "$(printf '%s\n' "$after" | awk -F'\t' -v s="$src" '$1 == s { print; exit }')"
  if [ "$b_rev" = "$a_rev" ]; then
    # shellcheck disable=SC2059
    printf "$fmt_unchanged" "$src" "$remote" "$b_rev" "$b_date"
  else
    # shellcheck disable=SC2059
    printf "$fmt_moved" "$src" "$remote" "$b_rev" "$b_date" "$a_rev" "$a_date"
  fi
done <<< "$before"
