# check-can-change-so-pin: rotate the SO-PIN of a flashed TEST PicoHSM.
#
# Finds the HSM by USB serial + TEST firmware label (`Pico-HSM-PATCHED_UNSAFE`)
# from picohsm-list's parseable table, then rotates the SO-PIN via the card's
# CHANGE REFERENCE DATA path (INS 0x24 P2=0x88) through `pkcs11-tool --change-pin
# --login-type so`.
#
# NON-DESTRUCTIVE: the DKEK and all keys are preserved (the MKEK is re-wrapped
# under the new SO-PIN). The pico-hsm-dkek library verifies the DKEK state is
# UNCHANGED afterwards, proving the keys survived.
#
# The firmware-label gate ensures we only ever touch a test-firmware HSM.
#
# Usage: check-can-change-so-pin --serial <serial> --old-so-pin <pin> --new-so-pin <pin>
{
  pkgs,
  inputs,
  pname,
  ...
}:
let
  system = pkgs.stdenv.hostPlatform.system;
in
pkgs.writeShellApplication {
  # Follow external `source`d libraries (store paths).
  extraShellCheckFlags = [ "-x" ];
  meta = {
    description = "Check that a given test-firmware PicoHSM can have its SO-PIN rotated (and do it)";
    mainProgram = "check-can-change-so-pin";
  };
  name = pname;
  runtimeInputs = [
    inputs.self.packages.${system}.pico-hsm-list
    inputs.self.packages.${system}.pico-hsm-dkek
    pkgs.opensc # pkcs11-tool
    pkgs.coreutils
    pkgs.gawk # awk
  ];
  text = ''
    set -euo pipefail

    source ${inputs.self.packages.${system}.pkcs11-slots}
    source ${inputs.self.packages.${system}.pico-hsm-dkek}

    serial="" oldSoPin="" newSoPin=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --serial)       serial="$2"; shift 2 ;;
        --old-so-pin)   oldSoPin="$2"; shift 2 ;;
        --new-so-pin)   newSoPin="$2"; shift 2 ;;
        *) echo "Unknown arg: $1" >&2; exit 2 ;;
      esac
    done
    if [[ -z "$serial" || -z "$oldSoPin" || -z "$newSoPin" ]]; then
      echo "Usage: check-can-change-so-pin --serial <serial> --old-so-pin <pin> --new-so-pin <pin>" >&2
      exit 2
    fi

    # Gate: the HSM must be present AND running TEST firmware. Match BOTH the
    # USB serial and the TEST firmware label (`Pico-HSM-PATCHED_UNSAFE`) in
    # picohsm-list's parseable table. Record schema:
    #   kind|slot|port|usbserial|serial|fwlabel|fw|keylabel|keyid
    if ! pico-hsm-list --format table \
      | awk -F'|' -v s="$serial" '
          !found && ($1 == "uninit" || $1 == "active") && $4 == s && $6 == "Pico-HSM-PATCHED_UNSAFE" { found = 1 }
          END { exit !found }
        '; then
      echo "no: no test-firmware HSM with USB serial $serial is present." >&2
      exit 1
    fi
    echo "==> Confirmed test HSM (serial $serial, label Pico-HSM-PATCHED_UNSAFE)."

    # NON-DESTRUCTIVE: rotate the SO-PIN. change_so_pin verifies the DKEK state
    # is unchanged afterwards (proving the keys survived).
    change_so_pin "$pkcs11_opensc_module" "$serial" "$oldSoPin" "$newSoPin"

    echo "==> SO-PIN rotated: the DKEK and keys are intact."
  '';
}
