# picohsm-list: list connected ESP32s and PicoHSMs.
#
# Lists connected ESP32 boards (probed via esptool) and connected PKCS#11
# tokens (serial + slot).
#
# Usage: pico-hsm-list [--pkcs11-library <lib>] [--format human|table]
#
# --format table emits one '|'-delimited record per line (no header), so the
# output is directly parseable by downstream tools:
#
#   kind|slot|port|usbserial|serial|fwlabel|fw|keylabel|keyid
#
# where kind is one of:
#   esp32   a board pending flash / in download mode (port set)
#   uninit  a flashed but uninitialized PicoHSM (usbserial, fwlabel, fw set)
#   active  an initialized PicoHSM (usbserial, serial, fwlabel, fw set)
#   key     a public key on an active PicoHSM (keylabel, keyid set)
#
# Empty columns are preserved; zero matches = zero lines.
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
    pkgs.coreutils
    pkgs.gawk # awk
    keyid
    fwlabel
  ];
  text = ''
    set -euo pipefail

    source ${inputs.self.packages.${pkgs.stdenv.hostPlatform.system}.pkcs11-slots}
    source ${fwlabel}

    pkcs11Lib="$pkcs11_opensc_module"
    format="human"
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --pkcs11-library) pkcs11Lib="$2"; shift 2 ;;
        --format)         format="$2"; shift 2 ;;
        --table)          format="table"; shift ;;
        *) echo "Unknown arg: $1" >&2; exit 2 ;;
      esac
    done
    case "$format" in
      human|table) ;;
      *) echo "Unknown format: $format (expected 'human' or 'table')" >&2; exit 2 ;;
    esac

    # A record is a '|'-delimited line:
    #   kind|slot|port|usbserial|serial|fwlabel|fw|keylabel|keyid
    emit() { printf '%s|%s|%s|%s|%s|%s|%s|%s|%s\n' "$@"; }

    # Discover all devices/keys exactly once, emitting table records.
    discover() {
      # ESP32 boards pending flash / in download mode.
      for port in /dev/ttyUSB* /dev/ttyACM*; do
        [[ -e "$port" ]] || continue
        # Probe the port; a responding ESP32 prints "Connected to <chip> on <port>".
        # Capture output (not a pipe) so esptool runs to completion under pipefail.
        if out="$(esptool --port "$port" --chip auto chip-id 2>/dev/null)" \
            && [[ "$out" == *"Connected to"* ]]; then
          emit esp32 "" "$port" "" "" "" "" "" ""
        fi
      done

      # Flashed but uninitialized PicoHSMs (empty token label).
      while read -r slot; do
        [[ -n "$slot" ]] || continue
        # USB serial (from the reader name), firmware label, firmware version.
        usbserial="$(opensc-tool --list-readers \
          | awk -v s="$slot" '$1==s && match($0, /\(([0-9A-Fa-f]+)\)/, m) {print m[1]; exit}')"
        fwlabel="$(firmware_label "$slot")"
        fw="$(list_slot_info "$pkcs11Lib" | awk -F'|' -v s="$slot" '$1==s {print $3}')"
        emit uninit "$slot" "" "$usbserial" "" "$fwlabel" "$fw" "" ""
      done < <(list_uninitialized_slots "$pkcs11Lib")

      # Active PicoHSMs (and their public keys).
      while read -r slot serial; do
        [[ -n "$serial" ]] || continue
        # Show only PicoHSMs with expected serial prefix.
        [[ "$serial" == ESPICOHSMTR* ]] || continue
        usbserial="$(opensc-tool --list-readers \
          | awk -v s="$slot" '$1==s && match($0, /\(([0-9A-Fa-f]+)\)/, m) {print m[1]; exit}')"
        fwlabel="$(firmware_label "$slot")"
        fw="$(list_slot_info "$pkcs11Lib" | awk -F'|' -v s="$slot" '$1==s {print $3}')"
        emit active "$slot" "" "$usbserial" "$serial" "$fwlabel" "$fw" "" ""
        while read -r label id; do
          [[ -n "$label" ]] || continue
          emit key "$slot" "" "$usbserial" "$serial" "" "" "$label" "$id"
        done < <(list_public_keys "$pkcs11Lib" "$serial")
      done < <(list_slots "$pkcs11Lib")
    }

    render_human() {
      local kind slot port usbserial serial fwlabel fw keylabel keyid
      local -a esp32=() uninit=() active=() keys=()
      while IFS='|' read -r kind slot port usbserial serial fwlabel fw keylabel keyid; do
        case "$kind" in
          esp32)  esp32+=("$port") ;;
          uninit) uninit+=("$slot|$usbserial|$fwlabel|$fw") ;;
          active) active+=("$slot|$usbserial|$serial|$fwlabel|$fw") ;;
          key)    keys+=("$slot|$keylabel|$keyid") ;;
        esac
      done

      echo "==> Connected ESP32 boards (pending flash or in download mode)"
      if ((''${#esp32[@]})); then
        for p in "''${esp32[@]}"; do echo "  $p"; done
      else
        echo "  (none)"
      fi

      echo "==> Flashed but uninitialized PicoHSMs"
      if ((''${#uninit[@]})); then
        for r in "''${uninit[@]}"; do
          IFS='|' read -r s u fl x <<<"$r"
          echo "  slot $s  usbserial $u  fwlabel $fl  fw $x"
        done
      else
        echo "  (none)"
      fi

      echo "==> Active PicoHSMs"
      if ((''${#active[@]})); then
        for r in "''${active[@]}"; do
          IFS='|' read -r s u ser fl x <<<"$r"
          echo "  slot $s  serial $ser  usbserial $u  fwlabel $fl  fw $x"
          for k in "''${keys[@]}"; do
            IFS='|' read -r ks kl kid <<<"$k"
            [[ "$ks" == "$s" ]] || continue
            echo "    key $kl  id $kid"
          done
        done
      else
        echo "  (none)"
      fi
    }

    if [[ "$format" == table ]]; then
      discover
    else
      discover | render_human
    fi
  '';
}
