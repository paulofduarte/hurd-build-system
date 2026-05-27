# Generic helpers used by every scenario script.

# die <msg> — print to stderr, exit 1
die() { echo "ERROR: $*" >&2; exit 1; }

# scenario_check_target <scenario_name> <space-separated supported list>
#   Validates $TARGET; calls die with an informative message on mismatch.
scenario_check_target() {
  local scenario="$1" supported="$2"
  case " $supported " in
    *" $TARGET "*) return 0 ;;
    *) die "TARGET=$TARGET not supported by SCENARIO=$scenario (supported: $supported)" ;;
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
#   restoring it ourselves — we're about to exec into qemu anyway.
#
#   Scenario name is auto-derived from $0 (e.g., "boot", "hurd-debian").
print_qemu_hint() {
  local scenario_name
  scenario_name="$(basename "${0%.sh}")"
  echo "==> qemu (${scenario_name}, TARGET=$TARGET) — Ctrl-A X = quit · Ctrl-A C = monitor · Ctrl-A H = help" >&2
  # OSC 0 sets both window title and icon name; BEL terminator (\007)
  # is more widely compatible than \e\\.  Always to stderr; if the
  # terminal doesn't grok OSC, this prints a stray sequence but doesn't
  # break anything.
  printf '\033]0;qemu · %s · TARGET=%s · Ctrl-A X to quit\007' \
    "$scenario_name" "$TARGET" >&2 || :
}
