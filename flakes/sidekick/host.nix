# SPDX-FileCopyrightText: 2026 Paulo Duarte <paulofernandobd@gmail.com>
# SPDX-License-Identifier: GPL-3.0-or-later
# Sidekick host tools (darwin) — the `sidekick-run` dispatcher plus the guest
# artifacts it boots. The guest closure is Linux (built on CI, substituted from
# the cache on darwin); the dispatcher is a darwin script with stock vfkit/socat/
# openssh baked in. Wired from flake.nix per darwin host. See guest.nix.
{
  lib,
  hostPkgs, # darwin pkgs (vfkit/socat/openssh/bash run here)
  guestPkgs, # native-arch linux pkgs (the artifacts build here)
  guestConfig, # the sidekick nixosConfiguration's `config`
  linuxTarget, # kernel image name for the guest arch (Image / bzImage)
}:
let
  # The entire host->guest transfer: kernel + initrd + erofs store blob + a
  # GENERIC cmdline (no host path/key; the launcher appends sidekick.project= and
  # sidekick.authkey= at boot).
  sidekick-guest = guestPkgs.linkFarm "sidekick-guest" [
    {
      name = "kernel";
      path = "${guestConfig.microvm.kernel}/${linuxTarget}";
    }
    {
      name = "initrd";
      path = guestConfig.microvm.initrdPath;
    }
    {
      name = "store.img";
      path = guestConfig.microvm.storeDisk;
    }
    {
      name = "cmdline";
      path = guestPkgs.writeText "sidekick-cmdline" (
        "console=hvc0 reboot=t panic=-1 " + lib.concatStringsSep " " guestConfig.microvm.kernelParams
      );
    }
  ];

  # Launch vfkit under a recognizable name: `ps`/`pgrep` then show `sidekick-vm`
  # instead of a generic `vfkit` (the symlink preserves the binary's codesigned
  # virtualization entitlement). Activity Monitor still resolves it to `vfkit`,
  # and Apple's per-VM `com.apple.Virtualization.VirtualMachine` XPC helper is
  # system-owned and unrenameable — the singleton guard keeps it to exactly one.
  sidekick-vm = hostPkgs.runCommand "sidekick-vm" { } ''
    mkdir -p $out/bin
    ln -s ${lib.getExe hostPkgs.vfkit} $out/bin/sidekick-vm
  '';

  sidekick-run = hostPkgs.runCommand "sidekick-run" { } ''
    mkdir -p $out/bin
    substitute ${./sidekick-run.sh} $out/bin/sidekick-run \
      --replace-fail '@vfkit@'     '${sidekick-vm}/bin/sidekick-vm' \
      --replace-fail '@socat@'     '${lib.getExe hostPkgs.socat}' \
      --replace-fail '@ssh@'       '${hostPkgs.openssh}/bin/ssh' \
      --replace-fail '@sshkeygen@' '${hostPkgs.openssh}/bin/ssh-keygen' \
      --replace-fail '@artifacts@' '${sidekick-guest}'
    # Pin bash (macOS /usr/bin/env bash is 3.2); BSD userland (stat -f, seq, ...)
    # still comes from the host PATH on purpose.
    sed -i '1s|.*|#!${hostPkgs.bash}/bin/bash|' $out/bin/sidekick-run
    chmod +x $out/bin/sidekick-run
  '';
in
{
  inherit sidekick-run sidekick-guest;
}
