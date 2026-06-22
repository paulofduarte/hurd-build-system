# SPDX-FileCopyrightText: 2026 Paulo Duarte <paulofernandobd@gmail.com>
# SPDX-License-Identifier: GPL-3.0-or-later
# glibc-hurd - per-target Hurd C library derivation.
# (See .claude/docs/build/HURD-TOOLCHAIN-DESIGN.md for the overall plan.)
#
# Builds vanilla upstream glibc 2.43 from the pinned `glibc-src` flake input,
# configured for the Hurd target via `--host=<cpu>-gnu`.  glibc 2.43 has the htl
# (Hurd Threading Library) port built in - no separate `libpthread` add-on.
#
# A standalone derivation (not `nixpkgs.glibc.override`): nixpkgs' glibc bakes in
# Linux-specific assumptions (post-install hooks, linker-script rewrites, audit-
# libs propagation) plus a hard `meta.platforms = lib.platforms.linux` gate that
# refuses Hurd at eval time.  Working around all of it means rewriting most of the
# derivation anyway; a fresh one against vanilla glibc is cleaner - the standard
# build dance is ~20 lines (out-of-tree build dir, configure, make + make install).
#
# Outputs:
#   $out/lib/libc.so.0.3                 the Hurd libc SONAME
#                                        (vs Linux's libc.so.6)
#   $out/lib/libpthread.so.0.3           Hurd pthread
#   $out/lib/ld.so.1 (i686) /            dynamic linker, per-arch
#     ld-x86-64.so.1 (x86_64)
#   $out/lib/{crt1.o,crti.o,crtn.o}      C runtime startup objects
#   $out/include/{stdio.h,stdlib.h,...}  the full glibc header tree
#   $out/include/hurd/, mach/             headers propagated from
#                                        hurd-headers + gnumach-headers
#
# Toolchain inputs come from the from-source cross toolchain:
#   bootstrap-gcc (gcc.nix) + cross-binutils (binutils.nix)
#   gnumach-headers + hurd-headers    sibling flakes
#   mig                               sibling flake
#
# The combined sysroot include tree is built in preConfigure by symlink-farming
# gnumach-headers + hurd-headers into one directory, so
# `--with-headers=$sysroot/include` sees both as one GNU/Hurd installation.

{
  nixpkgs,
  system,
  targets,
  mig,
  gnumachHeaders,
  hurdHeaders,
  srcInput,
  # The from-source toolchain: `binutils` = the cross-binutils-<name> attrset,
  # `bootstrapGcc` = the
  # bootstrap-gcc-<name> attrset (the default buildCC).  Both reached by ABSOLUTE
  # PATH - the cc is unwrapped (bakes --with-as/--with-ld -> binutils), no nix
  # cc/bintools-wrapper, so none of the meta-gate dodge or salted NIX_* channels
  # the old path needed apply here.
  binutils,
  bootstrapGcc,
  # Which cross-cc builds this glibc, as a `name: target: cc` function (referenced
  # by absolute path for CC=, so pass a derivation with bin/<tp>-gcc).  Default = the
  # from-source libc-free bootstrap-gcc (single-glibc model: cross-gcc consumes this
  # glibc's ABI, no separate shipped-glibc builder).
  buildCC ? (name: _target: bootstrapGcc."bootstrap-gcc-${name}"),
}:

let
  pkgs = nixpkgs.legacyPackages.${system};
  inherit (nixpkgs) lib;
  # Shared cross-build determinism flags (the SAME source the dev-shell +
  # gnumach/hurd use), fed through NIX_CFLAGS_COMPILE below so the nix glibc comes
  # out byte-identical cross-host, like the in-tree build.
  buildFlags = import ./build-flags.nix { inherit lib; };

  # glibc configure extras (inlined - glibc-config.nix had no other consumer):
  #  - libc_cv_ctors_header=yes: skip a crt ctor-section link test that needs a
  #    working libc (unavailable on the first cross pass).
  #  - the rest pin the DEPLOYABLE /-rooted install layout: with --prefix=/ alone
  #    glibc derives //lib, //etc, ...; pin every install dir + glibc's own libc_cv_*
  #    path cache vars to clean /-paths.  NOT wrapper-related (unaffected by the
  #    wrapper removal) - this is the Hurd-system layout the dist ships: libc.so /
  #    ld.so in /lib, locales in /lib/locale, headers in /include.
  glibcConfigFlags = [
    "libc_cv_ctors_header=yes"
    "--libdir=/lib"
    "--sysconfdir=/etc"
    "--datarootdir=/share"
    "--localstatedir=/var"
    "--sbindir=/sbin"
    "--bindir=/bin"
    "--libexecdir=/libexec"
    "--includedir=/include"
    "libc_cv_slibdir=/lib"
    "libc_cv_rtlddir=/lib"
    "libc_cv_complocaledir=/lib/locale"
    "libc_cv_sysconfdir=/etc"
    "libc_cv_localstatedir=/var"
    "libc_cv_rootsbindir=/sbin"
  ];

  # Patched (deterministic) install-info - the SAME one the dev-shell uses
  # (texinfo-det.nix).  glibc's `make install` runs install-info to build
  # share/info/dir; the unpatched upstream comparator is host-dependent + writes a
  # different default header, so the shipped dir diverges.  The patch makes it
  # identical and reproducible.
  texinfoDet = import ./texinfo-det.nix { inherit pkgs; };

  # glibc's version lives in version.h as `#define VERSION "2.43"`, not in
  # configure.ac or a version.m4 - parse it with a regex match.
  upstreamVersion =
    let
      content = builtins.readFile (srcInput + "/version.h");
      m = builtins.match ".*define VERSION \"([0-9.]+)\".*" content;
    in
    if m == null then "unknown" else builtins.head m;

  # Userland targets only (the non-xen ones - i686, x86_64).
  hurdTargets = lib.filterAttrs (_name: target: (target.platform or null) != "xen") targets;

  mkOne =
    name: target:
    let
      # The from-source toolchain, reached by ABSOLUTE PATH (cc unwrapped; binutils
      # tools from crossBinu/bin) - so no nix cc/bintools-wrapper setup-hook runs,
      # which is what made the old path need the meta-gate dodge + the salted NIX_*
      # channels.  crossCC bakes --with-as/--with-ld -> crossBinu already.
      crossCC = buildCC name target;
      crossBinu = binutils."cross-binutils-${name}";
      crossMig = mig."mig-${name}";
      gnumach-headers = gnumachHeaders."gnumach-headers-${name}";
      hurd-headers = hurdHeaders."hurd-headers-${name}";
      pname = "glibc-hurd-${target.crossTarget}";
      tp = target.crossTarget;
      buildTriple = pkgs.stdenv.hostPlatform.config;
    in
    # Native (host) stdenv - glibc IS the cross libc, can't be built by a
    # cross-stdenv that requires libc to bootstrap.  Cross tools come via explicit
    # env vars in preConfigure (matches cross-hurd's bootstrap-funcs.sh).
    pkgs.stdenv.mkDerivation (
      {
        inherit pname;
        version = upstreamVersion;
        # `out` = the installed glibc.  `buildtree` = the writable src+build/ tree,
        # kept as a SECOND output of this one build so hurd-stubs.nix can copy it,
        # swap the alias RPC headers, and re-link ONLY libmachuser/libhurduser (~30s)
        # without recompiling glibc - the rt-base pattern.  Previously this was a
        # separate `buildTree=true` derivation, i.e. a whole second glibc compile.
        # `buildtree` is irreproducible (sandbox paths + config.log timestamps) and
        # input-addressed; consumed only by hurd-stubs.nix, never shipped.
        outputs = [
          "out"
          "buildtree"
        ];
        src = srcInput;

        # rtld.c: walk _environ directly in process_envvars_secure, else the ld.so
        # link fails with undefined `getenv` when cross-building from a non-Linux
        # host.  See the patch preamble.
        patches = [ ./patches/01-rtld-getenv-walk-environ.patch ];

        # Host-side build tools.  No autoreconf - glibc ships a working configure.
        # patchelf: glibc's Makerules probes `patchelf --version` + runs
        # `--clear-execstack` per installed .so; without it on PATH the install logs
        # "patchelf: command not found".  NOTE: glibc gates the actual scrub on
        # patchelf >= 0.18.0 and nixpkgs ships 0.15.2, so this silences the probe but
        # the scrub still skips until patchelf is overridden to >= 0.18.0.
        nativeBuildInputs =
          (with pkgs; [
            bison
            perl
            gawk
            python3
            gettext
            gnumake
          ])
          ++ [ texinfoDet ]
          ++ buildFlags.commonNativeBuildInputs pkgs;

        # buildInputs only carries derivations whose meta.platforms allows the Hurd
        # target (our own per-target outputs).  The cross-cc + cross-binutils are
        # reached by absolute path in configurePhase to dodge the wrapped binutils'
        # libc_bin dep -> meta.platforms gate.
        buildInputs = [
          crossMig
          gnumach-headers
          hurd-headers
        ];

        # glibc REQUIRES an out-of-tree build dir.  Sets up the combined sysroot
        # include tree (gnumach + hurd headers symlink-farmed) and the build dir,
        # and exports the cross-toolchain tool names for glibc's configure.
        configurePhase = ''
          runHook preConfigure

          # Combined headers sysroot - glibc's --with-headers wants ONE
          # path containing both Mach + Hurd .h files.  Using cp -rs
          # (symlink farm) keeps the closure size down vs cp -r.
          mkdir -p $TMPDIR/sysroot/include
          cp -rs ${gnumach-headers}/include/. $TMPDIR/sysroot/include/
          chmod -R u+w $TMPDIR/sysroot/include
          cp -rs ${hurd-headers}/include/.    $TMPDIR/sysroot/include/
          chmod -R u+w $TMPDIR/sysroot/include

          # Cross toolchain - glibc's configure honours these explicit env vars
          # (matches cross-hurd's bootstrap-funcs.sh).  The from-source cc is unwrapped
          # and bakes --with-as/--with-ld -> crossBinu; the AR/AS/... here pin the same
          # binutils by absolute path for glibc's archive/link steps.  CXX points at the
          # bootstrap cc's (absent) g++ - it is C-only, so glibc's configure detects a
          # non-working C++ and disables the C++ test suite (not built here anyway).
          export BUILD_CC=${pkgs.stdenv.cc}/bin/cc
          export CC=${crossCC}/bin/${tp}-gcc
          export CXX=${crossCC}/bin/${tp}-g++
          export AR=${crossBinu}/bin/${tp}-ar
          export AS=${crossBinu}/bin/${tp}-as
          export LD=${crossBinu}/bin/${tp}-ld
          export NM=${crossBinu}/bin/${tp}-nm
          export OBJCOPY=${crossBinu}/bin/${tp}-objcopy
          export OBJDUMP=${crossBinu}/bin/${tp}-objdump
          export RANLIB=${crossBinu}/bin/${tp}-ranlib
          export READELF=${crossBinu}/bin/${tp}-readelf
          export STRIP=${crossBinu}/bin/${tp}-strip

          # Out-of-tree build dir.  glibc's configure aborts hard if
          # invoked from $srcdir.
          mkdir -p build
          cd build

          # Cross-host + in-tree==nix determinism: map every host-varying / build-
          # method-specific root out of glibc's DWARF so the result is identical in any
          # combination of {darwin,linux} x {in-tree,nix}:
          #   debugPrefixMapUnwrapped : the from-source gcc + binutils store paths (gcc's
          #     internal include dir leaks into DWARF) -> /cross-gcc, /cross-binutils.
          #   ${buildFlags.glibcCanonBuild} <- $PWD (build dir - nix's is a SANDBOX temp,
          #     host-varying, so load-bearing for nix cross-host).
          #   ${buildFlags.glibcCanonSrc} <- $src (the source root, /nix/store/-source).
          #   ${buildFlags.glibcCanonSysroot} <- $TMPDIR/sysroot (combined headers; also a
          #     host-varying sandbox temp).
          #
          # The maps go in CPPFLAGS, NOT CFLAGS.  glibc applies $(CFLAGS) only to .c
          # compiles but $(CPPFLAGS) to BOTH .c and .S - and the .S objects (crt*.o,
          # Scrt1.o, ...) are assembled by GNU as, whose DWARF comp_dir would otherwise
          # embed the RAW $src store path (= the glibc source leaking into the closure).
          # CPPFLAGS reaches every compile, so gcc passes --debug-prefix-map down to as
          # too - mirroring what the old cc-wrapper's universal NIX_CFLAGS_COMPILE
          # injection did for free.  CFLAGS keeps only the -g -O2 base.
          #
          # No -frandom-seed: the raw cc never sees the reproducible-builds hook's $out
          # seed (it reads CFLAGS/CPPFLAGS, not the wrapper's NIX_CFLAGS_COMPILE), and
          # gcc's default seed is output-name-derived = deterministic (proven by the
          # bootstrap matrix).  ORDER: -ffile-prefix-map is last-match-wins, so the
          # specific "$PWD/hurd/." (collapses the Machrules `./` vpath that makes
          # libhurduser's DWARF build-order-dependent - `$(objpfx)./`) MUST come after
          # the general "$PWD" build-dir map - keep it the very last map.
          export CFLAGS="${buildFlags.baseCflags}"
          export CPPFLAGS="${
            buildFlags.debugPrefixMapUnwrappedStr {
              gcc = crossCC;
              binutils = crossBinu;
            }
          } -ffile-prefix-map=$PWD=${buildFlags.glibcCanonBuild} -ffile-prefix-map=$src=${buildFlags.glibcCanonSrc} -ffile-prefix-map=$TMPDIR/sysroot=${buildFlags.glibcCanonSysroot} -ffile-prefix-map=$PWD/hurd/.=${buildFlags.glibcCanonBuild}/hurd"

          # Configure.  No --disable-werror: the from-source gcc builds the Hurd glibc
          # clean (confirmed by the cross-host matrix).  libc_cv_ctors_header=yes
          # pre-declares the crt*.o ctor-section detection - the link test it replaces
          # needs a working libc, unavailable on the first cross pass.
          $src/configure \
            --build=${buildTriple} \
            --host=${tp} \
            --prefix=/ \
            --with-headers=$TMPDIR/sysroot/include \
            --with-binutils=${crossBinu}/bin \
            ${lib.concatStringsSep " " glibcConfigFlags}

          runHook postConfigure
        '';

        # glibc emits per-subdir `stamp.os` (shared) and `stamp.oS` (static-nonshared)
        # sentinels that differ only in case, so the BUILD itself needs a case-sensitive
        # sandbox (the nix store volume must be case-sensitive APFS, or any Linux fs).
        # The SHIPPED buildtree is canonicalised collision-free in postInstall (the .oS
        # stamp is renamed), so downstream consumers (hurd-stubs) work even on a case-
        # insensitive filesystem.
        enableParallelBuilding = true;

        # Keep glibc's `-g` DWARF (don't let stdenv strip it): debugging /
        # historical ABI analysis want DWARF on the real libraries directly
        # instead of unstripped twins.
        # Stripping for a release artifact is a dist-phase concern (no dist-glibc
        # today - glibc is a toolchain component, not a shipped artifact).
        # See TOOLCHAIN-LIBC-DECOUPLING.md / task #197.
        dontStrip = true;

        # patchelf is in nativeBuildInputs for glibc's own `--clear-execstack` step,
        # but pulling it in also registers patchelf's `--shrink-rpath` setup-hook.
        # We don't want that mutating the cross libc's .so RPATHs (output stability),
        # and it spams "shrinking RPATHs ..." over the tree (harmless).  `dontPatchELF`
        # guards ONLY that shrink hook - glibc's own patchelf call is unaffected.
        dontPatchELF = true;

        # audit-tmpdir is a SEPARATE hook (NOT covered by dontPatchELF): it runs
        # `patchelf --print-rpath` on every ELF to catch RPATHs leaking the build
        # sandbox.  On the buildtree - a raw glibc OBJDIR of thousands of .o/.os
        # ET_REL relocatables - patchelf rejects each one with "patchelf: wrong ELF
        # type" (~9k lines of noise; a relocatable carries no RPATH, so there is
        # nothing to check anyway).  Disable the blanket hook and re-run the check on
        # $out alone in postFixup: the buildtree is an in-sandbox intermediate
        # (consumed only by hurd-stubs, which is itself audited), so it needs no
        # separate purity gate of its own.
        noAuditTmpdir = true;

        # Smoke-validate the deliverable: libc.so.0.3 (Hurd SONAME, NOT libc.so.6) +
        # the per-arch dynamic linker; fails early on a wrong install layout.
        # glibc install-headers lays down glibc's own headers + the mig RPC stubs,
        # but not the gnumach/hurd headers (e.g. bits/sigcontext.h includes
        # mach/machine/fp_reg.h from gnumach-headers).  A consumer treating this as
        # the cross sysroot (gcc's libcCross, the wrapped cc) needs the complete
        # GNU/Hurd include tree, so merge them in.  cp -an preserves the
        # mach/machine -> <arch> symlink and keeps glibc's own headers on overlap
        # (built against these exact headers - no version skew).
        postInstall = ''
          # Merge in the gnumach + hurd headers (cp -a preserves the
          # mach/machine -> <arch> symlink; -n keeps glibc's own on any
          # overlap).  chmod between copies because each cp finalises the
          # dirs it creates read-only, which would block the next one.
          chmod -R u+w $out/include
          cp -an ${gnumach-headers}/include/. $out/include/ ; chmod -R u+w $out/include
          cp -an ${hurd-headers}/include/.    $out/include/ ; chmod -R u+w $out/include

          # Augment the libc.so linker script so `-lc` also pulls the Mach
          # + Hurd RPC stub libraries.  libc.so.0.3 has undefined refs to
          # __mach_port_*, __io_*, __proc_*, __file_* ... which live in
          # libmachuser / libhurduser; without adding them to the GROUP,
          # every Hurd userland link fails on those undefined references.
          # (Same step as Guix's augment-libc.so.)  Restrict the sed to
          # the GROUP line so OUTPUT_FORMAT(...) - which also ends in ')'
          # - is untouched.
          sed -i "/^GROUP/ s|)\$| /lib/libmachuser.so /lib/libhurduser.so )|" \
            $out/lib/libc.so

          # i386: gcc's vanilla interpreter is /lib/ld.so (config/i386/gnu.h
          # GNU_USER_DYNAMIC_LINKER) but glibc names the loader ld.so.1, and
          # upstream installs no /lib/ld.so.  Add the bridge symlink - the same
          # packaging step Debian/Gentoo glibc do.  Self-gated on ld.so.1, so it's
          # a no-op on x86_64 (loader is ld-x86-64.so.1, which gcc emits directly).
          [ -e $out/lib/ld.so.1 ] && ln -sf ld.so.1 $out/lib/ld.so || true

          ls $out/lib/libc.so.0.3               || { echo "ERROR: libc.so.0.3 missing"; exit 1; }
          ls $out/include/stdio.h               || { echo "ERROR: stdio.h missing"; exit 1; }
          ls $out/include/mach/machine/fp_reg.h || { echo "ERROR: mach kernel headers not merged"; exit 1; }
          grep -q libmachuser $out/lib/libc.so  || { echo "ERROR: libc.so not augmented"; exit 1; }

          # Second output (buildtree): the build/ OBJDIR ONLY, for hurd-stubs' fast
          # stub re-link.  $PWD is the build dir.  We deliberately DON'T ship the
          # source root: glibc is an objdir build (build/Makefile does `make -C
          # $(srcdir)`), so a copy of the source here would be dead weight.
          #
          # We also canonicalise the glibc SOURCE store path ($src) out of the kept
          # make files (-> the @GLIBC_SRCDIR@ sentinel) so the buildtree does NOT
          # reference it.  Otherwise the buildtree's closure would drag the (large,
          # re-fetchable-from-upstream) source into the binary cache.  hurd-stubs.nix
          # substitutes @GLIBC_SRCDIR@ with a fresh source checkout at build time.
          # The .o/.d files already carry the canonical /glibc-src (configure's
          # -ffile-prefix-map), not $src, so only a handful of make files match.
          # config.log / debugglibc.sh are pure artefacts that also bake $src - drop
          # them.  All rewrites are mtime-preserving (sed-to-temp + touch -r + mv,
          # also dodging BSD sed's lack of -i) so hurd-stubs' make still sees only the
          # stub targets as stale.
          mkdir -p $buildtree
          cp -a . $buildtree/build
          rm -f $buildtree/build/config.log $buildtree/build/debugglibc.sh
          # config.status alone wraps long S["VAR"]="..." values with autoconf's
          # `"<NL>"` adjacent-string splits, at a column that depends on the value's
          # LENGTH - so the sandbox path lands split mid-token across lines (and the wrap
          # column itself shifts with $NIX_BUILD_TOP's length), which the line-based seds
          # below cannot canonicalise.  Rejoin those splits first, but ONLY where the next
          # line resumes with `"` (the concat pattern) so the ac_cs_usage / ac_cs_version
          # here-text - which also opens with `"\` but continues in plain text - is left
          # intact.  A joined value is byte-for-byte the same string and width-independent.
          # config.status is dormant (config.make is mtime-pinned, so its rule never
          # re-runs) but must still be reproducible.  mtime-preserving.
          if [ -f $buildtree/build/config.status ]; then
            cs=$buildtree/build/config.status
            awk '
              function flush() { print buf; buf = "" }
              {
                if (buf == "") { buf = $0 }
                else if (buf ~ /"\\$/ && $0 ~ /^"/) {
                  sub(/"\\$/, "", buf); sub(/^"/, "", $0); buf = buf $0
                } else { flush(); buf = $0 }
              }
              END { if (buf != "") flush() }
            ' "$cs" > "$cs.tmp" && touch -r "$cs" "$cs.tmp" && mv -f "$cs.tmp" "$cs"
          fi
          for f in $(grep -rlIF "$src" $buildtree/build 2>/dev/null); do
            sed "s|$src|@GLIBC_SRCDIR@|g" "$f" > "$f.tmp" \
              && touch -r "$f" "$f.tmp" && mv -f "$f.tmp" "$f"
          done
          # The kept make files + generated dep files also bake the EPHEMERAL build-
          # sandbox top ($NIX_BUILD_TOP) as absolute paths: config.make's sysheaders /
          # sysincludes (-I/-isystem <top>/sysroot/include), its -ffile-prefix-map flags,
          # and ~7k *.d/*.dt/*.udeps dependency files listing <top>/sysroot/include/mach/
          # *.h as prereqs.  $NIX_BUILD_TOP varies per build (darwin's per-build sandbox
          # dirs) and differs from linux's fixed /build, so leaving it makes the buildtree
          # non-reproducible across builds AND hosts.  Canonicalise it to a stable sentinel
          # (text files only - the .o/.os DWARF was already -ffile-prefix-map'd to
          # /glibc-{build,sysroot,src}, never the sandbox top, so no binary is touched).
          # hurd-stubs' consumption-time remap reads the -isystem <sentinel>/sysroot path
          # straight out of config.make and repoints it at its real sysroot; the dep-file
          # prereqs are glibc -MP phony targets, so the now-canonical (absent) paths are
          # tolerated.  mtime-preserving, as above.
          for f in $(grep -rlIF "$NIX_BUILD_TOP" $buildtree/build 2>/dev/null); do
            sed "s|$NIX_BUILD_TOP|/glibc-buildtop|g" "$f" > "$f.tmp" \
              && touch -r "$f" "$f.tmp" && mv -f "$f.tmp" "$f"
          done
          # Two more buildtree-only non-determinisms, both darwin-specific:
          #
          # (a) gcc bakes the WRAP COLUMN of its -MD dependency output from the raw
          #     compile-time path length; darwin's per-build sandbox dir varies in
          #     length, so the *.d/*.dt line-wrapping (where the `\`-continuations fall)
          #     differs build-to-build even after the path TEXT is canonicalised above.
          #     Unfold the continuations - join every `\`-terminated line with its
          #     successor - so each make rule is one line.  Joining alone is NOT enough:
          #     gcc's wrap leaves a position-dependent run of spaces at each fold point
          #     (`errno.o: errno.c` vs `errno.o:  errno.c`), so ALSO squeeze every
          #     whitespace run to a single space - then the rule is wrap- and length-
          #     independent, identical on darwin and linux.  The -MP phony targets
          #     (`hdr:`) end in `:` not `\`, so they stay separate.  mtime-preserving.
          find $buildtree/build \( -name '*.d' -o -name '*.dt' \) -print | while IFS= read -r f; do
            awk '{ while (sub(/\\$/, "")) { if ((getline nl) > 0) $0 = $0 nl; else break } gsub(/[ \t]+/, " "); print }' \
              "$f" > "$f.tmp" && touch -r "$f" "$f.tmp" && mv -f "$f.tmp" "$f"
          done
          #
          # (b) glibc emits a per-subdir `stamp.os` (shared) AND `stamp.oS` (static-
          #     nonshared) sentinel that differ only in case.  On a case-sensitive store
          #     both ship plainly, but nix's use-case-hack (darwin default-on) renames
          #     one with a ~nix~case~hack~N suffix NON-deterministically at store-
          #     registration (after this postInstall, so unfixable from here).  Rename
          #     the .oS member to a non-colliding name so the canonical buildtree has
          #     ZERO case collisions: deterministic on a case-sensitive store (no hack to
          #     apply) AND restorable on a case-INSENSITIVE store (no collision in the
          #     NAR) - letting stock macOS consume the buildtree.  These are empty
          #     existence-sentinels; hurd-stubs renames them back before `make` (mv keeps
          #     the mtime, so the "only the stubs rebuild" invariant holds; on a case-
          #     insensitive fs the rename-back just collapses onto stamp.os, which make
          #     tolerates - both targets are satisfied by the single file).
          find $buildtree/build -name 'stamp.oS' -print | while IFS= read -r f; do
            mv "$f" "$f.nixcase"
          done
          # A few glibc TEST-support objects (support/support_paths.oS, test-container,
          # ...) bake $src as a -DSRCDIR STRING macro, not a DWARF path, so the
          # -ffile-prefix-map can't canonicalise it and the text sed above (-I = skip
          # binary) doesn't touch them.  They're the test harness - not used by the
          # stub relink - so drop any file still carrying $src; hurd-stubs' make
          # rebuilds whatever it actually needs from the supplied source.  Otherwise
          # they'd pin the (re-fetchable) source into the binary cache.
          for f in $(grep -rlaF "$src" $buildtree/build 2>/dev/null); do rm -f "$f"; done
        '';

        # The blanket audit-tmpdir hook is off (noAuditTmpdir, above) to spare the
        # buildtree's relocatables; re-run the build-sandbox-reference check on the
        # shipped libc, where it is both cheap and meaningful.
        postFixup = ''
          auditTmpdir "$out"
        '';

        # No meta.platforms restriction - only built for the non-xen userland targets
        # anyway.
        passthru = { inherit target; };
        meta = with lib; {
          description = "GNU C Library for ${tp} (Hurd port)";
          platforms = platforms.all;
          license = licenses.lgpl21Plus;
        };
      }
      // {
        installFlags = [ "DESTDIR=${placeholder "out"}" ];
        dontMoveSbin = true;
        # No DT_RUNPATH to suppress: the from-source cc links via its baked --with-ld =
        # our RAW cross-binutils ld (no nix ld-wrapper), which never auto-bakes a
        # /nix/store rpath.  (The old wrapped path needed NIX_DONT_SET_RPATH to strip
        # exactly that store DT_RUNPATH; dropping the wrapper removes the leak at source.
        # libmachuser/libhurduser etc. link against the just-built libc in the build
        # tree, not a prior store glibc, so there is no store path to leak anyway.)
        # glibc's helper scripts (bin/{ldd,tzselect,xtrace,sotruss,mtrace}) ship a
        # portable shebang from their *.in source; nixpkgs' patchShebangs rewrites it
        # to a /nix/store bash, the lone store leak left in a deployed tree.  These
        # scripts run on the TARGET, so disable the rewrite and keep the /-rooted
        # shebang (fixed at build, no dist sed).
        dontPatchShebangs = true;
      }
    );
in
lib.mapAttrs' (name: target: lib.nameValuePair "glibc-hurd-${name}" (mkOne name target)) hurdTargets
