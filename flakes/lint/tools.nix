# SPDX-FileCopyrightText: 2026 Paulo Duarte <paulofernandobd@gmail.com>
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Single source of truth for the lint + format tool set.  Consumed by:
#   * flake.nix  -> the `lint-tools` package (a symlinkJoin the Makefile/hook/CI use)
#   * the dev shell (flakes/cross-toolchain/dev-shell.nix) -> tools on PATH in-shell
# so `make lint`/`make fmt`, the .githooks pre-commit hook, and the lint CI all run
# the exact same, pinned tools.  Binary -> use:
#   nixfmt (nixfmt-rfc-style) / statix / deadnix  -> nix
#   clang-format (clang-tools)                     -> C/C++
#   shfmt / shellcheck                             -> shell
#   mdformat                                       -> markdown
#   yamlfmt / yamllint                             -> yaml
#   reuse                                          -> SPDX/license compliance
pkgs: with pkgs; [
  nixfmt-rfc-style
  statix
  deadnix
  clang-tools
  shfmt
  shellcheck
  mdformat
  yamlfmt
  yamllint
  reuse
]
