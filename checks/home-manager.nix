
{ config, ... }: {
  imports = [
    ../modules/home-manager/sops.nix
  ];
  home.stateVersion = "25.05";
  home.username = "sops-user";
  home.homeDirectory = "/home/sops-user";
  home.enableNixpkgsReleaseCheck = false;

  sops.age.generateKey = true;
  sops.age.keyFile = "${config.home.homeDirectory}/.age-key.txt";
  sops.secrets.test_key = { };
  sops.defaultSopsFile = ../pkgs/sops-install-secrets/test-assets/secrets.yaml;
}
