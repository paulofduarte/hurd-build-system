#!/usr/bin/env bash
# Populate / reconcile the src/<name> working clones from the nix source pins.
#
# The pins come from the flake's `.#srcs` output (derived from flake.lock via
# flakes/sources), so this always tracks exactly what nix builds.  Per source:
#
#   absent          → clone the pinned fork url, checkout the pinned rev
#   present + clean  → ensure a remote for the pinned url exists (ADDED, never
#                     replacing the dev's other remotes), fetch it, checkout
#                     the pinned rev
#   present + dirty  → REFUSE everything (we never touch uncommitted work)
#
# Dirtiness is checked for ALL sources up front, so a dirty tree aborts the
# whole run before any source is modified.  `SRCS_DRY_RUN=1` prints the git
# commands instead of running them.
set -euo pipefail

# Run from the repo root regardless of caller cwd.
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# name<TAB>url<TAB>rev<TAB>ref, one source per line.
lines=$(nix --extra-experimental-features 'nix-command flakes' eval --raw .#srcs --apply '
  srcs: builtins.concatStringsSep "\n" (map (n:
    let s = srcs.${n}; in builtins.concatStringsSep "\t" [ n s.url s.rev s.ref ])
    (builtins.attrNames srcs))')
[ -n "$lines" ] || { echo "srcs: .#srcs is empty" >&2; exit 1; }

run() { if [ "${SRCS_DRY_RUN:-}" = "1" ]; then echo "  + $*"; else "$@"; fi; }

# Pass 1 — refuse if any existing working tree is dirty (before touching any).
while IFS=$'\t' read -r name url rev ref; do
  [ -n "${name:-}" ] || continue
  dir="src/$name"
  if [ -e "$dir/.git" ] && [ -n "$(git -C "$dir" status --porcelain)" ]; then
    echo "srcs: REFUSING — $dir has uncommitted changes; commit or stash first." >&2
    exit 1
  fi
done < <(printf '%s\n' "$lines")

# Pass 2 — clone / reconcile / checkout the pinned rev.
while IFS=$'\t' read -r name url rev ref; do
  [ -n "${name:-}" ] || continue
  dir="src/$name"

  if [ ! -e "$dir/.git" ]; then
    echo "==> $name: cloning $url ($ref)"
    run git clone "$url" "$dir"
    run git -C "$dir" checkout --detach "$rev"
    continue
  fi

  # Existing tree: reuse a remote already pointing at the pinned url, else add
  # one named "pin" — leaving the dev's other remotes (origin, upstream, …) be.
  remote=$(git -C "$dir" remote -v | awk -v u="$url" '$2 == u { print $1; exit }')
  if [ -z "$remote" ]; then
    remote=pin
    if git -C "$dir" remote get-url "$remote" >/dev/null 2>&1; then
      run git -C "$dir" remote set-url "$remote" "$url"
    else
      run git -C "$dir" remote add "$remote" "$url"
    fi
    echo "==> $name: added remote '$remote' -> $url"
  fi

  echo "==> $name: fetching '$remote', checking out ${rev:0:12} ($ref)"
  run git -C "$dir" fetch --quiet "$remote"
  run git -C "$dir" checkout --detach "$rev"
done < <(printf '%s\n' "$lines")

echo "srcs: done."
