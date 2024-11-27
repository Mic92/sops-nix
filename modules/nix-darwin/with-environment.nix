{ cfg, lib }:

sopsCall:

if cfg.environment == { } then
  sopsCall
else
  ''
    (
    # shellcheck disable=SC2030,SC2031
    ${lib.concatStringsSep "\n" (lib.mapAttrsToList (n: v: "  export ${n}='${v}'") cfg.environment)}
      ${sopsCall}
    )
  ''
