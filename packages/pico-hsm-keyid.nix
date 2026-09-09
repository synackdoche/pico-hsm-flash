# `pico-hsm-keyid`: base64-encode a single key label.
#
# The `blechschmidt/pkcs11` provider expects a CKA_ID as base64 of the raw
# bytes. This encodes an arbitrary label (e.g. "root", "env-root-prod")
# into the base64 value used as an ID.
#
# Usage: pico-hsm-keyid <label>
#   e.g. pico-hsm-keyid root           -> <base64 of "root">
#        pico-hsm-keyid env-root-prod  -> <base64 of "env-root-prod">
{
  pkgs,
  ...
}:
pkgs.writeShellApplication {
  meta = {
    description = "Base64-encode a key label for a PKCS#11 CKA_ID";
    mainProgram = "pico-hsm-keyid";
  };
  name = "pico-hsm-keyid";
  runtimeInputs = [
    pkgs.coreutils
  ];
  text = ''
    set -euo pipefail
    if [[ $# -ne 1 ]]; then
      echo "Usage: pico-hsm-keyid <label>" >&2
      exit 2
    fi
    printf '%s' "$1" | base64 -w0
  '';
}
