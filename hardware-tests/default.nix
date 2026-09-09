# Hardware tests. Not under packages/ so blueprint does not make them checks
# (they need hardware + PINs and would fail `nix flake check` in CI). Tests are
# auto-discovered from this directory; lib files are filtered by name.
{
  pkgs,
  inputs,
  perSystem,
  ...
}:
let
  # Names that are libraries/aggregators, not runnable tests.
  blacklist = [
    "all"
    "confirm"
    "default"
  ];
  confirm = import ./confirm.nix { inherit pkgs; };
  entries = builtins.readDir ./.;
  mkTest = name: import (./. + "/${name}.nix") (scopeArgs // { pname = name; });
  scopeArgs = {
    inherit pkgs inputs perSystem;
    system = pkgs.stdenv.hostPlatform.system;
  };
  testNames = builtins.filter (n: !(builtins.elem n blacklist)) (
    map (f: builtins.head (builtins.match "(.*)\\.nix" f)) (
      builtins.filter (f: builtins.match ".*\\.nix" f != null) (builtins.attrNames entries)
    )
  );
  tests = builtins.listToAttrs (
    map (n: {
      name = n;
      value = mkTest n;
    }) testNames
  );
in
tests
// {
  inherit confirm;
  all = import ./all.nix (
    scopeArgs
    // {
      inherit confirm;
      inherit tests;
      pname = "hardware-tests-all";
    }
  );
}
