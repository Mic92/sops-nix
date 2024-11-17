
{
  imports = [
    ../modules/nix-darwin/default.nix
  ];
  documentation.enable = false;
  sops.secrets.test_key = { };
  sops.defaultSopsFile = ../pkgs/sops-install-secrets/test-assets/secrets.yaml;
  sops.age.generateKey = true;
  system.stateVersion = 5;
}
