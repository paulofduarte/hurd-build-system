# SPDX-FileCopyrightText: 2026 Paulo Duarte <paulofernandobd@gmail.com>
# SPDX-License-Identifier: GPL-3.0-or-later
# shellcheck shell=bash
# Generic helpers used by every scenario script.

# die <msg> - print to stderr, exit 1
die() {
  echo "ERROR: $*" >&2
  exit 1
}

# sha256_stdin - read stdin, print only the hex digest (no filename).
#   Tool picker: Linux distros + nix's coreutils ship `sha256sum`;
#   macOS BSD ships `shasum` (Perl Digest::SHA) but not the coreutils
#   variant.  Either tool's output is `<hex>  <filename>`, and we
#   want the first column.  Try sha256sum first, fall back to
#   `shasum -a 256` so this works whether you're inside nix's shell
#   or running the scripts under a plain macOS/Linux environment.
sha256_stdin() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum | cut -d' ' -f1
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 | cut -d' ' -f1
  else
    die "neither sha256sum nor shasum found on PATH"
  fi
}

# scenario_check_target <scenario_name> <space-separated supported list>
#   Validates $ARCH; calls die with an informative message on mismatch.
scenario_check_target() {
  local scenario="$1" supported="$2"
  case " $supported " in
    *" $ARCH "*) return 0 ;;
    *) die "ARCH=$ARCH not supported by SCENARIO=$scenario (supported: $supported)" ;;
  esac
}

# print_qemu_hint
#   Call right before exec'ing qemu in -nographic mode.  Emits the
#   Ctrl-A escape-prefix cheat sheet to stderr (catches the user before
#   qemu starts taking over the terminal) AND sets the terminal title
#   (persists across panic-spam scroll, so the user can still see
#   "Ctrl-A X to quit" no matter how much the kernel prints).
#
#   Title is restored automatically by most shells on the next prompt
#   (zsh/bash with PROMPT_COMMAND / precmd hooks), so we don't bother
#   restoring it ourselves - we're about to exec into qemu anyway.
#
#   Scenario name is auto-derived from $0 (e.g., "boot", "hurd-debian").
print_qemu_hint() {
  local scenario_name
  scenario_name="$(basename "${0%.sh}")"
  echo "==> qemu (${scenario_name}, ARCH=$ARCH) - Ctrl-A X = quit | Ctrl-A C = monitor | Ctrl-A H = help" >&2
  # OSC 0 sets both window title and icon name; BEL terminator (\007)
  # is more widely compatible than \e\\.  Always to stderr; if the
  # terminal doesn't grok OSC, this prints a stray sequence but doesn't
  # break anything.
  printf '\033]0;qemu | %s | ARCH=%s | Ctrl-A X to quit\007' \
    "$scenario_name" "$ARCH" >&2 || :
}
