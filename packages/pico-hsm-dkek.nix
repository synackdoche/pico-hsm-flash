# pico-hsm-dkek: DKEK share lifecycle helpers for a PicoHSM.
#
# A source-able function library (writeTextFile — no shebang, not executable).
# `deps` lists the tools these functions need; sourcing apps add it to their
# runtimeInputs, so Nix tracks the dependency without baking store paths here.
#
# sc-hsm-tool is UNRELIABLE: it exits 0 even when --initialize fails or the
# card is unreachable, and its output is unstructured. So we NEVER infer
# success from exit status or output text. Instead, every operation verifies
# its own POSTCONDITION against the device or filesystem, and fails loudly if
# the intended state change did not happen.
#
# TRANSIENT connection failures: the firmware stages flash writes in RAM and
# flushes them LATER on core0 (do_flash), disabling interrupts and locking out
# core1 (which services TinyUSB) around each erase/program. A host APDU that
# arrives during that window sees the reader briefly absent. This is transient
# and safe to retry. schsm retries ONLY those conditions and surfaces any other
# failure immediately so a real error is never masked.
#
# SECRETS: every PIN/password argument is the NAME of an environment variable
# holding the secret. Tools are passed `env:<name>` so the secret is read by
# the tool itself and never appears in a process's argv (visible to `ps`).
#
# Apps `source` it to get:
#
#   schsm <serial> <args...>   run sc-hsm-tool against that HSM, re-resolving
#                              the reader per attempt, retrying transient
#                              connection failures and failing on any other error
#   dkek_complete <serial>     0 iff the DKEK is fully reconstructed
#   dkek_pending <serial>      0 iff the DKEK is waiting for share imports
#   dkek_state <serial>        the DKEK state string (KCV or pending)
#   create_dkek_shares <serial> <dir> <shares> <passwordEnv>
#     -> create <shares> DKEK share files, verifying each is a valid share
#   import_dkek_shares <serial> <dir> <shares> <passwordEnv>
#     -> import the shares, verifying the DKEK is complete afterwards
#   validate_dkek_shares <dir> <shares>
#     -> fail before touching the device if any share file is missing/invalid
#   init_hsm <serial> <soPinEnv> <pinEnv> <shares> <force> <newSoPinEnv>
#     -> initialize the HSM, verifying it is initialized afterwards; if
#        <newSoPinEnv> is given (and differs), rotate the SO-PIN afterwards
#   change_so_pin <serial> <oldSoPinEnv> <newSoPinEnv>
#     -> rotate the SO-PIN, verifying the DKEK state is unchanged afterwards
#
# Every operation takes a USB SERIAL, never a reader index: the serial is a
# stable identity, whereas a reader index is positional and can shift between
# enumeration and use. The reader index is resolved internally, immediately
# before the operation, via require_reader (which fails loudly if absent).
{ pkgs, inputs, ... }:
let
  lib = pkgs.writeTextFile {
    name = "pico-hsm-dkek";
    text = ''
      source ${slots}
      # Run sc-hsm-tool against <serial>, re-resolving the reader index on
      # every attempt: a deferred flash flush re-enumerates the device, and an
      # index resolved before the flush can point at the wrong reader after it.
      # Retries ONLY transient connection failures; any other failure (or a
      # masked exit 0) is retried, but callers MUST verify their postcondition
      # — a dropped reader can still exit 0 with no output.
      schsm() {
        local serial="$1" reader out rc=0
        shift
        local attempts=20 i
        for (( i = 1; i <= attempts; i++ )); do
          rc=0
          wait_settled "$serial"
          reader="$(usb_serial_to_slot "$serial")"
          if [[ -z "$reader" ]]; then
            sleep 1
            continue
          fi
          # `|| rc=$?` keeps `set -e` from aborting before rc is read.
          out="$(sc-hsm-tool --reader "$reader" "$@" 2>&1)" || rc=$?
          if [[ $rc -eq 0 ]] && ! _schsm_transient "$out"; then
            [[ -n "$out" ]] && printf '%s\n' "$out"
            return 0
          fi
          if [[ $i -lt $attempts ]]; then
            sleep 1
            continue
          fi
          [[ -n "$out" ]] && printf '%s\n' "$out"
          echo "ERROR: sc-hsm-tool failed (exit $rc)." >&2
          exit 2
        done
      }

      # --- Device-state probes (query the DEVICE, not an operation's output) ---

      # The current SO-PIN retry count, or empty when the token has no SO PIN
      # yet (a pre-init --initialize only SETS pins, so nothing is verified).
      so_pin_tries() {
        local serial="$1" out
        out="$(wait_for_status "$serial")"
        grep -iE 'SO-PIN tries' <<< "$out" | grep -oE '[0-9]+$' || true
      }

      # Refuse to present a PIN when one wrong presentation would drop the last
      # try to 0 and block the token. Whether the PIN is right cannot be known
      # before presenting it, so a counter below 2 is never risked.
      require_pin_tries() {
        local serial="$1" what="$2" tries
        tries="$(so_pin_tries "$serial")"
        [[ -z "$tries" ]] && return 0
        if (( tries < 2 )); then
          echo "ERROR: SO-PIN tries left: $tries; refusing to $what — a wrong PIN would block the HSM. Present the correct PIN deliberately with pico-hsm-verify-pin --serial $serial to reset the counter." >&2
          exit 2
        fi
      }

      # 0 iff the DKEK on the HSM with the given USB serial is fully
      # reconstructed. PKCS#11 has no DKEK concept; the device prints its Key
      # Check Value only when no shares are outstanding. The verdict is taken
      # from one clean status read.
      dkek_complete() {
        local serial="$1" out
        out="$(wait_for_status "$serial")"
        # Pre-init prints a zero KCV with "DKEK shares : 0"; a pending card
        # prints no KCV line at all. A completed DKEK prints a KCV and has a
        # nonzero share count (the KCV itself may legitimately be all zeros).
        grep -qiE 'key check value +:' <<< "$out" \
          && ! grep -qi 'import pending' <<< "$out" \
          && grep -qiE 'DKEK shares +: +[1-9]' <<< "$out"
      }

      # 0 iff the device is in the pending-DKEK state ("DKEK import pending").
      # PKCS#11 reports such a token as uninitialized, so this can only be
      # probed via sc-hsm-tool's status text.
      dkek_pending() {
        local serial="$1" out
        out="$(wait_for_status "$serial")"
        grep -qi 'DKEK import pending' <<< "$out"
      }

      # The DKEK state as a single stable string: the Key Check Value when the
      # DKEK is complete, or the pending-share count when it is not. Deliberately
      # EXCLUDES the SO-PIN tries counter (which a rotation resets), so it
      # isolates "did the keys survive" for before/after comparison.
      dkek_state() {
        local serial="$1" out
        out="$(wait_for_status "$serial")"
        grep -iE 'key check value|import pending' <<< "$out" \
          | sed 's/^[[:space:]]*//' || true
      }

      # --- Operations (each verifies its own postcondition) --------------------

      # Create <shares> DKEK share files (<dir>/dkek.<i>.pbe). Refuses to run if
      # ANY share already exists: a share is the only path back to the keys, so
      # silently overwriting one destroys recovery. Fresh dirs are the caller's
      # job. An empty password env var lets sc-hsm-tool prompt (with confirmation).
      create_dkek_shares() {
        local serial="$1" dir="$2" shares="$3" passwordEnv="$4"
        local -a pwArgs=()
        [[ -z "$passwordEnv" ]] || pwArgs=(--password "env:$passwordEnv")
        mkdir -p "$dir"
        local -a existing=("$dir"/dkek.*.pbe)
        if [[ -e "''${existing[0]}" ]]; then
          echo "ERROR: DKEK share(s) already exist in $dir; refusing to overwrite recovery shares." >&2
          exit 2
        fi
        echo "==> Creating $shares DKEK share(s) in $dir"
        local i f
        for i in $(seq 1 "$shares"); do
          f="$dir/dkek.$i.pbe"
          schsm "$serial" --create-dkek-share "$f" "''${pwArgs[@]}"
          # Postcondition: a valid 64-byte DKEK share file (OpenSSL "Salted__").
          if [[ ! -f "$f" ]] || [[ "$(stat -c %s "$f")" != 64 ]] || [[ "$(head -c 8 "$f")" != "Salted__" ]]; then
            echo "ERROR: DKEK share $f was not created (postcondition failed)." >&2
            exit 2
          fi
        done
      }

      # Validate every share before touching the device: they are the only
      # path back to the keys, and a partial import would destroy that path.
      validate_dkek_shares() {
        local dir="$1" shares="$2"
        local i f
        for i in $(seq 1 "$shares"); do
          f="$dir/dkek.$i.pbe"
          if [[ ! -f "$f" ]] || [[ "$(stat -c %s "$f")" != 64 ]] || [[ "$(head -c 8 "$f")" != "Salted__" ]]; then
            echo "ERROR: DKEK share $f is missing or invalid; cannot import." >&2
            exit 2
          fi
        done
      }

      # Import the DKEK shares from <dir> into the HSM.
      import_dkek_shares() {
        local serial="$1" dir="$2" shares="$3" passwordEnv="$4"
        validate_dkek_shares "$dir" "$shares"
        local -a pwArgs=()
        [[ -z "$passwordEnv" ]] || pwArgs=(--password "env:$passwordEnv")
        echo "==> Importing DKEK share(s) from $dir"
        for i in $(seq 1 "$shares"); do
          schsm "$serial" --import-dkek-share "$dir/dkek.$i.pbe" "''${pwArgs[@]}"
        done
        # Postcondition: the DKEK is fully reconstructed.
        if ! dkek_complete "$serial"; then
          echo "ERROR: DKEK is not complete after importing $shares share(s)." >&2
          exit 2
        fi
      }

      # Initialize the HSM with a DKEK of <shares> shares. <force> (non-empty)
      # passes --force. <newSoPinEnv> (optional) rotates the SO-PIN to the value
      # held there after a successful init.
      init_hsm() {
        local serial="$1" soPinEnv="$2" pinEnv="$3" shares="$4" force="''${5:-}" newSoPinEnv="''${6:-}"
        local reader
        reader="$(require_reader "$serial")"
        local -a forceArgs=()
        [[ -n "$force" ]] && forceArgs=(--force)
        echo "==> Initializing HSM (serial $serial, reader $reader), $shares DKEK share(s)"
        require_pin_tries "$serial" "initialize the HSM"
        schsm "$serial" --initialize "''${forceArgs[@]}" --so-pin "env:$soPinEnv" --pin "env:$pinEnv" --dkek-shares "$shares"
        # Postcondition: --initialize puts the device into the pending-DKEK
        # state. PKCS#11 still reports it uninitialized at this point, so the
        # token flag cannot be used here. dkek_pending waits for a clean read.
        if ! dkek_pending "$serial"; then
          echo "ERROR: HSM (serial $serial) is not waiting for DKEK shares after --initialize." >&2
          exit 2
        fi

        # Optional: rotate the SO-PIN to a distinct final value. change_so_pin
        # verifies the DKEK state is unchanged (keys survived).
        if [[ -n "$newSoPinEnv" ]]; then
          change_so_pin "$serial" "$soPinEnv" "$newSoPinEnv"
        fi
      }

      # Rotate the SO-PIN of an initialized HSM. NON-DESTRUCTIVE: the DKEK and all
      # keys are preserved (the MKEK is re-wrapped under the new SO-PIN). Verifies
      # the DKEK state is UNCHANGED afterwards, proving the keys survived.
      #
      # PIN-try safety: only the applet's verify inside C_SetPIN spends a try
      # (PKCS#11 SO login on this stack does not verify). So retry ONLY a
      # detach-class failure — the APDU died at the transport and the applet
      # never judged the PIN. Anything else, in particular PIN_INCORRECT, must
      # not be retried: each retry re-presents a PIN. Worst case is one spent
      # try, when a detach swallowed a change that had actually applied.
      change_so_pin() {
        local serial="$1" oldSoPinEnv="$2" newSoPinEnv="$3"
        local slot
        slot="$(require_reader "$serial")"
        if ! dkek_complete "$serial"; then
          echo "ERROR: HSM (serial $serial) has no DKEK; nothing to rotate." >&2
          exit 2
        fi
        local before after
        before="$(dkek_state "$serial")"
        require_pin_tries "$serial" "rotate the SO-PIN"
        echo "==> Rotating SO-PIN (serial $serial, slot $slot)"
        local attempts=10 i out rc rotated=0
        for (( i = 1; i <= attempts; i++ )); do
          # Re-resolve the slot per attempt: the reader index shifts when the
          # device re-enumerates after a deferred flash flush.
          wait_settled "$serial"
          slot="$(usb_serial_to_slot "$serial")"
          if [[ -z "$slot" ]]; then
            sleep 1
            continue
          fi
          rc=0
          out="$(pkcs11-tool --module "$pkcs11_opensc_module" --slot-index "$slot" --change-pin \
              --login --login-type so --so-pin "env:$oldSoPinEnv" --new-pin "env:$newSoPinEnv" 2>&1)" || rc=$?
          if [[ $rc -eq 0 ]]; then
            rotated=1
            break
          fi
          if grep -qi 'CKR_PIN_INCORRECT' <<< "$out"; then
            echo "ERROR: SO-PIN change rejected PIN_INCORRECT. Either the SO-PIN in $oldSoPinEnv is wrong, or an earlier detach already applied the change (the old PIN is gone). Not retrying: each wrong presentation spends an SO-PIN try." >&2
            echo "$out" >&2
            exit 2
          fi
          if grep -qiE 'CKR_DEVICE_ERROR|CKR_DEVICE_REMOVED|CKR_TOKEN_NOT_PRESENT|CKR_USER_PIN_NOT_INITIALIZED|CKR_GENERAL_ERROR|reader|transact|connect' <<< "$out"; then
            if [[ $i -lt $attempts ]]; then
              wait_reconnect "$serial" 20
              continue
            fi
          fi
          echo "ERROR: SO-PIN change failed (pkcs11-tool exit $rc):" >&2
          echo "$out" >&2
          exit 2
        done
        if [[ $rotated -ne 1 ]]; then
          echo "ERROR: SO-PIN change did not complete after $attempts attempts." >&2
          exit 2
        fi
        after="$(dkek_state "$serial")"
        if [[ "$before" != "$after" ]]; then
          echo "ERROR: DKEK state changed during SO-PIN rotation (keys may be lost):" >&2
          printf '  before: %s\n  after:  %s\n' "$before" "$after" >&2
          exit 2
        fi
      }
    '';
  };
  slots = inputs.self.packages.${system}.pkcs11-slots;
  system = pkgs.stdenv.hostPlatform.system;
in
lib.overrideAttrs (old: {
  meta.license = pkgs.lib.licenses.agpl3Only;
  passthru = (old.passthru or { }) // {
    deps = slots.deps ++ [
      pkgs.gnugrep
      pkgs.gnused
    ];
  };
})
