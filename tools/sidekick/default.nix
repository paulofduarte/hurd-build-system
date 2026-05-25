# Sidekick helper VM — Linux Swiss-army-knife for harness operations
# that darwin can't do natively (read ext2, run grub-mkrescue, etc.).
#
# Built by FETCHING pre-built Alpine x86_64 binaries (no compilation),
# so the same derivation builds identically on darwin, linux-arm64,
# linux-x86_64 — fully reproducible via pinned APK hashes.
#
# Inputs (host-system pkgs): tar, gzip, cpio.  All POSIX tools, present
# in any nixpkgs.  No Linux-only build tools needed.
#
# Output (under $out):
#   vmlinuz             Alpine linux-virt bzImage (x86_64)
#   initramfs.cpio.gz   minimal Alpine rootfs + /init dispatcher
#
# The VM dispatches on SIDEKICK_OP=<extract|mkiso> in the kernel
# cmdline.  See tools/sidekick/init.sh.

{ pkgs }:

let
  inherit (pkgs) lib runCommand fetchurl writeText;

  spec = import ./packages.nix;
  inherit (spec) alpineBranch alpineRepo alpineArch packages;

  # fetchurl per pinned APK.  HTTPS-fetched from dl-cdn.alpinelinux.org;
  # sha256 protects against any future tampering.
  apkFor = name: { version, sha256 }: fetchurl {
    url = "https://dl-cdn.alpinelinux.org/alpine/${alpineBranch}/${alpineRepo}/${alpineArch}/${name}-${version}.apk";
    inherit sha256;
  };
  fetchedApks = lib.mapAttrs apkFor packages;

  # /init script — separate file so it's editable + diff-friendly.
  initScript = writeText "sidekick-init" (builtins.readFile ./init.sh);

  # Build-host tools used during runCommand.  Available on any platform.
  hostTools = with pkgs; [ gnutar gzip cpio findutils ];

in runCommand "sidekick-vm" {
  nativeBuildInputs = hostTools;
  passthru = { inherit fetchedApks; };
  meta = with lib; {
    description = "x86_64 Linux helper VM for the GNU Hurd build-system test harness.";
    platforms = platforms.all;
  };
} ''
  set -eu
  rootfs=$PWD/rootfs
  kpkg=$PWD/kernel-pkg
  mkdir -p "$rootfs" "$kpkg" "$out"

  # ---- Extract the Linux kernel ------------------------------------
  # linux-virt APK ships /boot/vmlinuz-virt + /lib/modules/<ver>/...
  # The bzImage goes to $out; the modules go into the initramfs (so
  # /init can modprobe ext2/3/4 if they aren't built in).
  tar -xzf ${fetchedApks.linux-virt} -C "$kpkg" 2>/dev/null || true
  # vmlinuz-virt is at /boot/vmlinuz-virt — pluck it out.
  if [ ! -f "$kpkg/boot/vmlinuz-virt" ]; then
    echo "FATAL: linux-virt APK did not contain /boot/vmlinuz-virt" >&2
    find "$kpkg" -maxdepth 3 -type f | head -20 >&2
    exit 1
  fi
  cp "$kpkg/boot/vmlinuz-virt" "$out/vmlinuz"

  # Copy kernel modules into the rootfs so modprobe works.
  mkdir -p "$rootfs/lib"
  if [ -d "$kpkg/lib/modules" ]; then
    cp -a "$kpkg/lib/modules" "$rootfs/lib/"
  fi

  # ---- Extract every other APK into the rootfs ---------------------
  # APKs are concatenated gzip streams: control segment first (.PKGINFO,
  # .SIGN.*, .trigger, sometimes .scripts.tar) then a data segment with
  # the actual files.  `tar -xzf` happens to accept this and yields
  # both segments interleaved.  We just delete control files at the
  # end before packing.
  ${lib.concatMapStringsSep "\n" (name:
    if name == "linux-virt" then ""
    else ''tar -xzf ${fetchedApks.${name}} -C "$rootfs" 2>/dev/null || true''
  ) (builtins.attrNames fetchedApks)}

  # ---- Clean up APK control files ----------------------------------
  rm -f "$rootfs/.PKGINFO" "$rootfs/.SIGN."* "$rootfs/.trigger" \
        "$rootfs/.scripts.tar"* "$rootfs/.pre-install" \
        "$rootfs/.post-install" "$rootfs/.pre-upgrade" \
        "$rootfs/.post-upgrade" "$rootfs/.pre-deinstall" \
        "$rootfs/.post-deinstall" 2>/dev/null || true

  # ---- Standard rootfs setup ---------------------------------------
  # Some Alpine packages assume /var, /tmp, /proc, /sys, /dev exist.
  mkdir -p "$rootfs/var" "$rootfs/tmp" "$rootfs/proc" "$rootfs/sys" \
           "$rootfs/dev" "$rootfs/mnt" "$rootfs/shared" "$rootfs/run" \
           "$rootfs/etc"

  # Minimal /etc files so musl/glibc don't complain.
  : > "$rootfs/etc/passwd"
  : > "$rootfs/etc/group"
  : > "$rootfs/etc/fstab"

  # ---- Install /init -----------------------------------------------
  cp ${initScript} "$rootfs/init"
  chmod 755 "$rootfs/init"

  # ---- Pack the initramfs ------------------------------------------
  # cpio + gzip — POSIX tools, same on every host.  Use newc format
  # (the standard initramfs format Linux's early-init expects).
  cd "$rootfs"
  find . -print0 \
    | cpio --null --create --format=newc 2>/dev/null \
    | gzip -9 > "$out/initramfs.cpio.gz"

  # Report sizes — useful when iterating on what to include.
  echo "sidekick: vmlinuz=$(stat -c%s "$out/vmlinuz" 2>/dev/null || stat -f%z "$out/vmlinuz") bytes" >&2
  echo "sidekick: initramfs.cpio.gz=$(stat -c%s "$out/initramfs.cpio.gz" 2>/dev/null || stat -f%z "$out/initramfs.cpio.gz") bytes" >&2
''
