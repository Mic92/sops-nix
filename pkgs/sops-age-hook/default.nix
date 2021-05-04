{ stdenv, makeSetupHook, nix, sops }:
(makeSetupHook {
  deps = [ sops ];
} ./sops-age-hook.bash)
