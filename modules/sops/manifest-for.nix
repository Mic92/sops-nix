{
  writeTextFile,
  cfg,
  lib,
}:

suffix: secrets: templates: extraJson:

let

  failedAssertions = builtins.foldl' (
    acc: secret:
    acc
    ++ (lib.optional (!builtins.pathExists secret.sopsFile)
      "Cannot find path '${secret.sopsFile}' set in sops.secrets.${lib.strings.escapeNixIdentifier secret.name}.sopsFile\n"
    )
    ++
      lib.optional
        (
          !builtins.isPath secret.sopsFile
          && !(builtins.isString secret.sopsFile && lib.hasPrefix builtins.storeDir secret.sopsFile)
        )
        "'${secret.sopsFile}' is not in the Nix store. Either add it to the Nix store or set sops.validateSopsFiles to false"
  ) [ ] (builtins.attrValues secrets);

in
if failedAssertions != [ ] then
  throw "\nFailed assertions:\n${lib.concatStringsSep "\n" (map (x: "- ${x}") failedAssertions)}"
else
  writeTextFile {
    name = "manifest${suffix}.json";
    text = builtins.toJSON (
      {
        secrets = builtins.attrValues secrets;
        templates = builtins.attrValues templates;
        # Does this need to be configurable?
        secretsMountPoint = "/run/secrets.d";
        symlinkPath = "/run/secrets";
        keepGenerations = cfg.keepGenerations;
        gnupgHome = cfg.gnupg.home;
        sshKeyPaths = cfg.gnupg.sshKeyPaths;
        ageKeyFile = cfg.age.keyFile;
        ageSshKeyPaths = cfg.age.sshKeyPaths;
        useTmpfs = cfg.useTmpfs;
        placeholderBySecretName = cfg.placeholder;
        userMode = false;
        logging = {
          keyImport = builtins.elem "keyImport" cfg.log;
          secretChanges = builtins.elem "secretChanges" cfg.log;
        };
      }
      // extraJson
    );
    checkPhase = ''
      ${cfg.validationPackage}/bin/sops-install-secrets -check-mode=${
        if cfg.validateSopsFiles then "sopsfile" else "manifest"
      } "$out"
    '';
  }
