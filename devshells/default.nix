{
  pkgs,
  inputs,
  ...
}:
let
  inherit (inputs.self.checks.${pkgs.stdenv.hostPlatform.system}.pre-commit)
    shellHook
    enabledPackages
    ;
in
pkgs.mkShell {
  inherit shellHook;
  buildInputs = enabledPackages;
  packages = with pkgs; [

  ];
}
