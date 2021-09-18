{ makeTest ? import <nixpkgs/nixos/tests/make-test-python.nix>, pkgs ? import <nixpkgs> }:
{
 ssh-keys = makeTest {
  name = "sops-ssh-keys";
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
   inherit (pkgs) system;
 };

 pgp-keys = makeTest {
   name = "sops-pgp-keys";
   nodes.server = { pkgs, lib, config, ... }: {
     imports = [
       ../../modules/sops
     ];

     users.users.someuser = {
       isSystemUser = true;
       group = "nogroup";
     };

     sops.gnupgHome = "/run/gpghome";
     sops.defaultSopsFile = ./test-assets/secrets.yaml;
     sops.secrets.test_key.owner = config.users.users.someuser.name;
     sops.secrets.existing-file = {
       key = "test_key";
       path = "/run/existing-file";
     };
     # must run before sops
     system.activationScripts.gnupghome = lib.stringAfter [ "etc" ] ''
       cp -r ${./test-assets/gnupghome} /run/gpghome
       chmod -R 700 /run/gpghome

       touch /run/existing-file
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
    def assertEqual(exp: str, act: str) -> None:
        if exp != act:
            raise Exception(f"'{exp}' != '{act}'")


    start_all()

    value = server.succeed("cat /run/secrets/test_key")
    assertEqual("test_value", value)

    server.succeed("runuser -u someuser -- cat /run/secrets/test_key >&2")

    target = server.succeed("readlink -f /run/existing-file")
    assertEqual("/run/secrets.d/1/existing-file", target.strip())
  '';
 } {
   inherit pkgs;
   inherit (pkgs) system;
 };
}
