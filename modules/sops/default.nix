{ config, lib, pkgs, ... }:

with lib;

let
  cfg = config.sops;
  users = config.users.users;
  sops-install-secrets = cfg.package;
  sops-install-secrets-check = cfg.validationPackage;
  secrets = mapAttrs (_: secret: removeAttrs secret ["sopsFile"]) cfg.secrets;
  regularSecrets = lib.filterAttrs (_: v: !v.neededForUsers) secrets;
  secretsForUsers = lib.filterAttrs (_: v: v.neededForUsers) secrets;
  secretType = types.submodule ({ config, options, ... }: {
    config = mkMerge [{
      sopsFile = mkOptionDefault cfg.defaultSopsFile;
      sopsFiles = mkIf (length cfg.defaultSopsFiles > 0) (mkOptionDefault cfg.defaultSopsFiles);
      sopsFilesHash = mkOptionDefault (optionals cfg.validateSopsFiles (forEach config.sopsFiles (builtins.hashFile "sha256")));
    }
    {
      sopsFiles = mkIf (config.sopsFile != null) (mkOverride options.sopsFile.highestPrio (mkBefore [config.sopsFile]));
    }];
    options = {
      name = mkOption {
        type = types.str;
        default = config._module.args.name;
        description = ''
          Name of the file used in /run/secrets
        '';
      };
      key = mkOption {
        type = types.str;
        default = config._module.args.name;
        description = ''
          Key used to lookup in the sops file.
          No tested data structures are supported right now.
          This option is ignored if format is binary.
        '';
      };
      path = mkOption {
        type = types.str;
        default = if config.neededForUsers then "/run/secrets-for-users/${config.name}" else "/run/secrets/${config.name}";
        defaultText = "/run/secrets-for-users/$name when neededForUsers is set, /run/secrets/$name when otherwise.";
        description = ''
          Path where secrets are symlinked to.
          If the default is kept no symlink is created.
        '';
      };
      format = mkOption {
        type = types.enum ["yaml" "json" "binary" "dotenv" "ini"];
        default = cfg.defaultSopsFormat;
        description = ''
          File format used to decrypt the sops secret.
          Binary files are written to the target file as is.
        '';
      };
      mode = mkOption {
        type = types.str;
        default = "0400";
        description = ''
          Permissions mode of the in octal.
        '';
      };
      owner = mkOption {
        type = types.str;
        default = "root";
        description = ''
          User of the file.
        '';
      };
      group = mkOption {
        type = types.str;
        default = users.${config.owner}.group;
        defaultText = literalMD "{option}`config.users.users.\${owner}.group`";
        description = ''
          Group of the file.
        '';
      };
      sopsFile = mkOption {
        type = types.nullOr types.path;
        defaultText = "\${config.sops.defaultSopsFile}";
        description = ''
          Sops file the secret is loaded from.
        '';
      };
      sopsFiles = mkOption {
        type = types.nonEmptyListOf types.path;
        defaultText = "\${config.sops.defaultSopsFiles}";
        description = ''
          Sops files the secret is loaded from.
        '';
      };
      sopsFilesHash = mkOption {
        type = types.nonEmptyListOf types.str;
        readOnly = true;
        description = ''
          Hash of the sops files, useful in <xref linkend="opt-systemd.services._name_.restartTriggers" />.
        '';
      };
      restartUnits = mkOption {
        type = types.listOf types.str;
        default = [ ];
        example = [ "sshd.service" ];
        description = ''
          Names of units that should be restarted when this secret changes.
          This works the same way as <xref linkend="opt-systemd.services._name_.restartTriggers" />.
        '';
      };
      reloadUnits = mkOption {
        type = types.listOf types.str;
        default = [ ];
        example = [ "sshd.service" ];
        description = ''
          Names of units that should be reloaded when this secret changes.
          This works the same way as <xref linkend="opt-systemd.services._name_.reloadTriggers" />.
        '';
      };
      neededForUsers = mkOption {
        type = types.bool;
        default = false;
        description = ''
          Enabling this option causes the secret to be decrypted before users and groups are created.
          This can be used to retrieve user's passwords from sops-nix.
          Setting this option moves the secret to /run/secrets-for-users and disallows setting owner and group to anything else than root.
        '';
      };
    };
  });

  manifestFor = suffix: secrets: extraJson: pkgs.writeTextFile {
    name = "manifest${suffix}.json";
    text = builtins.toJSON ({
      secrets = builtins.attrValues secrets;
      # Does this need to be configurable?
      secretsMountPoint = "/run/secrets.d";
      symlinkPath = "/run/secrets";
      keepGenerations = cfg.keepGenerations;
      gnupgHome = cfg.gnupg.home;
      sshKeyPaths = cfg.gnupg.sshKeyPaths;
      ageKeyFile = cfg.age.keyFile;
      ageSshKeyPaths = cfg.age.sshKeyPaths;
      useTmpfs = cfg.useTmpfs;
      userMode = false;
      logging = {
        keyImport = builtins.elem "keyImport" cfg.log;
        secretChanges = builtins.elem "secretChanges" cfg.log;
      };
    } // extraJson);
    checkPhase = ''
      ${sops-install-secrets-check}/bin/sops-install-secrets -check-mode=${if cfg.validateSopsFiles then "sopsfile" else "manifest"} "$out"
    '';
  };

  manifest = manifestFor "" regularSecrets {};
  manifestForUsers = manifestFor "-for-users" secretsForUsers {
    secretsMountPoint = "/run/secrets-for-users.d";
    symlinkPath = "/run/secrets-for-users";
  };

  withEnvironment = sopsCall: if cfg.environment == {} then sopsCall else ''
    (
    ${concatStringsSep "\n" (mapAttrsToList (n: v: "  export ${n}='${v}'") cfg.environment)}
      ${sopsCall}
    )
  '';
  # Skip ssh keys deployed with sops to avoid a catch 22
  defaultImportKeys = algo:
    if config.services.openssh.enable then
      map (e: e.path) (lib.filter (e: e.type == algo && !(lib.hasPrefix "/run/secrets" e.path)) config.services.openssh.hostKeys)
    else
      [];
in {
  options.sops = {
    secrets = mkOption {
      type = types.attrsOf secretType;
      default = {};
      description = ''
        Path where the latest secrets are mounted to.
      '';
    };

    defaultSopsFile = mkOption {
      type = types.nullOr types.path;
      default = null;
      description = ''
        Default sops file used for all secrets.
      '';
    };

    defaultSopsFiles = mkOption {
      type = types.listOf types.path;
      default = [];
      description = ''
        Default sops files used for all secrets.
      '';
    };

    defaultSopsFormat = mkOption {
      type = types.str;
      default = "yaml";
      description = ''
        Default sops format used for all secrets.
      '';
    };

    validateSopsFiles = mkOption {
      type = types.bool;
      default = true;
      description = ''
        Check all sops files at evaluation time.
        This requires sops files to be added to the nix store.
      '';
    };

    keepGenerations = mkOption {
      type = types.ints.unsigned;
      default = 1;
      description = ''
        Number of secrets generations to keep. Setting this to 0 disables pruning.
      '';
    };

    log = mkOption {
      type = types.listOf (types.enum [ "keyImport" "secretChanges" ]);
      default = [ "keyImport" "secretChanges" ];
      description = "What to log";
    };

    environment = mkOption {
      type = types.attrsOf (types.either types.str types.path);
      default = {};
      description = ''
        Environment variables to set before calling sops-install-secrets.

        The values are placed in single quotes and not escaped any further to
        allow usage of command substitutions for more flexibility. To properly quote
        strings with quotes use lib.escapeShellArg.

        This will be evaluated twice when using secrets that use neededForUsers but
        in a subshell each time so the environment variables don't collide.
      '';
    };

    package = mkOption {
      type = types.package;
      default = (pkgs.callPackage ../.. {}).sops-install-secrets;
      defaultText = literalExpression "(pkgs.callPackage ../.. {}).sops-install-secrets";
      description = ''
        sops-install-secrets package to use.
      '';
    };

    validationPackage = mkOption {
      type = types.package;
      default =
        if pkgs.stdenv.buildPlatform == pkgs.stdenv.hostPlatform
          then sops-install-secrets
          else (pkgs.pkgsBuildHost.callPackage ../.. {}).sops-install-secrets;
      defaultText = literalExpression "config.sops.package";

      description = ''
        sops-install-secrets package to use when validating configuration.

        Defaults to sops.package if building natively, and a native version of sops-install-secrets if cross compiling.
      '';
    };

    useTmpfs = mkOption {
      type = types.bool;
      default = false;
      description = lib.mdDoc ''
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
      keyFile = mkOption {
        type = types.nullOr types.path;
        default = null;
        example = "/var/lib/sops-nix/key.txt";
        description = ''
          Path to age key file used for sops decryption.
        '';
      };

      generateKey = mkOption {
        type = types.bool;
        default = false;
        description = ''
          Whether or not to generate the age key. If this
          option is set to false, the key must already be
          present at the specified location.
        '';
      };

      sshKeyPaths = mkOption {
        type = types.listOf types.path;
        default = defaultImportKeys "ed25519";
        defaultText = literalMD "The ed25519 keys from {option}`config.services.openssh.hostKeys`";
        description = ''
          Paths to ssh keys added as age keys during sops description.
        '';
      };
    };

    gnupg = {
      home = mkOption {
        type = types.nullOr types.str;
        default = null;
        example = "/root/.gnupg";
        description = ''
          Path to gnupg database directory containing the key for decrypting the sops file.
        '';
      };

      sshKeyPaths = mkOption {
        type = types.listOf types.path;
        default = defaultImportKeys "rsa";
        defaultText = literalMD "The rsa keys from {option}`config.services.openssh.hostKeys`";
        description = ''
          Path to ssh keys added as GPG keys during sops description.
          This option must be explicitly unset if <literal>config.sops.gnupg.sshKeyPaths</literal> is set.
        '';
      };
    };
  };
  imports = [
    ./templates
    (mkRenamedOptionModule [ "sops" "gnupgHome" ] [ "sops" "gnupg" "home" ])
    (mkRenamedOptionModule [ "sops" "sshKeyPaths" ] [ "sops" "gnupg" "sshKeyPaths" ])
  ];
  config = mkMerge [
    (mkIf (cfg.secrets != {}) {
      assertions = [{
        assertion = cfg.gnupg.home != null || cfg.gnupg.sshKeyPaths != [] || cfg.age.keyFile != null || cfg.age.sshKeyPaths != [];
        message = "No key source configured for sops. Either set services.openssh.enable or set sops.age.keyFile or sops.gnupg.home";
      } {
        assertion = !(cfg.gnupg.home != null && cfg.gnupg.sshKeyPaths != []);
        message = "Exactly one of sops.gnupg.home and sops.gnupg.sshKeyPaths must be set";
      } {
        assertion = (filterAttrs (_: v: v.owner != "root" || v.group != "root") secretsForUsers) == {};
        message = "neededForUsers cannot be used for secrets that are not root-owned";
      }] ++ optionals cfg.validateSopsFiles (
        concatLists (mapAttrsToList
          (name: secret:
            concatMap
              (sopsFile: [{
                assertion = builtins.pathExists sopsFile;
                message = "Cannot find path '${sopsFile}' set in sops.secrets.${strings.escapeNixIdentifier name}.sopsFiles";
              } {
                assertion =
                    builtins.isPath sopsFile ||
                    (builtins.isString sopsFile && hasPrefix builtins.storeDir sopsFile);
                message = "'${sopsFile}' is not in the Nix store. Either add it to the Nix store or set sops.validateSopsFiles to false";
              }])
              secret.sopsFiles)
          cfg.secrets)
      );


      sops.environment.SOPS_GPG_EXEC = mkIf (cfg.gnupg.home != null) (mkDefault "${pkgs.gnupg}/bin/gpg");

      system.activationScripts = {
        setupSecretsForUsers = mkIf (secretsForUsers != {}) (stringAfter ([ "specialfs" ] ++ optional cfg.age.generateKey "generate-age-key") ''
          [ -e /run/current-system ] || echo setting up secrets for users...
          ${withEnvironment "${sops-install-secrets}/bin/sops-install-secrets -ignore-passwd ${manifestForUsers}"}
        '' // lib.optionalAttrs (config.system ? dryActivationScript) {
          supportsDryActivation = true;
        });

        users = mkIf (secretsForUsers != {}) {
          deps = [ "setupSecretsForUsers" ];
        };

        setupSecrets = mkIf (regularSecrets != {}) (stringAfter ([ "specialfs" "users" "groups" ] ++ optional cfg.age.generateKey "generate-age-key") ''
          [ -e /run/current-system ] || echo setting up secrets...
          ${withEnvironment "${sops-install-secrets}/bin/sops-install-secrets ${manifest}"}
        '' // lib.optionalAttrs (config.system ? dryActivationScript) {
          supportsDryActivation = true;
        });

        generate-age-key = mkIf (cfg.age.generateKey) (stringAfter [] ''
          if [[ ! -f '${cfg.age.keyFile}' ]]; then
            echo generating machine-specific age key...
            mkdir -p $(dirname ${cfg.age.keyFile})
            # age-keygen sets 0600 by default, no need to chmod.
            ${pkgs.age}/bin/age-keygen -o ${cfg.age.keyFile}
          fi
        '');
      };
    })
    {
      system.build = {
        sops-nix-users-manifest = manifestForUsers;
        sops-nix-manifest = manifest;
      };
    }
  ];
}
