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
                default = "/run/secrets/rendered/${config.name}";
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
              owner = mkOption {
                type = with lib.types; nullOr singleLineStr;
                default = null;
                description = ''
                  User of the file. Can only be set if uid is 0;
                '';
              };
              uid = mkOption {
                type = with lib.types; nullOr int;
                default = 0;
                description = ''
                  UID of the template, only applied with owner is null. the UID will be applied even if the corresponding user doesn't exist.
                '';
              };
              group = mkOption {
                type = with lib.types; nullOr singleLineStr;
                default = if config.owner != null then "staff" else null;
                defaultText = "staff";
                description = ''
                  Group of the file. Can only be set if gid is 0. Default on darwin to 'staff'
                '';
              };
              gid = mkOption {
                type = with lib.types; nullOr int;
                default = 0;
                description = ''
                  GID of the template, only applied when group is null. The GID will be applied even if the corresponding group doesn't exist.
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
