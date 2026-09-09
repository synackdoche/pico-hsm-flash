# Test-only helper: factory-reset a flashed TEST PicoHSM to pre-init state.
#
# This is the SAME APDU flow as pico-hsm-factory-reset (no second, divergent
# success criterion). It exists only as a test-namespace alias; the shared
# require_test_hsm gate verifies the TEST firmware label before any action.
#
# Usage: check-can-factory-reset --serial <serial> [--confirm]
{
  pkgs,
  inputs,
  pname,
  ...
}:
let
  confirm = import ./confirm.nix { inherit pkgs; };
  system = pkgs.stdenv.hostPlatform.system;
in
pkgs.writeShellApplication {
  extraShellCheckFlags = [ "-x" ];
  meta = {
    description = "Check that a given test-firmware PicoHSM can be factory reset (and do it)";
    license = pkgs.lib.licenses.agpl3Only;
    mainProgram = "check-can-factory-reset";
  };
  name = pname;
  runtimeInputs = [
    inputs.self.packages.${system}.pico-hsm-factory-reset
    confirm
  ];
  text = ''
    # shellcheck source=/dev/null
    source ${confirm}
    args=()
    # shellcheck disable=SC2034
    for arg in "$@"; do
      if [[ "$arg" == "--confirm" ]]; then CONFIRMED=1; else args+=("$arg"); fi
    done
    require_confirm
    exec pico-hsm-factory-reset "''${args[@]}"
  '';
}
