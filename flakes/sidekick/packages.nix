# Pinned Alpine linux-virt KERNEL for the sidekick VM (kernel + modules
# only — the userland tools come from Debian; see debian-packages.nix).
#
# The kernel is libc-agnostic, so the Alpine bzImage boots the Debian
# glibc rootfs fine; we keep it because linux-virt is small, 9p/virtio-
# ready, and APK-hash-pinned (reproducible on every host).  Bump with
# flakes/sidekick/refresh-packages.sh's kernel pin (or by hand here).
#
# Hash verifies content; HTTPS-fetched from dl-cdn.alpinelinux.org.

{
  alpineBranch = "v3.21";
  alpineRepo   = "main";
  alpineArch   = "x86_64";

  packages = {
    "linux-virt" = { version = "6.12.90-r0"; sha256 = "40f3734bfe75d9865dbe6aadc154d7b52d9c700319c63de7beae55cc65306934"; };
  };
}
