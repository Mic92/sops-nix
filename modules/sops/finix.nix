{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.sops;
  sops-install-secrets = cfg.package;
  manifest = config.system.build.sops-nix-manifest;
  manifestForUsers = config.system.build.sops-nix-users-manifest;
  regularSecrets = lib.filterAttrs (_: v: !v.neededForUsers) cfg.secrets;
  secretsForUsers = lib.filterAttrs (_: v: v.neededForUsers) cfg.secrets;
  withEnvironment = import ./with-environment.nix { inherit cfg lib; };
in
{
  imports = [ ./common.nix ];

  config = lib.mkIf (cfg.secrets != { }) {
    system.activation.scripts = {
      setupSecrets = lib.mkIf (regularSecrets != { }) (
        lib.stringAfter ([ "users" ] ++ lib.optional cfg.age.generateKey "generate-age-key") ''
          [ -e /run/current-system ] || echo setting up secrets...
          ${withEnvironment "${sops-install-secrets}/bin/sops-install-secrets ${manifest}"}
        ''
      );

      setupSecretsForUsers = lib.mkIf (secretsForUsers != { }) (
        lib.stringAfter (lib.optional cfg.age.generateKey "generate-age-key") ''
          [ -e /run/current-system ] || echo setting up secrets for users...
          ${withEnvironment "${sops-install-secrets}/bin/sops-install-secrets -ignore-passwd ${manifestForUsers}"}
        ''
      );

      users.deps = lib.mkIf (secretsForUsers != { }) [ "setupSecretsForUsers" ];

      generate-age-key = import ./generate-age-key.nix { inherit cfg lib pkgs; };
    };
  };
}
