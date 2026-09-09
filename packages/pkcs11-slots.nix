# Shared PKCS#11 slot/key discovery shell functions.
#
# A source-able function library (writeTextFile — no shebang, not executable).
# `deps` lists the tools these functions need; sourcing apps add it to their
# runtimeInputs, so Nix tracks the dependency without baking store paths here.
#
# Exports $pkcs11_opensc_module (the OpenSC PKCS#11 module path — the single
# source of truth for the default module) and these functions:
#
#   require_opensc_module <module>  0 iff <module> is the OpenSC module
#   list_slots <module>          -> "slot serial" lines for all slots
#   serial_to_slot <module> <sn> -> slot index for a PKCS#11 serial (or empty)
#   list_slot_info <module>      -> "slot|label|firmware|serial" lines for all
#     slots (| delimiter survives empty fields, serial empty pre-init)
#   list_readers                 -> "reader usbserial" lines for all readers
#   usb_serial_to_slot <sn>      -> reader index for a USB serial (or empty)
#   usb_serial_to_slot_id <sn>   -> OpenSC CK_SLOT_ID for a USB serial (or empty)
#   wait_reconnect <sn> <attempts> -> wait up to <attempts>*1s for the reader to return
#   wait_settled <sn> [reads]    -> wait until <reads> consecutive clean status reads see no flush
#   require_reader <sn>          -> reader index for a USB serial, or exit 2
#   _schsm_transient <text>      0 iff text reports a transient sc-hsm-tool failure
#   wait_for_status <serial>     -> the device status text, waiting for a clean read
#   hsm_initialized <module> <usb-serial> -> 0 iff that HSM is initialized
#   list_public_keys <module> <serial> -> "label ID" lines for each public key
#     on the slot (no login required)
#
# Functions taking <usb-serial> map it to a slot index via opensc-tool (OpenSC
# reader index), which equals the PKCS#11 slot index ONLY for OpenSC; they
# assert the module is OpenSC (require_opensc_module).
{ pkgs, ... }:
let
  lib = pkgs.writeTextFile {
    meta.license = pkgs.lib.licenses.agpl3Only;
    name = "pkcs11-slots";
    text = ''
      # The OpenSC PKCS#11 module path. Single source of truth for the default
      # module — callers reference $pkcs11_opensc_module instead of re-spelling it.
      pkcs11_opensc_module="${pkgs.opensc}/lib/opensc-pkcs11.so"

      # Functions below that map a USB serial (via opensc-tool, OpenSC reader
      # index) to a PKCS#11 slot index rely on reader-index == slot-index, which
      # holds ONLY for OpenSC. Assert the module is OpenSC so this never silently
      # indexes a different module's slots.
      require_opensc_module() {
        if [[ "$1" != "$pkcs11_opensc_module" ]]; then
          echo "ERROR: this operation maps USB serials via opensc-tool, so it requires the OpenSC module ($pkcs11_opensc_module), got: $1" >&2
          exit 2
        fi
      }

      list_slots() {
        local module="$1"
        pkcs11-tool --module "$module" --list-slots \
          | awk '/^Slot/ { s=$2 } /serial num/ { sub(/^[[:space:]]*serial num[[:space:]]*:[[:space:]]*/, ""); print s, $0 }'
      }

      # Emit "slot|label|firmware|serial" for every slot (| delimiter survives
      # empty fields). serial num prints AFTER firmware version, so rows are
      # emitted on the serial num line.
      list_slot_info() {
        local module="$1"
        pkcs11-tool --module "$module" --list-slots \
          | awk '/^Slot/ { s=$2; lab=""; fwv=""; ser="" } /token label/ { sub(/^.*token label[[:space:]]*:[[:space:]]*/, ""); lab=$0 } /firmware version/ { sub(/^.*firmware version[[:space:]]*:[[:space:]]*/, ""); fwv=$0 } /serial num/ { sub(/^.*serial num[[:space:]]*:[[:space:]]*/, ""); ser=$0; print s "|" lab "|" fwv "|" ser }'
      }

      # 0 iff the HSM with the given USB serial is initialized. Probed via the
      # PKCS#11 `PIN initialized` token flag: a freshly-flashed HSM lacks it.
      # The token label is NOT usable (empty both pre-init and in some initialized
      # states), and `token initialized` is set even pre-init.
      hsm_initialized() {
        local module="$1" serial="$2" slot
        require_opensc_module "$module"
        slot="$(usb_serial_to_slot "$serial")"
        [[ -z "$slot" ]] && return 1
        pkcs11-tool --module "$module" --list-slots 2>/dev/null \
          | awk -v s="$slot" '
              /^Slot/ { cur=$2 }
              /token flags/ { if (cur==s && /PIN initialized/) found=1 }
              END { exit !found }
            '
      }

      serial_to_slot() {
        local module="$1" want="$2"
        list_slots "$module" | awk -v w="$want" '$2==w {print $1; exit}'
      }

      # USB serials (from opensc-tool --list-readers) uniquely identify each
      # physical HSM. Emit "reader usbserial" lines.
      list_readers() {
        opensc-tool --list-readers \
          | awk '/^[0-9]+/ { idx=$1; if (match($0, /\(([0-9A-Fa-f]+)\)/, m)) print idx, m[1] }'
      }

      usb_serial_to_slot() {
        local want="$1"
        list_readers | awk -v w="$want" '$2==w {print $1; exit}'
      }

      # The OpenSC CK_SLOT_ID for a USB serial. OpenSC numbers slots reader*4
      # (Slot 0 (0x0), Slot 1 (0x4)); PKCS#11 consumers pass that opaque id to
      # --slot, which is distinct from the positional --slot-index.
      usb_serial_to_slot_id() {
        local want="$1" idx
        idx="$(usb_serial_to_slot "$want")"
        [[ -z "$idx" ]] && return 0
        printf '%d' "$((idx * 4))"
      }

      # Wait (bounded) until the reader for <serial> is present again. After a
      # transient failure the device is usually mid-flush and detached; the
      # re-enumeration is the "ready to retry" signal. Fails loudly if it
      # never comes back.
      wait_reconnect() {
        local serial="$1" attempts="$2"
        local i
        for (( i = 1; i <= attempts; i++ )); do
          [[ -n "$(usb_serial_to_slot "$serial")" ]] && return 0
          sleep 1
        done
        echo "ERROR: HSM (serial $serial) did not come back (waited ''${attempts}s)." >&2
        exit 2
      }

      # Wait until the device answers <reads> consecutive clean status reads
      # (0.5s apart). A flash drain shows up as short unreadable windows between
      # chunks of the deferred flush; a calm stretch means the drain has ended,
      # so a write sent now is not queued into it — an import queued into the
      # init's drain interleaves the flash log and leaves the multi-file PKCS#15
      # skeleton incomplete (the DKEK file survives, so only the PKCS#11 view
      # goes bare). Measured drain windows are ~1s, so 4 calm reads (~2s) clear
      # them.
      wait_settled() {
        local serial="$1" need="''${2:-4}"
        local calm=0 i reader out
        for (( i = 1; i <= 60; i++ )); do
          reader="$(usb_serial_to_slot "$serial")"
          if [[ -n "$reader" ]]; then
            out="$(sc-hsm-tool --reader "$reader" 2>&1)" || out=""
          fi
          if [[ -n "$reader" && -n "$out" ]] && ! _schsm_transient "$out"; then
            calm=$((calm + 1))
            (( calm >= need )) && return 0
          else
            calm=0
          fi
          sleep 0.5
        done
        echo "ERROR: HSM (serial $serial) never settled (still flushing after 30s)." >&2
        exit 2
      }

      # Resolve a USB serial to its reader index, failing loudly if the HSM is
      # absent. Destructive operations gate on a serial (stable identity), never
      # a reader index (positional, can shift between enumeration and use).
      require_reader() {
        local serial="$1" slot
        slot="$(usb_serial_to_slot "$serial")"
        if [[ -z "$slot" ]]; then
          echo "ERROR: no HSM with USB serial $serial is present." >&2
          exit 2
        fi
        printf '%s' "$slot"
      }

      # 0 iff sc-hsm-tool's output reports a transient connection failure. The
      # firmware flushes deferred flash writes after each write APDU, locking
      # out core1 (which services TinyUSB); an APDU in that window sees the
      # reader briefly absent.
      _schsm_transient() {
        grep -qiE 'card not present|transmit failed|failed to connect to card|reader .* not found' <<< "$1"
      }

      # Run a status read, waiting (bounded) until the device answers cleanly.
      # Every read after a write APDU can fail transiently inside the deferred
      # flash-flush window; once a clean read succeeds, the state it shows is
      # final. Fails loudly if the device never comes back.
      wait_for_status() {
        local serial="$1" out rc=0
        local attempts=30 i reader
        for (( i = 1; i <= attempts; i++ )); do
          rc=0
          reader="$(usb_serial_to_slot "$serial")"
          if [[ -z "$reader" ]]; then
            sleep 1
            continue
          fi
          out="$(sc-hsm-tool --reader "$reader" 2>&1)" || rc=$?
          if _schsm_transient "$out" || [[ -z "$out" ]]; then
            sleep 1
            continue
          fi
          if [[ $rc -ne 0 ]]; then
            echo "ERROR: status read from HSM (serial $serial) failed:" >&2
            printf '%s\n' "$out" >&2
            exit 2
          fi
          printf '%s\n' "$out"
          return 0
        done
        echo "ERROR: HSM (serial $serial) did not become reachable after the last operation." >&2
        exit 2
      }

      # Public keys are readable without login. Emit "label ID" per key.
      list_public_keys() {
        local module="$1" serial="$2"
        local slot
        slot="$(serial_to_slot "$module" "$serial")"
        [[ -z "$slot" ]] && return 0
        pkcs11-tool --module "$module" --slot-index "$slot" \
            --list-objects --type pubkey 2>/dev/null \
          | awk '
              /label/  { sub(/^.*label[[:space:]]*:[[:space:]]*/, ""); lab=$0 }
              /ID:/    { sub(/^.*ID:[[:space:]]*/, ""); print lab, $0 }
            '
      }
    '';
  };
in
lib.overrideAttrs (old: {
  meta.license = pkgs.lib.licenses.agpl3Only;
  passthru = (old.passthru or { }) // {
    deps = [
      pkgs.coreutils
      pkgs.opensc
      pkgs.gawk
      pkgs.gnugrep
    ];
  };
})
