{ stdenv, makeSetupHook, gnupg, sops, go, nix }:

(makeSetupHook {
  substitutions = {
    gpg = "${gnupg}/bin/gpg";
  };
  deps = [ sops gnupg ];
} ./sops-pgp-hook.bash)
