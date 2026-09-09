{
  description = "SYNACKDOCHE - Pico HSM firmware build + flashing";
  inputs = {
    blueprint = {
      inputs = {
        nixpkgs.follows = "nixpkgs";
        systems.follows = "systems";
      };
      url = "github:numtide/blueprint";
    };
    flake-compat.url = "github:NixOS/flake-compat";
    git-hooks = {
      inputs = {
        flake-compat.follows = "flake-compat";
        nixpkgs.follows = "nixpkgs";
      };
      url = "github:cachix/git-hooks.nix";
    };
    nixpkgs.url = "github:nixos/nixpkgs/nixos-26.05";
    nixpkgs-esp-dev = {
      inputs = {
        flake-utils.inputs.systems.follows = "systems";
        nixpkgs.follows = "nixpkgs";
      };
      url = "github:synackdoche/nixpkgs-esp-dev";
    };
    nixpkgs-unstable.url = "github:nixos/nixpkgs/nixos-unstable";
    pedantix = {
      inputs = {
        git-hooks-nix.inputs.flake-compat.follows = "flake-compat";
        nixpkgs.follows = "nixpkgs";
        treefmt-nix.follows = "treefmt-nix";
      };
      url = "github:swarsel/pedantix";
    };
    systems.url = "github:nix-systems/default";
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
      # python3.13-ecdsa, which nixpkgs marks insecure. It cannot be dropped
      # by disabling tests. Permit it here so our pkgs accepts it; the
      # rationale and overlay use live in packages/pico-hsm-firmware.nix.
      nixpkgs.config.permittedInsecurePackages = [
        "python3.13-ecdsa-0.19.2"
      ];
      systems = import inputs.systems;
    };
}
