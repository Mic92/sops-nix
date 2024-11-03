{ writeTextFile, cfg }:

suffix: secrets: extraJson:

writeTextFile {
  name = "manifest${suffix}.json";
  text = builtins.toJSON ({
    secrets = builtins.attrValues secrets;
    # Does this need to be configurable?
    secretsMountPoint = "/run/secrets.d";
    symlinkPath = "/run/secrets";
    keepGenerations = cfg.keepGenerations;
    gnupgHome = cfg.gnupg.home;
    sshKeyPaths = cfg.gnupg.sshKeyPaths;
    ageKeyFile = cfg.age.keyFile;
    ageSshKeyPaths = cfg.age.sshKeyPaths;
    useTmpfs = false;
    templates = cfg.templates;
    placeholderBySecretName = cfg.placeholder;
    userMode = false;
    logging = {
      keyImport = builtins.elem "keyImport" cfg.log;
      secretChanges = builtins.elem "secretChanges" cfg.log;
    };
  } // extraJson);
  checkPhase = ''
    ${cfg.validationPackage}/bin/sops-install-secrets -check-mode=${if cfg.validateSopsFiles then "sopsfile" else "manifest"} "$out"
  '';
}
