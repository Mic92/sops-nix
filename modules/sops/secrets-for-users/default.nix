{
  lib,
  options,
  config,
  ...
}:
let
  cfg = config.sops;
  secretsForUsers = lib.filterAttrs (_: v: v.neededForUsers) cfg.secrets;
  withEnvironment = import ../with-environment.nix { inherit cfg lib; };
  manifestForUsers = config.system.build.sops-nix-users-manifest;
  sysusersEnabled = options.systemd ? sysusers && config.systemd.sysusers.enable;
  useSystemdActivation =
    sysusersEnabled || (options.services ? userborn && config.services.userborn.enable);
in
{
  systemd.services.sops-install-secrets-for-users =
    lib.mkIf (secretsForUsers != { } && useSystemdActivation)
      {
        wantedBy = [ "systemd-sysusers.service" ];
        before = [ "systemd-sysusers.service" ];
        environment = cfg.environment // {
          SOPS_RESTART_UNITS_VIA_SYSTEMCTL = "1";
        };
        unitConfig.DefaultDependencies = "no";
        path = cfg.age.plugins;

        serviceConfig = {
          Type = "oneshot";
          ExecStart = [ "${cfg.package}/bin/sops-install-secrets -ignore-passwd ${manifestForUsers}" ];
          RemainAfterExit = true;
        };
        unitConfig.WantsMountsFor = lib.concatLists [
          (lib.lists.optional (cfg.gnupg.home != null) cfg.gnupg.home)
          cfg.gnupg.sshKeyPaths
          (lib.lists.optional (cfg.age.keyFile != null) cfg.age.keyFile)
          cfg.age.sshKeyPaths
        ];
      };

  system.activationScripts = lib.mkIf (secretsForUsers != { } && !useSystemdActivation) {
    setupSecretsForUsers =
      lib.stringAfter ([ "specialfs" ] ++ lib.optional cfg.age.generateKey "generate-age-key") ''
        [ -e /run/current-system ] || echo setting up secrets for users...
        ${withEnvironment "${cfg.package}/bin/sops-install-secrets -ignore-passwd ${manifestForUsers}"}
      ''
      // lib.optionalAttrs (config.system ? dryActivationScript) {
        supportsDryActivation = true;
      };

    users.deps = [ "setupSecretsForUsers" ];
  };

  assertions = [
    {
      assertion = secretsForUsers != { } && sysusersEnabled -> config.users.mutableUsers;
      message = ''
        systemd.sysusers.enable in combination with sops.secrets.<name>.neededForUsers can only work with config.users.mutableUsers enabled.
        See https://github.com/Mic92/sops-nix/issues/475
      '';
    }
  ];
}
