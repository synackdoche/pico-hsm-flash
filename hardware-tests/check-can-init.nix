# Test-only helper: guarded device-init of a flashed TEST PicoHSM.
#
# This is a TEST tool, not part of the live deployment path. PINs come from the
# environment, never from this repo. Finds the HSM by USB serial + TEST
# firmware label via the shared require_test_hsm gate, then initializes it
# (sc-hsm-tool --initialize, plus DKEK share create/import when --dkek-dir is
# given).
#
# DESTRUCTIVE: initializing wipes the device's keys and DKEK. The firmware-label
# gate ensures we only ever touch a test-firmware HSM.
#
# Usage: PICO_HSM_PIN=<pin> PICO_HSM_SO_PIN=<pin> [PICO_HSM_NEW_SO_PIN=<pin>]
#        check-can-init --serial <serial> [--dkek-shares N] [--dkek-dir <dir>]
#        [--force] [--confirm]
{
  pkgs,
  inputs,
  pname,
  ...
}:
let
  confirm = import ./confirm.nix { inherit pkgs; };
  dkek = inputs.self.packages.${system}.pico-hsm-dkek;
  fwlabel = inputs.self.packages.${system}.pico-hsm-fwlabel;
  system = pkgs.stdenv.hostPlatform.system;
in
pkgs.writeShellApplication {
  extraShellCheckFlags = [ "-x" ];
  meta = {
    description = "Check that a given test-firmware PicoHSM can be initialized (and do it)";
    license = pkgs.lib.licenses.agpl3Only;
    mainProgram = "check-can-init";
  };
  name = pname;
  runtimeInputs = dkek.deps;
  text = ''
    set -euo pipefail

    source ${dkek}
    source ${fwlabel}
    source ${confirm}

    serial="" dkekShares=1 dkekDir="" forceWipe=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --serial)      serial="$2"; shift 2 ;;
        --dkek-shares) dkekShares="$2"; shift 2 ;;
        --dkek-dir)    dkekDir="$2"; shift 2 ;;
        --force)       forceWipe="--force"; shift ;;
        --confirm)     CONFIRMED=1; shift ;;
        *) echo "Unknown arg: $1" >&2; exit 2 ;;
      esac
    done
    if [[ -z "$serial" ]]; then
      echo "Usage: PICO_HSM_PIN=<pin> PICO_HSM_SO_PIN=<pin> check-can-init --serial <serial> [--dkek-shares N] [--dkek-dir <dir>] [--force] [--confirm]" >&2
      exit 2
    fi

    require_confirm

    : "''${PICO_HSM_PIN:?PICO_HSM_PIN is required}"
    : "''${PICO_HSM_SO_PIN:?PICO_HSM_SO_PIN is required}"
    PICO_HSM_DKEK_PASSWORD="''${PICO_HSM_DKEK_PASSWORD:-$PICO_HSM_PIN}"
    export PICO_HSM_DKEK_PASSWORD

    require_test_hsm "$serial"
    echo "==> Confirmed test HSM (serial $serial, label Pico-HSM-PATCHED_UNSAFE)."

    # Create the DKEK shares first if a directory was given (idempotent: reuse
    # existing shares so a prior recovery set keeps working).
    if [[ -n "$dkekDir" && ! -f "$dkekDir/dkek.1.pbe" ]]; then
      create_dkek_shares "$serial" "$dkekDir" "$dkekShares" PICO_HSM_DKEK_PASSWORD
    fi

    # DESTRUCTIVE: initialize the device (wipes keys + DKEK). init_hsm verifies
    # the HSM is actually initialized afterwards (sc-hsm-tool exits 0 even on
    # failure, so its exit status is not a success signal).
    newSoPinEnv=""
    [[ -z "''${PICO_HSM_NEW_SO_PIN:-}" ]] || newSoPinEnv=PICO_HSM_NEW_SO_PIN
    init_hsm "$serial" PICO_HSM_SO_PIN PICO_HSM_PIN "$dkekShares" "$forceWipe" "$newSoPinEnv"

    if [[ -n "$dkekDir" ]]; then
      import_dkek_shares "$serial" "$dkekDir" "$dkekShares" PICO_HSM_DKEK_PASSWORD
    fi

    echo "==> Initialized: the HSM is ready for key provisioning."
  '';
}
