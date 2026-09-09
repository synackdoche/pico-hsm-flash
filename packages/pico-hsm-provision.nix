# pico-hsm-provision: one-time PicoHSM device bring-up.
#
# Initializes the device (SO-PIN/user PIN) and creates + imports the DKEK
# share(s) that anchor the device's trust domain. Creates NO keys or certs —
# those are provisioned declaratively by `hsm-apply` (provider-agnostic).
#
#   PICO_HSM_PIN=<pin> PICO_HSM_SO_PIN=<pin> PICO_HSM_NEW_SO_PIN=<pin> \
#     PICO_HSM_DKEK_PASSWORD=<password> \
#     pico-hsm-provision <serial> [--dkek-shares N] [--dkek-dir D] [--force]
#
# Pass --restore-dkek to import existing shares. It works from any device
# state: a pre-init device is initialized first, a pending device is imported
# directly. A plain re-run after an interrupted run (device pending, shares in
# --dkek-dir) resumes by importing them. The shares are just encrypted files,
# so any shares — for example
# a production DKEK backup being moved onto a former test device — can be
# restored. A complete DKEK is left alone unless --force is given, which
# wipes the device (keys and PINs) and rebuilds it from those files.
# This path never creates new shares.
#
# PINs and the DKEK password come from the environment, never argv: the tools
# are given `env:VARIABLE` so secrets stay out of `ps` output. The serial is
# the device's USB serial (from `opensc-tool --list-readers`). The device's
# role (root / env) is a property of the keys `hsm-apply` writes, not of the
# device, so bring-up is role-agnostic.
{
  pkgs,
  inputs,
  perSystem,
  ...
}:
let
  dkek = perSystem.self.pico-hsm-dkek;
in
pkgs.writeShellApplication {
  extraShellCheckFlags = [ "-x" ];
  meta = {
    description = "One-time Pico HSM device bring-up: initializes the device and creates the DKEK shares that anchor its trust domain.";
    license = pkgs.lib.licenses.agpl3Only;
    mainProgram = "pico-hsm-provision";
  };
  name = "pico-hsm-provision";
  # Hardware tests live outside packages/ so blueprint does not turn them
  # into checks that run (and fail) without hardware + PINs in CI. Exposed via
  # passthru as pico-hsm-provision.hardwareTests.<name>.
  passthru.hardwareTests = import ../hardware-tests {
    inherit pkgs inputs perSystem;
  };
  runtimeInputs = dkek.deps;
  text = ''
    set -euo pipefail

    source ${dkek}

    serial="''${1:-}"
    shift || true
    dkekShares=1 dkekDir="." force="" restore=""

    while [[ $# -gt 0 ]]; do
      case "$1" in
        --dkek-shares) dkekShares="$2"; shift 2 ;;
        --dkek-dir) dkekDir="$2"; shift 2 ;;
        --force) force="--force"; shift ;;
        --restore-dkek) restore="1"; shift ;;
        *) echo "Unknown arg: $1" >&2; exit 2 ;;
      esac
    done

    : "''${PICO_HSM_PIN:?PICO_HSM_PIN is required}"
    : "''${PICO_HSM_SO_PIN:?PICO_HSM_SO_PIN is required}"

    module="$pkcs11_opensc_module"
    reader="$(require_reader "$serial")"
    # The DKEK password is optional: pass its env-var NAME so sc-hsm-tool reads
    # the value itself. When unset, omit the option so the tool prompts.
    dkekPasswordEnv=""
    [[ -z "''${PICO_HSM_DKEK_PASSWORD:-}" ]] || dkekPasswordEnv=PICO_HSM_DKEK_PASSWORD

    mkdir -p "$dkekDir"

    if [[ -n "$restore" ]]; then
      # Validate the shares before any state check: bad files must fail even
      # when the device already has a complete DKEK.
      validate_dkek_shares "$dkekDir" "$dkekShares"
      # Plain restore must never wipe a complete DKEK; --force is the explicit
      # permission to destroy existing keys. Otherwise, initialize whatever
      # state the device is in so it becomes pending, then import the shares.
      if dkek_complete "$serial" && [[ -z "$force" ]]; then
        echo "==> [pico-hsm-provision] DKEK already complete. Use --force to wipe and restore."
        exit 0
      fi
      if dkek_complete "$serial" || ! dkek_pending "$serial"; then
        init_hsm "$serial" PICO_HSM_SO_PIN PICO_HSM_PIN "$dkekShares" "$force" ""
      fi
      import_dkek_shares "$serial" "$dkekDir" "$dkekShares" "$dkekPasswordEnv"
      echo "==> [pico-hsm-provision] done. DKEK restored from $dkekDir."
      exit 0
    fi

    if [[ -z "$force" ]] && hsm_initialized "$module" "$serial" \
       && dkek_complete "$serial"; then
      echo "==> [pico-hsm-provision] HSM $serial already provisioned. No-op."
      exit 0
    fi

    # An interrupted run leaves the device pending with its shares in the
    # target dir; import them instead of wiping and re-creating.
    if dkek_pending "$serial" && [[ -e "$dkekDir"/dkek.1.pbe ]]; then
      import_dkek_shares "$serial" "$dkekDir" "$dkekShares" "$dkekPasswordEnv"
      echo "==> [pico-hsm-provision] done. DKEK restored from $dkekDir."
      exit 0
    fi

    echo "==> [pico-hsm-provision] HSM $serial (reader $reader)"
    create_dkek_shares "$serial" "$dkekDir" "$dkekShares" "$dkekPasswordEnv"
    newSoPinEnv=""
    [[ -z "''${PICO_HSM_NEW_SO_PIN:-}" ]] || newSoPinEnv=PICO_HSM_NEW_SO_PIN
    init_hsm "$serial" PICO_HSM_SO_PIN PICO_HSM_PIN "$dkekShares" "$force" "$newSoPinEnv"
    import_dkek_shares "$serial" "$dkekDir" "$dkekShares" "$dkekPasswordEnv"

    echo "==> [pico-hsm-provision] done. HSM $serial initialized (DKEK complete)."
  '';
}
