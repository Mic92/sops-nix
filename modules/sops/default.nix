{ config, lib, pkgs, ... }:

with lib;

let
  cfg = config.sops;
  users = config.users.users;
  secretType = types.submodule ({ config, ... }: {
    config = {
      sopsFile = lib.mkOptionDefault cfg.defaultSopsFile;
    };
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
        default = "/run/secrets/${config.name}";
        description = ''
          Path where secrets are symlinked to.
          If the default is kept no symlink is created.
        '';
      };
      format = mkOption {
        type = types.enum ["yaml" "json" "binary"];
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
        description = ''
          Group of the file.
        '';
      };
      sopsFile = mkOption {
        type = types.path;
        defaultText = "\${config.sops.defaultSopsFile}";
        description = ''
          Sops file the secret is loaded from.
        '';
      };
    };
  });
  manifest = pkgs.writeText "manifest.json" (builtins.toJSON {
    secrets = builtins.attrValues cfg.secrets;
    # Does this need to be configurable?
    secretsMountPoint = "/run/secrets.d";
    symlinkPath = "/run/secrets";
    inherit (cfg) gnupgHome sshKeyPaths;
  });

  checkedManifest = let
    sops-install-secrets = (pkgs.buildPackages.callPackage ../.. {}).sops-install-secrets;
  in pkgs.runCommandNoCC "checked-manifest.json" {
    nativeBuildInputs = [ sops-install-secrets ];
  } ''
    sops-install-secrets -check-mode=${if cfg.validateSopsFiles then "sopsfile" else "manifest"} ${manifest}
    cp ${manifest} $out
  '';
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
      type = types.path;
      description = ''
        Default sops file used for all secrets.
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

    gnupgHome = mkOption {
      type = types.nullOr types.str;
      default = null;
      example = "/root/.gnupg";
      description = ''
        Path to gnupg database directory containing the key for decrypting sops file.
      '';
    };

    sshKeyPaths = mkOption {
      type = types.listOf types.path;
      default = if config.services.openssh.enable then
                  map (e: e.path) (lib.filter (e: e.type == "rsa") config.services.openssh.hostKeys)
                else [];
      description = ''
        Path to ssh keys added as GPG keys during sops description.
        This option must be explicitly unset if <literal>config.sops.sshKeyPaths</literal>.
      '';
    };
  };
  config = mkIf (cfg.secrets != {}) {
    assertions = [{
      assertion = (cfg.gnupgHome == null) != (cfg.sshKeyPaths == []);
      message = "Exactly one of sops.gnupgHome and sops.sshKeyPaths must be set";
    }] ++ optionals cfg.validateSopsFiles (
      concatLists (mapAttrsToList (name: secret: [{
        assertion = builtins.pathExists secret.sopsFile;
        message = "Cannot find path '${secret.sopsFile}' set in sops.secrets.${strings.escapeNixIdentifier name}.sopsFile";
      } {
        assertion =
          builtins.isPath secret.sopsFile ||
          (builtins.isString secret.sopsFile && hasPrefix builtins.storeDir secret.sopsFile);
        message = "'${secret.sopsFile}' is not in the Nix store. Either add it to the Nix store or set sops.validateSopsFiles to false";
      }]) cfg.secrets)
    );

    system.activationScripts.setup-secrets = let
      sops-install-secrets = (pkgs.callPackage ../.. {}).sops-install-secrets;
    in stringAfter [ "users" "groups" ] ''
      echo setting up secrets...
      ${optionalString (cfg.gnupgHome != null) "SOPS_GPG_EXEC=${pkgs.gnupg}/bin/gpg"} ${sops-install-secrets}/bin/sops-install-secrets ${checkedManifest}
    '';
  };
}
