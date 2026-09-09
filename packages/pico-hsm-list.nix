# picohsm-list: list connected ESP32s and PicoHSMs.
#
# Lists connected ESP32 boards (probed via esptool) and connected PKCS#11
# tokens (serial + slot). Uses the OpenSC module: USB serials come from
# opensc-tool and the reader index is used as the PKCS#11 slot index, which
# holds only for OpenSC.
#
# Usage: pico-hsm-list [--format human|table]
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
  meta = {
    description = "List connected ESP32s and flashed PicoHSMs";
    license = pkgs.lib.licenses.agpl3Only;
    mainProgram = "pico-hsm-list";
  };
  name = pname;
  runtimeInputs = [ pkgs.esptool ] ++ slots.deps;
  text = ''
    set -euo pipefail

    source ${slots}
    source ${fwlabel}

    format="human"
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --format) format="$2"; shift 2 ;;
        --table)  format="table"; shift ;;
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

      # Snapshot the bus once: slot info (PKCS#11) and reader serials (OpenSC)
      # are paired by index within the same enumeration, so a re-enumeration
      # mid-list cannot mix generations inside a row.
      local readers info slot label fw p11serial usbserial fl r
      local -a uninit=() active=()
      readers="$(opensc-tool --list-readers)"
      info="$(list_slot_info "$pkcs11_opensc_module")"

      while IFS='|' read -r slot label fw p11serial; do
        [[ -n "$slot" ]] || continue
        usbserial="$(awk -v s="$slot" '$1==s && match($0, /\(([0-9A-Fa-f]+)\)/, m) {print m[1]; exit}' <<<"$readers")"
        fl="$(firmware_label "$slot")"
        if [[ -z "$p11serial" ]]; then
          uninit+=("$slot|$usbserial|$fl|$fw")
        else
          [[ -z "$fl" ]] && continue
          active+=("$slot|$usbserial|$p11serial|$fl|$fw")
        fi
      done <<<"$info"

      for r in "''${uninit[@]}"; do
        IFS='|' read -r slot usbserial fl fw <<<"$r"
        emit uninit "$slot" "" "$usbserial" "" "$fl" "$fw" "" ""
      done
      for r in "''${active[@]}"; do
        IFS='|' read -r slot usbserial p11serial fl fw <<<"$r"
        emit active "$slot" "" "$usbserial" "$p11serial" "$fl" "$fw" "" ""
        while read -r label id; do
          [[ -n "$label" ]] || continue
          emit key "$slot" "" "$usbserial" "$p11serial" "" "" "$label" "$id"
        done < <(list_public_keys "$pkcs11_opensc_module" "$p11serial")
      done
    }

    render_human() {
      local kind slot port usbserial serial fl fw keylabel keyid
      local -a esp32=() uninit=() active=() keys=()
      while IFS='|' read -r kind slot port usbserial serial fl fw keylabel keyid; do
        case "$kind" in
          esp32)  esp32+=("$port") ;;
          uninit) uninit+=("$slot|$usbserial|$fl|$fw") ;;
          active) active+=("$slot|$usbserial|$serial|$fl|$fw") ;;
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
          IFS='|' read -r s u label x <<<"$r"
          echo "  slot $s  usbserial $u  fwlabel $label  fw $x"
        done
      else
        echo "  (none)"
      fi

      echo "==> Active PicoHSMs"
      if ((''${#active[@]})); then
        for r in "''${active[@]}"; do
          IFS='|' read -r s u ser label x <<<"$r"
          echo "  slot $s  serial $ser  usbserial $u  fwlabel $label  fw $x"
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
