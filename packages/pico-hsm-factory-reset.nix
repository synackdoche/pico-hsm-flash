# pico-hsm-factory-reset: erase a test HSM to a freshly-flashed pre-init state.
#
# SAFETY: this is DESTRUCTIVE and only works on HSMs running the TEST firmware
# (token label `Pico-HSM-PATCHED_UNSAFE`). require_test_hsm verifies the label
# BEFORE any action and refuses to run on a production HSM.
#
# The factory-reset APDU (80 64 0F 00) is exempt from PIN auth in the test
# firmware (see patches/factory-reset.patch), so it works from ANY HSM state:
# uninitialized, initialized, PIN-locked, with or without keys. It erases the
# flash and re-initializes to the "Flashed but uninitialized" state.
#
# Usage: pico-hsm-factory-reset --serial <serial>
{
  pkgs,
  inputs,
  pname,
  ...
}:
let
  fwlabel = inputs.self.packages.${system}.pico-hsm-fwlabel;
  slots = inputs.self.packages.${system}.pkcs11-slots;
  system = pkgs.stdenv.hostPlatform.system;
in
pkgs.writeShellApplication {
  # Follow external `source`d libraries (store paths).
  extraShellCheckFlags = [ "-x" ];
  meta.license = pkgs.lib.licenses.agpl3Only;
  name = pname;
  runtimeInputs = slots.deps;
  text = ''
    set -euo pipefail

    source ${slots}
    source ${fwlabel}

    serial=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --serial) serial="$2"; shift 2 ;;
        *) echo "Unknown arg: $1" >&2; exit 2 ;;
      esac
    done
    if [[ -z "$serial" ]]; then
      echo "Usage: pico-hsm-factory-reset --serial <serial>" >&2
      exit 2
    fi

    slot="$(require_reader "$serial")"
    require_test_hsm "$serial"

    # The factory-reset APDU is exempt from PIN auth in the test firmware, so
    # it works from ANY state (including PIN-locked). It erases the flash and
    # re-initializes to the freshly-flashed pre-init state.
    echo "==> Sending factory-reset APDU (erase flash to pre-init)."
    out="$(opensc-tool -r "$slot" -s 80640F00 2>&1)"
    if [[ "$(grep -c 'SW1=0x90, SW2=0x00' <<< "$out")" != "1" ]]; then
      echo "ERROR: factory-reset APDU failed:" >&2
      echo "$out" >&2
      exit 2
    fi

    # Postcondition: the HSM is back and pre-init. The device detaches from
    # USB while the erase flushes, so wait_for_status returns only after the
    # re-enumeration. A dropped reader also reads as "not initialized", so the
    # clean read must succeed first.
    wait_for_status "$serial" >/dev/null
    if hsm_initialized "$pkcs11_opensc_module" "$serial"; then
      echo "ERROR: HSM still reports an initialized token after factory reset." >&2
      exit 2
    fi

    echo "==> Factory reset sent. The HSM is now in a freshly-flashed pre-init state."
    echo "==> Re-initialize with pico-hsm-provision when ready."
  '';
}
