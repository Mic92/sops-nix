{
  lib,
  config,
  pkgs,
  ...
}:
let
  cfg = config.sops;
  secretsForUsers = lib.filterAttrs (_: v: v.neededForUsers) cfg.secrets;
  templatesForUsers = { }; # We do not currently support `neededForUsers` for templates.
  manifestFor = pkgs.callPackage ../manifest-for.nix {
    inherit cfg;
    inherit (pkgs) writeTextFile;
  };
  withEnvironment = import ../with-environment.nix {
    inherit cfg lib;
  };
  manifestForUsers = manifestFor "-for-users" secretsForUsers templatesForUsers {
    secretsMountPoint = "/run/secrets-for-users.d";
    symlinkPath = "/run/secrets-for-users";
  };

  installScript = ''
    echo "Setting up secrets for users"
    ${withEnvironment "${cfg.package}/bin/sops-install-secrets -ignore-passwd ${manifestForUsers}"}
  '';
in
{

  assertions = [
    {
      assertion =
        (lib.filterAttrs (
          _: v: (v.uid != 0 && v.owner != "root") || (v.gid != 0 && v.group != "root")
        ) secretsForUsers) == { };
      message = "neededForUsers cannot be used for secrets that are not root-owned";
    }
  ];

  system.activationScripts = lib.mkIf (secretsForUsers != [ ]) {
    postActivation.text = lib.mkAfter installScript;
  };

  launchd.daemons.sops-install-secrets-for-users = lib.mkIf (secretsForUsers != [ ]) {
    command = installScript;
    serviceConfig = {
      RunAtLoad = true;
      KeepAlive = false;
    };
  };

  system.build.sops-nix-users-manifest = manifestForUsers;
}
