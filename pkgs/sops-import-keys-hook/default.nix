{ stdenv, makeSetupHook, gnupg, sops, nix }:

(makeSetupHook {
  name = "sops-import-keys-hook";
  substitutions = {
    gpg = "${gnupg}/bin/gpg";
  };
  propagatedBuildInputs = [ sops gnupg ];
} ./sops-import-keys-hook.bash)
