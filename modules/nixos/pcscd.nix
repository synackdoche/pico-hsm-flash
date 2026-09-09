{ pkgs, inputs, ... }:
let
  # nixpkgs' ccid (1.7.1) does not list PicoHSM in supported_readers. The
  # unstable input ships 1.8.4, which does. Use it whole — overriding only
  # `version` on the old derivation leaves the 1.7.1 source in place.
  ccid = inputs.nixpkgs-unstable.legacyPackages.${system}.ccid;
  system = pkgs.stdenv.hostPlatform.system;
in
{
  services.pcscd.plugins = [ ccid ];
}
