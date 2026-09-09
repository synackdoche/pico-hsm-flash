# pico-hsm-dkek: DKEK share lifecycle helpers for a PicoHSM.
#
# A source-able function library (writeTextFile — no shebang, not executable).
#
# sc-hsm-tool is UNRELIABLE: it exits 0 even when --initialize fails or the
# card is unreachable, and its output is unstructured. So we NEVER infer
# success from exit status or output text. Instead, every operation verifies
# its own POSTCONDITION against the device or filesystem, and fails loudly if
# the intended state change did not happen. This is correct-by-construction:
# a false success is impossible because success is only reported once the
# resulting state is positively confirmed.
#
# TRANSIENT "Card not present": the firmware stages flash writes in RAM and
# flushes them LATER on core0 (do_flash), disabling interrupts and locking out
# core1 (which services TinyUSB) around each erase/program. A host APDU that
# arrives during that window sees the reader briefly absent. This is transient
# and safe to retry. schsm retries ONLY on that condition; any other failure is
# surfaced immediately so a real error is never masked.
#
# Apps `source` it to get:
#
#   schsm <args...>            run sc-hsm-tool, retrying transient
#                              "Card not present", failing on any other
#                              non-zero exit
#   dkek_complete <module> <serial>     0 iff the DKEK is fully reconstructed
#   dkek_state <module> <serial>        the DKEK state string (KCV or pending)
#   create_dkek_shares <module> <serial> <dir> <shares> <password>
#     -> create <shares> DKEK share files, verifying each is a valid share
#   import_dkek_shares <module> <serial> <dir> <shares> <password>
#     -> import the shares, verifying the DKEK is complete afterwards
#   init_hsm <module> <serial> <so-pin> <pin> <shares> <force> <new-so-pin>
#     -> initialize the HSM, verifying it is initialized afterwards; if
#        <new-so-pin> is given (and differs from <so-pin>), rotate the SO-PIN
#        to it afterwards (via change_so_pin)
#   change_so_pin <module> <serial> <old-so-pin> <new-so-pin>
#     -> rotate the SO-PIN, verifying the DKEK state is unchanged afterwards
#
# <module> is the caller-owned PKCS#11 module (use $pkcs11_opensc_module from
# pkcs11-slots for the default); it is never hardcoded here.
#
# Every operation takes a USB SERIAL, never a reader index: the serial is a
# stable identity, whereas a reader index is positional and can shift between
# enumeration and use. The reader index is resolved internally, immediately
# before the operation, via require_reader (which fails loudly if absent).
#
# Requires `hsm_initialized` and `require_reader` (from pkcs11-slots) to be
# sourced by the caller. Verification interfaces: initialization is probed via
# PKCS#11 (token label), a DIFFERENT and more stable interface than sc-hsm-tool's
# text. DKEK state has no PKCS#11 representation, so dkek_complete uses a fresh
# read-only sc-hsm-tool status query (independent of any operation's output).
{
  pkgs,
  ...
}:
pkgs.writeTextFile {
  name = "pico-hsm-dkek";
  text = ''
    # Run sc-hsm-tool, retrying ONLY on the transient "Card not present" error
    # and failing on any other non-zero exit. The firmware flushes deferred
    # flash writes after the APDU returns, disabling interrupts and locking out
    # core1 (which services TinyUSB), so the reader can briefly report absent
    # right after an init/keygen/wrap. That condition is transient and safe to
    # retry; every other failure is surfaced immediately so a real error is
    # never masked. Callers MUST still verify their postcondition — this only
    # catches errors the tool reports.
    schsm() {
      local attempts=5 i out rc
      for (( i = 1; i <= attempts; i++ )); do
        out="$(sc-hsm-tool "$@" 2>&1)"; rc=$?
        if [[ $rc -eq 0 ]]; then
          [[ -n "$out" ]] && printf '%s\n' "$out"
          return 0
        fi
        if [[ $i -lt $attempts ]] && grep -qi 'card not present' <<< "$out"; then
          sleep 1
          continue
        fi
        [[ -n "$out" ]] && printf '%s\n' "$out"
        echo "ERROR: sc-hsm-tool exited $rc." >&2
        exit 2
      done
    }

    # --- Device-state probes (query the DEVICE, not an operation's output) ---

    # 0 iff the DKEK on the HSM with the given USB serial is fully
    # reconstructed. PKCS#11 has no DKEK concept, so this is a fresh read-only
    # sc-hsm-tool status query: the device prints its Key Check Value only when
    # no shares are outstanding.
    dkek_complete() {
      local module="$1" serial="$2" reader
      reader="$(require_reader "$serial")"
      sc-hsm-tool --reader "$reader" 2>&1 | grep -qi 'key check value'
    }

    # The DKEK state as a single stable string: the Key Check Value when the
    # DKEK is complete, or the pending-share count when it is not. Deliberately
    # EXCLUDES the SO-PIN tries counter (which a rotation resets), so it
    # isolates "did the keys survive" for before/after comparison.
    dkek_state() {
      local module="$1" serial="$2" reader
      reader="$(require_reader "$serial")"
      sc-hsm-tool --reader "$reader" 2>&1 \
        | grep -iE 'key check value|import pending' \
        | sed 's/^[[:space:]]*//' || true
    }

    # --- Operations (each verifies its own postcondition) --------------------

    # Create <shares> DKEK share files (<dir>/dkek.<i>.pbe). An empty <password>
    # lets sc-hsm-tool prompt for it (with confirmation). Whether to reuse
    # existing shares is a caller policy, not a primitive concern.
    create_dkek_shares() {
      local module="$1" serial="$2" dir="$3" shares="$4" password="''${5:-}"
      local reader
      reader="$(require_reader "$serial")"
      local -a pwArgs=()
      [[ -n "$password" ]] && pwArgs=(--password "$password")
      mkdir -p "$dir"
      echo "==> Creating $shares DKEK share(s) in $dir"
      local i f
      for i in $(seq 1 "$shares"); do
        f="$dir/dkek.$i.pbe"
        rm -f "$f"
        schsm --reader "$reader" --create-dkek-share "$f" "''${pwArgs[@]}"
        # Postcondition: a valid 64-byte DKEK share file (OpenSSL "Salted__").
        if [[ ! -f "$f" ]] || [[ "$(stat -c %s "$f")" != 64 ]] || [[ "$(head -c 8 "$f")" != "Salted__" ]]; then
          echo "ERROR: DKEK share $f was not created (postcondition failed)." >&2
          exit 2
        fi
      done
    }

    # Import the DKEK shares from <dir> into the HSM. An empty <password> lets
    # sc-hsm-tool prompt for it.
    import_dkek_shares() {
      local module="$1" serial="$2" dir="$3" shares="$4" password="''${5:-}"
      local reader
      reader="$(require_reader "$serial")"
      local -a pwArgs=()
      [[ -n "$password" ]] && pwArgs=(--password "$password")
      echo "==> Importing DKEK share(s) from $dir"
      local i
      for i in $(seq 1 "$shares"); do
        schsm --reader "$reader" --import-dkek-share "$dir/dkek.$i.pbe" "''${pwArgs[@]}"
      done
      # Postcondition: the DKEK is fully reconstructed.
      if ! dkek_complete "$module" "$serial"; then
        echo "ERROR: DKEK is not complete after importing $shares share(s)." >&2
        exit 2
      fi
    }

    # Initialize the HSM with a DKEK of <shares> shares. <force> (non-empty)
    # passes --force. <new-so-pin> (optional) rotates the SO-PIN to that value
    # after a successful init (the init SO-PIN is used to authorize, then the
    # SO-PIN is changed to <new-so-pin>).
    init_hsm() {
      local module="$1" serial="$2" soPin="$3" pin="$4" shares="$5" force="''${6:-}" newSoPin="''${7:-}"
      local reader
      reader="$(require_reader "$serial")"
      local -a forceArgs=()
      [[ -n "$force" ]] && forceArgs=(--force)
      local wasInitialized=0
      if hsm_initialized "$module" "$serial"; then wasInitialized=1; fi
      echo "==> Initializing HSM (serial $serial, reader $reader), $shares DKEK share(s)"
      schsm --reader "$reader" --initialize "''${forceArgs[@]}" --so-pin "$soPin" --pin "$pin" --dkek-shares "$shares"
      # Postcondition: the HSM is initialized.
      if ! hsm_initialized "$module" "$serial"; then
        echo "ERROR: HSM (serial $serial) is not initialized after --initialize." >&2
        exit 2
      fi
      if [[ $wasInitialized -eq 1 && -z "$force" ]]; then
        echo "WARNING: HSM was already initialized; --initialize did not wipe it (use --force)." >&2
      fi
      # Optional: rotate the SO-PIN to a distinct final value. change_so_pin
      # verifies the DKEK state is unchanged (keys survived).
      if [[ -n "$newSoPin" && "$newSoPin" != "$soPin" ]]; then
        change_so_pin "$module" "$serial" "$soPin" "$newSoPin"
      fi
    }

    # Rotate the SO-PIN of an initialized HSM. NON-DESTRUCTIVE: the DKEK and all
    # keys are preserved (the MKEK is re-wrapped under the new SO-PIN). Verifies
    # the DKEK state is UNCHANGED afterwards, proving the keys survived.
    change_so_pin() {
      local module="$1" serial="$2" oldSoPin="$3" newSoPin="$4"
      local slot
      require_opensc_module "$module"
      slot="$(require_reader "$serial")"
      if ! hsm_initialized "$module" "$serial"; then
        echo "ERROR: HSM (serial $serial) is not initialized; nothing to rotate." >&2
        exit 2
      fi
      local before after out rc=0
      before="$(dkek_state "$module" "$serial")"
      echo "==> Rotating SO-PIN (serial $serial, slot $slot)"
      # `|| rc=$?` keeps `set -e` from aborting before we can report the error.
      out="$(pkcs11-tool --module "$module" --slot-index "$slot" --change-pin \
          --login --login-type so --so-pin "$oldSoPin" --new-pin "$newSoPin" 2>&1)" || rc=$?
      if [[ $rc -ne 0 ]]; then
        echo "ERROR: SO-PIN change failed (pkcs11-tool exit $rc):" >&2
        echo "$out" >&2
        exit 2
      fi
      after="$(dkek_state "$module" "$serial")"
      if [[ "$before" != "$after" ]]; then
        echo "ERROR: DKEK state changed during SO-PIN rotation (keys may be lost):" >&2
        printf '  before: %s\n  after:  %s\n' "$before" "$after" >&2
        exit 2
      fi
    }
  '';
}
