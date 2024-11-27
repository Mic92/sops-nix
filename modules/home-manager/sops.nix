{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.sops;
  sops-install-secrets = (pkgs.callPackage ../.. { }).sops-install-secrets;
  secretType = lib.types.submodule (
    { name, ... }:
    {
      options = {
        name = lib.mkOption {
          type = lib.types.str;
          default = name;
          description = ''
            Name of the file used in /run/user/*/secrets
          '';
        };

        key = lib.mkOption {
          type = lib.types.str;
          default = if cfg.defaultSopsKey != null then cfg.defaultSopsKey else name;
          description = ''
            Key used to lookup in the sops file.
            No tested data structures are supported right now.
            This option is ignored if format is binary.
            "" means whole file.
          '';
        };

        path = lib.mkOption {
          type = lib.types.str;
          default = "${cfg.defaultSymlinkPath}/${name}";
          description = ''
            Path where secrets are symlinked to.
            If the default is kept no other symlink is created.
            `%r` is replaced by $XDG_RUNTIME_DIR on linux or `getconf
            DARWIN_USER_TEMP_DIR` on darwin.
          '';
        };

        format = lib.mkOption {
          type = lib.types.enum [
            "yaml"
            "json"
            "binary"
            "ini"
            "dotenv"
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

        sopsFile = lib.mkOption {
          type = lib.types.path;
          default = cfg.defaultSopsFile;
          defaultText = lib.literalExpression "\${config.sops.defaultSopsFile}";
          description = ''
            Sops file the secret is loaded from.
          '';
        };
      };
    }
  );

  pathNotInStore = lib.mkOptionType {
    name = "pathNotInStore";
    description = "path not in the Nix store";
    descriptionClass = "noun";
    check = x: !lib.path.hasStorePathPrefix (/. + x);
    merge = lib.mergeEqualOption;
  };

  manifestFor =
    suffix: secrets: templates:
    pkgs.writeTextFile {
      name = "manifest${suffix}.json";
      text = builtins.toJSON {
        secrets = builtins.attrValues secrets;
        templates = builtins.attrValues templates;
        secretsMountPoint = cfg.defaultSecretsMountPoint;
        symlinkPath = cfg.defaultSymlinkPath;
        keepGenerations = cfg.keepGenerations;
        gnupgHome = cfg.gnupg.home;
        sshKeyPaths = cfg.gnupg.sshKeyPaths;
        ageKeyFile = cfg.age.keyFile;
        ageSshKeyPaths = cfg.age.sshKeyPaths;
        userMode = true;
        logging = {
          keyImport = builtins.elem "keyImport" cfg.log;
          secretChanges = builtins.elem "secretChanges" cfg.log;
        };
      };
      checkPhase = ''
        ${sops-install-secrets}/bin/sops-install-secrets -check-mode=${
          if cfg.validateSopsFiles then "sopsfile" else "manifest"
        } "$out"
      '';
    };

  manifest = manifestFor "" cfg.secrets cfg.templates;

  escapedAgeKeyFile = lib.escapeShellArg cfg.age.keyFile;

  script = toString (
    pkgs.writeShellScript "sops-nix-user" (
      lib.optionalString cfg.age.generateKey ''
        if [[ ! -f ${escapedAgeKeyFile} ]]; then
          echo generating machine-specific age key...
          ${pkgs.coreutils}/bin/mkdir -p $(${pkgs.coreutils}/bin/dirname ${escapedAgeKeyFile})
          # age-keygen sets 0600 by default, no need to chmod.
          ${pkgs.age}/bin/age-keygen -o ${escapedAgeKeyFile}
        fi
      ''
      + ''
        ${sops-install-secrets}/bin/sops-install-secrets -ignore-passwd ${manifest}
      ''
    )
  );
in
{
  imports = [
    ./templates.nix
  ];

  options.sops = {
    secrets = lib.mkOption {
      type = lib.types.attrsOf secretType;
      default = { };
      description = ''
        Secrets to decrypt.
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

    defaultSymlinkPath = lib.mkOption {
      type = lib.types.str;
      default = "${config.xdg.configHome}/sops-nix/secrets";
      description = ''
        Default place where the latest generation of decrypt secrets
        can be found.
      '';
    };

    defaultSecretsMountPoint = lib.mkOption {
      type = lib.types.str;
      default = "%r/secrets.d";
      description = ''
        Default place where generations of decrypted secrets are stored.
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

        To properly quote strings with quotes use lib.escapeShellArg.
      '';
    };

    age = {
      keyFile = lib.mkOption {
        type = lib.types.nullOr pathNotInStore;
        default = null;
        example = "/home/someuser/.age-key.txt";
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
        default = [ ];
        description = ''
          Paths to ssh keys added as age keys during sops description.
        '';
      };
    };

    gnupg = {
      home = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        example = "/home/someuser/.gnupg";
        description = ''
          Path to gnupg database directory containing the key for decrypting the sops file.
        '';
      };

      qubes-split-gpg = {
        enable = lib.mkEnableOption "Enable support for Qubes Split GPG feature: https://www.qubes-os.org/doc/split-gpg";

        domain = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = null;
          example = "vault-gpg";
          description = ''
            It tells Qubes OS which secure Qube holds your GPG keys for isolated cryptographic operations.
          '';
        };
      };

      sshKeyPaths = lib.mkOption {
        type = lib.types.listOf lib.types.path;
        default = [ ];
        description = ''
          Path to ssh keys added as GPG keys during sops description.
          This option must be explicitly unset if <literal>config.sops.gnupg.sshKeyPaths</literal> is set.
        '';
      };
    };
  };

  config = lib.mkIf (cfg.secrets != { }) {
    assertions =
      [
        {
          assertion =
            cfg.gnupg.home != null
            || cfg.gnupg.sshKeyPaths != [ ]
            || cfg.gnupg.qubes-split-gpg.enable == true
            || cfg.age.keyFile != null
            || cfg.age.sshKeyPaths != [ ];
          message = "No key source configured for sops. Either set services.openssh.enable or set sops.age.keyFile or sops.gnupg.home or sops.gnupg.qubes-split-gpg.enable";
        }
        {
          assertion =
            !(cfg.gnupg.home != null && cfg.gnupg.sshKeyPaths != [ ])
            && !(cfg.gnupg.home != null && cfg.gnupg.qubes-split-gpg.enable == true)
            && !(cfg.gnupg.sshKeyPaths != [ ] && cfg.gnupg.qubes-split-gpg.enable == true);
          message = "Exactly one of sops.gnupg.home, sops.gnupg.qubes-split-gpg.enable and sops.gnupg.sshKeyPaths must be set";
        }
        {
          assertion =
            cfg.gnupg.qubes-split-gpg.enable == false
            || (
              cfg.gnupg.qubes-split-gpg.enable == true
              && cfg.gnupg.qubes-split-gpg.domain != null
              && cfg.gnupg.qubes-split-gpg.domain != ""
            );
          message = "sops.gnupg.qubes-split-gpg.domain is required when sops.gnupg.qubes-split-gpg.enable is set to true";
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
          ]) cfg.secrets
        )
      );

    home.sessionVariables = lib.mkIf cfg.gnupg.qubes-split-gpg.enable {
      # TODO: Add this package to nixpkgs and use it from the store
      # https://github.com/QubesOS/qubes-app-linux-split-gpg
      SOPS_GPG_EXEC = "qubes-gpg-client-wrapper";
    };

    sops.environment = {
      SOPS_GPG_EXEC = lib.mkMerge [
        (lib.mkIf (cfg.gnupg.home != null || cfg.gnupg.sshKeyPaths != [ ]) (
          lib.mkDefault "${pkgs.gnupg}/bin/gpg"
        ))
        (lib.mkIf cfg.gnupg.qubes-split-gpg.enable (
          lib.mkDefault config.home.sessionVariables.SOPS_GPG_EXEC
        ))
      ];

      QUBES_GPG_DOMAIN = lib.mkIf cfg.gnupg.qubes-split-gpg.enable (
        lib.mkDefault cfg.gnupg.qubes-split-gpg.domain
      );
    };

    systemd.user.services.sops-nix = lib.mkIf pkgs.stdenv.hostPlatform.isLinux {
      Unit = {
        Description = "sops-nix activation";
      };
      Service = {
        Type = "oneshot";
        Environment = builtins.concatStringsSep " " (
          lib.mapAttrsToList (name: value: "'${name}=${value}'") cfg.environment
        );
        ExecStart = script;
      };
      Install.WantedBy =
        if cfg.gnupg.home != null then [ "graphical-session-pre.target" ] else [ "default.target" ];
    };

    # Darwin: load secrets once on login
    launchd.agents.sops-nix = {
      enable = true;
      config = {
        Program = script;
        EnvironmentVariables = cfg.environment;
        KeepAlive = false;
        RunAtLoad = true;
        StandardOutPath = "${config.home.homeDirectory}/Library/Logs/SopsNix/stdout";
        StandardErrorPath = "${config.home.homeDirectory}/Library/Logs/SopsNix/stderr";
      };
    };

    # [re]load secrets on home-manager activation
    home.activation =
      let
        darwin =
          let
            domain-target = "gui/$(id -u ${config.home.username})";
          in
          ''
            /bin/launchctl bootout ${domain-target}/org.nix-community.home.sops-nix && true
            /bin/launchctl bootstrap ${domain-target} ${config.home.homeDirectory}/Library/LaunchAgents/org.nix-community.home.sops-nix.plist
          '';

        linux =
          let
            systemctl = config.systemd.user.systemctlPath;
          in
          ''
            systemdStatus=$(${systemctl} --user is-system-running 2>&1 || true)

            if [[ $systemdStatus == 'running' || $systemdStatus == 'degraded' ]]; then
              ${systemctl} restart --user sops-nix
            else
              echo "User systemd daemon not running. Probably executed on boot where no manual start/reload is needed."
            fi

            unset systemdStatus
          '';

      in
      {
        sops-nix = if pkgs.stdenv.isLinux then linux else darwin;
      };
  };
}
