{
  pkgs,
  inputs,
  ...
}:
inputs.git-hooks.lib.${pkgs.stdenv.hostPlatform.system}.run {
  hooks.treefmt = {
    enable = true;
    packageOverrides.treefmt = inputs.self.formatter.${pkgs.stdenv.hostPlatform.system};
  };
  src = ../.;
}
