# SPDX-FileCopyrightText: 2026 Paulo Duarte <paulofernandobd@gmail.com>
# SPDX-License-Identifier: GPL-3.0-or-later
# Parse the upstream version string out of an autoconf input file - version.m4
# (gnumach: `m4_define([AC_PACKAGE_VERSION], [X])`) or configure.ac (mig:
# `AC_INIT([Name], [X], ...)`).  Pure-eval (readFile + match).  Returns "unknown"
# on no match.
#
# NB: nix's `builtins.match` uses POSIX ERE, which rejects `\(` / `\[`.
# Literals are spelled via single-char classes: `[(]`, `[[]`, `[]]`.  `.`
# already matches newlines in nix's regex, so no multi-line dance.

{
  parseM4Version =
    path:
    let
      content = builtins.readFile path;
      match = builtins.match ".*m4_define[(][[]AC_PACKAGE_VERSION[]],[[]([0-9.]+)[]][)].*" content;
    in
    if match == null then "unknown" else builtins.head match;

  parseAcInitVersion =
    path:
    let
      content = builtins.readFile path;
      match = builtins.match ".*AC_INIT[(][[][^]]*[]], [[]([0-9.]+)[]], .*" content;
    in
    if match == null then "unknown" else builtins.head match;
}
