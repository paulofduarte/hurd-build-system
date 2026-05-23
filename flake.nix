{
  description = "Cross-compilation environment for GNU Mach";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-25.11";
  };

  outputs = { self, nixpkgs }:
    let
      # Host systems this flake supports. The build target is cross-compiled
      # and chosen via `nix develop .#<target>` — independent of host.
      supportedSystems = [
        "aarch64-darwin"
        "x86_64-darwin"
        "aarch64-linux"
        "x86_64-linux"
        "i686-linux"
        "armv6l-linux"
        "armv7l-linux"
        "riscv64-linux"
        "powerpc64le-linux"
      ];
      forAllSystems = f: nixpkgs.lib.genAttrs supportedSystems (system: f system);

      # Cross targets we know how to build for. Add an entry here to support
      # a new target; everything in mkDevShell consumes from this attrset.
      #
      #   crossSystem : nixpkgs cross-system identifier (drives the toolchain)
      #   migTarget   : the triple passed to MIG's --target= flag (CPU ABI;
      #                 Xen variants share this with their non-Xen siblings)
      #   platform    : value for gnumach's --enable-platform= ("at" / "xen"
      #                 on x86; null where the option doesn't apply, e.g.
      #                 aarch64)
      targets = {
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
      };

      # Build one dev shell for (host system, target).
      mkDevShell = system: name: target:
        let
          pkgs = nixpkgs.legacyPackages.${system};

          # GNU Mach is a freestanding microkernel — no libc, no hosted OS.
          # Use a bare-metal cross-toolchain for the chosen target.
          crossPkgs = import nixpkgs {
            localSystem = { inherit system; };
            crossSystem = target.crossSystem;
          };

          # The cross-toolchain's binary prefix (e.g. "aarch64-unknown-none-elf-").
          # Includes the trailing "-".
          toolPrefix = crossPkgs.stdenv.cc.targetPrefix;
        in
        crossPkgs.mkShell {
          nativeBuildInputs = [
            crossPkgs.stdenv.cc      # cross-toolchain (kernel)
            pkgs.gcc                 # native compiler for host tools (MIG)
            pkgs.autoconf
            pkgs.automake
            pkgs.gnumake
            pkgs.bison
            pkgs.flex
            pkgs.gawk          # MIG's cpu.sym is generated via awk
            pkgs.gnum4         # MIG's autoreconf needs m4
            pkgs.perl          # MIG's wrapper script uses perl at runtime
            pkgs.texinfo
            pkgs.git           # read-only ops + `git clean -fdX` for mrproper
            pkgs.nix           # so the Makefile can re-dispatch into a different target shell
            pkgs.qemu          # provides qemu-system-* for running the kernel
            pkgs.which         # gnumach's run-qemu.sh test runner uses `which` to gate test execution
            pkgs.starship      # nicer prompt inside the dev shell
            pkgs.bash-completion
          ]
          # gnumach's kernel-side `make check` (i.e. `make check-mach`)
          # builds a bootable ISO with grub-mkrescue (which itself needs
          # xorriso + mtools) and boots it under qemu-system-<arch>.  All
          # three targets we cross-build for use this path:
          #   x86_64 / i686 — grub-mkrescue's i386-pc target, multiboot1
          #   aarch64       — grub-mkrescue's arm64-efi target,
          #                   linux+initrd via the standard arm64 boot
          #                   protocol (gnumach reads
          #                   /chosen/linux,initrd-* from the DTB)
          # Pull these tools in only on Linux hosts — nixpkgs's grub2
          # has meta.platforms = linux-only; the upstream GRUB build
          # doesn't compile cleanly on darwin and nobody has packaged a
          # cross-build for it.  On a darwin host, `make check` errors
          # out at the Makefile level (see Makefile's check-mach rule);
          # use a Linux host (orbstack, docker, native) to run the full
          # test suite.
          ++ nixpkgs.lib.optionals
               ((target.crossSystem == "x86_64-elf"
                  || target.crossSystem == "i686-elf"
                  || target.crossSystem == "aarch64-none-elf")
                && nixpkgs.lib.hasSuffix "-linux" system)
               [ pkgs.grub2 pkgs.xorriso pkgs.mtools ];

          shellHook = ''
            # GCC 15+ defaults to C23 mode, which is stricter about function
            # types — `(*)()` no longer means "K&R unspecified" but `(void)`,
            # so older Mach code (parts of upstream + Bugaev's wip-aarch64)
            # fails to compile. Pin gnu17 globally so every target builds.
            export CFLAGS="-std=gnu17 -g -O2"

            # pkgs.gcc's setup-hook puts native binutils on PATH, whose
            # unprefixed `ld`/`ar`/`nm` shadow the cross ones. gnumach's
            # configure tries the host-triple prefix first, then falls back
            # to bare names — which would pick up the wrong (host) tools.
            # Pin every cross tool by absolute name so configure uses what
            # we actually want.
            export CC=${toolPrefix}gcc
            export LD=${toolPrefix}ld
            export AR=${toolPrefix}ar
            export NM=${toolPrefix}nm
            export RANLIB=${toolPrefix}ranlib
            export STRIP=${toolPrefix}strip
            export OBJCOPY=${toolPrefix}objcopy

            # Cross-target compiler MIG's configure picks up for the cpu.sym
            # build step.
            export TARGET_CC=${toolPrefix}gcc

            # Pin MIG so AC_CHECK_TOOL respects it instead of falling back to
            # bare `mig` (which doesn't exist).
            export MIG=${target.migTarget}-mig

            # Target identity for the top-level Makefile.
            export TARGET=${name}
            export GNUMACH_HOST=${target.crossSystem}
            export MIG_TARGET=${target.migTarget}
            ${if target.platform != null
              then "export GNUMACH_PLATFORM=${target.platform}"
              else "unset GNUMACH_PLATFORM"}

            # nix develop -i isolates env vars but doesn't change IN_NIX_SHELL,
            # so starship still shows "impure" even in a sandboxed shell. Detect
            # pure mode by the tell-tale empty HOME and correct the label.
            if [ -z "$HOME" ]; then
              export IN_NIX_SHELL=pure
            fi

            # Nix pure shells default TERM to "dumb" which kills colour and
            # most TUI features. Force a sane default.
            export TERM=xterm-256color

            # Local toolchain — anything installed here (MIG, etc.) becomes
            # visible to the next configure run. Enter the dev shell from
            # the project root for this to resolve correctly.
            export PATH="$PWD/toolchain/bin:$PATH"

            # Bash programmable completion.
            if [ -r "${pkgs.bash-completion}/share/bash-completion/bash_completion" ]; then
              source "${pkgs.bash-completion}/share/bash-completion/bash_completion"
            fi

            # Starship prompt.
            eval "$(${pkgs.starship}/bin/starship init bash)"

            # Compute the MIG label once, before the banner is printed.
            mig=$(command -v ${target.migTarget}-mig 2>/dev/null)
            mig_label=''${mig:+$(basename "$mig")}
            mig_label=''${mig_label:-(build in work/mig)}

            echo "========================================================"
            echo " GNU Mach Cross-Build Environment"
            echo " Target:    ${name} (--target=${target.migTarget})"
            ${if target.platform != null
              then ''echo " Platform:  ${target.platform} (--enable-platform)"''
              else ""}
            echo " Compiler:  $CC"
            echo " TARGET_CC: $TARGET_CC"
            echo " MIG:       $mig_label"
            echo " CFLAGS:    $CFLAGS"
            echo "========================================================"
            echo "Type 'make' to build, 'make help' for the full target list."
          '';
        };
    in
    {
      # `default` picks the target whose CPU matches the host, so `nix develop`
      # without an explicit `.#<name>` works out of the box. Override with
      # `nix develop .#x86_64` (or whichever) for a deliberate cross-target.
      devShells = forAllSystems (system:
        let
          shells = nixpkgs.lib.mapAttrs (name: target: mkDevShell system name target) targets;
          # Pick the cross-target whose ABI is closest to the host CPU.
          # Hosts without a matching cross-target (armv6l/armv7l/riscv64/
          # powerpc64le) fall through to aarch64 — the most generic 64-bit
          # default. Override with `nix develop .#<target>` for anything else.
          defaultName =
            if nixpkgs.lib.hasPrefix "aarch64-" system then "aarch64"
            else if nixpkgs.lib.hasPrefix "x86_64-" system then "x86_64"
            else if nixpkgs.lib.hasPrefix "i686-" system then "i686"
            else "aarch64";
        in
        shells // { default = shells.${defaultName}; }
      );
    };
}
