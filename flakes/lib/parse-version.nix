# Parse the upstream version string out of an autoconf input file —
# version.m4 (gnumach-style: `m4_define([AC_PACKAGE_VERSION], [X])`) or
# configure.ac (mig-style: `AC_INIT([Name], [X], …)`).  Both run at pure
# flake eval via `builtins.readFile` + `builtins.match`; no impure flag,
# no in-sandbox git.  Returns "unknown" when the file doesn't match the
# expected shape.
#
# NB: nix's `builtins.match` uses POSIX ERE, which rejects `\(` / `\[` as
# invalid escapes.  Literals are spelled via single-char classes:
# `[(]` matches `(`, `[[]` matches `[`, `[]]` matches `]`.  `.` already
# matches newlines in nix's regex, so no multi-line dance.

{ lib }:

{
  parseM4Version = path:
    let
      content = builtins.readFile path;
      match = builtins.match
        ".*m4_define[(][[]AC_PACKAGE_VERSION[]],[[]([0-9.]+)[]][)].*" content;
    in
    if match == null then "unknown" else builtins.head match;

  parseAcInitVersion = path:
    let
      content = builtins.readFile path;
      match = builtins.match
        ".*AC_INIT[(][[][^]]*[]], [[]([0-9.]+)[]], .*" content;
    in
    if match == null then "unknown" else builtins.head match;
}
