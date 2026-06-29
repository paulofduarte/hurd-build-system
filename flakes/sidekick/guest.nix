# SPDX-FileCopyrightText: 2026 Paulo Duarte <paulofernandobd@gmail.com>
# SPDX-License-Identifier: GPL-3.0-or-later
# Sidekick guest — a minimal NixOS microVM that transparently provides the
# Linux-only build tools darwin can't run natively. Built for the host's NATIVE
# Linux arch (aarch64-linux / x86_64-linux), driven by our own vfkit launcher
# (NOT microvm.nix's runner, which forces a pipe console + can't do vsock).
#
# Cacheability rule: this closure must contain NOTHING host-specific (no project
# path, no user key) so it builds once on CI and substitutes byte-identically on
# every darwin host. The project mountpoint and the authorized key are injected at
# boot via the kernel cmdline (sidekick.project=, sidekick.authkey=) by the
# launcher. See memory `sidekick-vfkit-vsock-spike`.
{
  pkgs,
  config,
  ...
}:

{
  # microvm.nix is the GUEST BUILDER only; we build kernel/initrd/storeDisk/
  # kernelParams from this config and drive vfkit ourselves.
  # No microvm.shares: the project mountpoint is host-specific (would make the
  # closure per-user) — mounted at runtime from the cmdline instead. No network
  # interfaces -> sandbox (vsock is independent of networking).
  microvm = {
    hypervisor = "vfkit";
    vcpu = 2;
    # mem is a ceiling, not a reservation — AVF allocates guest RAM on demand (an
    # idle 2GB guest costs the host ~0.5GB). No virtio-balloon (vfkit 0.6.3 can't
    # drive its target anyway); the idle-shutdown reaper is the real reclaim path.
    mem = 2048;
    storeOnDisk = true;
  };

  boot.kernelModules = [ "virtiofs" ];

  # The audited sidekick tool set — exactly the tools with no darwin-native build.
  # (pahole was 'dwarves' in older nixpkgs.)
  environment.systemPackages = with pkgs; [
    glibc.bin # localedef
    libabigail # abidiff / abidw
    pahole # pahole
    grub2 # grub-mkrescue (pulls xorriso/mtools itself)
    util-linux # mount
    kmod # modprobe
    e2fsprogs # mke2fs
  ];

  # --- exec channel: sshd over AF_VSOCK, no network device ---
  services.openssh = {
    enable = true;
    settings = {
      PasswordAuthentication = false;
      KbdInteractiveAuthentication = false;
      PermitRootLogin = "prohibit-password";
    };
  };

  systemd = {
    services = {
      # Inject the authorized key from the cmdline (sidekick.authkey=<base64 pubkey>).
      sidekick-authkey = {
        wantedBy = [ "multi-user.target" ];
        before = [ "sidekick-ssh.socket" ];
        wants = [ "sidekick-ssh.socket" ];
        unitConfig.DefaultDependencies = false;
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
        };
        script = ''
          b64=$(${pkgs.gnused}/bin/sed -n 's/.*sidekick\.authkey=\([^ ]*\).*/\1/p' /proc/cmdline)
          [ -n "$b64" ] || { echo "sidekick: no authkey on cmdline" >&2; exit 0; }
          install -d -m700 /root/.ssh
          printf '%s' "$b64" | ${pkgs.coreutils}/bin/base64 -d > /root/.ssh/authorized_keys
          chmod 600 /root/.ssh/authorized_keys
        '';
      };

      # Mount the project virtiofs share at the host-identical path from the cmdline
      # (sidekick.project=<abs path>) — transparency without baking the path.
      sidekick-mount-project = {
        wantedBy = [ "multi-user.target" ];
        before = [ "sidekick-ssh.socket" ];
        after = [ "systemd-modules-load.service" ];
        unitConfig.DefaultDependencies = false;
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
        };
        script = ''
          p=$(${pkgs.gnused}/bin/sed -n 's/.*sidekick\.project=\([^ ]*\).*/\1/p' /proc/cmdline)
          [ -n "$p" ] || { echo "sidekick: no project path on cmdline" >&2; exit 0; }
          ${pkgs.coreutils}/bin/mkdir -p "$p"
          ${pkgs.util-linux}/bin/mount -t virtiofs project "$p"
        '';
      };

      # Per-connection sshd for the vsock socket below.
      "sidekick-ssh@" = {
        description = "sidekick SSH per-connection over vsock";
        serviceConfig = {
          ExecStart = "-${config.services.openssh.package}/bin/sshd -i -f /etc/ssh/sshd_config";
          StandardInput = "socket";
          StandardError = "journal";
        };
      };
    };

    # Socket-activated sshd on vsock port 2222. Custom unit name (NOT sshd-vsock,
    # which systemd-ssh-generator reserves -> NixOS would degrade it to a drop-in
    # over a non-existent base unit). CID_ANY accepts the host-bridged connection.
    sockets.sidekick-ssh = {
      description = "sidekick SSH over AF_VSOCK";
      wantedBy = [ "sockets.target" ];
      socketConfig = {
        ListenStream = "vsock:4294967295:2222"; # VMADDR_CID_ANY:2222
        Accept = "yes";
      };
    };
  };

  # Headless: no getty noise needed, but keep the console on hvc0 (launcher points
  # it at a logfile). Trim the closure a little.
  documentation.enable = false;
  system.stateVersion = "24.11";
}
