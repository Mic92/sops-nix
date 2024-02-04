{ config, lib, pkgs, ... }:

let
  cfg = config.sops;
  sops-install-secrets = (pkgs.callPackage ../.. {}).sops-install-secrets;
  secretType = lib.types.submodule ({ config, options, name, ... }: {
    config = lib.mkMerge[{
      sopsFile = lib.mkOptionDefault cfg.defaultSopsFile;
      sopsFiles = lib.mkIf (lib.length cfg.defaultSopsFiles > 0) (lib.mkOptionDefault cfg.defaultSopsFiles);
    }
    {
      sopsFiles = lib.mkIf (config.sopsFile != null) ( lib.mkOverride options.sopsFile.highestPrio (lib.mkBefore [config.sopsFile]));
    }];
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
        default = name;
        description = ''
          Key used to lookup in the sops file.
          No tested data structures are supported right now.
          This option is ignored if format is binary.
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
        type = lib.types.enum [ "yaml" "json" "binary" "ini" "dotenv" ];
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
        defaultText = "\${config.sops.defaultSopsFile}";
        description = ''
          Sops file the secret is loaded from.
        '';
      };

      sopsFiles = lib.mkOption {
        type = lib.types.nonEmptyListOf lib.types.path;
        defaultText = "\${config.sops.defaultSopsFiles}";
        description = ''
          Sops files the secret is loaded from.
        '';
      };
    };
  });

  manifestFor = suffix: secrets: pkgs.writeTextFile {
    name = "manifest${suffix}.json";
    text = builtins.toJSON {
      secrets = builtins.attrValues secrets;
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
      ${sops-install-secrets}/bin/sops-install-secrets -check-mode=${if cfg.validateSopsFiles then "sopsfile" else "manifest"} "$out"
    '';
  };

  manifest = manifestFor "" cfg.secrets;

  script = toString (pkgs.writeShellScript "sops-nix-user" ((lib.optionalString (cfg.gnupg.home != null) ''
    export SOPS_GPG_EXEC=${pkgs.gnupg}/bin/gpg
  '')
    + (lib.optionalString cfg.age.generateKey ''
    if [[ ! -f '${cfg.age.keyFile}' ]]; then
      echo generating machine-specific age key...
      mkdir -p $(dirname ${cfg.age.keyFile})
      # age-keygen sets 0600 by default, no need to chmod.
      ${pkgs.age}/bin/age-keygen -o ${cfg.age.keyFile}
    fi
  '' + ''
    ${sops-install-secrets}/bin/sops-install-secrets -ignore-passwd '${manifest}'
  '')));
in {
  options.sops = {
    secrets = lib.mkOption {
      type = lib.types.attrsOf secretType;
      default = {};
      description = ''
        Secrets to decrypt.
      '';
    };

    defaultSopsFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = ''
        Default sops file used for all secrets.
      '';
    };

    defaultSopsFiles = lib.mkOption {
      type = lib.types.listOf lib.types.path;
      default = [];
      description = ''
        Default sops files used for all secrets.
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

    defaultSymlinkPath = lib.mkOption {
      type = lib.types.str;
      default = "%r/secrets";
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
      type = lib.types.listOf (lib.types.enum [ "keyImport" "secretChanges" ]);
      default = [ "keyImport" "secretChanges" ];
      description = "What to log";
    };

    age = {
      keyFile = lib.mkOption {
        type = lib.types.nullOr lib.types.path;
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
        default = [];
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

      sshKeyPaths = lib.mkOption {
        type = lib.types.listOf lib.types.path;
        default = [];
        description = ''
          Path to ssh keys added as GPG keys during sops description.
          This option must be explicitly unset if <literal>config.sops.gnupg.sshKeyPaths</literal> is set.
        '';
      };
    };
  };

  config = lib.mkIf (cfg.secrets != {}) {
    assertions = [{
      assertion = cfg.gnupg.home != null || cfg.gnupg.sshKeyPaths != [] || cfg.age.keyFile != null || cfg.age.sshKeyPaths != [];
      message = "No key source configured for sops. Either set services.openssh.enable or set sops.age.keyFile or sops.gnupg.home";
    } {
      assertion = !(cfg.gnupg.home != null && cfg.gnupg.sshKeyPaths != []);
      message = "Exactly one of sops.gnupg.home and sops.gnupg.sshKeyPaths must be set";
    }] ++ lib.optionals cfg.validateSopsFiles (
      lib.concatLists (lib.mapAttrsToList
        (name: secret:
          lib.concatMap
            (sopsFile: [{
              assertion = builtins.pathExists sopsFile;
              message = "Cannot find path '${sopsFile}' set in sops.secrets.${lib.strings.escapeNixIdentifier name}.sopsFiles";
            } {
              assertion =
                  builtins.isPath sopsFile ||
                  (builtins.isString sopsFile && lib.hasPrefix builtins.storeDir sopsFile);
              message = "'${sopsFile}' is not in the Nix store. Either add it to the Nix store or set sops.validateSopsFiles to false";
            }])
            secret.sopsFiles)
        cfg.secrets)
    );

    systemd.user.services.sops-nix = lib.mkIf pkgs.stdenv.hostPlatform.isLinux {
      Unit = {
        Description = "sops-nix activation";
      };
      Service = {
        Type = "oneshot";
        ExecStart = script;
      };
      Install.WantedBy = if cfg.gnupg.home != null then [ "graphical-session-pre.target" ] else [ "default.target" ];
    };

    launchd.agents.sops-nix = {
      enable = true;
      config = {
        ProgramArguments = [ script ];
        KeepAlive = {
          Crashed = false;
          SuccessfulExit = false;
        };
        ProcessType = "Background";
        StandardOutPath = "${config.home.homeDirectory}/Library/Logs/SopsNix/stdout";
        StandardErrorPath = "${config.home.homeDirectory}/Library/Logs/SopsNix/stderr";
      };
    };
  };
}
