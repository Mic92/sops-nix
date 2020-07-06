{ config, lib, pkgs, ... }:

with lib;

let
  cfg = config.sops;
  users = config.users.users;
  sops-install-secrets = pkgs.callPackage ../../pkgs/sops-install-secrets {};
  secretType = types.submodule ({ config, ... }: {
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
      path = assert assertMsg (builtins.pathExists config.sopsFile) ''
          Cannot find path '${config.sopsFile}' set in 'sops.secrets."${config._module.args.name}".sopsFile'
        '';
        mkOption {
          type = types.str;
          default = "/run/secrets/${config.name}";
          description = ''
            Path where secrets are symlinked to.
            If the default is kept no symlink is created.
          '';
        };
      format = mkOption {
        type = types.enum ["yaml" "json" "binary"];
        default = "yaml";
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
        description = ''
          Group of the file.
        '';
      };
      sopsFile = mkOption {
        type = types.either types.str types.path;
        default = cfg.defaultSopsFile;
        description = ''
          Sops file the secret is loaded from.
        '';
      };
    };
  });
  manifest = builtins.toFile "manifest.json" (builtins.toJSON {
    secrets = builtins.attrValues cfg.secrets;
    # Does this need to be configurable?
    secretsMountPoint = "/run/secrets.d";
    symlinkPath = "/run/secrets";
  });
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
      type = types.either types.str types.path;
      description = ''
        Default sops file used for all secrets.
      '';
    };

    gnupgHome = mkOption {
      type = types.str;
      default = "/root/.gnupg";
      description = ''
        Path to gnupg database directory containing the key for decrypting sops file
      '';
    };
  };
  config = mkIf (cfg.secrets != {}) {
    system.activationScripts.setup-secrets = stringAfter [ "users" "groups" ] ''
      echo setting up secrets...
      SOPS_GPG_EXEC=${pkgs.gnupg}/bin/gpg GNUPGHOME=${cfg.gnupgHome} ${sops-install-secrets}/bin/sops-install-secrets ${manifest}
    '';
  };
}
