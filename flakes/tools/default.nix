# SPDX-FileCopyrightText: 2026 Paulo Duarte <paulofernandobd@gmail.com>
# SPDX-License-Identifier: GPL-3.0-or-later
#
# The rpc-wire-drift gate's C++ comparator (mig-wire-manifest) AND its clang-tidy
# lint, built from ONE shared clang/LLVM env so the compile flags are written in a
# single place.  Both recipes feed the source through `clang++ $(llvm-config
# --cxxflags)` - the lint additionally captures that wrapped clang++'s FULL expanded
# argv with -MJ (a compile-db fragment carrying the cc-wrapper's injected
# SDK/sysroot/resource-dir flags too) and hands it to clang-tidy via -p, so the lint
# reuses the exact build flags without re-deriving or hand-listing any of them.
{ pkgs }:
let
  inherit (pkgs) llvmPackages runCommand;
  src = ./mig-wire-manifest.cpp;

  # The LLVM toolchain both outputs build against (the pin's default llvmPackages -
  # the SAME LLVM hurd-stubs' emitIR uses to harvest the .ll, so emitter and reader
  # always match).
  clangEnv = with llvmPackages; [
    clang
    llvm.dev
  ];

  # Compile/link flags defined ONCE, as the commands that produce them - reused
  # verbatim by the tool build and the lint's compile-db capture below.
  cxxflags = "$(llvm-config --cxxflags)";
  linkflags = "$(llvm-config --ldflags --libs irreader --system-libs) -Wl,-rpath,$(llvm-config --libdir)";

  # The wire-fact manifest tool: an LLVM-API extractor (robust GEP offsets,
  # def-expression + memcpy facts).  One source of truth (this dir); the Makefile
  # gate just resolves + calls it.
  manifest = runCommand "mig-wire-manifest" { nativeBuildInputs = clangEnv; } ''
    mkdir -p $out/bin
    clang++ ${cxxflags} ${src} ${linkflags} -o $out/bin/mig-wire-manifest
  '';

  # clang-tidy over the SAME source with the SAME flags.  -MJ captures the wrapped
  # clang++'s expanded argv as a compile DB in this build's own cwd (so its
  # `directory` is valid); clang-tidy -p then resolves every header exactly as the
  # build does.  .clang-tidy (repo root) selects the checks + WarningsAsErrors, so
  # any finding fails the derivation -> `make lint-cpp` / CI go red.
  lint =
    runCommand "mig-wire-manifest-tidy"
      {
        nativeBuildInputs = clangEnv ++ [ llvmPackages.clang-tools ];
      }
      ''
        mkdir -p db
        clang++ ${cxxflags} ${src} -MJ db/entry.json -c -o db/tu.o
        printf '[%s]' "$(sed 's/,$//' db/entry.json)" > db/compile_commands.json
        clang-tidy -p db ${src} --config-file=${../../.clang-tidy}
        touch $out
      '';
in
{
  inherit manifest lint;
}
