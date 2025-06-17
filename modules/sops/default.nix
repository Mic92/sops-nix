{
  config,
  options,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.sops;
  users = config.users.users;
  sops-install-secrets = cfg.package;
  manifestFor = pkgs.callPackage ./manifest-for.nix {
    inherit cfg;
    inherit (pkgs) writeTextFile;
  };
  manifest = manifestFor "" regularSecrets regularTemplates { };

  pathNotInStore = lib.mkOptionType {
    name = "pathNotInStore";
    description = "path not in the Nix store";
    descriptionClass = "noun";
    check = x: !lib.path.hasStorePathPrefix (/. + x);
    merge = lib.mergeEqualOption;
  };

  regularSecrets = lib.filterAttrs (_: v: !v.neededForUsers) cfg.secrets;

  # Currently, all templates are "regular" (there's no support for `neededForUsers` for templates.)
  regularTemplates = cfg.templates;

  useSystemdActivation =
    (options.systemd ? sysusers && config.systemd.sysusers.enable)
    || (options.services ? userborn && config.services.userborn.enable);

  withEnvironment = import ./with-environment.nix {
    # sops >=3.10.0 now unconditionally searches 
    # for an SSH key in $HOME/.ssh/, introduced in #1692 [0]. Since in the
    # activation script $HOME is never set, it just spits out a slew a
    # warnings [1].
    #
    # [0] https://github.com/Mic92/sops-nix/issues/764
    # [1] https://github.com/getsops/sops/pull/1692
    cfg = lib.recursiveUpdate cfg {
      environment.HOME = "/var/empty";
      environment.PATH = lib.makeBinPath cfg.age.plugins;
    };
    inherit lib;
  };
  secretType = lib.types.submodule (
    { config, ... }:
    {
      config = {
        sopsFile = lib.mkOptionDefault cfg.defaultSopsFile;
        sopsFileHash = lib.mkOptionDefault (
          lib.optionalString cfg.validateSopsFiles "${builtins.hashFile "sha256" config.sopsFile}"
        );
      };
      options = {
        name = lib.mkOption {
          type = lib.types.str;
          default = config._module.args.name;
          description = ''
            Name of the file used in /run/secrets
          '';
        };
        key = lib.mkOption {
          type = lib.types.str;
          default = if cfg.defaultSopsKey != null then cfg.defaultSopsKey else config._module.args.name;
          description = ''
            Key used to lookup in the sops file.
            No tested data structures are supported right now.
            This option is ignored if format is binary.
            "" means whole file.
          '';
        };
        path = lib.mkOption {
          type = lib.types.str;
          default =
            if config.neededForUsers then
              "/run/secrets-for-users/${config.name}"
            else
              "/run/secrets/${config.name}";
          defaultText = "/run/secrets-for-users/$name when neededForUsers is set, /run/secrets/$name when otherwise.";
          description = ''
            Path where secrets are symlinked to.
            If the default is kept no symlink is created.
          '';
        };
        format = lib.mkOption {
          type = lib.types.enum [
            "yaml"
            "json"
            "binary"
            "dotenv"
            "ini"
          ];
          default = cfg.defaultSopsFormat;
          description = ''
            File format used to decrypt the sops secret.
            Binary files are written to the target file as is.
          '';
        };
        mode = lib.mkOption {
          type = lib.types.str;
          default = "0400";
          description = ''
            Permissions mode of the in octal.
          '';
        };
        owner = lib.mkOption {
          type = with lib.types; nullOr str;
          default = null;
          description = ''
            User of the file. Can only be set if uid is 0.
          '';
        };
        uid = lib.mkOption {
          type = with lib.types; nullOr int;
          default = 0;
          description = ''
            UID of the file, only applied when owner is null. The UID will be applied even if the corresponding user doesn't exist.
          '';
        };
        group = lib.mkOption {
          type = with lib.types; nullOr str;
          default = if config.owner != null then users.${config.owner}.group else null;
          defaultText = lib.literalMD "{option}`config.users.users.\${owner}.group`";
          description = ''
            Group of the file. Can only be set if gid is 0.
          '';
        };
        gid = lib.mkOption {
          type = with lib.types; nullOr int;
          default = 0;
          description = ''
            GID of the file, only applied when group is null. The GID will be applied even if the corresponding group doesn't exist.
          '';
        };
        sopsFile = lib.mkOption {
          type = lib.types.path;
          defaultText = lib.literalExpression "\${config.sops.defaultSopsFile}";
          description = ''
            Sops file the secret is loaded from.
          '';
        };
        sopsFileHash = lib.mkOption {
          type = lib.types.str;
          readOnly = true;
          description = ''
            Hash of the sops file, useful in <xref linkend="opt-systemd.services._name_.restartTriggers" />.
          '';
        };
        restartUnits = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          default = [ ];
          example = [ "sshd.service" ];
          description = ''
            Names of units that should be restarted when this secret changes.
            This works the same way as <xref linkend="opt-systemd.services._name_.restartTriggers" />.
          '';
        };
        reloadUnits = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          default = [ ];
          example = [ "sshd.service" ];
          description = ''
            Names of units that should be reloaded when this secret changes.
            This works the same way as <xref linkend="opt-systemd.services._name_.reloadTriggers" />.
          '';
        };
        neededForUsers = lib.mkOption {
          type = lib.types.bool;
          default = false;
          description = ''
            Enabling this option causes the secret to be decrypted before users and groups are created.
            This can be used to retrieve user's passwords from sops-nix.
            Setting this option moves the secret to /run/secrets-for-users and disallows setting owner and group to anything else than root.
          '';
        };
      };
    }
  );

  # Skip ssh keys deployed with sops to avoid a catch 22
  defaultImportKeys =
    algo:
    if config.services.openssh.enable then
      map (e: e.path) (
        lib.filter (
          e: e.type == algo && !(lib.hasPrefix "/run/secrets" e.path)
        ) config.services.openssh.hostKeys
      )
    else
      [ ];
in
{
  options.sops = {
    secrets = lib.mkOption {
      type = lib.types.attrsOf secretType;
      default = { };
      description = ''
        Path where the latest secrets are mounted to.
      '';
    };

    defaultSopsFile = lib.mkOption {
      type = lib.types.path;
      description = ''
        Default sops file used for all secrets.
      '';
    };

    defaultSopsFormat = lib.mkOption {
      type = lib.types.str;
      default = "yaml";
      description = ''
        Default sops format used for all secrets.
      '';
    };

    defaultSopsKey = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = ''
        Default key used to lookup in all secrets.
        This option is ignored if format is binary.
        "" means whole file.
      '';
    };

    validateSopsFiles = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Check all sops files at evaluation time.
        This requires sops files to be added to the nix store.
      '';
    };

    keepGenerations = lib.mkOption {
      type = lib.types.ints.unsigned;
      default = 1;
      description = ''
        Number of secrets generations to keep. Setting this to 0 disables pruning.
      '';
    };

    log = lib.mkOption {
      type = lib.types.listOf (
        lib.types.enum [
          "keyImport"
          "secretChanges"
        ]
      );
      default = [
        "keyImport"
        "secretChanges"
      ];
      description = "What to log";
    };

    environment = lib.mkOption {
      type = lib.types.attrsOf (lib.types.either lib.types.str lib.types.path);
      default = { };
      description = ''
        Environment variables to set before calling sops-install-secrets.

        The values are placed in single quotes and not escaped any further to
        allow usage of command substitutions for more flexibility. To properly quote
        strings with quotes use lib.escapeShellArg.

        This will be evaluated twice when using secrets that use neededForUsers but
        in a subshell each time so the environment variables don't collide.
      '';
    };

    package = lib.mkOption {
      type = lib.types.package;
      default = (pkgs.callPackage ../.. { }).sops-install-secrets;
      defaultText = lib.literalExpression "(pkgs.callPackage ../.. {}).sops-install-secrets";
      description = ''
        sops-install-secrets package to use.
      '';
    };

    validationPackage = lib.mkOption {
      type = lib.types.package;
      default =
        if pkgs.stdenv.buildPlatform == pkgs.stdenv.hostPlatform then
          sops-install-secrets
        else
          (pkgs.pkgsBuildHost.callPackage ../.. { }).sops-install-secrets;
      defaultText = lib.literalExpression "config.sops.package";

      description = ''
        sops-install-secrets package to use when validating configuration.

        Defaults to sops.package if building natively, and a native version of sops-install-secrets if cross compiling.
      '';
    };

    useTmpfs = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Use tmpfs in place of ramfs for secrets storage.

        *WARNING*
        Enabling this option has the potential to write secrets to disk unencrypted if the tmpfs volume is written to swap. Do not use unless absolutely necessary.

        When using a swap file or device, consider enabling swap encryption by setting the `randomEncryption.enable` option

        ```
        swapDevices = [{
          device = "/dev/sdXY";
          randomEncryption.enable = true;
        }];
        ```
      '';
    };

    age = {
      keyFile = lib.mkOption {
        type = lib.types.nullOr pathNotInStore;
        default = null;
        example = "/var/lib/sops-nix/key.txt";
        description = ''
          Path to age key file used for sops decryption.
        '';
      };

      plugins = lib.mkOption {
        type = lib.types.listOf lib.types.package;
        default = [ ];
        description = ''
          List of plugins to use for sops decryption.
        '';
      };

      generateKey = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = ''
          Whether or not to generate the age key. If this
          option is set to false, the key must already be
          present at the specified location.
        '';
      };

      sshKeyPaths = lib.mkOption {
        type = lib.types.listOf lib.types.path;
        default = defaultImportKeys "ed25519";
        defaultText = lib.literalMD "The ed25519 keys from {option}`config.services.openssh.hostKeys`";
        description = ''
          Paths to ssh keys added as age keys during sops description.
        '';
      };
    };

    gnupg = {
      home = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        example = "/root/.gnupg";
        description = ''
          Path to gnupg database directory containing the key for decrypting the sops file.
        '';
      };

      sshKeyPaths = lib.mkOption {
        type = lib.types.listOf lib.types.path;
        default = defaultImportKeys "rsa";
        defaultText = lib.literalMD "The rsa keys from {option}`config.services.openssh.hostKeys`";
        description = ''
          Path to ssh keys added as GPG keys during sops description.
          This option must be explicitly unset if <literal>config.sops.gnupg.home</literal> is set.
        '';
      };
    };
  };
  imports = [
    ./templates
    ./secrets-for-users
    (lib.mkRenamedOptionModule
      [
        "sops"
        "gnupgHome"
      ]
      [
        "sops"
        "gnupg"
        "home"
      ]
    )
    (lib.mkRenamedOptionModule
      [
        "sops"
        "sshKeyPaths"
      ]
      [
        "sops"
        "gnupg"
        "sshKeyPaths"
      ]
    )
  ];
  config = lib.mkMerge [
    (lib.mkIf (cfg.secrets != { }) {
      assertions =
        [
          {
            assertion =
              cfg.gnupg.home != null
              || cfg.gnupg.sshKeyPaths != [ ]
              || cfg.age.keyFile != null
              || cfg.age.sshKeyPaths != [ ];
            message = "No key source configured for sops. Either set services.openssh.enable or set sops.age.keyFile or sops.gnupg.home";
          }
          {
            assertion = !(cfg.gnupg.home != null && cfg.gnupg.sshKeyPaths != [ ]);
            message = "Exactly one of sops.gnupg.home and sops.gnupg.sshKeyPaths must be set";
          }
        ]
        ++ lib.optionals cfg.validateSopsFiles (
          lib.concatLists (
            lib.mapAttrsToList (name: secret: [
              {
                assertion = secret.uid != null && secret.uid != 0 -> secret.owner == null;
                message = "In ${secret.name} exactly one of sops.owner and sops.uid must be set";
              }
              {
                assertion = secret.gid != null && secret.gid != 0 -> secret.group == null;
                message = "In ${secret.name} exactly one of sops.group and sops.gid must be set";
              }
            ]) cfg.secrets
          )
        );

      sops.environment.SOPS_GPG_EXEC = lib.mkIf (cfg.gnupg.home != null || cfg.gnupg.sshKeyPaths != [ ]) (
        lib.mkDefault "${pkgs.gnupg}/bin/gpg"
      );

      # When using sysusers we no longer are started as an activation script because those are started in initrd while sysusers is started later.
      systemd.services.sops-install-secrets = lib.mkIf (regularSecrets != { } && useSystemdActivation) {
        wantedBy = [ "sysinit.target" ];
        after = [ "systemd-sysusers.service" ];
        environment = cfg.environment;
        unitConfig.DefaultDependencies = "no";
        path = cfg.age.plugins;

        serviceConfig = {
          Type = "oneshot";
          ExecStart = [ "${cfg.package}/bin/sops-install-secrets ${manifest}" ];
          RemainAfterExit = true;
        };
      };

      system.activationScripts = {
        setupSecrets = lib.mkIf (regularSecrets != { } && !useSystemdActivation) (
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

        generate-age-key =
          let
            escapedKeyFile = lib.escapeShellArg cfg.age.keyFile;
          in
          lib.mkIf cfg.age.generateKey (
            lib.stringAfter [ ] ''
              if [[ ! -f ${escapedKeyFile} ]]; then
                echo generating machine-specific age key...
                mkdir -p $(dirname ${escapedKeyFile})
                # age-keygen sets 0600 by default, no need to chmod.
                ${pkgs.age}/bin/age-keygen -o ${escapedKeyFile}
              fi
            ''
          );
      };
    })
    {
      system.build.sops-nix-manifest = manifest;
    }
  ];
}
