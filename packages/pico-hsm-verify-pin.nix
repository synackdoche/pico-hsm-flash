{
  pkgs,
  inputs,
  pname,
  ...
}:
let
  slots = inputs.self.packages.${system}.pkcs11-slots;
  system = pkgs.stdenv.hostPlatform.system;
in
pkgs.writeShellApplication {
  extraShellCheckFlags = [ "-x" ];
  name = pname;
  runtimeInputs = slots.deps;
  text = ''
    source ${slots}

    usage() {
      echo "Usage: pico-hsm-verify-pin --serial <serial>"
      echo "Verify the SO-PIN and reset its retry counter. The PIN is verified by"
      echo "a same-PIN change: the applet verifies it and re-writes the same value,"
      echo "which resets the retry counter to full without changing anything else."
      echo "The call is one deliberate presentation: a WRONG PIN spends one try, and"
      echo "on a device with a single try left it blocks the SO-PIN. Use it when the"
      echo "counter is depleted and you are sure of the PIN."
      echo ""
      echo "Environment: PICO_HSM_SO_PIN (the PIN to verify, never an argument)."
    }

    main() {
      local serial=""
      while (( $# )); do
        case "$1" in
          --serial) serial="$2"; shift 2 ;;
          -h|--help) usage; return 0 ;;
          *) echo "ERROR: unknown argument: $1" >&2; usage >&2; exit 2 ;;
        esac
      done
      : "''${PICO_HSM_SO_PIN:?PICO_HSM_SO_PIN is required (the SO-PIN to verify)}"
      [[ -n "$serial" ]] || { echo "ERROR: --serial is required." >&2; exit 2; }
      local attempts=10 i out rc slot verified=0
      for (( i = 1; i <= attempts; i++ )); do
        wait_settled "$serial"
        slot="$(usb_serial_to_slot "$serial")"
        if [[ -z "$slot" ]]; then
          sleep 1
          continue
        fi
        rc=0
        out="$(pkcs11-tool --module "$pkcs11_opensc_module" --slot-index "$slot" --change-pin \
            --login --login-type so \
            --so-pin "env:PICO_HSM_SO_PIN" --new-pin "env:PICO_HSM_SO_PIN" 2>&1)" || rc=$?
        if [[ $rc -eq 0 ]]; then
          verified=1
          break
        fi
        # A PIN rejection is final: retrying would spend another try.
        if grep -qi 'CKR_PIN_INCORRECT' <<< "$out"; then
          echo "ERROR: PIN verification failed (PIN_INCORRECT). One SO-PIN try was spent." >&2
          echo "$out" >&2
          exit 2
        fi
        # Detach during the transfer: the applet never judged the PIN, retry.
        if grep -qiE 'CKR_DEVICE_ERROR|CKR_DEVICE_REMOVED|CKR_TOKEN_NOT_PRESENT|CKR_USER_PIN_NOT_INITIALIZED|CKR_GENERAL_ERROR|reader|transact|connect' <<< "$out"; then
          if [[ $i -lt $attempts ]]; then
            wait_reconnect "$serial" 20
            continue
          fi
        fi
        echo "ERROR: PIN verification failed (pkcs11-tool exit $rc):" >&2
        echo "$out" >&2
        exit 2
      done
      [[ $verified -eq 1 ]] || { echo "ERROR: PIN verification did not complete after $attempts attempts." >&2; exit 2; }
      echo "==> SO-PIN verified on HSM (serial $serial): the retry counter is reset."
    }

    main "$@"
  '';
}
