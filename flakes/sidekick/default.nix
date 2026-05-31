# Sidekick helper VM — a generic Debian (glibc) command dispatcher for
# harness operations darwin can't do natively (abidiff/pahole for the ABI
# gate, grub-mkrescue/ext-mount for the run scenarios).  The VM is dumb: it
# runs host-supplied commands/scripts (see dispatcher.sh); all logic lives
# host-side (the ABI gate + flakes/run).  See SIDEKICK-DISPATCHER.md.
#
# Built by FETCHING pre-built binaries (no compilation), reproducibly:
#   - kernel + modules: the Alpine linux-virt bzImage (libc-agnostic boot
#     vehicle, small, 9p-ready), pinned by APK hash (packages.nix);
#   - userland: a glibc Debian tool closure, pinned by snapshot.debian.org
#     version+SHA256 (debian-packages.nix, regen via refresh-packages.sh).
# So the same derivation builds identically on darwin / linux-arm64 /
# linux-x86_64.
#
# Output (under $out): vmlinuz + initramfs.cpio.gz.

{ nixpkgs, system }:

let
  pkgs = nixpkgs.legacyPackages.${system};
  inherit (pkgs) lib runCommand fetchurl writeText;

  # --- Alpine linux-virt kernel (kernel + modules only) ---
  alpine = import ./packages.nix;
  kernelApk = fetchurl {
    url = "https://dl-cdn.alpinelinux.org/alpine/${alpine.alpineBranch}/${alpine.alpineRepo}/${alpine.alpineArch}/linux-virt-${alpine.packages.linux-virt.version}.apk";
    inherit (alpine.packages.linux-virt) sha256;
  };

  # --- Debian glibc userland (the tools) ---
  deb = import ./debian-packages.nix;
  fetchedDebs = lib.mapAttrs (_: { url, sha256, ... }: fetchurl { inherit url sha256; }) deb.packages;

  dispatcher = writeText "sidekick-dispatcher" (builtins.readFile ./dispatcher.sh);
  # gnutar/gzip/cpio (POSIX) + ar (.deb) + xz/zstd (data.tar.{xz,zst}).
  hostTools = with pkgs; [ gnutar gzip cpio findutils binutils xz zstd ];
in
{
  sidekick = runCommand "sidekick-vm" {
    nativeBuildInputs = hostTools;
    passthru = { inherit fetchedDebs; inherit (deb) snapshot; };
    meta = with lib; {
      description = "Debian glibc helper VM (generic dispatcher) for the GNU Hurd build-system harness.";
      platforms = platforms.all;
    };
  } ''
    set -eu
    rootfs=$PWD/rootfs; kpkg=$PWD/kernel-pkg
    mkdir -p "$rootfs" "$kpkg" "$out"

    # ---- Alpine linux-virt kernel + modules (libc-agnostic) ----
    tar -xzf ${kernelApk} -C "$kpkg" 2>/dev/null || true
    [ -f "$kpkg/boot/vmlinuz-virt" ] || { echo "FATAL: linux-virt APK lacked /boot/vmlinuz-virt" >&2; exit 1; }
    cp "$kpkg/boot/vmlinuz-virt" "$out/vmlinuz"
    mkdir -p "$rootfs/lib"
    [ -d "$kpkg/lib/modules" ] && cp -a "$kpkg/lib/modules" "$rootfs/lib/"

    # Decompress the 9p-over-virtio stack into /mods (dependency order) —
    # busybox insmod wants uncompressed .ko.  (Block/ext modules for the
    # overlay op are modprobe'd on demand from /lib/modules.)
    moddir=$(echo "$rootfs"/lib/modules/*)
    mkdir -p "$rootfs/mods"; i=0
    for m in fs/netfs/netfs net/9p/9pnet net/9p/9pnet_virtio fs/9p/9p; do
      src="$moddir/kernel/$m.ko.gz"
      [ -f "$src" ] && gzip -dc "$src" > "$rootfs/mods/$(printf '%02d' "$i")-$(basename "$m").ko" && i=$((i+1)) || true
    done

    # ---- Debian .deb data trees → rootfs (ar then data.tar.*) ----
    ${lib.concatMapStringsSep "\n" (name: ''
      ( tmp=$(mktemp -d); cd "$tmp"; ar x ${fetchedDebs.${name}}; \
        tar xf data.tar.* -C "$rootfs"; cd /; rm -rf "$tmp" )
    '') (builtins.attrNames fetchedDebs)}

    # busybox applet symlinks aren't created (no postinst); dispatcher.sh
    # runs `busybox --install -s /bin` at boot, but give it /bin/sh up front.
    [ -e "$rootfs/bin/sh" ] || ln -s busybox "$rootfs/bin/sh"

    mkdir -p "$rootfs"/{proc,sys,dev,tmp,shared,run,mnt,etc,nix/store}
    : > "$rootfs/etc/passwd"; : > "$rootfs/etc/group"
    cp ${dispatcher} "$rootfs/init"; chmod 755 "$rootfs/init"

    cd "$rootfs"
    find . -print0 | cpio --null --create --format=newc 2>/dev/null \
      | gzip -9 > "$out/initramfs.cpio.gz"
    echo "sidekick: vmlinuz=$(stat -c%s "$out/vmlinuz" 2>/dev/null || stat -f%z "$out/vmlinuz") initramfs=$(stat -c%s "$out/initramfs.cpio.gz" 2>/dev/null || stat -f%z "$out/initramfs.cpio.gz") bytes" >&2
  '';
}
