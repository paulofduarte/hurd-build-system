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
  # x86_64 grub2 (passed from the flake) — its i386-pc module blobs let us build
  # x86 BIOS boot media even on an aarch64 guest (grub's tools are cross-capable).
  # On an x86_64 guest this IS the native grub2.
  sidekickI386Grub,
  ...
}:

let
  # x86 boot-media tools (sidekick-mkrescue / sidekick-distro-iso) + their runtime
  # deps — shared verbatim with the Linux dev shell (flakes/sidekick/tools.nix).
  sidekickTools = import ./tools.nix {
    inherit pkgs;
    i386Grub = sidekickI386Grub;
  };
in
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
    # drive its target anyway); the guest self-powers-off on idle (see below).
    mem = 2048;
    storeOnDisk = true;
  };

  boot = {
    kernelModules = [ "virtiofs" ];
    # systemd-in-initrd (the scripted initrd is deprecated, removed in 26.11).
    initrd.systemd.enable = true;
  };

  # The audited sidekick tool set — exactly the tools with no darwin-native build.
  # (pahole was 'dwarves' in older nixpkgs.) The x86 boot-media tools + their deps
  # (grub2/xorriso/mtools/e2fsprogs/qemu-storage-daemon/util-linux/...) come from
  # the shared sidekickTools so the guest and the Linux dev shell stay identical.
  environment.systemPackages =
    (with pkgs; [
      glibc.bin # localedef
      libabigail # abidiff / abidw
      pahole # pahole
      kmod # modprobe
      fuse3 # fusermount3 (made setuid below for non-root FUSE)
    ])
    ++ sidekickTools.deps
    ++ [
      sidekickTools.sidekick-mkrescue
      sidekickTools.sidekick-imgcp
    ];

  # Hardening: commands run as an UNPRIVILEGED account with no password and no
  # sudo/wheel, so a compromised tool can't escalate inside the (already
  # network-less, project-only) sandbox. AVF virtiofs performs writes as the host
  # user regardless of the guest uid, so this account still has full project
  # access without any uid mapping. The `make run` distro boot needs NO root: it
  # reads the distro grub.cfg with debugfs (+ a FUSE qcow2 view) and boots our
  # gnumach via an external GRUB ISO over the UNMODIFIED disk (option 1) — never
  # mounting or editing the image.
  users.users = {
    sidekick = {
      isNormalUser = true; # no password set -> login locked except by SSH key
      description = "sidekick unprivileged exec account";
    };
    root.hashedPassword = "!"; # explicitly no root password
  };

  security = {
    # No privilege-escalation path: drop sudo entirely (nobody is in wheel, root
    # login is off, the sidekick user has no password) — no `sudo` to abuse.
    sudo.enable = false;
    sudo-rs.enable = false;
    # Non-root FUSE: qemu-storage-daemon's FUSE export mounts via fusermount3,
    # which must be setuid for the unprivileged sidekick user to mount.
    wrappers.fusermount3 = {
      source = "${pkgs.fuse3}/bin/fusermount3";
      owner = "root";
      group = "root";
      setuid = true;
    };
  };

  # --- exec channel: sshd over AF_VSOCK, no network device ---
  services.openssh = {
    enable = true;
    settings = {
      PasswordAuthentication = false;
      KbdInteractiveAuthentication = false;
      PermitRootLogin = "no"; # only the unprivileged sidekick user may log in
      AllowUsers = [ "sidekick" ];
    };
  };

  systemd = {
    services = {
      # Inject the authorized key from the cmdline (sidekick.authkey=<base64 pubkey>)
      # into the unprivileged sidekick user's home. Ordered as a prerequisite of the
      # per-connection sshd below (Requires/After), NOT hooked onto sockets.target —
      # touching sockets.target forms an ordering cycle that systemd breaks by
      # dropping the socket. The first connection waits for this to finish.
      sidekick-authkey = {
        wantedBy = [ "multi-user.target" ];
        after = [ "local-fs.target" ]; # the sidekick home must exist first
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
        };
        script = ''
          b64=$(${pkgs.gnused}/bin/sed -n 's/.*sidekick\.authkey=\([^ ]*\).*/\1/p' /proc/cmdline)
          [ -n "$b64" ] || { echo "sidekick: no authkey on cmdline" >&2; exit 0; }
          install -d -m700 -o sidekick -g users /home/sidekick/.ssh
          printf '%s' "$b64" | ${pkgs.coreutils}/bin/base64 -d > /home/sidekick/.ssh/authorized_keys
          chmod 600 /home/sidekick/.ssh/authorized_keys
          chown sidekick:users /home/sidekick/.ssh/authorized_keys
        '';
      };

      # Mount the virtiofs shares at their host-identical paths from the cmdline —
      # transparency without baking host paths into the closure. Two shares:
      #   sidekick.project=<abs path>  the repo (where build artefacts live)
      #   sidekick.cache=<abs path>    the host's XDG cache dir, where `nix run`
      #                                keeps distro images / ISO staging (outside
      #                                the repo tree). Always mounted so the
      #                                singleton VM serves every caller.
      # A prerequisite of the per-connection sshd, so commands see the shares.
      sidekick-mount-shares = {
        wantedBy = [ "multi-user.target" ];
        after = [
          "local-fs.target"
          "systemd-modules-load.service"
        ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
        };
        script = ''
          mount_one() { # <cmdline-key> <virtiofs-tag>
            p=$(${pkgs.gnused}/bin/sed -n "s/.*sidekick\.$1=\([^ ]*\).*/\1/p" /proc/cmdline)
            [ -n "$p" ] || return 0
            ${pkgs.coreutils}/bin/mkdir -p "$p"
            ${pkgs.util-linux}/bin/mount -t virtiofs "$2" "$p"
          }
          mount_one project project
          mount_one cache cache
        '';
      };

      # Per-connection sshd for the vsock socket below. It pulls in + waits for the
      # authkey and project-mount oneshots, so the key is present and the project
      # mounted before authentication/exec — no sockets.target ordering cycle.
      "sidekick-ssh@" = {
        description = "sidekick SSH per-connection over vsock";
        requires = [
          "sidekick-authkey.service"
          "sidekick-mount-shares.service"
        ];
        after = [
          "sidekick-authkey.service"
          "sidekick-mount-shares.service"
        ];
        serviceConfig = {
          ExecStart = "-${config.services.openssh.package}/bin/sshd -i -f /etc/ssh/sshd_config";
          StandardInput = "socket";
          StandardError = "journal";
        };
      };

      # Self-shutdown: the VM powers ITSELF off once the exec channel has been
      # idle, so nothing needs to run on the darwin host (no reaper to orphan; a
      # wedged host can't leave us running). "Idle" = no active per-connection
      # sshd instance, which naturally treats a long-running command as busy (it
      # holds a connection) — no host-side keepalive/timestamps needed. vfkit
      # exits when the guest powers off. Effective idle window seen by the user ~=
      # the host's ssh ControlPersist + this timeout.
      sidekick-idle = {
        description = "Power off the sidekick VM when the SSH channel is idle";
        wantedBy = [ "multi-user.target" ];
        serviceConfig = {
          Restart = "always";
          RestartSec = 5;
        };
        script = ''
          step=30
          idle=0
          limit=300
          while ${pkgs.coreutils}/bin/sleep "$step"; do
            n=$(${pkgs.systemd}/bin/systemctl list-units 'sidekick-ssh@*' \
                  --state=running --no-legend 2>/dev/null | ${pkgs.coreutils}/bin/wc -l)
            if [ "$n" -gt 0 ]; then idle=0; else idle=$((idle + step)); fi
            if [ "$idle" -ge "$limit" ]; then
              exec ${pkgs.systemd}/bin/systemctl poweroff
            fi
          done
        '';
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
