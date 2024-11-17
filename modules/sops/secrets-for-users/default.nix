{
  lib,
  options,
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
        environment = cfg.environment;
        unitConfig.DefaultDependencies = "no";

        serviceConfig = {
          Type = "oneshot";
          ExecStart = [ "${cfg.package}/bin/sops-install-secrets -ignore-passwd ${manifestForUsers}" ];
          RemainAfterExit = true;
        };
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
      assertion =
        (lib.filterAttrs (
          _: v: (v.uid != 0 && v.owner != "root") || (v.gid != 0 && v.group != "root")
        ) secretsForUsers) == { };
      message = "neededForUsers cannot be used for secrets that are not root-owned";
    }
    {
      assertion = secretsForUsers != { } && sysusersEnabled -> config.users.mutableUsers;
      message = ''
        systemd.sysusers.enable in combination with sops.secrets.<name>.neededForUsers can only work with config.users.mutableUsers enabled.
        See https://github.com/Mic92/sops-nix/issues/475
      '';
    }
  ];

  system.build.sops-nix-users-manifest = manifestForUsers;
}
