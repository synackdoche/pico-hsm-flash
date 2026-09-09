{
  description = "SYNACKDOCHE - Pico HSM firmware build + flashing";
  inputs = {
    blueprint = {
      inputs.nixpkgs.follows = "nixpkgs";
      url = "github:numtide/blueprint";
    };
    git-hooks = {
      inputs.nixpkgs.follows = "nixpkgs";
      url = "github:cachix/git-hooks.nix";
    };
    nixpkgs.url = "github:nixos/nixpkgs/nixos-26.05";
    nixpkgs-esp-dev = {
      inputs.nixpkgs.follows = "nixpkgs";
      url = "github:synackdoche/nixpkgs-esp-dev";
    };
    nixpkgs-unstable.url = "github:nixos/nixpkgs/nixos-unstable";
    pedantix = {
      inputs = {
        nixpkgs.follows = "nixpkgs";
        treefmt-nix.follows = "treefmt-nix";
      };
      url = "github:swarsel/pedantix";
    };
    treefmt-nix = {
      inputs.nixpkgs.follows = "nixpkgs";
      url = "github:numtide/treefmt-nix";
    };
  };
  outputs =
    inputs:
    inputs.blueprint {
      inherit inputs;
      # esptool 4.9.0 (bundled in the ESP-IDF toolchain) has a RUNTIME dep on
      # python3.13-ecdsa, which nixpkgs marks insecure (upstream: "not for
      # production use"). It cannot be dropped by disabling tests. Permit it
      # here so our pkgs accepts it; pico-hsm-firmware builds esp-idf from our
      # pkgs (via the esp-dev overlay) so this config actually applies.
      nixpkgs.config.permittedInsecurePackages = [ "python3.13-ecdsa-0.19.2" ];
      systems = [ "x86_64-linux" ];
    };
}
