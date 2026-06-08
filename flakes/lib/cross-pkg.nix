# Shared preConfigure prelude for the cross gnumach/hurd derivations.  Consumed via
# flakes/lib (helpers.crossPkg).
{ lib }:

{
  # Configure + build in a sibling dir with an absolute $srcdir, so DWARF/__FILE__
  # paths map cleanly to the canonical root (an in-source build leaves unmapped `../`
  # paths).  $srcdir is read by the preBuild det-flags rewrite.
  outOfTreePreConfigure = ''
    srcdir="$PWD"
    mkdir -p "$NIX_BUILD_TOP/build"
    cd "$NIX_BUILD_TOP/build"
    configureScript="$srcdir/configure"
  '';
}
