# pico-hsm-factory-reset: erase a test HSM to a freshly-flashed pre-init state.
#
# SAFETY: this is DESTRUCTIVE and only works on HSMs running the TEST firmware
# (token label `Pico-HSM-PATCHED_UNSAFE`). It verifies the label BEFORE any
# action and refuses to run on a production HSM (label `Pico-HSM`).
#
# Usage: pico-hsm-factory-reset --serial <serial> --pin <pin>
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
  name = pname;
  runtimeInputs = [
    pkgs.opensc # opensc-tool, pkcs11-tool
    pkgs.coreutils
    pkgs.gawk # awk
  ];
  text = ''
    set -euo pipefail

    source ${inputs.self.packages.${system}.pkcs11-slots}
    source ${inputs.self.packages.${system}.pico-hsm-fwlabel}

    pin=""
    serial=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --pin) pin="$2"; shift 2 ;;
        --serial) serial="$2"; shift 2 ;;
        *) echo "Unknown arg: $1" >&2; exit 2 ;;
      esac
    done
    if [[ -z "$pin" || -z "$serial" ]]; then
      echo "Usage: pico-hsm-factory-reset --serial <serial> --pin <pin>" >&2
      exit 2
    fi

    slot="$(usb_serial_to_slot "$serial")"
    if [[ -z "$slot" ]]; then
      echo "ERROR: no HSM with serial $serial is plugged in." >&2
      exit 2
    fi

    # SAFETY: verify the token label is the TEST firmware marker BEFORE any
    # action. Refuse to run on a production HSM (label `Pico-HSM`).
    label="$(firmware_label "$slot")"
    if [[ "$label" != "Pico-HSM-PATCHED_UNSAFE" ]]; then
      echo "ERROR: token label is '$label', not 'Pico-HSM-PATCHED_UNSAFE'." >&2
      echo "Refusing to factory-reset: this is not a test-firmware HSM." >&2
      exit 2
    fi
    echo "==> Confirmed test firmware (serial $serial, label: $label)."

    # The extras command requires isUserAuthenticated in the SAME raw-APDU
    # session. Authenticate with a VERIFY APDU (INS=0x20, P2=0x81 = user PIN)
    # and send the factory-reset APDU in one opensc-tool invocation, so the
    # session state carries over. Both responses must be 0x9000.
    pin_hex="$(printf '%s' "$pin" | od -An -tx1 | tr -d ' \n')"
    pin_len="$(printf '%s' "$pin" | wc -c | tr -d ' ')"
    verify_apdu="00200081$(printf '%02x' "$pin_len")$pin_hex"

    echo "==> Sending factory-reset APDU (erase flash to pre-init)."
    out="$(opensc-tool -r "$slot" -s "$verify_apdu" -s 80640F00 2>&1)"
    if [[ "$(grep -c 'SW1=0x90, SW2=0x00' <<< "$out")" != "2" ]]; then
      echo "ERROR: APDU failed (PIN verify or factory reset):" >&2
      echo "$out" >&2
      exit 2
    fi

    echo "==> Factory reset sent. The HSM is now in a freshly-flashed pre-init state."
    echo "==> Re-initialize with picohsm-device-init when ready."
  '';
}
