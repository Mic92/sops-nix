{
  cfg,
  lib,
  pkgs,
}:

let
  escapedKeyFile = lib.escapeShellArg cfg.age.keyFile;
in
lib.mkIf cfg.age.generateKey (
  lib.stringAfter [ ] ''
    if [[ ! -f ${escapedKeyFile} ]]; then
      echo generating machine-specific age key...
      mkdir -p $(dirname ${escapedKeyFile})
      # age-keygen sets 0600 by default, no need to chmod.
      ${pkgs.age}/bin/age-keygen -o ${escapedKeyFile}
    fi
  ''
)
