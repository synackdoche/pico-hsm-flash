# Shared PKCS#11 slot/key discovery shell functions.
#
# A source-able function library (writeTextFile — no shebang, not executable).
#
# Exports $pkcs11_opensc_module (the OpenSC PKCS#11 module path — the single
# source of truth for the default module) and these functions:
#
#   require_opensc_module <module>  0 iff <module> is the OpenSC module
#   list_slots <module>          -> "slot serial" lines for all slots
#   serial_to_slot <module> <sn> -> slot index for a PKCS#11 serial (or empty)
#   list_readers                 -> "reader usbserial" lines for all readers
#   usb_serial_to_slot <sn>      -> reader index for a USB serial (or empty)
#   require_reader <sn>          -> reader index for a USB serial, or exit 2
#   list_slot_info <module>      -> "slot label firmware" lines for all slots
#   list_uninitialized_slots <module> -> "slot" lines for slots with no token
#     label (flashed but not yet initialized)
#   hsm_initialized <module> <usb-serial> -> 0 iff that HSM is initialized
#   list_public_keys <module> <serial> -> "label ID" lines for each public key
#     on the slot (no login required)
#   hsm_has_key <module> <usb-serial> <pin> <label> <hexId> -> 0 if a private
#     key with the given label + CKA_ID (hex) exists on the HSM, 1 otherwise
#
# Functions taking <usb-serial> map it to a slot index via opensc-tool (OpenSC
# reader index), which equals the PKCS#11 slot index ONLY for OpenSC; they
# assert the module is OpenSC (require_opensc_module).
{
  pkgs,
  ...
}:
pkgs.writeTextFile {
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
      pkcs11-tool --module "$module" --list-slots 2>/dev/null \
        | awk '/^Slot/ { s=$2 } /serial num/ { sub(/^[[:space:]]*serial num[[:space:]]*:[[:space:]]*/, ""); print s, $0 }' \
        || true
    }

    # Emit "slot|label|firmware" for every slot (| delimiter survives empty labels).
    list_slot_info() {
      local module="$1"
      pkcs11-tool --module "$module" --list-slots 2>/dev/null \
        | awk '/^Slot/ { s=$2; lab="" } /token label/ { sub(/^.*token label[[:space:]]*:[[:space:]]*/, ""); lab=$0 } /firmware version/ { sub(/^.*firmware version[[:space:]]*:[[:space:]]*/, ""); print s "|" lab "|" $0 }' \
        || true
    }

    # Slots with an empty token label are flashed but not yet initialized.
    list_uninitialized_slots() {
      local module="$1"
      pkcs11-tool --module "$module" --list-slots 2>/dev/null \
        | awk '/^Slot/ { s=$2 } /token label/ { sub(/^.*token label[[:space:]]*:[[:space:]]*/, ""); if ($0 == "") print s }' \
        || true
    }

    # 0 iff the HSM with the given USB serial is initialized. Probed via the
    # PKCS#11 `PIN initialized` token flag: a freshly-flashed HSM lacks it. The
    # token label is NOT usable (empty both pre-init and in some initialized
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
    # physical HSM; the PKCS#11 token serial is duplicated across test HSMs.
    # Emit "reader usbserial" lines.
    list_readers() {
      opensc-tool --list-readers \
        | awk '/^[0-9]+/ { idx=$1; if (match($0, /\(([0-9A-Fa-f]+)\)/, m)) print idx, m[1] }'
    }

    usb_serial_to_slot() {
      local want="$1"
      list_readers | awk -v w="$want" '$2==w {print $1; exit}'
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

    # Returns 0 if a private key with the given label + CKA_ID exists on the
    # HSM, 1 if the HSM is readable but has no such key. FAILS LOUDLY if the
    # HSM cannot be read (e.g. PIN-locked) — an unreadable HSM must never be
    # mistaken for a clean one.
    hsm_has_key() {
      local module="$1" serial="$2" pin="$3" label="$4" hexId="$5"
      local slot out rc
      require_opensc_module "$module"
      slot="$(usb_serial_to_slot "$serial")"
      [[ -z "$slot" ]] && return 1
      out="$(pkcs11-tool --module "$module" --slot-index "$slot" --login --pin "$pin" \
          --list-objects --type privkey 2>&1)"
      rc=$?
      if [[ $rc -ne 0 ]]; then
        echo "ERROR: cannot read HSM at slot $slot (pkcs11-tool exit $rc):" >&2
        echo "$out" >&2
        exit 2
      fi
      echo "$out" \
        | awk -v l="$label" -v e="$hexId" '
            /Object/ { lab=""; hx="" }
            /label/  { lab=$NF }
            /ID:/    { if (match($0, /\(0x([0-9A-Fa-f:]+)\)/, m)) { hx=m[1]; gsub(/:/,"",hx); hx=tolower(hx) } }
            lab==l && hx==e && hx!="" { print "yes"; exit }
          ' | grep -qx yes
    }
  '';
}
