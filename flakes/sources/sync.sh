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
# When the pin's ref is a branch, the checkout lands on a local branch of that
# name at the pinned rev (so you can commit/push) rather than a detached HEAD;
# an existing local branch is switched to but never moved.  Tags / bare-commit
# pins stay detached.
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

# Normalise a git URL to host/owner/repo so ssh vs https and a trailing .git
# compare equal (git@github.com:o/r.git and https://github.com/o/r → github.com/o/r).
norm_url() {
  printf '%s' "$1" | sed -E 's#^git@([^:]+):#\1/#; s#^[a-z]+://([^@]+@)?##; s#\.git$##; s#/+$##'
}

# Land $dir on the pin.  If the pinned ref is a branch on the remote, check out
# a local branch <ref> (so you can commit/push) instead of a detached HEAD; an
# existing local <ref> is switched to but never moved (your commits stay put —
# reset/rebase yourself if you want it at the pin).  Tags / bare commits detach.
checkout_pinned() {
  local dir="$1" remote="$2" url="$3" ref="$4" rev="$5" on_branch=""
  [ -n "$(git ls-remote --heads "$url" "$ref" 2>/dev/null)" ] && on_branch=1
  # Fresh-clone dry-run: the repo isn't there yet, so just state the intent.
  if [ "${SRCS_DRY_RUN:-}" = "1" ] && [ ! -e "$dir/.git" ]; then
    [ -n "$on_branch" ] && echo "  + (checkout branch '$ref' @ ${rev:0:12})" \
                        || echo "  + (checkout --detach ${rev:0:12})"
    return 0
  fi
  if [ -n "$on_branch" ]; then
    if git -C "$dir" show-ref --verify --quiet "refs/heads/$ref"; then
      run git -C "$dir" checkout "$ref"
      [ "${SRCS_DRY_RUN:-}" = "1" ] || [ "$(git -C "$dir" rev-parse "$ref")" = "$rev" ] || \
        echo "    note: branch '$ref' is not at the pinned rev ${rev:0:12} (left as-is)"
    else
      run git -C "$dir" checkout -b "$ref" "$rev"
      run git -C "$dir" branch --set-upstream-to="$remote/$ref" "$ref"
    fi
  else
    run git -C "$dir" checkout --detach "$rev"
  fi
}

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
    checkout_pinned "$dir" origin "$url" "$ref" "$rev"
    continue
  fi

  # Existing tree: reuse a remote that already points at the pinned repo
  # (ssh/https-insensitive), else add one named "pin" — leaving the dev's other
  # remotes (origin, upstream, …) untouched.
  nurl=$(norm_url "$url")
  remote=""
  while read -r rname rurl _; do
    [ "$(norm_url "$rurl")" = "$nurl" ] && { remote="$rname"; break; }
  done < <(git -C "$dir" remote -v | awk '$3 == "(fetch)"')
  if [ -z "$remote" ]; then
    remote=pin
    if git -C "$dir" remote get-url "$remote" >/dev/null 2>&1; then
      run git -C "$dir" remote set-url "$remote" "$url"
    else
      run git -C "$dir" remote add "$remote" "$url"
    fi
    echo "==> $name: added remote '$remote' -> $url"
  fi

  echo "==> $name: fetching '$remote', reconciling to '$ref' @ ${rev:0:12}"
  run git -C "$dir" fetch --quiet "$remote"
  checkout_pinned "$dir" "$remote" "$url" "$ref" "$rev"
done < <(printf '%s\n' "$lines")

echo "srcs: done."
