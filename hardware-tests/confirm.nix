# Confirmation gate shared by every hardware test. Hardware tests destroy or
# rotate device state, so they must not run unattended.
#
# Apps source this, parse `--confirm` in their own argument loop (setting
# CONFIRMED=1), then call `require_confirm`. That function exits 0 silently
# when CONFIRMED=1; otherwise it warns and prompts on stdin (y/n), exiting 2
# on "no", EOF, or non-interactive stdin.
{ pkgs, ... }:
pkgs.writeTextFile {
  name = "hardware-test-confirm";
  text = ''
    CONFIRMED=0

    require_confirm() {
      [[ $CONFIRMED -eq 1 ]] && return 0
      echo "WARNING: this test will modify, erase or rotate state on the target HSM." >&2
      if [[ ! -t 0 ]]; then
        echo "Refusing to run without --confirm (no interactive terminal)." >&2
        exit 2
      fi
      local reply=""
      read -r -p "Continue? [y/N] " reply || reply=""
      [[ "$reply" == "y" || "$reply" == "Y" || "$reply" == "yes" || "$reply" == "YES" ]] || {
        echo "Aborted." >&2
        exit 2
      }
    }
  '';
}
