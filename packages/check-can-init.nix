# check-can-init: guarded device-init of a flashed TEST PicoHSM.
#
# Finds the HSM by USB serial + TEST firmware label (`Pico-HSM-PATCHED_UNSAFE`)
# from picohsm-list's parseable table, then runs `sc-hsm-tool --initialize`
# (+ optional DKEK share create/import when --dkek-dir is given, via the
# pico-hsm-dkek library).
#
# DESTRUCTIVE: initializing wipes the device's keys and DKEK. The firmware-label
# gate ensures we only ever touch a test-firmware HSM.
#
# Usage: check-can-init --serial <serial> --pin <pin> --so-pin <so-pin>
#                      [--new-so-pin <pin>] [--dkek-shares N] [--dkek-dir <dir>]
#                      [--force]
{
  pkgs,
  inputs,
  pname,
  ...
}:
let
  system = pkgs.stdenv.hostPlatform.system;
in
pkgs.writeShellApplication {
  # Follow external `source`d libraries (store paths).
  extraShellCheckFlags = [ "-x" ];
  meta = {
    description = "Check that a given test-firmware PicoHSM can be initialized (and do it)";
    mainProgram = "check-can-init";
  };
  name = pname;
  runtimeInputs = [
    inputs.self.packages.${system}.pico-hsm-list
    inputs.self.packages.${system}.pico-hsm-dkek
    pkgs.opensc # sc-hsm-tool, pkcs11-tool
    pkgs.coreutils # mkdir, seq
    pkgs.gawk # awk
  ];
  text = ''
    set -euo pipefail

    source ${inputs.self.packages.${system}.pkcs11-slots}
    source ${inputs.self.packages.${system}.pico-hsm-dkek}

    serial="" pin="" soPin="" newSoPin="" dkekShares=1 dkekDir="" forceWipe=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --serial)      serial="$2"; shift 2 ;;
        --pin)         pin="$2"; shift 2 ;;
        --so-pin)      soPin="$2"; shift 2 ;;
        --new-so-pin)  newSoPin="$2"; shift 2 ;;
        --dkek-shares) dkekShares="$2"; shift 2 ;;
        --dkek-dir)    dkekDir="$2"; shift 2 ;;
        --force)       forceWipe="--force"; shift ;;
        *) echo "Unknown arg: $1" >&2; exit 2 ;;
      esac
    done
    if [[ -z "$serial" || -z "$pin" || -z "$soPin" ]]; then
      echo "Usage: check-can-init --serial <serial> --pin <pin> --so-pin <so-pin> [--new-so-pin <pin>] [--dkek-shares N] [--dkek-dir <dir>] [--force]" >&2
      exit 2
    fi

    # Gate: the HSM must be present AND running TEST firmware. Match BOTH the
    # USB serial and the TEST firmware label (`Pico-HSM-PATCHED_UNSAFE`) in
    # picohsm-list's parseable table. Record schema:
    #   kind|slot|port|usbserial|serial|fwlabel|fw|keylabel|keyid
    if ! pico-hsm-list --format table \
      | awk -F'|' -v s="$serial" '
          !found && ($1 == "uninit" || $1 == "active") && $4 == s && $6 == "Pico-HSM-PATCHED_UNSAFE" { found = 1 }
          END { exit !found }
        '; then
      echo "no: no test-firmware HSM with USB serial $serial is present." >&2
      exit 1
    fi
    echo "==> Confirmed test HSM (serial $serial, label Pico-HSM-PATCHED_UNSAFE)."

    # Create the DKEK shares first if a directory was given (idempotent: reuse
    # existing shares so a prior recovery set keeps working).
    if [[ -n "$dkekDir" && ! -f "$dkekDir/dkek.1.pbe" ]]; then
      create_dkek_shares "$pkcs11_opensc_module" "$serial" "$dkekDir" "$dkekShares" "$pin"
    fi

    # DESTRUCTIVE: initialize the device (wipes keys + DKEK). init_hsm verifies
    # the HSM is actually initialized afterwards (sc-hsm-tool exits 0 even on
    # failure, so its exit status is not a success signal). --force wipes an
    # already-initialized device; without it, --initialize is a no-op. If
    # --new-so-pin is given, the SO-PIN is rotated to it after init.
    init_hsm "$pkcs11_opensc_module" "$serial" "$soPin" "$pin" "$dkekShares" "$forceWipe" "$newSoPin"

    if [[ -n "$dkekDir" ]]; then
      import_dkek_shares "$pkcs11_opensc_module" "$serial" "$dkekDir" "$dkekShares" "$pin"
    fi

    echo "==> Initialized: the HSM is ready for key provisioning."
  '';
}
