{
  config,
  ...
}:
{
  imports = [
    ../modules/nix-darwin/default.nix
  ];
  documentation.enable = false;
  sops.secrets.test_key = { };
  sops.templates."template.toml" = {
    content = ''
      password = "${config.sops.placeholder.test_key}";
    '';
  };
  sops.templates."template-with-uid.toml" = {
    content = ''
      password = "${config.sops.placeholder.test_key}";
    '';
    uid = 1000;
  };
  sops.templates."template-with-gid.toml" = {
    content = ''
      password = "${config.sops.placeholder.test_key}";
    '';
    gid = 1000;
  };
  sops.defaultSopsFile = ../pkgs/sops-install-secrets/test-assets/secrets.yaml;
  sops.age.generateKey = true;
  system.stateVersion = 5;
}
