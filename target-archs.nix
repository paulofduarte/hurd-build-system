# Cross targets we know how to build for.  Add an entry here to support a
# new target; the cross-toolchain, gnumach-headers, mig, and gnumach
# sub-flakes all consume from this attrset.
#
# Kept in its own root-level module (imported by flake.nix) so the
# toolchain-cache CI can path-filter on it: changing the target set affects
# which toolchains are built, but it stays separate from the package wiring.
#
#   crossSystem : nixpkgs cross-system identifier (drives the toolchain)
#   migTarget   : the triple passed to MIG's --target= flag (CPU ABI;
#                 Xen variants share this with their non-Xen siblings)
#   platform    : value for gnumach's --enable-platform= ("at" / "xen" on
#                 x86; null where the option doesn't apply, e.g. aarch64)
{
  aarch64 = {
    crossSystem = "aarch64-none-elf";
    migTarget   = "aarch64-gnu";
    platform    = null;
  };
  x86_64 = {
    crossSystem = "x86_64-elf";
    migTarget   = "x86_64-gnu";
    platform    = "at";
  };
  x86_64-xen = {
    crossSystem = "x86_64-elf";
    migTarget   = "x86_64-gnu";
    platform    = "xen";
  };
  i686 = {
    crossSystem = "i686-elf";
    migTarget   = "i686-gnu";
    platform    = "at";
  };
  i686-xen = {
    crossSystem = "i686-elf";
    migTarget   = "i686-gnu";
    platform    = "xen";
  };
}
