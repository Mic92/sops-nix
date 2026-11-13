{
  pkgs,
  finix,
}:
let
  inherit (pkgs) lib;

  testLib = import "${finix}/tests/lib" { inherit lib pkgs; };
  testAssets = ../pkgs/sops-install-secrets/test-assets;
in
testLib.mkTest {
  name = "sops-finix";

  nodes.machine =
    { config, lib, ... }:
    {
      imports = [ ../modules/sops/finix.nix ];

      services.getty.enable = true;
      services.mdevd.enable = true;

      sops = {
        age.keyFile = "/run/age-keys.txt";
        defaultSopsFile = testAssets + "/secrets.yaml";
        secrets.test_key.neededForUsers = true;
        secrets."nested/test/file".owner = "example-user";
      };

      users.users.example-user = {
        isNormalUser = true;
        passwordFile = config.sops.secrets.test_key.path;
      };

      system.activation.scripts.earlySecrets = lib.stringAfter [ "specialfs" ] ''
        cp ${testAssets + "/age-keys.txt"} /run/age-keys.txt
        chmod 600 /run/age-keys.txt
      '';
      system.activation.scripts.setupSecrets.deps = [ "earlySecrets" ];
      system.activation.scripts.setupSecretsForUsers.deps = [ "earlySecrets" ];
    };

  testScript = ''
    machine.start()
    machine.wait_for_console_text("entering runlevel 2")

    with subtest("regular secrets are decrypted"):
        machine.succeed("grep -q 'another value' /run/secrets/nested/test/file")

    with subtest("regular secrets get the configured owner"):
        owner = machine.succeed("stat -c%U /run/secrets/nested/test/file").strip()
        assert owner == "example-user", f"expected owner 'example-user', got '{owner}'"

    with subtest("neededForUsers secrets are decrypted"):
        machine.succeed("grep -q 'test_value' /run/secrets-for-users/test_key")

    with subtest("neededForUsers secret was available when users were created"):
        # Proves setupSecretsForUsers ran before the `users` activation script.
        machine.succeed("grep -q '^example-user:test_value:' /etc/shadow")

    machine.shutdown()
  '';
}
