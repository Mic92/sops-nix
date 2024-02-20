{ config, pkgs, lib, options, ... }:
with lib;
with lib.types;
with builtins;
let
  cfg = config.sops;
  secretsForUsers = lib.filterAttrs (_: v: v.neededForUsers) cfg.secrets;
  users = config.users.users;
in {
  options.sops = {
    templates = mkOption {
      description = "Templates for secret files";
      type = attrsOf (submodule ({ config, ... }: {
        options = {
          name = mkOption {
            type = singleLineStr;
            default = config._module.args.name;
            description = ''
              Name of the file used in /run/secrets-rendered
            '';
          };
          path = mkOption {
            description = "Path where the rendered file will be placed";
            type = singleLineStr;
            default = "/run/secrets-rendered/${config.name}";
          };
          content = mkOption {
            type = lines;
            default = "";
            description = ''
              Content of the file
            '';
          };
          mode = mkOption {
            type = singleLineStr;
            default = "0400";
            description = ''
              Permissions mode of the rendered secret file in octal.
            '';
          };
          owner = mkOption {
            type = singleLineStr;
            default = "root";
            description = ''
              User of the file.
            '';
          };
          group = mkOption {
            type = singleLineStr;
            default = users.${config.owner}.group;
            defaultText = ''config.users.users.''${cfg.owner}.group'';
            description = ''
              Group of the file.
            '';
          };
          file = mkOption {
            type = types.path;
            default = pkgs.writeText config.name config.content;
            visible = false;
            readOnly = true;
          };
        };
      }));
      default = { };
    };
    placeholder = mkOption {
      type = attrsOf (mkOptionType {
        name = "coercibleToString";
        description = "value that can be coerced to string";
        check = strings.isConvertibleWithToString;
        merge = mergeEqualOption;
      });
      default = { };
      visible = false;
    };
  };

  config = optionalAttrs (options ? sops.secrets)
    (mkIf (config.sops.templates != { }) {
      sops.placeholder = mapAttrs
        (name: _: mkDefault "<SOPS:${hashString "sha256" name}:PLACEHOLDER>")
        config.sops.secrets;

      system.activationScripts.renderSecrets = mkIf (cfg.templates != { })
        (stringAfter ([ "setupSecrets" ]
          ++ optional (secretsForUsers != { }) "setupSecretsForUsers") ''
            echo Setting up sops templates...
            ${concatMapStringsSep "\n" (name:
              let
                tpl = config.sops.templates.${name};
                substitute = pkgs.writers.writePython3 "substitute" { }
                  (readFile ./subs.py);
                subst-pairs = pkgs.writeText "pairs" (concatMapStringsSep "\n"
                  (name:
                    "${toString config.sops.placeholder.${name}} ${
                      config.sops.secrets.${name}.path
                    }") (attrNames config.sops.secrets));
              in ''
                mkdir -p "${dirOf tpl.path}"
                (umask 077; ${substitute} ${tpl.file} ${subst-pairs} > ${tpl.path})
                chmod "${tpl.mode}" "${tpl.path}"
                chown "${tpl.owner}:${tpl.group}" "${tpl.path}"
              '') (attrNames config.sops.templates)}
          '');
    });
}
