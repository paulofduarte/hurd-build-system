# Pinned Alpine 3.21 x86_64 APKs the sidekick helper VM needs.
#
# Closure of (busybox-static + kmod + e2fsprogs + grub + grub-bios +
# xorriso + mtools + linux-virt), resolved via the v3.21 APKINDEX.
# Regenerate with tools/sidekick/refresh-packages.sh (write that
# helper if you want to bump versions).
#
# Hashes verify content; HTTPS-fetched from dl-cdn.alpinelinux.org.
# Same set used on every build host so the resulting initramfs is
# byte-identical across darwin / linux / arm64 / x86_64.

{
  alpineBranch = "v3.21";
  alpineRepo   = "main";
  alpineArch   = "x86_64";

  packages = {
    "acl-libs"               = { version = "2.3.2-r1";           sha256 = "97aa6d629b26a4329757aa82629ce283710e78b0edc4ac26117246bac037591d"; };
    "apk-tools"              = { version = "2.14.6-r3";          sha256 = "8d402d6298373b7cf122fc12ba3c5bcd2e20a6b671028bef529e1dbec7413f4d"; };
    "busybox"                = { version = "1.37.0-r14";         sha256 = "e0c42bc21e4d25cf5b4e15947d9bd75045ea4b7a8237e87cbefbfa425e7d4717"; };
    "busybox-binsh"          = { version = "1.37.0-r14";         sha256 = "cdb0e74af11fa4cc78cf6626637fdf63ee960871637f15483fcbc111c1f10996"; };
    "busybox-static"         = { version = "1.37.0-r14";         sha256 = "feef45f02f31ee30b6b47eed9b643a0f99e63a21a08a90e7c680066a712405bd"; };
    "ca-certificates-bundle" = { version = "20260413-r0";        sha256 = "79bcf4fd3818e37cb7760033abb82387042c15cd7675f814d4c25e95d6ff24aa"; };
    "cryptsetup-libs"        = { version = "2.7.5-r1";           sha256 = "8c378aee6959e5442eb636f1ed03e19857c73dcff503c8d278978f548ecd65e7"; };
    "device-mapper-libs"     = { version = "2.03.29-r1";         sha256 = "f43e8d1066609c96fec8f4513b1dc4def5d56935579cd46ebc6d7da599f98edd"; };
    "e2fsprogs"              = { version = "1.47.1-r1";          sha256 = "f778a891aa832f40cf3be200b8ac346540c87fb90063e843f0d74044cff0b9c5"; };
    "e2fsprogs-libs"         = { version = "1.47.1-r1";          sha256 = "728d6d3c4d2f3a8d4384f64b00811f47c2ad1760f52b9e1ac82f88216c8fcbb3"; };
    "grub"                   = { version = "2.12-r7";            sha256 = "16257402a270c3db5dfef00293e9bfb9c47c43ddf253f6e24cdde4fe4b840f9e"; };
    "grub-bios"              = { version = "2.12-r7";            sha256 = "0cf0b7277b61fd446780ddd9a17c9f045f20152e1958113235aa7dd12d57cce6"; };
    "json-c"                 = { version = "0.18-r0";            sha256 = "d140ce9aa6d49ef3026869159a555f456b61365bd8e4195c5e9f055637a1f851"; };
    "kmod"                   = { version = "33-r2";              sha256 = "b603af1eb4520d149550c74362647cb0ca2c85590b7e9a9d5598f5facb4a6f15"; };
    "kmod-libs"              = { version = "33-r2";              sha256 = "b8ae7001a412f1d799a9366c39de3616d969d764436649af3aafbf90ef3f2482"; };
    "lddtree"                = { version = "1.27-r0";            sha256 = "b5eeb6984951040558a0e5ad040e629d68e5ca787379f9e38bb76f81ac88be05"; };
    "libblkid"               = { version = "2.40.4-r1";          sha256 = "74dbd807a8e2a7e88bbdbd0a30329c467e7d6512c03644e373ef12d14d28e817"; };
    "libburn"                = { version = "1.5.6-r0";           sha256 = "16c483a87feed6c4115f25a266cb803614230b9279770a3e51683ab8d0347347"; };
    "libcom_err"             = { version = "1.47.1-r1";          sha256 = "71bd3a0c8590da126ac8372e0f2dd78007bc1f6471580e4d632cf2fa960dabeb"; };
    "libcrypto3"             = { version = "3.3.7-r0";           sha256 = "e2b420a2f7a6e810c58e7ed7242a177e68148b47399018d13e5d5768ca6832b4"; };
    "libeconf"               = { version = "0.6.3-r0";           sha256 = "9bcd1c0d8fafa5532a0fe3c76a24dbbe06ef05d2f2c106c55074552251b446f0"; };
    "libedit"                = { version = "20240808.3.1-r0";    sha256 = "975bd0133e92a3df828adabd4bf6654fa7d1a05727963dd4dfcdcf0ed8fbe20e"; };
    "libisoburn"             = { version = "1.5.6-r0";           sha256 = "799c67c1d9d491e3db6fdd03b98f3d8446a5ac2ecf2bc85f4897eee3c3144fbd"; };
    "libisofs"               = { version = "1.5.6-r0";           sha256 = "c5f239d3d1edd3f2d86cbd809764a88adae3ea44a82adf195831c78fe9af9425"; };
    "libncursesw"            = { version = "6.5_p20241006-r3";   sha256 = "3919cf673e841d91865213799ccfd5f77a48f5f9f5402723167470295ee32a49"; };
    "libssl3"                = { version = "3.3.7-r0";           sha256 = "bd50e1a43eba14a47f90076d99297ca01cb2ede6d70ccea27062552adc4bbeb6"; };
    "libuuid"                = { version = "2.40.4-r1";          sha256 = "67dd6b9a714841008389bfa5cb4e42fd0539cd873eaf904481babee49eb11454"; };
    "linux-virt"             = { version = "6.12.90-r0";         sha256 = "40f3734bfe75d9865dbe6aadc154d7b52d9c700319c63de7beae55cc65306934"; };
    "mdev-conf"              = { version = "4.7-r0";             sha256 = "d0cf822938dae8f6be407506e974c996d1a9fd533b656de596b0288533e811fd"; };
    "mkinitfs"               = { version = "3.11.1-r0";          sha256 = "ffd4afb54dd843050111e4f0b634879b54d4c4591c0c6de26b0582529e9fe7b1"; };
    "mtools"                 = { version = "4.0.46-r0";          sha256 = "151fa65b3931494981f398618e073577cc58ee254f3cd0f69d4c64a131535d7f"; };
    "musl"                   = { version = "1.2.5-r11";          sha256 = "61e84757a8bfbc0d7fa8f4ce6de9cd4d791714369d78f6a08e5b03510fb2a623"; };
    "ncurses-terminfo-base"  = { version = "6.5_p20241006-r3";   sha256 = "46402464710d165a8fed4b843b3a20d9950e1e9a20923c3869241014bf6b2f51"; };
    "scanelf"                = { version = "1.3.8-r1";           sha256 = "ab09a222be0de397e5102107f057f1181be1bf3b70bc66c645750f92d861ae14"; };
    "xorriso"                = { version = "1.5.6-r0";           sha256 = "bd71b1d2670d0af0bb9885c2d7d6621c11b6e8bbd3ad904af32756fbcb2ea429"; };
    "xz-libs"                = { version = "5.8.3-r0";           sha256 = "0a6e2ffa63da3314193103cc33dd0bb07a7c0683cc0001fde1fa0cf036a7ddeb"; };
    "zlib"                   = { version = "1.3.2-r0";           sha256 = "b224a975eb04ec3ec9bce7db2fce91c9e9d669996f79a9a750d4a3cd9324a404"; };
    "zstd-libs"              = { version = "1.5.6-r2";           sha256 = "45a06bfc107f44502b7e0503fcd5c8d2d2e6cff255134ed959275eb99caf9979"; };
  };
}
