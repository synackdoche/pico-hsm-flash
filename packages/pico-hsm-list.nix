# picohsm-list: list connected ESP32s and PicoHSMs.
#
# Lists connected ESP32 boards (probed via esptool) and connected PKCS#11
# tokens (serial + slot).
#
# Usage: picohsm-list [--pkcs11-library <lib>]
#
# --pkcs11-library defaults to the OpenSC module (opensc-pkcs11.so); override
# for other providers (e.g. SoftHSM2).
{
  pkgs,
  inputs,
  pname,
  ...
}:
let
  fwlabel = inputs.self.packages.${pkgs.stdenv.hostPlatform.system}.pico-hsm-fwlabel;
  keyid = inputs.self.packages.${pkgs.stdenv.hostPlatform.system}.pico-hsm-keyid;
in
pkgs.writeShellApplication {
  # Follow external `source`d libraries (store paths).
  extraShellCheckFlags = [ "-x" ];
  meta = {
    description = "List connected ESP32s and flashed PicoHSMs";
    mainProgram = "pico-hsm-list";
  };
  name = pname;
  runtimeInputs = [
    pkgs.esptool
    pkgs.opensc # pkcs11-tool, opensc-tool
    pkgs.jq
    pkgs.coreutils
    pkgs.gawk # awk
    keyid
    fwlabel
  ];
  text = ''
    set -euo pipefail

    source ${inputs.self.packages.${pkgs.stdenv.hostPlatform.system}.pkcs11-slots}
    source ${fwlabel}

    pkcs11Lib="${pkgs.opensc}/lib/opensc-pkcs11.so"
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --pkcs11-library) pkcs11Lib="$2"; shift 2 ;;
        *) echo "Unknown arg: $1" >&2; exit 2 ;;
      esac
    done

    echo "==> Connected ESP32 boards (pending flash or in download mode)"
    found=0
    for port in /dev/ttyUSB* /dev/ttyACM*; do
      [[ -e "$port" ]] || continue
      # Probe the port; a responding ESP32 prints "Connected to <chip> on <port>".
      # Capture output (not a pipe) so esptool runs to completion under pipefail.
      if out="$(esptool --port "$port" --chip auto chip-id 2>/dev/null)" \
          && [[ "$out" == *"Connected to"* ]]; then
        echo "  $port"
        found=1
      fi
    done
    [[ "$found" == "1" ]] || echo "  (none)"

    echo "==> Flashed but uninitialized PicoHSMs"
    uninit=0
    while read -r slot; do
      [[ -z "$slot" ]] && continue
      # Firmware label (read via raw APDU) + firmware version.
      fwlabel="$(firmware_label "$slot")"
      fw="$(list_slot_info "$pkcs11Lib" | awk -F'|' -v s="$slot" '$1==s {print $3}')"
      echo "  slot $slot  fwlabel $fwlabel  fw $fw"
      uninit=1
    done < <(list_uninitialized_slots "$pkcs11Lib")
    [[ "$uninit" == "1" ]] || echo "  (none)"

    echo "==> Active PicoHSMs"
    list_slots "$pkcs11Lib" | while read -r slot serial; do
      [[ -z "$serial" ]] && continue
      # Show only PicoHSMs with expected serial prefix.
      [[ "$serial" == ESPICOHSMTR* ]] || continue
      # USB serial (from the reader name) + firmware label + firmware version.
      usbserial="$(opensc-tool --list-readers | awk -v s="$slot" '$1==s && match($0, /\(([0-9A-Fa-f]+)\)/, m) {print m[1]; exit}')"
      fwlabel="$(firmware_label "$slot")"
      fw="$(list_slot_info "$pkcs11Lib" | awk -F'|' -v s="$slot" '$1==s {print $3}')"
      echo "  slot $slot  serial $serial  usbserial $usbserial  fwlabel $fwlabel  fw $fw"
      list_public_keys "$pkcs11Lib" "$serial" | while read -r label id; do
        [[ -z "$label" ]] && continue
        echo "    key $label  id $id"
      done
    done
  '';
}
