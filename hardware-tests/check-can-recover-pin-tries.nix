# Test-only: prove the SO-PIN try guard refuses to present a PIN at one try,
# and that pico-hsm-verify-pin recovers the counter.
#
# Safety: lowers the SO-PIN retry counter to exactly 1 by reading the counter
# after every wrong presentation (a detach that spends nothing just retries, so
# the count never overshoots), asserts the guarded paths REFUSE without
# spending, then recovers with a same-PIN verify back to the starting count.
# Requires an initialized TEST PicoHSM whose SO-PIN is PICO_HSM_SO_PIN; leaves
# it initialized with the same PIN and the counter reset.
#
# Usage: PICO_HSM_PIN=<pin> PICO_HSM_SO_PIN=<pin> \
#        check-can-recover-pin-tries --serial <serial> [--confirm]
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
  verifyPin = inputs.self.packages.${system}.pico-hsm-verify-pin;
in
pkgs.writeShellApplication {
  extraShellCheckFlags = [ "-x" ];
  meta = {
    description = "Check the SO-PIN try guard refuses at one try and pico-hsm-verify-pin recovers it";
    license = pkgs.lib.licenses.agpl3Only;
    mainProgram = "check-can-recover-pin-tries";
  };
  name = pname;
  runtimeInputs = dkek.deps;
  text = ''
    set -euo pipefail

    source ${dkek}
    source ${fwlabel}
    source ${confirm}

    serial=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --serial)  serial="$2"; shift 2 ;;
        --confirm) CONFIRMED=1; shift ;;
        *) echo "Unknown arg: $1" >&2; exit 2 ;;
      esac
    done
    if [[ -z "$serial" ]]; then
      echo "Usage: PICO_HSM_PIN=<pin> PICO_HSM_SO_PIN=<pin> check-can-recover-pin-tries --serial <serial> [--confirm]" >&2
      exit 2
    fi

    require_confirm

    : "''${PICO_HSM_PIN:?PICO_HSM_PIN is required}"
    : "''${PICO_HSM_SO_PIN:?PICO_HSM_SO_PIN is required}"

    require_test_hsm "$serial"
    echo "==> Confirmed test HSM (serial $serial, label Pico-HSM-PATCHED_UNSAFE)."

    die() { echo "FAIL: $*" >&2; exit 1; }

    start="$(so_pin_tries "$serial")"
    [[ -n "$start" ]] || die "device has no SO-PIN; run check-can-init first"
    (( start >= 2 )) || die "device starts with $start tries; refusing to run"

    # A length-valid wrong PIN derived from the real one (one character
    # differs), so no credential is hardcoded here.
    first="''${PICO_HSM_SO_PIN:0:1}"
    repl=0
    [[ "$first" == "0" ]] && repl=1
    export PICO_HSM_SO_PIN_WRONG="$repl''${PICO_HSM_SO_PIN:1}"

    echo "==> Lowering SO-PIN tries from $start to 1"
    tries="$start"
    i=0
    while (( tries > 1 )); do
      (( ++i <= 60 )) || die "no progress lowering tries (stuck at $tries)"
      slot="$(usb_serial_to_slot "$serial")"
      if [[ -n "$slot" ]]; then
        pkcs11-tool --module "$pkcs11_opensc_module" --slot-index "$slot" --change-pin \
          --login --login-type so \
          --so-pin "env:PICO_HSM_SO_PIN_WRONG" --new-pin "env:PICO_HSM_SO_PIN" >/dev/null 2>&1 || true
      fi
      tries="$(so_pin_tries "$serial")"
      (( tries >= 1 )) || die "device blocked while lowering tries (unexpected)"
    done
    (( tries == 1 )) || die "expected 1 try, got $tries"
    echo "==> At 1 try; the guarded paths must refuse without spending it."

    rc=0
    out="$( ( change_so_pin "$serial" PICO_HSM_SO_PIN PICO_HSM_NEW_SO_PIN ) 2>&1 )" || rc=$?
    (( rc == 2 )) || die "rotation guard did not refuse (rc=$rc): $out"
    [[ "$out" == *"refusing to rotate the SO-PIN"* ]] || die "rotation guard message missing: $out"
    (( "$(so_pin_tries "$serial")" == 1 )) || die "rotation guard spent a try"
    echo "==> Rotation refused at 1 try; counter unchanged."

    rc=0
    out="$( ( init_hsm "$serial" PICO_HSM_SO_PIN PICO_HSM_PIN 1 --force ) 2>&1 )" || rc=$?
    (( rc == 2 )) || die "init guard did not refuse (rc=$rc): $out"
    [[ "$out" == *"refusing to initialize"* ]] || die "init guard message missing: $out"
    (( "$(so_pin_tries "$serial")" == 1 )) || die "init guard spent a try"
    echo "==> Initialization refused at 1 try; counter unchanged."

    ${pkgs.lib.getExe verifyPin} --serial "$serial" || die "pico-hsm-verify-pin failed"
    tries="$(so_pin_tries "$serial")"
    (( tries == start )) || die "counter not reset: expected $start, got $tries"
    echo "==> Counter reset to $start."
    require_pin_tries "$serial" "check the guard passes again"
    echo "==> Guard passes again."
    echo "check-can-recover-pin-tries: PASSED"
  '';
}
