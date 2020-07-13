{ makeSetupHook, gnupg, sops }:

makeSetupHook {
  substitutions = {
    gpg = "${gnupg}/bin/gpg";
  };
  deps = [ sops gnupg ];
} ./sops-pgp-hook.bash
