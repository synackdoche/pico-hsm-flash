{
  pkgs,
  inputs,
  ...
}:
let
  inherit (pkgs) lib;
  firmware = inputs.self.packages.${system}.pico-hsm-firmware.pico-hsm-firmware;
  firmwareTest = inputs.self.packages.${system}.pico-hsm-firmware.pico-hsm-firmware-test;
  system = pkgs.stdenv.hostPlatform.system;
in
pkgs.writeShellApplication {
  meta = {
    description = "Flash Pico HSM firmware to an ESP32-S2/S3 board";
    mainProgram = "pico-hsm-flash";
  };
  name = "pico-hsm-flash";
  runtimeInputs = [
    pkgs.esptool
    firmware
    firmwareTest
  ];
  text = ''
    set -euo pipefail

    # --test-firmware selects the patched test firmware (factory-reset APDU).
    # Default is the production firmware.
    FIRMWARE="${firmware}/pico-hsm-6.6-esp32s3.bin"
    testFirmware=""
    portArgs=()
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --test-firmware) FIRMWARE="${firmwareTest}/pico-hsm-6.6-esp32s3.bin"; testFirmware="1"; shift ;;
        --port) portArgs=(--port "$2"); shift 2 ;;
        *) echo "Usage: pico-hsm-flash [--test-firmware] [--port /dev/ttyUSB0]" >&2; exit 2 ;;
      esac
    done

    if [[ -n "$testFirmware" ]]; then
      echo "==> WARNING: flashing TEST firmware (factory-reset APDU enabled)."
      echo "==> Only for spare test HSMs. Never flash this to production HSMs."
    fi

    echo "==> Flashing $FIRMWARE"
    ${lib.getExe pkgs.esptool} --chip auto "''${portArgs[@]}" write-flash 0x0 "$FIRMWARE"
    echo "==> Done. Reboot the board."
  '';
}
