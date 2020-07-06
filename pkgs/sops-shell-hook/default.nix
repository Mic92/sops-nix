{ makeSetupHook, gnupg, sops }:

makeSetupHook {
  substitutions = {
    gpg = "${gnupg}/bin/gpg";
  };
  deps = [ sops ];
} ./sops-shell-hook.bash
