# Hardware-gated check for the DKEK restore state table.
#
# A runnable tool (not a `checks/` derivation): it needs a real HSM and PINs
# from the caller's environment at RUN time. Skips with exit 0 if either is
# absent, mirroring the other hardware suites. Verifies:
#   pre-init  -> --restore-dkek initializes, then imports
#   pending   -> --restore-dkek imports directly
#   pending   -> plain provision resumes by importing the shares
#   complete  -> --restore-dkek is a no-op; --force wipes and rebuilds
#   bad files -> --restore-dkek refuses before touching the device
# Factory-reset leaves the HSM pre-init at the end.
#
# Usage:
#   PICO_HSM_TEST_SERIAL=<serial> PICO_HSM_PIN=<pin> PICO_HSM_SO_PIN=<pin> \
#     dkek-restore-states [--confirm]
{
  pkgs,
  inputs,
  pname,
  ...
}:
let
  confirm = import ./confirm.nix { inherit pkgs; };
  dkek = inputs.self.packages.${system}.pico-hsm-dkek;
  provision = inputs.self.packages.${system}.pico-hsm-provision;
  reset = inputs.self.packages.${system}.pico-hsm-factory-reset;
  system = pkgs.stdenv.hostPlatform.system;
in
pkgs.writeShellApplication {
  extraShellCheckFlags = [ "-x" ];
  meta = {
    description = "Drive and verify all DKEK restore states on the test HSM (hardware-gated).";
    license = pkgs.lib.licenses.agpl3Only;
    mainProgram = "dkek-restore-states";
  };
  name = pname;
  runtimeInputs = dkek.deps;
  text = ''
    set -euo pipefail

    source ${dkek}
    # shellcheck source=/dev/null
    source ${confirm}

    # shellcheck disable=SC2034
    for arg in "$@"; do
      [[ "$arg" == "--confirm" ]] && CONFIRMED=1
    done
    require_confirm

    # Gate: skip if the test HSM or its credentials are not supplied.
    if [[ -z "''${PICO_HSM_TEST_SERIAL:-}" || -z "''${PICO_HSM_PIN:-}" || -z "''${PICO_HSM_SO_PIN:-}" ]]; then
      echo "SKIP: PICO_HSM_TEST_SERIAL / PICO_HSM_PIN / PICO_HSM_SO_PIN not set."
      exit 0
    fi
    serial="$PICO_HSM_TEST_SERIAL"
    readers="$(opensc-tool --list-readers 2>/dev/null | tr -d '\n' || true)"
    if ! grep -q "$serial" <<< "$readers"; then
      echo "SKIP: test HSM $serial not present; hardware-gated check skipped."
      exit 0
    fi
    export PICO_HSM_DKEK_PASSWORD="''${PICO_HSM_DKEK_PASSWORD:-$PICO_HSM_PIN}"
    # This check rotates nothing; ambient rotation settings would change the
    # SO-PIN underneath its state assertions.
    unset PICO_HSM_NEW_SO_PIN

    work="$(mktemp -d)"
    trap 'rm -rf "$work"' EXIT

    must_fail() {
      local label="$1" expected="$2"; shift 2
      local rc=0
      "$@" >"$work/out" 2>&1 || rc=$?
      if [[ $rc -eq 0 ]] || ! grep -q "$expected" "$work/out"; then
        echo "FAIL $label: expected failure containing '$expected', got rc=$rc:" >&2
        cat "$work/out" >&2
        exit 1
      fi
    }

    must_pass() {
      local label="$1"; shift
      if ! "$@" >"$work/out" 2>&1; then
        echo "FAIL $label:" >&2
        cat "$work/out" >&2
        exit 1
      fi
    }

    # Save a known-good share set. Every restore below uses this dir; the
    # restore paths must never create or modify its files.
    shares="$work/shares"
    ${pkgs.lib.getExe reset} --serial "$serial" >/dev/null
    must_pass "seed-provision: pre-init --force -> init, create/import shares" ${pkgs.lib.getExe provision} "$serial" \
      --dkek-dir "$shares" --force
    test -s "$shares/dkek.1.pbe"
    before="$(sha256sum "$shares/dkek.1.pbe" | cut -d' ' -f1)"

    ${pkgs.lib.getExe reset} --serial "$serial" >/dev/null
    if dkek_complete "$serial"; then echo "FAIL pre-init: dkek_complete must be false" >&2; exit 1; fi
    must_pass "restore-from-preinit: pre-init -> --restore-dkek initializes, then imports" ${pkgs.lib.getExe provision} "$serial" \
      --dkek-dir "$shares" --restore-dkek
    dkek_complete "$serial" || { echo "FAIL pre-init: DKEK not complete after restore" >&2; exit 1; }

    to_pending() {
      ${pkgs.lib.getExe reset} --serial "$serial" >/dev/null
      require_pin_tries "$serial" "initialize the HSM"
      schsm "$serial" --initialize \
        --so-pin env:PICO_HSM_SO_PIN --pin env:PICO_HSM_PIN \
        --dkek-shares 1 >/dev/null 2>&1
      dkek_pending "$serial" || { echo "FAIL: expected pending state" >&2; exit 1; }
    }

    to_pending
    must_pass "restore-from-pending: pending -> --restore-dkek imports directly" ${pkgs.lib.getExe provision} "$serial" \
      --dkek-dir "$shares" --restore-dkek
    dkek_complete "$serial" || { echo "FAIL pending: DKEK not complete after restore" >&2; exit 1; }

    to_pending
    must_pass "provision-from-pending: pending -> plain provision imports the shares" ${pkgs.lib.getExe provision} "$serial" \
      --dkek-dir "$shares"
    dkek_complete "$serial" || { echo "FAIL pending: DKEK not complete after plain provision" >&2; exit 1; }

    must_pass "restore-from-complete: complete -> --restore-dkek is a no-op" ${pkgs.lib.getExe provision} "$serial" \
      --dkek-dir "$shares" --restore-dkek
    must_pass "force-restore: complete --force -> wipes and rebuilds from the shares" ${pkgs.lib.getExe provision} "$serial" \
      --dkek-dir "$shares" --restore-dkek --force
    dkek_complete "$serial" || { echo "FAIL force: DKEK not complete after restore" >&2; exit 1; }

    bad="$work/bad"
    mkdir -p "$bad"
    printf 'not a share' > "$bad/dkek.1.pbe"
    must_fail "invalid-share: bad shares -> refuses before touching the device" "missing or invalid" ${pkgs.lib.getExe provision} "$serial" \
      --dkek-dir "$bad" --restore-dkek

    # No restore path modified the share files.
    after="$(sha256sum "$shares/dkek.1.pbe" | cut -d' ' -f1)"
    [[ "$before" == "$after" ]] || { echo "FAIL: share file was modified" >&2; exit 1; }

    ${pkgs.lib.getExe reset} --serial "$serial" >/dev/null
    echo "dkek-restore-states: PASSED"
  '';
}
