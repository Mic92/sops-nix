{
  makeSetupHook,
  gnupg,
  sops,
  lib,
}:

let
  # FIXME: drop after 23.05
  propagatedBuildInputs =
    if (lib.versionOlder (lib.versions.majorMinor lib.version) "23.05") then
      "deps"
    else
      "propagatedBuildInputs";
in
(makeSetupHook {
  name = "sops-import-keys-hook";
  substitutions = {
    gpg = "${gnupg}/bin/gpg";
  };
  ${propagatedBuildInputs} = [
    sops
    gnupg
  ];
} ./sops-import-keys-hook.bash)
