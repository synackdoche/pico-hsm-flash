{
  flake,
  system,
}:
let
  formatter = treefmtEval.config.build.wrapper;
  treefmtEval =
    flake.inputs.treefmt-nix.lib.evalModule
      (import flake.inputs.nixpkgs {
        inherit system;
        overlays = [
          (_: _final: {
            flake-edit = flake.inputs.nixpkgs-unstable.legacyPackages.${system}.flake-edit;
          })
        ];
      })
      {
        imports = [ flake.inputs.pedantix.treefmtModules.default ];
        programs = {
          deadnix.enable = true;
          flake-edit.enable = true;
          pedantix.enable = true;
          statix.enable = true;
        };
        projectRootFile = "flake.nix";
      };
in
formatter
