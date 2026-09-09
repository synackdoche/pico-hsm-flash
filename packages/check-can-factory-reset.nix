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
    description = "Check that a given test-firmware PicoHSM can be factory reset (and do it)";
    mainProgram = "check-can-factory-reset";
  };
  name = pname;
  runtimeInputs = [
    inputs.self.packages.${system}.pico-hsm-list
    pkgs.opensc # opensc-tool, pkcs11-tool
    pkgs.coreutils
    pkgs.gawk # awk
  ];
  text = ''
    set -euo pipefail

    source ${inputs.self.packages.${system}.pkcs11-slots}

    serial=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --serial) serial="$2"; shift 2 ;;
        *) echo "Unknown arg: $1" >&2; exit 2 ;;
      esac
    done
    if [[ -z "$serial" ]]; then
      echo "Usage: check-can-factory-reset --serial <serial>" >&2
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

    slot="$(require_reader "$serial")"

    # The factory-reset APDU (80 64 0F 00) is exempt from PIN auth in the test
    # firmware, so it works from ANY state. It erases the flash to pre-init.
    echo "==> Sending factory-reset APDU (erase flash to pre-init)."
    out="$(opensc-tool -r "$slot" -s 80640F00 2>&1)"
    if [[ "$out" != *"SW1=0x90, SW2=0x00"* ]]; then
      echo "ERROR: factory-reset APDU failed:" >&2
      echo "$out" >&2
      exit 2
    fi

    # Postcondition: the HSM is now pre-init (no PIN initialized flag).
    if hsm_initialized "$pkcs11_opensc_module" "$serial"; then
      echo "ERROR: HSM still reports an initialized token after factory reset." >&2
      exit 2
    fi

    echo "==> Factory reset sent: the HSM is now in a freshly-flashed pre-init state."
  '';
}
