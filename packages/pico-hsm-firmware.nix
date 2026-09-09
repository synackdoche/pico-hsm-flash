# Pico HSM firmware for ESP32-S3 (reproducible build).
#
# Two variants:
#   pico-hsm-firmware       — production firmware (unpatched, no factory reset)
#   pico-hsm-firmware-test  — test firmware (patched with a factory-reset APDU
#                             command that erases flash to a pre-init state)
#
# The test variant is ONLY for the spare test HSMs. It is never flashed to
# production HSMs; `pico-hsm-flash --test-firmware` is the explicit opt-in.
{
  pkgs,
  inputs,
  ...
}:
let
  lib = pkgs.lib;
  esp-idf =
    (inputs.nixpkgs-esp-dev.packages.${pkgs.stdenv.hostPlatform.system}.esp-idf-xtensa).override
      {
        rev = "v5.5";
        sha256 = "sha256-5G3IBVkpt8uuFzazwVHiwnqfMig3aMYmfcpKyMPWCBI=";
      };

  esp-tinyusb = pkgs.fetchzip {
    url = "https://components-file.espressif.com/components/espressif/esp_tinyusb/1.7.6/espressif__esp_tinyusb-v1.7.6.zip";
    hash = "sha256-so6Vb1z91B8/k2PBftPQjpB12OamqnbTKA2Fs33WFgs=";
    stripRoot = false;
  };
  neopixel = pkgs.fetchzip {
    url = "https://components-file.espressif.com/components/zorxx/neopixel/1.0.10/zorxx__neopixel-v1.0.10.zip";
    hash = "sha256-mJZWcHqPDQVUWkNHQazDEI+AJybn13Ld8njOwp5f2GQ=";
    stripRoot = false;
  };
  tinyusb = pkgs.fetchzip {
    url = "https://components-file.espressif.com/components/espressif/tinyusb/0.19.0~3/espressif__tinyusb-v0.19.0_3.zip";
    hash = "sha256-VMkTz+eP6kqSCZ6U/bjfqTXIm7W/4joGi0+/ZJraayQ=";
    stripRoot = false;
  };

  # Build the firmware, optionally applying the factory-reset patch.
  mkFirmware =
    { testFirmware }:
    pkgs.stdenv.mkDerivation rec {
      pname = if testFirmware then "pico-hsm-firmware-test" else "pico-hsm-firmware";
      version = "6.6";

      src = pkgs.fetchFromGitHub {
        owner = "polhenarejos";
        repo = "pico-hsm";
        rev = "v${version}";
        hash = "sha256-0fHbn6lttHVac/xkHthfmWrbIGNgXf51uMwbqc8wYhI=";
        fetchSubmodules = true;
      };

      buildInputs = [
        esp-idf
        esp-tinyusb
        neopixel
        tinyusb
        pkgs.esptool
      ];

      # Apply the factory-reset patch only for the test variant.
      patches = lib.optional testFirmware ../patches/factory-reset.patch;

      phases = [
        "unpackPhase"
        "patchPhase"
        "buildPhase"
      ];

      buildPhase = ''
        cp -r ${src}/* .
        chmod -R +w .

        mkdir temp-home
        export HOME=$(readlink -f temp-home)

        mkdir -p managed_components
        cp -r ${esp-tinyusb} managed_components/espressif__esp_tinyusb
        cp -r ${neopixel} managed_components/zorxx__neopixel
        cp -r ${tinyusb} managed_components/espressif__tinyusb
        chmod -R +w managed_components

        cat > pico-keys-sdk/config/esp32/components/pico-keys-sdk/idf_component.yml <<EOF
        dependencies:
          espressif/esp_tinyusb:
            version: "*"
            override_path: "../../../../../managed_components/espressif__esp_tinyusb"
          zorxx/neopixel:
            version: "*"
            override_path: "../../../../../managed_components/zorxx__neopixel"
        EOF

        cat > managed_components/espressif__esp_tinyusb/idf_component.yml <<EOF
        dependencies:
          idf: '>=5.0'
          tinyusb:
            public: true
            version: '*'
            override_path: "../espressif__tinyusb"
        description: Espressif's additions to TinyUSB
        version: 1.7.6
        EOF

        idf.py --preview set-target esp32s3
        export NINJAFLAGS=-v
        idf.py build

        mkdir -p $out
        cd build
        ${lib.getExe pkgs.esptool} --chip ESP32-S3 merge_bin -o "$out/pico-hsm-${version}-esp32s3.bin" @flash_args
      '';

      meta = {
        description = "Pico HSM firmware for ESP32-S3 (reproducible build)";
        license = lib.licenses.agpl3Only;
        homepage = "https://github.com/polhenarejos/pico-hsm";
        platforms = lib.platforms.all;
      };
    };
in
pkgs.emptyDirectory.overrideAttrs {
  passthru = {
    pico-hsm-firmware = mkFirmware { testFirmware = false; };
    pico-hsm-firmware-test = mkFirmware { testFirmware = true; };
  };
}
