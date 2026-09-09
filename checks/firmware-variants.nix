# Build both firmware variants so their build-time label verification runs
# under `nix flake check`. Each variant's buildPhase asserts it identifies
# itself with the expected token label, so a wrong/absent label fails the build.
{
  pkgs,
  inputs,
  ...
}:
let
  fw = inputs.self.packages.${system}.pico-hsm-firmware;
  system = pkgs.stdenv.hostPlatform.system;
  variants = {
    production = fw.pico-hsm-firmware;
    test = fw.pico-hsm-firmware-test;
  };
in
pkgs.runCommand "firmware-variants" { } ''
  ${pkgs.lib.concatStringsSep "\n" (
    pkgs.lib.mapAttrsToList (name: drv: ''
      test -s ${drv}/pico-hsm-6.6-esp32s3.bin
      echo "ok: firmware variant '${name}'"
    '') variants
  )}
  touch $out
''
