# Test-only helper: rotate the SO-PIN of a flashed TEST PicoHSM.
#
# NON-DESTRUCTIVE: the DKEK and all keys are preserved (the MKEK is re-wrapped
# under the new SO-PIN). The pico-hsm-dkek library verifies the DKEK state is
# UNCHANGED afterwards, proving the keys survived.
#
# The shared require_test_hsm gate ensures we only ever touch a test-firmware
# All PINs are env vars, never argv (the tool receives `env:VARIABLE`).
#
# Usage: PICO_HSM_SO_PIN=<pin> PICO_HSM_NEW_SO_PIN=<pin> \
#        check-can-change-so-pin --serial <serial> [--confirm]
{
  pkgs,
  inputs,
  pname,
  ...
}:
let
  confirm = import ./confirm.nix { inherit pkgs; };
  dkek = inputs.self.packages.${system}.pico-hsm-dkek;
  fwlabel = inputs.self.packages.${system}.pico-hsm-fwlabel;
  system = pkgs.stdenv.hostPlatform.system;
in
pkgs.writeShellApplication {
  extraShellCheckFlags = [ "-x" ];
  meta = {
    description = "Check that a given test-firmware PicoHSM can have its SO-PIN rotated (and do it)";
    license = pkgs.lib.licenses.agpl3Only;
    mainProgram = "check-can-change-so-pin";
  };
  name = pname;
  runtimeInputs = dkek.deps;
  text = ''
    set -euo pipefail

    source ${dkek}
    source ${fwlabel}
    source ${confirm}

    serial=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --serial)       serial="$2"; shift 2 ;;
        --confirm)      CONFIRMED=1; shift ;;
        *) echo "Unknown arg: $1" >&2; exit 2 ;;
      esac
    done
    if [[ -z "$serial" ]]; then
      echo "Usage: PICO_HSM_SO_PIN=<pin> PICO_HSM_NEW_SO_PIN=<pin> check-can-change-so-pin --serial <serial> [--confirm]" >&2
      exit 2
    fi

    require_confirm

    : "''${PICO_HSM_SO_PIN:?PICO_HSM_SO_PIN is required}"
    : "''${PICO_HSM_NEW_SO_PIN:?PICO_HSM_NEW_SO_PIN is required}"

    require_test_hsm "$serial"
    echo "==> Confirmed test HSM (serial $serial, label Pico-HSM-PATCHED_UNSAFE)."

    change_so_pin "$serial" PICO_HSM_SO_PIN PICO_HSM_NEW_SO_PIN
    echo "==> SO-PIN rotated: the DKEK and keys are intact."
  '';
}
