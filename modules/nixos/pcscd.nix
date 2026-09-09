{ pkgs, ... }:
{
  services.pcscd.plugins = [
    # As of writing, nixpkgs ccid version (1.7.1) does not include
    # PicoHSM in supported_readers
    (pkgs.ccid.overrideAttrs (_prev: {
      version = "1.8.4";
    }))
  ];
}
