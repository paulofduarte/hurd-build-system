#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Paulo Duarte <paulofernandobd@gmail.com>
# SPDX-License-Identifier: GPL-3.0-or-later
# abi-level: deep
# Probe 21 - the public, standalone headers still self-include (C and
# C++).  A header that stops compiling alone (a moved declaration, a
# dropped transitive include) breaks consumers even with libc.so intact.
#
# Scope: the curated set of headers that are *meant* to be included
# directly (ISO C + POSIX + common XSI).  We deliberately do NOT walk the
# whole include/ tree - glibc's Hurd port installs many internal
# server/implementation headers (hurd/diskfs.h, mach/boot.h, ...) that are
# not standalone-includable by contract, exactly as glibc's own
# scripts/check-installed-headers.sh excludes them.  When the working
# glibc source is reachable ($GLIBC_SRC) we note its exhaustive checker.
set -u
[ -n "${CROSS_CC:-}" ] && [ -x "$CROSS_CC" ] || { echo "SKIP 21-check-installed-headers - no cross cc"; exit 0; }
[ -d "$WORK/include" ] || { echo "SKIP 21-check-installed-headers - no include tree"; exit 0; }
td="$PROBE_TMP/21"; mkdir -p "$td"
cxx="${CROSS_CC%gcc}g++"

public='assert.h complex.h ctype.h errno.h fenv.h float.h inttypes.h iso646.h
        limits.h locale.h math.h setjmp.h signal.h stdarg.h stddef.h stdint.h
        stdio.h stdlib.h string.h tgmath.h time.h wchar.h wctype.h
        aio.h dirent.h dlfcn.h fcntl.h fmtmsg.h fnmatch.h ftw.h glob.h
        grp.h iconv.h langinfo.h libgen.h monetary.h netdb.h nl_types.h
        poll.h pthread.h pwd.h regex.h sched.h search.h semaphore.h
        spawn.h strings.h syslog.h termios.h ulimit.h unistd.h utmp.h wordexp.h
        arpa/inet.h net/if.h netinet/in.h netinet/tcp.h
        sys/ipc.h sys/mman.h sys/msg.h sys/resource.h sys/select.h sys/sem.h
        sys/shm.h sys/socket.h sys/stat.h sys/statvfs.h sys/time.h sys/times.h
        sys/types.h sys/uio.h sys/un.h sys/utsname.h sys/wait.h'

fails=()
n_c=0
for h in $public; do
  [ -f "$WORK/include/$h" ] || continue
  n_c=$((n_c+1))
  if ! echo "#include <$h>" | "$CROSS_CC" -fsyntax-only -D_ISOMAC \
        -isystem "$WORK/include" -x c - 2>"$td/e"; then
    grep -qiE 'error:' "$td/e" && fails+=("$h (C)")
  fi
done

n_cxx=0
if [ -x "$cxx" ]; then
  for h in $public; do
    [ -f "$WORK/include/$h" ] || continue
    n_cxx=$((n_cxx+1))
    if ! echo "#include <$h>" | "$cxx" -fsyntax-only -D_ISOMAC \
          -isystem "$WORK/include" -x c++ - 2>"$td/e"; then
      grep -qiE 'error:' "$td/e" && fails+=("$h (C++)")
    fi
  done
fi

note=""
[ -n "${GLIBC_SRC:-}" ] && [ -f "$GLIBC_SRC/scripts/check-installed-headers.sh" ] \
  && note=" (exhaustive checker at \$GLIBC_SRC/scripts/check-installed-headers.sh)"

if [ "${#fails[@]}" -ne 0 ]; then
  echo "FAIL 21-check-installed-headers - public header(s) no longer self-include:"
  printf '       - %s\n' "${fails[@]}" | head -30
  exit 1
fi
echo "PASS 21-check-installed-headers - $n_c public headers self-include (C${n_cxx:+, $n_cxx C++})$note"
