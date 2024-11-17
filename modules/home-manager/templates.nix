{
  config,
  pkgs,
  lib,
  options,
  ...
}:
let
  inherit (lib)
    mkOption
    mkDefault
    mapAttrs
    types
    ;
in
{
  options.sops = {
    templates = mkOption {
      description = "Templates for secret files";
      type = types.attrsOf (
        types.submodule (
          { config, ... }:
          {
            options = {
              name = mkOption {
                type = types.singleLineStr;
                default = config._module.args.name;
                description = ''
                  Name of the file used in /run/secrets/rendered
                '';
              };
              path = mkOption {
                description = "Path where the rendered file will be placed";
                type = types.singleLineStr;
                # Keep this in sync with `RenderedSubdir` in `pkgs/sops-install-secrets/main.go`
                default = "${config.xdg.configHome}/sops-nix/secrets/rendered/${config.name}";
              };
              content = mkOption {
                type = types.lines;
                default = "";
                description = ''
                  Content of the file
                '';
              };
              mode = mkOption {
                type = types.singleLineStr;
                default = "0400";
                description = ''
                  Permissions mode of the rendered secret file in octal.
                '';
              };
              file = mkOption {
                type = types.path;
                default = pkgs.writeText config.name config.content;
                defaultText = lib.literalExpression ''pkgs.writeText config.name config.content'';
                example = "./configuration-template.conf";
                description = ''
                  File used as the template. When this value is specified, `sops.templates.<name>.content` is ignored.
                '';
              };
              restartUnits = lib.mkOption {
                type = lib.types.listOf lib.types.str;
                default = [ ];
                example = [ "sshd.service" ];
                description = ''
                  Names of units that should be restarted when the rendered template changes.
                  This works the same way as <xref linkend="opt-systemd.services._name_.restartTriggers" />.
                '';
              };
              reloadUnits = lib.mkOption {
                type = lib.types.listOf lib.types.str;
                default = [ ];
                example = [ "sshd.service" ];
                description = ''
                  Names of units that should be reloaded when the rendered template changes.
                  This works the same way as <xref linkend="opt-systemd.services._name_.reloadTriggers" />.
                '';
              };
            };
          }
        )
      );
      default = { };
    };
    placeholder = mkOption {
      type = types.attrsOf (
        types.mkOptionType {
          name = "coercibleToString";
          description = "value that can be coerced to string";
          check = lib.strings.isConvertibleWithToString;
          merge = lib.mergeEqualOption;
        }
      );
      default = { };
      visible = false;
    };
  };

  config = lib.optionalAttrs (options ? sops.secrets) (
    lib.mkIf (config.sops.templates != { }) {
      sops.placeholder = mapAttrs (
        name: _: mkDefault "<SOPS:${builtins.hashString "sha256" name}:PLACEHOLDER>"
      ) config.sops.secrets;
    }
  );
}
