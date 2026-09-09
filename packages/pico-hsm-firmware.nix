# Pico HSM firmware for ESP32-S3 (reproducible build).
#
# Two variants, each stamped with a distinct on-device token label so it is
# identifiable via `pico-hsm-list` / the PKCS#11 token label:
#   pico-hsm-firmware       — production build (SO-PIN init hardening applied),
#                             label `Pico-HSM-PATCHED`
#   pico-hsm-firmware-test  — test build (additionally exposes the factory-reset
#                             APDU), label `Pico-HSM-PATCHED_UNSAFE`
#
# The test variant is ONLY for the spare test HSMs. It is never flashed to
# production HSMs; `pico-hsm-flash --test-firmware` is the explicit opt-in.
{
  pkgs,
  inputs,
  pname,
  ...
}:
let
  inherit (pkgs) lib;
  argpname = pname;
  # Build esp-idf from OUR pkgs (via the esp-dev overlay) so it inherits our
  # nixpkgs config. The esp-dev flake hardcodes a STALE
  # permittedInsecurePackages ("python3.13-ecdsa-0.19.1"), but esptool 4.9.0
  # (bundled in the ESP-IDF toolchain) now pulls ecdsa 0.19.2 — so the input's
  # own package fails to evaluate. Using the overlay against our pkgs (which
  # permits 0.19.2) sidesteps the stale pin.
  esp-idf = (pkgs.extend inputs.nixpkgs-esp-dev.overlays.default).esp-idf-xtensa.override {
    rev = "v5.5";
    sha256 = "sha256-5G3IBVkpt8uuFzazwVHiwnqfMig3aMYmfcpKyMPWCBI=";
  };
  esp-tinyusb = pkgs.fetchzip {
    hash = "sha256-so6Vb1z91B8/k2PBftPQjpB12OamqnbTKA2Fs33WFgs=";
    stripRoot = false;
    url = "https://components-file.espressif.com/components/espressif/esp_tinyusb/1.7.6/espressif__esp_tinyusb-v1.7.6.zip";
  };
  # Build the firmware. <buildFirmwareLabel> is stamped into the token label so
  # each variant is identifiable on-device; <testFirmware> additionally adds the
  # factory-reset APDU.
  mkFirmware =
    { buildFirmwareLabel, testFirmware }:
    pkgs.stdenv.mkDerivation rec {
      buildInputs = [
        esp-idf
        esp-tinyusb
        neopixel
        tinyusb
        pkgs.esptool
      ];
      buildPhase = ''
        chmod -R +w .

        # Stamp the variant's build label into the unpatched token-label
        # literals. Checked substitution: fail the build if the expected
        # literals are not found (so an upstream change can't silently ship a
        # mis-identified firmware).
        expected_label_literals=2
        got=$(grep -c '"Pico-HSM"' src/hsm/sc_hsm.c)
        if [ "$got" != "$expected_label_literals" ]; then
          echo "ERROR: expected $expected_label_literals 'Pico-HSM' literals in sc_hsm.c, found $got" >&2
          exit 1
        fi
        sed -i 's/"Pico-HSM"/"${buildFirmwareLabel}"/g' src/hsm/sc_hsm.c
        if grep -q '"Pico-HSM"' src/hsm/sc_hsm.c; then
          echo "ERROR: unpatched 'Pico-HSM' literal remains in sc_hsm.c" >&2
          exit 1
        fi

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

        # Verify the resulting image actually identifies itself with the
        # expected label, and does NOT still carry the stock 'Pico-HSM' string.
        img="$out/pico-hsm-${version}-esp32s3.bin"
        want="${buildFirmwareLabel}"
        if ! grep -aqP "$want\\x00" "$img"; then
          echo "ERROR: firmware image does not contain label '$want'" >&2
          exit 1
        fi
        if grep -aqP 'Pico-HSM\x00' "$img"; then
          echo "ERROR: firmware image still contains the stock 'Pico-HSM' label" >&2
          exit 1
        fi
      '';
      meta = {
        description = "Pico HSM firmware for ESP32-S3 (reproducible build)";
        homepage = "https://github.com/polhenarejos/pico-hsm";
        license = lib.licenses.agpl3Only;
        platforms = lib.platforms.all;
      };
      # Always harden the init path (require the existing SO-PIN to re-init an
      # already-initialized token) and disable the WebCCID interface, whose
      # WebUSB landing page ("www.picokeys.com") makes the host browser pop up
      # a "Pico Key detected" notification on every USB re-enumeration. The test
      # variant additionally adds the factory-reset APDU. The production variant
      # disables the UART core dump, which would otherwise leak runtime RAM
      # (MKEK/DKEK and derived key material) over an unauthenticated serial port
      # on a crash.
      patches = [
        ../patches/secure-init.patch
        ../patches/disable-webusb-landing.patch
      ]
      ++ lib.optional (!testFirmware) ../patches/disable-coredump-uart.patch
      ++ lib.optional testFirmware ../patches/factory-reset.patch;
      phases = [
        "unpackPhase"
        "patchPhase"
        "buildPhase"
      ];
      pname = argpname + (if testFirmware then "-test" else "");
      src = pkgs.fetchFromGitHub {
        fetchSubmodules = true;
        hash = "sha256-0fHbn6lttHVac/xkHthfmWrbIGNgXf51uMwbqc8wYhI=";
        owner = "polhenarejos";
        repo = "pico-hsm";
        rev = "v${version}";
      };
      version = "6.6";
    };
  neopixel = pkgs.fetchzip {
    hash = "sha256-mJZWcHqPDQVUWkNHQazDEI+AJybn13Ld8njOwp5f2GQ=";
    stripRoot = false;
    url = "https://components-file.espressif.com/components/zorxx/neopixel/1.0.10/zorxx__neopixel-v1.0.10.zip";
  };
  tinyusb = pkgs.fetchzip {
    hash = "sha256-VMkTz+eP6kqSCZ6U/bjfqTXIm7W/4joGi0+/ZJraayQ=";
    stripRoot = false;
    url = "https://components-file.espressif.com/components/espressif/tinyusb/0.19.0~3/espressif__tinyusb-v0.19.0_3.zip";
  };
in
pkgs.emptyDirectory.overrideAttrs {
  passthru = {
    pico-hsm-firmware = mkFirmware {
      buildFirmwareLabel = "Pico-HSM-PATCHED";
      testFirmware = false;
    };
    pico-hsm-firmware-test = mkFirmware {
      buildFirmwareLabel = "Pico-HSM-PATCHED_UNSAFE";
      testFirmware = true;
    };
  };
}
