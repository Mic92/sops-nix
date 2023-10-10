{ makeTest ? import <nixpkgs/nixos/tests/make-test-python.nix>
, pkgs ? (import <nixpkgs> { }) }: {
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
      sops.defaultSopsFiles = [ ./test-assets/secrets.yaml ];
      sops.secrets.test_key = { };
    };

    testScript = ''
      start_all()
      server.succeed("cat /run/secrets/test_key | grep -q test_value")
    '';
  } {
    inherit pkgs;
    inherit (pkgs) system;
  };

  user-passwords = makeTest {
    name = "sops-user-passwords";
    nodes.machine = { config, lib, ... }: {
      imports = [ ../../modules/sops ];
      sops = {
        age.keyFile = ./test-assets/age-keys.txt;
        defaultSopsFiles = [ ./test-assets/secrets.yaml ];
        secrets.test_key.neededForUsers = true;
        secrets."nested/test/file".owner = "example-user";
      };

      users.users.example-user = let
        passwordFileKey =
          if (lib.versionAtLeast (lib.versions.majorMinor lib.version)
            "23.11") then
            "hashedPasswordFile"
          else
            "passwordFile";
      in {
        isNormalUser = true;
        ${passwordFileKey} = config.sops.secrets.test_key.path;
      };
    };

    testScript = ''
      start_all()
      machine.succeed("getent shadow example-user | grep -q :test_value:")  # password was set
      machine.succeed("cat /run/secrets/nested/test/file | grep -q 'another value'")  # regular secrets work...
      machine.succeed("[ $(stat -c%U /run/secrets/nested/test/file) = example-user ]")  # ...and are owned...
      machine.succeed("cat /run/secrets-for-users/test_key | grep -q 'test_value'")  # the user password still exists

      machine.succeed("/run/current-system/bin/switch-to-configuration test")
      machine.succeed("cat /run/secrets/nested/test/file | grep -q 'another value'")  # the regular secrets still work after a switch
      machine.succeed("cat /run/secrets-for-users/test_key | grep -q 'test_value'")  # the user password is still present after a switch
    '';
  } {
    inherit pkgs;
    inherit (pkgs) system;
  };

  pruning = makeTest {
    name = "sops-pruning";
    nodes.machine = { lib, ... }: {
      imports = [ ../../modules/sops ];
      sops = {
        age.keyFile = ./test-assets/age-keys.txt;
        defaultSopsFiles = [ ./test-assets/secrets.yaml ];
        secrets.test_key = { };
        keepGenerations = lib.mkDefault 0;
      };

      specialisation.pruning.configuration.sops.keepGenerations = 10;
    };

    testScript = ''
      # Force us to generation 100
      machine.succeed("mkdir /run/secrets.d/{2..99} /run/secrets.d/non-numeric")
      machine.succeed("ln -fsn /run/secrets.d/99 /run/secrets")
      machine.succeed("/run/current-system/activate")
      machine.succeed("test -d /run/secrets.d/100")

      # Ensure nothing is pruned, these are just random numbers
      machine.succeed("test -d /run/secrets.d/1")
      machine.succeed("test -d /run/secrets.d/90")
      machine.succeed("test -d /run/secrets.d/non-numeric")

      machine.succeed("/run/current-system/specialisation/pruning/bin/switch-to-configuration test")
      print(machine.succeed("ls -la /run/secrets.d/"))

      # Ensure stuff was properly pruned.
      # We are now at generation 101 so 92 must exist when we keep 10 generations
      # and 91 must not.
      machine.fail("test -d /run/secrets.d/91")
      machine.succeed("test -d /run/secrets.d/92")
      machine.succeed("test -d /run/secrets.d/non-numeric")
    '';
  } {
    inherit pkgs;
    inherit (pkgs) system;
  };

  age-keys = makeTest {
    name = "sops-age-keys";
    nodes.machine = {
      imports = [ ../../modules/sops ];
      sops = {
        age.keyFile = ./test-assets/age-keys.txt;
        defaultSopsFiles = [ ./test-assets/secrets.yaml ];
        secrets.test_key = { };
      };
    };

    testScript = ''
      start_all()
      machine.succeed("cat /run/secrets/test_key | grep -q test_value")
    '';
  } {
    inherit pkgs;
    inherit (pkgs) system;
  };

  age-ssh-keys = makeTest {
    name = "sops-age-ssh-keys";
    nodes.machine = {
      imports = [ ../../modules/sops ];
      services.openssh.enable = true;
      services.openssh.hostKeys = [{
        type = "ed25519";
        path = ./test-assets/ssh-ed25519-key;
      }];
      sops = {
        defaultSopsFiles = [ ./test-assets/secrets.yaml ];
        secrets.test_key = { };
        # Generate a key and append it to make sure it appending doesn't break anything
        age = {
          keyFile = "/tmp/testkey";
          generateKey = true;
        };
      };
    };

    testScript = ''
      start_all()
      machine.succeed("cat /run/secrets/test_key | grep -q test_value")
    '';
  } {
    inherit pkgs;
    inherit (pkgs) system;
  };

  pgp-keys = makeTest {
    name = "sops-pgp-keys";
    nodes.server = { pkgs, lib, config, ... }: {
      imports = [ ../../modules/sops ];

      users.users.someuser = {
        isSystemUser = true;
        group = "nogroup";
      };

      sops.gnupg.home = "/run/gpghome";
      sops.defaultSopsFiles = [ ./test-assets/secrets.yaml ];
      sops.secrets.test_key.owner = config.users.users.someuser.name;
      sops.secrets."nested/test/file".owner = config.users.users.someuser.name;
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
      value = server.succeed("cat /run/secrets/nested/test/file")
      assertEqual(value, "another value")

      target = server.succeed("readlink -f /run/existing-file")
      assertEqual("/run/secrets.d/1/existing-file", target.strip())
    '';
  } {
    inherit pkgs;
    inherit (pkgs) system;
  };

  templates = makeTest {
    name = "sops-templates";
    nodes.machine = { config, ... }: {
      imports = [ ../../modules/sops ];
      sops = {
        age.keyFile = ./test-assets/age-keys.txt;
        defaultSopsFiles = [ ./test-assets/secrets.yaml ];
        secrets.test_key = { };
      };

      sops.templates.test_template = {
        content = ''
          This line is not modified.
          The next value will be replaced by ${config.sops.placeholder.test_key}
          This line is also not modified.
        '';
        mode = "0400";
        owner = "someuser";
        group = "somegroup";
      };
      sops.templates.test_default.content = ''
        Test value: ${config.sops.placeholder.test_key}
      '';

      users.groups.somegroup = {};
      users.users.someuser = {
        isSystemUser = true;
        group = "somegroup";
      };
    };

    testScript = ''
      start_all()
      machine.succeed("[ $(stat -c%U /run/secrets-rendered/test_template) = 'someuser' ]")
      machine.succeed("[ $(stat -c%G /run/secrets-rendered/test_template) = 'somegroup' ]")
      machine.succeed("[ $(stat -c%U /run/secrets-rendered/test_default) = 'root' ]")
      machine.succeed("[ $(stat -c%G /run/secrets-rendered/test_default) = 'root' ]")

      expected = """
      This line is not modified.
      The next value will be replaced by test_value
      This line is also not modified.
      """
      rendered = machine.succeed("cat /run/secrets-rendered/test_template")

      expected_default = """
      Test value: test_value
      """
      rendered_default = machine.succeed("cat /run/secrets-rendered/test_default")

      if rendered.strip() != expected.strip() or rendered_default.strip() != expected_default.strip():
        raise Exception("Template is not rendered correctly")
    '';
  } {
    inherit pkgs;
    inherit (pkgs) system;
  };

  restart-and-reload = makeTest {
    name = "sops-restart-and-reload";
    nodes.machine = { pkgs, lib, config, ... }: {
      imports = [ ../../modules/sops ];

      sops = {
        age.keyFile = ./test-assets/age-keys.txt;
        defaultSopsFiles = [ ./test-assets/secrets.yaml ];
        secrets.test_key = {
          restartUnits = [ "restart-unit.service" "reload-unit.service" ];
          reloadUnits = [ "reload-trigger.service" ];
        };
      };

      systemd.services."restart-unit" = {
        description = "Restart unit";
        # not started on boot
        serviceConfig = { ExecStart = "/bin/sh -c 'echo ok > /restarted'"; };
      };
      systemd.services."reload-unit" = {
        description = "Reload unit";
        wantedBy = [ "multi-user.target" ];
        reloadIfChanged = true;
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          ExecStart = "/bin/sh -c true";
          ExecReload = "/bin/sh -c 'echo ok > /reloaded'";
        };
      };
      systemd.services."reload-trigger" = {
        description = "Reload trigger unit";
        wantedBy = [ "multi-user.target" ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          ExecStart = "/bin/sh -c true";
          ExecReload = "/bin/sh -c 'echo ok > /reloaded'";
        };
      };
    };
    testScript = ''
      machine.wait_for_unit("multi-user.target")
      machine.fail("test -f /restarted")
      machine.fail("test -f /reloaded")

      # Nothing is to be restarted after boot
      machine.fail("ls /run/nixos/*-list")

      # Nothing happens when the secret is not changed
      machine.succeed("/run/current-system/bin/switch-to-configuration test")
      machine.fail("test -f /restarted")
      machine.fail("test -f /reloaded")

      # Ensure the secret is changed
      machine.succeed(": > /run/secrets/test_key")

      # The secret is changed, now something should happen
      machine.succeed("/run/current-system/bin/switch-to-configuration test")

      # Ensure something happened
      machine.succeed("test -f /restarted")
      machine.succeed("test -f /reloaded")

      with subtest("change detection"):
         machine.succeed("rm /run/secrets/test_key")
         out = machine.succeed("/run/current-system/bin/switch-to-configuration test")
         if "adding secret" not in out:
             raise Exception("Addition detection does not work")

         machine.succeed(": > /run/secrets/test_key")
         out = machine.succeed("/run/current-system/bin/switch-to-configuration test")
         if "modifying secret" not in out:
             raise Exception("Modification detection does not work")

         machine.succeed(": > /run/secrets/another_key")
         out = machine.succeed("/run/current-system/bin/switch-to-configuration test")
         if "removing secret" not in out:
             raise Exception("Removal detection does not work")

      with subtest("dry activation"):
          machine.succeed("rm /run/secrets/test_key")
          machine.succeed(": > /run/secrets/another_key")
          out = machine.succeed("/run/current-system/bin/switch-to-configuration dry-activate")
          if "would add secret" not in out:
              raise Exception("Dry addition detection does not work")
          if "would remove secret" not in out:
              raise Exception("Dry removal detection does not work")

          machine.fail("test -f /run/secrets/test_key")
          machine.succeed("test -f /run/secrets/another_key")

          machine.succeed("/run/current-system/bin/switch-to-configuration test")
          machine.succeed("test -f /run/secrets/test_key")
          machine.succeed("rm /restarted /reloaded")
          machine.fail("test -f /run/secrets/another_key")

          machine.succeed(": > /run/secrets/test_key")
          out = machine.succeed("/run/current-system/bin/switch-to-configuration dry-activate")
          if "would modify secret" not in out:
              raise Exception("Dry modification detection does not work")
          machine.succeed("[ $(cat /run/secrets/test_key | wc -c) = 0 ]")

          machine.fail("test -f /restarted")  # not done in dry mode
          machine.fail("test -f /reloaded")  # not done in dry mode
    '';
  } {
    inherit pkgs;
    inherit (pkgs) system;
  };
}
