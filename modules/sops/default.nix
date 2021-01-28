{ config, lib, pkgs, ... }:

with lib;

let
  cfg = config.sops;
  users = config.users.users;
  sops-install-secrets = (pkgs.callPackage ../.. {}).sops-install-secrets;
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
    inherit (cfg) gnupgHome sshKeyPaths;
  });

  checkedManifest = pkgs.runCommandNoCC "checked-manifest.json" {
    nativeBuildInputs = [ sops-install-secrets ];
  } ''
    sops-install-secrets -check-mode=${if cfg.validateSopsFiles then "sopsfile" else "manifest"} ${manifest}
    cp ${manifest} $out
  '';

  setupScript = ''
      echo setting up secrets...
      ${optionalString (cfg.gnupgHome != null) "SOPS_GPG_EXEC=${pkgs.gnupg}/bin/gpg"} ${sops-install-secrets}/bin/sops-install-secrets ${checkedManifest}
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
      type = types.either types.str types.path;
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

    activationMethod = mkOption {
      type = types.enum [ "script" "systemd" ];
      default = "script";
      description = ''
        Which method to use for setting up secrets. Use `script` for an
        activation script, and `systemd` for a systemd unit.
      '';
    };
  };
  config = mkIf (cfg.secrets != {}) {
    assertions = [{
      assertion = cfg.gnupgHome != null -> cfg.sshKeyPaths == [];
      message = "Configuration options sops.gnupgHome and sops.sshKeyPaths cannot be set both at the same time";
    } {
      assertion = cfg.gnupgHome == null -> cfg.sshKeyPaths != [];
      message = "Either sops.sshKeyPaths and sops.gnupgHome must be set";
    }] ++ map (name: let
      inherit (cfg.secrets.${name}) sopsFile;
    in {
      assertion = cfg.validateSopsFiles -> builtins.isPath sopsFile;
      message = "${sopsFile} is not in the nix store. Either add it to the nix store or set `sops.validateSopsFiles` to false";
    }) (builtins.attrNames cfg.secrets);

    system.activationScripts.setup-secrets = mkIf (cfg.activationMethod == "script") (stringAfter [ "users" "groups" ] setupScript);

    systemd.services.sops-nix-setup-secrets = mkIf (cfg.activationMethod == "systemd") {
      description = "sops-nix secrets setup";
      script = setupScript;
      serviceConfig.Type = "oneshot";
      wantedBy = [ "default.target" ];
    };
  };
}
