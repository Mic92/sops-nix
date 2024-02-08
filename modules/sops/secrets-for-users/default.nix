{ lib, config, pkgs, ... }:
let
  cfg = config.sops;
  secretsForUsers = lib.filterAttrs (_: v: v.neededForUsers) cfg.secrets;
  manifestFor = pkgs.callPackage ../manifest-for.nix {
    inherit cfg;
    inherit (pkgs) writeTextFile;
  };
  withEnvironment = import ../with-environment.nix {
    inherit cfg lib;
  };
  manifestForUsers = manifestFor "-for-users" secretsForUsers {
    secretsMountPoint = "/run/secrets-for-users.d";
    symlinkPath = "/run/secrets-for-users";
  };
in
{
  system.activationScripts = lib.mkIf (secretsForUsers != {}) {
    setupSecretsForUsers = lib.mkIf (secretsForUsers != {}) (lib.stringAfter ([ "specialfs" ] ++ lib.optional cfg.age.generateKey "generate-age-key") ''
      [ -e /run/current-system ] || echo setting up secrets for users...
      ${withEnvironment "${cfg.package}/bin/sops-install-secrets -ignore-passwd ${manifestForUsers}"}
    '' // lib.optionalAttrs (config.system ? dryActivationScript) {
    supportsDryActivation = true;
    });

    users = lib.mkIf (secretsForUsers != {}) {
      deps = [ "setupSecretsForUsers" ];
    };
  };

  assertions = [{
    assertion = (lib.filterAttrs (_: v: v.owner != "root" || v.group != "root") secretsForUsers) == {};
    message = "neededForUsers cannot be used for secrets that are not root-owned";
  }];

  system.build.sops-nix-users-manifest = manifestForUsers;
}
