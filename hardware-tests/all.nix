# Runs every hardware test by looping over the hardware-tests attributes.
# Each attribute has a shell preamble that sets/unsets env vars and supplies
# arguments for that test. All four env vars are required; missing any is a
# hard error, not a skip.
# Usage:
#   PICO_HSM_TEST_SERIAL=<serial> PICO_HSM_PIN=<pin> PICO_HSM_SO_PIN=<pin> \
#     PICO_HSM_NEW_SO_PIN=<new-pin> hardware-tests-all [--confirm]
{
  pkgs,
  confirm,
  pname,
  tests,
  ...
}:
let
  common = ''
    export PICO_HSM_PIN PICO_HSM_SO_PIN
    unset PICO_HSM_NEW_SO_PIN
  '';
  entries = map (name: {
    inherit name;
    drv = tests.${name};
    pre = envFor.${name} or common;
  }) ordered;
  envFor = {
    check-can-change-so-pin = ''
      export PICO_HSM_PIN PICO_HSM_SO_PIN PICO_HSM_NEW_SO_PIN
      args=(--serial "$PICO_HSM_TEST_SERIAL")
      # Rotate to the new SO-PIN and immediately back, so later tests still
      # use PICO_HSM_SO_PIN.
      restore() {
        local saved="$PICO_HSM_SO_PIN"
        PICO_HSM_SO_PIN="$PICO_HSM_NEW_SO_PIN"
        PICO_HSM_NEW_SO_PIN="$saved"
        export PICO_HSM_SO_PIN PICO_HSM_NEW_SO_PIN
        "$1" "''${args[@]}" --confirm
      }
    '';
    check-can-factory-reset = ''
      ${common}
      args=(--serial "$PICO_HSM_TEST_SERIAL")
    '';
    check-can-init = ''
      ${common}
      dkek="$(mktemp -d)"
      trap 'rm -rf "$dkek"' EXIT
      args=(--serial "$PICO_HSM_TEST_SERIAL" --dkek-dir "$dkek" --force)
    '';
    check-can-recover-pin-tries = ''
      ${common}
      args=(--serial "$PICO_HSM_TEST_SERIAL")
    '';
    dkek-restore-states = common;
  };
  lines = map (e: ''
    run ${pkgs.lib.escapeShellArg e.name} ${pkgs.lib.escapeShellArg (pkgs.lib.getExe e.drv)} ${pkgs.lib.escapeShellArg e.pre}
  '') entries;
  names = builtins.attrNames (builtins.removeAttrs tests [ "all" ]);
  # Factory-reset first: check-can-init only initializes from pre-init, and
  # re-initializing an initialized HSM needs its current SO-PIN. The reset
  # APDU works from any state without credentials.
  ordered = [
    "check-can-factory-reset"
    "check-can-init"
  ]
  ++ builtins.filter (n: n != "check-can-factory-reset" && n != "check-can-init") names;
in
pkgs.writeShellApplication {
  # The body is generated from Nix attribute values; shellcheck sees the
  # generator literals, not the final script.
  excludeShellChecks = [
    "SC2016"
    "SC2154"
    "SC1091"
    "SC2034"
  ];
  meta = {
    description = "Run all PicoHSM hardware tests in sequence";
    license = pkgs.lib.licenses.agpl3Only;
    mainProgram = "hardware-tests-all";
  };
  name = pname;
  runtimeInputs = builtins.attrValues (builtins.removeAttrs tests [ "all" ]) ++ [ pkgs.coreutils ];
  text = ''
    set -euo pipefail
    : "''${PICO_HSM_TEST_SERIAL:?PICO_HSM_TEST_SERIAL is required}"
    : "''${PICO_HSM_PIN:?PICO_HSM_PIN is required}"
    : "''${PICO_HSM_SO_PIN:?PICO_HSM_SO_PIN is required}"
    : "''${PICO_HSM_NEW_SO_PIN:?PICO_HSM_NEW_SO_PIN is required}"
    export PICO_HSM_TEST_SERIAL

    source ${confirm}
    confirmed_args=()
    for arg in "$@"; do
      if [[ "$arg" == "--confirm" ]]; then CONFIRMED=1
      else confirmed_args+=("$arg"); fi
    done
    require_confirm

    run() {
      local label="$1" testbin="$2" pre="$3"
      # The firmware flushes deferred flash writes and briefly drops the USB
      # token after each operation; let it re-enumerate before the next test.
      sleep 2
      echo "==> $label"
      # Subshell scopes the preamble's env and args. Any failure aborts the
      # whole suite: a hardware test is not optional.
      ( eval "$pre"; "$testbin" "''${args[@]}" --confirm; if declare -F restore >/dev/null; then restore "$testbin"; fi )
    }

    ${pkgs.lib.concatStringsSep "\n" lines}
    echo "hardware-tests-all: PASSED"
  '';
}
