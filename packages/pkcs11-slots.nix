# Shared PKCS#11 slot/key discovery shell functions.
#
# A source-able function library (writeTextFile — no shebang, not executable).
# Apps `source` it to get these functions:
#
#   list_slots <module>          -> "slot serial" lines for all slots
#   serial_to_slot <module> <sn> -> slot index for a serial (or empty)
#   usb_serial_to_slot <sn>      -> slot index for a USB serial (or empty)
#   list_slot_info <module>      -> "slot label firmware" lines for all slots
#   list_uninitialized_slots <module> -> "slot" lines for slots with no token
#     label (flashed but not yet initialized)
#   list_public_keys <module> <serial> -> "label ID" lines for each public key
#     on the slot (no login required)
#   hsm_has_key <module> <serial> <pin> <label> <hexId> -> 0 if a private key
#     with the given label + CKA_ID (hex) exists on the HSM, 1 otherwise
{
  pkgs,
  ...
}:
pkgs.writeTextFile {
  name = "pkcs11-slots";
  text = ''
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

    serial_to_slot() {
      local module="$1" want="$2"
      list_slots "$module" | awk -v w="$want" '$2==w {print $1; exit}'
    }

    # USB serials (from opensc-tool --list-readers) uniquely identify each
    # physical HSM; the PKCS#11 token serial is duplicated across test HSMs.
    usb_serial_to_slot() {
      local want="$1"
      opensc-tool --list-readers \
        | awk '/^[0-9]+/ { idx=$1; if (match($0, /\(([0-9A-Fa-f]+)\)/, m)) print idx, m[1] }' \
        | awk -v w="$want" '$2==w {print $1; exit}'
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

    hsm_has_key() {
      local module="$1" serial="$2" pin="$3" label="$4" hexId="$5"
      local slot
      slot="$(serial_to_slot "$module" "$serial")"
      [[ -z "$slot" ]] && return 1
      pkcs11-tool --module "$module" --slot-index "$slot" --login --pin "$pin" \
          --list-objects --type privkey 2>/dev/null \
        | awk -v l="$label" -v e="$hexId" '
            /Object/ { lab=""; hx="" }
            /label/  { lab=$NF }
            /ID:/    { hx=$NF; gsub(/[^0-9A-Fa-f]/,"",hx); hx=tolower(hx) }
            lab==l && hx==e && hx!="" { print "yes"; exit }
          ' | grep -qx yes
    }
  '';
}
