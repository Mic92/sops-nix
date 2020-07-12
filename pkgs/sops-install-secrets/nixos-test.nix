{ makeTest ? import <nixpkgs/nixos/tests/make-test-python.nix>, pkgs ? import <nixpkgs> }:
{
 ssh-keys = makeTest {
  nodes.server = { ... }: {
    imports = [ ../../modules/sops ];
    services.openssh.enable = true;
    services.openssh.hostKeys = [{
      type = "rsa";
      bits = 4096;
      path = ./test-assets/ssh-key;
    }];
    sops.defaultSopsFile = ./test-assets/secrets.yaml;
    sops.secrets.test_key = {};
  };

  testScript = ''
    start_all()
    server.succeed("cat /run/secrets/test_key | grep -q test_value")
  '';
 } {
   inherit pkgs;
 };

 pgp-keys = makeTest {
   nodes.server = { pkgs, lib, ... }: {
     imports = [ ../../modules/sops ];
      sops.gnupgHome = "/run/gpghome";
      sops.defaultSopsFile = ./test-assets/secrets.yaml;
      sops.secrets.test_key = {};
      # must run before sops
      system.activationScripts.gnupghome = lib.stringAfter [ "etc" ] ''
        cp -r ${./test-assets/gnupghome} /run/gpghome
        chmod -R 700 /run/gpghome
      '';
      # Useful for debugging
      #environment.systemPackages = [ pkgs.gnupg pkgs.sops ];
      #environment.variables = {
      #  GNUPGHOME = "/run/gpghome";
      #  SOPS_GPG_EXEC="${pkgs.gnupg}/bin/gpg";
      #  SOPSFILE = "${./test-assets/secrets.yaml}";
      #};
   };
   testScript = ''
     start_all()
     server.succeed("cat /run/secrets/test_key | grep -q test_value")
   '';
 } {
   inherit pkgs;
 };
}
