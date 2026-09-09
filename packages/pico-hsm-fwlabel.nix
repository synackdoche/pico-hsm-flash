# pico-hsm-fwlabel: read the firmware label from a PicoHSM via raw APDU.
#
# A source-able function library (writeTextFile — no shebang, not executable).
# Apps `source` it to get:
#
#   firmware_label <reader> -> the token label baked into the firmware
#
# The label is a compile-time constant in the firmware (e.g. `Pico-HSM` for
# production, `Pico-HSM-PATCHED_UNSAFE` for the test variant). It is readable
# pre-init via EF.TokenInfo (2F03), which is ACL_ALL (no auth required). This
# is the ONLY reliable way to identify the firmware variant before the HSM is
# initialized — `pkcs11-tool --list-slots` shows an empty label pre-init
# because OpenSC's PKCS#15 bind fails without a device cert.
{
  pkgs,
  ...
}:
pkgs.writeTextFile {
  name = "pico-hsm-fwlabel";
  text = ''
    firmware_label() {
      local reader="$1"
      # Select EF.TokenInfo (2F03) and read it. The response is a TLV where
      # tag 0x80 carries the label. opensc-tool prints a hex dump with ASCII.
      opensc-tool -r "$reader" -s 00A40000022F03 -s 00B0000000 2>/dev/null \
        | awk '
            /^[0-9A-Fa-f]{2}( [0-9A-Fa-f]{2})+/ {
              line = substr($0, 1, 48)   # first 16 bytes (hex portion)
              gsub(/ /, "", line)
              hex = hex line
            }
            END {
              n = length(hex) / 2
              i = 1
              while (i + 1 <= n) {
                tag = substr(hex, i*2-1, 2); i++
                len = strtonum("0x" substr(hex, i*2-1, 2)); i++
                if (tag == "30") continue   # SEQUENCE wrapper: parse inside
                if (tag == "80") {          # label
                  for (j = 0; j < len; j++) {
                    printf "%c", strtonum("0x" substr(hex, (i+j)*2-1, 2))
                  }
                  print ""
                  exit
                }
                i += len
              }
            }
          '
    }
  '';
}
