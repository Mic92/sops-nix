{ cfg, lib }:

sopsCall:

if cfg.environment == { } then
  sopsCall
else
  ''
    (
    ${lib.concatStringsSep "\n" (lib.mapAttrsToList (n: v: "  export ${n}='${v}'") cfg.environment)}
      ${sopsCall}
    )
  ''
