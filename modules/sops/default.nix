{
  config,
  options,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.sops;
  sops-install-secrets = cfg.package;
  manifest = config.system.build.sops-nix-manifest;
  regularSecrets = lib.filterAttrs (_: v: !v.neededForUsers) cfg.secrets;
  withEnvironment = import ./with-environment.nix { inherit cfg lib; };

  # Skip ssh keys deployed with sops to avoid a catch 22
  defaultImportKeys =
    algo:
    if config.services.openssh.enable || config.services.openssh.generateHostKeys then
      map (e: e.path) (
        lib.filter (
          e: e.type == algo && !(lib.hasPrefix "/run/secrets" e.path)
        ) config.services.openssh.hostKeys
      )
    else
      [ ];
in
{
  imports = [
    ./common.nix
    ./secrets-for-users
  ];

  options.sops.useSystemdActivation = lib.mkOption {
    type = lib.types.bool;
    default =
      (options.systemd ? sysusers && config.systemd.sysusers.enable)
      || (options.services ? userborn && config.services.userborn.enable);
    defaultText = lib.literalExpression (
      "(options.systemd ? sysusers && config.systemd.sysusers.enable) "
      + "|| (options.services ? userborn && config.services.userborn.enable)"
    );
    description = ''
      Use a systemd unit to install secrets, instead of deploying them using an activation script.

      This option is automatically enabled when systemd-sysusers or userborn are used to manage users and groups.
      It can also be useful to specify additional dependencies to be satisfied before secrets are installed, such as required mountpoints for SOPS key files.
    '';
  };

  config = lib.mkMerge [
    {
      sops.age.sshKeyPaths = lib.mkDefault (defaultImportKeys "ed25519");
      sops.gnupg.sshKeyPaths = lib.mkDefault (defaultImportKeys "rsa");
    }
    (lib.mkIf (cfg.secrets != { }) {
      # When using sysusers we no longer are started as an activation script because those are started in initrd while sysusers is started later.
      systemd.services.sops-install-secrets =
        lib.mkIf (regularSecrets != { } && cfg.useSystemdActivation)
          {
            wantedBy = [ "sysinit.target" ];
            after = [
              "local-fs.target"
              "systemd-sysusers.service"
              "userborn.service"
            ];
            requiredBy = [ "sysinit-reactivation.target" ];
            # WantedBy only pulls the unit in; without Before= normal services
            # (ordered after sysinit.target via DefaultDependencies) race with us.
            before = [
              "sysinit.target"
              "sysinit-reactivation.target"
              "shutdown.target"
            ];
            conflicts = [ "shutdown.target" ];
            environment = cfg.environment // {
              SOPS_RESTART_UNITS_VIA_SYSTEMCTL = "1";
            };
            unitConfig.DefaultDependencies = "no";
            path = cfg.age.plugins;

            serviceConfig = {
              Type = "oneshot";
              ExecStart = [ "${cfg.package}/bin/sops-install-secrets ${manifest}" ];
              RemainAfterExit = true;
            };
            unitConfig.RequiresMountsFor = lib.concatLists [
              (lib.lists.optional (cfg.gnupg.home != null) cfg.gnupg.home)
              cfg.gnupg.sshKeyPaths
              (lib.lists.optional (cfg.age.keyFile != null) cfg.age.keyFile)
              cfg.age.sshKeyPaths
            ];
          };

      system.activationScripts = {
        setupSecrets = lib.mkIf (regularSecrets != { } && !cfg.useSystemdActivation) (
          lib.stringAfter
            (
              [
                "specialfs"
                "users"
                "groups"
              ]
              ++ lib.optional cfg.age.generateKey "generate-age-key"
            )
            ''
              [ -e /run/current-system ] || echo setting up secrets...
              ${withEnvironment "${sops-install-secrets}/bin/sops-install-secrets ${manifest}"}
            ''
          // lib.optionalAttrs (config.system ? dryActivationScript) {
            supportsDryActivation = true;
          }
        );

        generate-age-key = import ./generate-age-key.nix { inherit cfg lib pkgs; };
      };
    })
  ];
}
