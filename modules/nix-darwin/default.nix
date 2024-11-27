{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.sops;
  sops-install-secrets = cfg.package;
  manifestFor = pkgs.callPackage ./manifest-for.nix {
    inherit cfg;
    inherit (pkgs) writeTextFile;
  };
  manifest = manifestFor "" regularSecrets regularTemplates { };

  # Currently, all templates are "regular" (there's no support for `neededForUsers` for templates.)
  regularTemplates = cfg.templates;

  pathNotInStore = lib.mkOptionType {
    name = "pathNotInStore";
    description = "path not in the Nix store";
    descriptionClass = "noun";
    check = x: !lib.path.hasStorePathPrefix (/. + x);
    merge = lib.mergeEqualOption;
  };

  regularSecrets = lib.filterAttrs (_: v: !v.neededForUsers) cfg.secrets;

  withEnvironment = import ./with-environment.nix {
    inherit cfg lib;
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
          default = config._module.args.name;
          description = ''
            Key used to lookup in the sops file.
            No tested data structures are supported right now.
            This option is ignored if format is binary.
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
          default = "root";
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
          default = "staff";
          defaultText = "staff";
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
            Hash of the sops file.
          '';
        };
        neededForUsers = lib.mkOption {
          type = lib.types.bool;
          default = false;
          description = ''
             **Warning** This option doesn't have any effect on macOS, as nix-darwin cannot manage user passwords on macOS.
            This can be used to retrieve user's passwords from sops-nix.
            Setting this option moves the secret to /run/secrets-for-users and disallows setting owner and group to anything else than root.
          '';
        };
      };
    }
  );

  darwinSSHKeys = [
    {
      type = "rsa";
      path = "/etc/ssh/ssh_host_rsa_key";
    }
    {
      type = "ed25519";
      path = "/etc/ssh/ssh_host_ed25519_key";
    }
  ];

  escapedKeyFile = lib.escapeShellArg cfg.age.keyFile;
  # Skip ssh keys deployed with sops to avoid a catch 22
  defaultImportKeys =
    algo:
    map (e: e.path) (
      lib.filter (e: e.type == algo && !(lib.hasPrefix "/run/secrets" e.path)) darwinSSHKeys
    );

  installScript = ''
    ${
      if cfg.age.generateKey then
        ''
          if [[ ! -f ${escapedKeyFile} ]]; then
            echo generating machine-specific age key...
            mkdir -p "$(dirname ${escapedKeyFile})"
            # age-keygen sets 0600 by default, no need to chmod.
            ${pkgs.age}/bin/age-keygen -o ${escapedKeyFile}
          fi
        ''
      else
        ""
    }
    echo "Setting up secrets..."
    ${withEnvironment "${sops-install-secrets}/bin/sops-install-secrets ${manifest}"}
  '';

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

    age = {
      keyFile = lib.mkOption {
        type = lib.types.nullOr pathNotInStore;
        default = null;
        example = "/var/lib/sops-nix/key.txt";
        description = ''
          Path to age key file used for sops decryption.
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
                assertion = builtins.pathExists secret.sopsFile;
                message = "Cannot find path '${secret.sopsFile}' set in sops.secrets.${lib.strings.escapeNixIdentifier name}.sopsFile";
              }
              {
                assertion =
                  builtins.isPath secret.sopsFile
                  || (builtins.isString secret.sopsFile && lib.hasPrefix builtins.storeDir secret.sopsFile);
                message = "'${secret.sopsFile}' is not in the Nix store. Either add it to the Nix store or set sops.validateSopsFiles to false";
              }
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

      system.build.sops-nix-manifest = manifest;
      system.activationScripts = {
        postActivation.text = lib.mkAfter installScript;
      };

      launchd.daemons.sops-install-secrets = {
        command = installScript;
        serviceConfig = {
          RunAtLoad = true;
          KeepAlive = false;
        };
      };
    })

    {
      sops.environment.SOPS_GPG_EXEC = lib.mkIf (cfg.gnupg.home != null || cfg.gnupg.sshKeyPaths != [ ]) (
        lib.mkDefault "${pkgs.gnupg}/bin/gpg"
      );
    }
  ];
}
