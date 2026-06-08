# Shared preConfigure prelude for the cross gnumach/hurd derivations.  Consumed via
# flakes/lib (helpers.crossPkg).
{ lib }:

{
  # OUT-OF-TREE build prelude: configure + build in a sibling dir with an ABSOLUTE
  # srcdir, so source paths in DWARF/__FILE__ are absolute and map cleanly to the
  # canonical root (an in-source build leaves unmapped relative `../` paths, diverging
  # from the in-tree out-of-tree build).  `$srcdir` is then read by the preBuild
  # det-flags rewrite (build-flags.detCflagsExport) + any doc-mtime touch.
  outOfTreePreConfigure = ''
    srcdir="$PWD"
    mkdir -p "$NIX_BUILD_TOP/build"
    cd "$NIX_BUILD_TOP/build"
    configureScript="$srcdir/configure"
  '';
}
