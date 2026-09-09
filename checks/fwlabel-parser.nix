# Pins pico-hsm-fwlabel's TLV parser against real opensc-tool output captured
# from a live TEST-firmware HSM: a format change must fail CI, not the operator.
{ pkgs, inputs, ... }:
let
  fwlabel = inputs.self.packages.${system}.pico-hsm-fwlabel;
  stub-opensc-tool = pkgs.writeShellScriptBin "opensc-tool" ''
    cat ${../fixtures/tokeninfo-unsafe.dump}
  '';
  system = pkgs.stdenv.hostPlatform.system;
in
pkgs.runCommand "fwlabel-parser" { } ''
  export PATH=${stub-opensc-tool}/bin:${pkgs.gawk}/bin:${pkgs.coreutils}/bin:${pkgs.opensc}/bin
  source ${fwlabel}
  got="$(firmware_label 0)"
  expected="Pico-HSM-PATCHED_UNSAFE"
  if [[ "$got" != "$expected" ]]; then
    echo "FAIL: firmware_label returned '$got', expected '$expected'" >&2
    exit 1
  fi
  echo "ok: firmware_label parsed 'Pico-HSM-PATCHED_UNSAFE'"
  touch $out
''
