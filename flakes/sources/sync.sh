#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Paulo Duarte <paulofernandobd@gmail.com>
# SPDX-License-Identifier: GPL-3.0-or-later
# Populate / reconcile the src/<name> working clones from the nix source pins.
#
# The sources come from the flake's `.#srcs` output (the master-tracking `*-src`
# WORK inputs, derived from flake.lock via flakes/sources) - the same source the
# in-tree AND shipped nix builds use.  The frozen `*-toolchain-src` bootstrap pins
# are NOT cloned (they feed the toolchain only).  Per source:
#
#   absent          -> clone the pin's url, then RENAME git's default `origin`
#                     to a stable host-named remote (e.g. github.<owner>.<repo>,
#                     savannah.<project>.<repo>) so the canonical source is
#                     named after what it IS - and so `origin` is free for the
#                     dev's own fork to fill later.  Check out the pinned rev.
#   present + clean -> find a remote already pointing at the pin (ssh/https-
#                     insensitive) for the fetch; AND always ensure the stable
#                     host-named remote exists pointing at the pin (added
#                     alongside the matched one if missing - never touches the
#                     matched remote).  REFUSE if a remote with the stable
#                     name already exists for a different url.  The dev's
#                     other remotes are untouched.
#   present + dirty -> REFUSE everything (we never touch uncommitted work)
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

# name<TAB>url<TAB>rev<TAB>ref<TAB>remote, one source per line.
_expr=$(
  cat <<'NIXEXPR'
  srcs: builtins.concatStringsSep "\n" (map (n:
    let s = srcs.${n};
    in builtins.concatStringsSep "\t" [ n s.url s.rev s.ref s.name ])
    (builtins.attrNames srcs))
NIXEXPR
)
lines=$(nix --extra-experimental-features 'nix-command flakes' eval --raw .#srcs --apply "$_expr")
[ -n "$lines" ] || {
  echo "src: .#srcs is empty" >&2
  exit 1
}

# Optional positional args restrict the run to the named source(s); with none
# we reconcile every source (the `make src` behaviour).  `make src-<name>`
# passes a single name.  An unknown name aborts before anything is touched.
if [ "$#" -gt 0 ]; then
  known=$(printf '%s\n' "$lines" | cut -f1)
  for want in "$@"; do
    printf '%s\n' "$known" | grep -qx -- "$want" || {
      echo "src: unknown source '$want'. Known: $(printf '%s\n' "$known" | tr '\n' ' ')" >&2
      exit 1
    }
  done
  sel=""
  while IFS= read -r line; do
    name=${line%%$'\t'*}
    for want in "$@"; do
      [ "$name" = "$want" ] && {
        sel+="$line"$'\n'
        break
      }
    done
  done < <(printf '%s\n' "$lines")
  lines=${sel%$'\n'}
fi

run() { if [ "${SRCS_DRY_RUN:-}" = "1" ]; then echo "  + $*"; else "$@"; fi; }

# Normalise a git URL to host/owner/repo so ssh vs https and a trailing .git
# compare equal (git@github.com:o/r.git and https://github.com/o/r -> github.com/o/r).
norm_url() {
  printf '%s' "$1" | sed -E 's#^git@([^:]+):#\1/#; s#^[a-z]+://([^@]+@)?##; s#\.git$##; s#/+$##'
}

# Land $dir on the pin.  If the pinned ref is a branch on the remote, check out
# a local branch <ref> (so you can commit/push) instead of a detached HEAD; an
# existing local <ref> is switched to but never moved (your commits stay put -
# reset/rebase yourself if you want it at the pin).  Tags / bare commits detach.
checkout_pinned() {
  local dir="$1" remote="$2" url="$3" ref="$4" rev="$5" on_branch=""
  [ -n "$(git ls-remote --heads "$url" "$ref" 2>/dev/null)" ] && on_branch=1
  # Fresh-clone dry-run: the repo isn't there yet, so just state the intent.
  if [ "${SRCS_DRY_RUN:-}" = "1" ] && [ ! -e "$dir/.git" ]; then
    [ -n "$on_branch" ] && echo "  + (checkout branch '$ref' @ ${rev:0:12})" ||
      echo "  + (checkout --detach ${rev:0:12})"
    return 0
  fi
  if [ -n "$on_branch" ]; then
    if git -C "$dir" show-ref --verify --quiet "refs/heads/$ref"; then
      run git -C "$dir" checkout "$ref"
      [ "${SRCS_DRY_RUN:-}" = "1" ] || [ "$(git -C "$dir" rev-parse "$ref")" = "$rev" ] ||
        echo "    note: branch '$ref' is not at the pinned rev ${rev:0:12} (left as-is)"
    else
      run git -C "$dir" checkout -b "$ref" "$rev"
      run git -C "$dir" branch --set-upstream-to="$remote/$ref" "$ref"
    fi
  else
    run git -C "$dir" checkout --detach "$rev"
  fi
}

# Pass 1 - refuse if any existing working tree is dirty (before touching any).
while IFS=$'\t' read -r name url rev ref remote_name; do
  [ -n "${name:-}" ] || continue
  dir="src/$name"
  if [ -e "$dir/.git" ] && [ -n "$(git -C "$dir" status --porcelain)" ]; then
    echo "src: REFUSING - $dir has uncommitted changes; commit or stash first." >&2
    exit 1
  fi
done < <(printf '%s\n' "$lines")

# Pass 2 - clone / reconcile / checkout the pinned rev.
while IFS=$'\t' read -r name url rev ref remote_name; do
  [ -n "${name:-}" ] || continue
  dir="src/$name"

  if [ ! -e "$dir/.git" ]; then
    echo "==> $name: cloning $url ($ref)"
    run git clone "$url" "$dir"
    # Rename git's clone-default `origin` to the stable host-named name.  The
    # canonical source is then named after what it IS (savannah/<host>/<repo>),
    # and `origin` is free for the dev to set to their own fork later.
    # `git remote rename` also rewrites refs/remotes/origin/* and the tracking
    # branches, so the local branch the clone landed on keeps working.
    # Refuse to clobber a pre-existing remote with the target name (shouldn't
    # exist on a fresh clone, but guards re-runs after a prior abort).
    if [ "${SRCS_DRY_RUN:-}" != "1" ] &&
      git -C "$dir" remote get-url "$remote_name" >/dev/null 2>&1; then
      echo "src: REFUSING - $dir already has a remote '$remote_name'." >&2
      exit 1
    fi
    run git -C "$dir" remote rename origin "$remote_name"
    checkout_pinned "$dir" "$remote_name" "$url" "$ref" "$rev"
    continue
  fi

  # Existing tree: find a remote whose url already matches the pin
  # (ssh/https-insensitive).  If none, add one under the stable host-named
  # name - but REFUSE if a remote with that name already exists for a
  # different url; we never silently overwrite the dev's setup.
  nurl=$(norm_url "$url")
  remote=""
  while read -r rname rurl _; do
    [ "$(norm_url "$rurl")" = "$nurl" ] && {
      remote="$rname"
      break
    }
  done < <(git -C "$dir" remote -v | awk '$3 == "(fetch)"')
  if [ -z "$remote" ]; then
    if git -C "$dir" remote get-url "$remote_name" >/dev/null 2>&1; then
      echo "src: REFUSING - $dir already has a remote '$remote_name' pointing" >&2
      echo "        at $(git -C "$dir" remote get-url "$remote_name")," >&2
      echo "        but the pin wants $url." >&2
      echo "        Rename/fix that remote and re-run." >&2
      exit 1
    fi
    run git -C "$dir" remote add "$remote_name" "$url"
    echo "==> $name: added remote '$remote_name' -> $url"
    remote="$remote_name"
  fi

  # Always ensure the stable host-named remote is present, even when another
  # remote already URL-matched the pin (so every clone advertises the canonical
  # source under the same name).  Refuse if that name already exists for a
  # different url; we never touch whichever remote we actually fetch from.
  if [ "$remote" != "$remote_name" ]; then
    existing_stable=$(git -C "$dir" remote get-url "$remote_name" 2>/dev/null || true)
    if [ -n "$existing_stable" ]; then
      if [ "$(norm_url "$existing_stable")" != "$nurl" ]; then
        echo "src: REFUSING - $dir has a remote '$remote_name' pointing at" >&2
        echo "        $existing_stable, but the pin wants $url." >&2
        echo "        Rename/fix that remote and re-run." >&2
        exit 1
      fi
      # Stable already configured correctly - nothing to do.
    else
      run git -C "$dir" remote add "$remote_name" "$url"
      echo "==> $name: also added '$remote_name' -> $url (cross-env consistency)"
    fi
  fi

  echo "==> $name: fetching '$remote', reconciling to '$ref' @ ${rev:0:12}"
  run git -C "$dir" fetch --quiet "$remote"
  checkout_pinned "$dir" "$remote" "$url" "$ref" "$rev"
done < <(printf '%s\n' "$lines")

echo "src: done."
