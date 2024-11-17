{ lib, testers }:
let
  testAssets = ../pkgs/sops-install-secrets/test-assets;

  userPasswordTest =
    name: extraConfig:
    testers.runNixOSTest {
      inherit name;
      nodes.machine =
        { config, lib, ... }:
        {
          imports = [
            ../modules/sops
            extraConfig
          ];
          sops = {
            age.keyFile = "/run/age-keys.txt";
            defaultSopsFile = testAssets + "/secrets.yaml";
            secrets.test_key.neededForUsers = true;
            secrets."nested/test/file".owner = "example-user";
          };
          system.switch.enable = true;

          users.users.example-user = lib.mkMerge [
            (lib.mkIf (!config.systemd.sysusers.enable) {
              isNormalUser = true;
              hashedPasswordFile = config.sops.secrets.test_key.path;
            })
            (lib.mkIf config.systemd.sysusers.enable {
              isSystemUser = true;
              group = "users";
              hashedPasswordFile = config.sops.secrets.test_key.path;
            })
          ];
        };

      testScript =
        ''
          start_all()
          machine.wait_for_unit("multi-user.target")

          machine.succeed("getent shadow example-user | grep -q :test_value:")  # password was set
          machine.succeed("cat /run/secrets/nested/test/file | grep -q 'another value'")  # regular secrets work...
          user = machine.succeed("stat -c%U /run/secrets/nested/test/file").strip()  # ...and are owned...
          assert user == "example-user", f"Expected 'example-user', got '{user}'"
          machine.succeed("cat /run/secrets-for-users/test_key | grep -q 'test_value'")  # the user password still exists

          # BUG in nixos's overlayfs... systemd crashes on switch-to-configuration test
        ''
        + lib.optionalString (!(extraConfig ? system.etc.overlay.enable)) ''
          machine.succeed("/run/current-system/bin/switch-to-configuration test")
          machine.succeed("cat /run/secrets/nested/test/file | grep -q 'another value'")  # the regular secrets still work after a switch
          machine.succeed("cat /run/secrets-for-users/test_key | grep -q 'test_value'")  # the user password is still present after a switch
        '';
    };
in
{
  ssh-keys = testers.runNixOSTest {
    name = "sops-ssh-keys";
    nodes.server =
      { ... }:
      {
        imports = [ ../modules/sops ];
        services.openssh.enable = true;
        services.openssh.hostKeys = [
          {
            type = "rsa";
            bits = 4096;
            path = testAssets + "/ssh-key";
          }
        ];
        sops.defaultSopsFile = testAssets + "/secrets.yaml";
        sops.secrets.test_key = { };
      };

    testScript = ''
      start_all()
      server.succeed("cat /run/secrets/test_key | grep -q test_value")
    '';
  };

  pruning = testers.runNixOSTest {
    name = "sops-pruning";
    nodes.machine =
      { lib, ... }:
      {
        imports = [ ../modules/sops ];
        sops = {
          age.keyFile = "/run/age-keys.txt";
          defaultSopsFile = testAssets + "/secrets.yaml";
          secrets.test_key = { };
          keepGenerations = lib.mkDefault 0;
        };

        # must run before sops sets up keys
        boot.initrd.postDeviceCommands = ''
          cp -r ${testAssets + "/age-keys.txt"} /run/age-keys.txt
          chmod -R 700 /run/age-keys.txt
        '';

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
  };

  age-keys = testers.runNixOSTest {
    name = "sops-age-keys";
    nodes.machine =
      { config, ... }:
      {
        imports = [ ../modules/sops ];
        sops = {
          age.keyFile = "/run/age-keys.txt";
          defaultSopsFile = testAssets + "/secrets.yaml";
          secrets = {
            test_key = { };

            test_key_someuser_somegroup = {
              uid = config.users.users."someuser".uid;
              gid = config.users.groups."somegroup".gid;
              key = "test_key";
            };
            test_key_someuser_root = {
              uid = config.users.users."someuser".uid;
              key = "test_key";
            };
            test_key_root_root = {
              key = "test_key";
            };
            test_key_1001_1001 = {
              uid = 1001;
              gid = 1001;
              key = "test_key";
            };
          };
        };

        users.users."someuser" = {
          uid = 1000;
          group = "somegroup";
          isNormalUser = true;
        };
        users.groups."somegroup" = {
          gid = 1000;
        };

        # must run before sops sets up keys
        boot.initrd.postDeviceCommands = ''
          cp -r ${testAssets + "/age-keys.txt"} /run/age-keys.txt
          chmod -R 700 /run/age-keys.txt
        '';
      };

    testScript = ''
      start_all()
      machine.succeed("cat /run/secrets/test_key | grep -q test_value")

      with subtest("test ownership"):
         machine.succeed("[ $(stat -c%u /run/secrets/test_key_someuser_somegroup) = '1000' ]")
         machine.succeed("[ $(stat -c%g /run/secrets/test_key_someuser_somegroup) = '1000' ]")
         machine.succeed("[ $(stat -c%U /run/secrets/test_key_someuser_somegroup) = 'someuser' ]")
         machine.succeed("[ $(stat -c%G /run/secrets/test_key_someuser_somegroup) = 'somegroup' ]")

         machine.succeed("[ $(stat -c%u /run/secrets/test_key_someuser_root) = '1000' ]")
         machine.succeed("[ $(stat -c%g /run/secrets/test_key_someuser_root) = '0' ]")
         machine.succeed("[ $(stat -c%U /run/secrets/test_key_someuser_root) = 'someuser' ]")
         machine.succeed("[ $(stat -c%G /run/secrets/test_key_someuser_root) = 'root' ]")

         machine.succeed("[ $(stat -c%u /run/secrets/test_key_1001_1001) = '1001' ]")
         machine.succeed("[ $(stat -c%g /run/secrets/test_key_1001_1001) = '1001' ]")
         machine.succeed("[ $(stat -c%U /run/secrets/test_key_1001_1001) = 'UNKNOWN' ]")
         machine.succeed("[ $(stat -c%G /run/secrets/test_key_1001_1001) = 'UNKNOWN' ]")
    '';
  };

  age-ssh-keys = testers.runNixOSTest {
    name = "sops-age-ssh-keys";
    nodes.machine = {
      imports = [ ../modules/sops ];
      services.openssh.enable = true;
      services.openssh.hostKeys = [
        {
          type = "ed25519";
          path = testAssets + "/ssh-ed25519-key";
        }
      ];

      sops = {
        defaultSopsFile = testAssets + "/secrets.yaml";
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
  };

  pgp-keys = testers.runNixOSTest {
    name = "sops-pgp-keys";
    nodes.server =
      { lib, config, ... }:
      {
        imports = [ ../modules/sops ];

        users.users.someuser = {
          isSystemUser = true;
          group = "nogroup";
        };

        sops.gnupg.home = "/run/gpghome";
        sops.defaultSopsFile = testAssets + "/secrets.yaml";
        sops.secrets.test_key.owner = config.users.users.someuser.name;
        sops.secrets."nested/test/file".owner = config.users.users.someuser.name;
        sops.secrets.existing-file = {
          key = "test_key";
          path = "/run/existing-file";
        };
        # must run before sops
        system.activationScripts.gnupghome = lib.stringAfter [ "etc" ] ''
          cp -r ${testAssets + "/gnupghome"} /run/gpghome
          chmod -R 700 /run/gpghome

          touch /run/existing-file
        '';
        # Useful for debugging
        #environment.systemPackages = [ pkgs.gnupg pkgs.sops ];
        #environment.variables = {
        #  GNUPGHOME = "/run/gpghome";
        #  SOPS_GPG_EXEC="${pkgs.gnupg}/bin/gpg";
        #  SOPSFILE = "${testAssets + "/secrets.yaml"}";
        #};
      };
    testScript = ''
      def assertEqual(exp: str, act: str) -> None:
          if exp != act:
              raise Exception(f"{exp!r} != {act!r}")


      start_all()

      value = server.succeed("cat /run/secrets/test_key")
      assertEqual("test_value", value)

      server.succeed("runuser -u someuser -- cat /run/secrets/test_key >&2")
      value = server.succeed("cat /run/secrets/nested/test/file")
      assertEqual(value, "another value")

      target = server.succeed("readlink -f /run/existing-file")
      assertEqual("/run/secrets.d/1/existing-file", target.strip())
    '';
  };

  templates = testers.runNixOSTest {
    name = "sops-templates";
    nodes.machine =
      { config, ... }:
      {
        imports = [ ../modules/sops ];
        sops = {
          age.keyFile = "/run/age-keys.txt";
          defaultSopsFile = testAssets + "/secrets.yaml";
          secrets.test_key = { };

          # Verify that things work even with `neededForUsers` secrets. See
          # <https://github.com/Mic92/sops-nix/issues/659>.
          secrets."nested/test/file".neededForUsers = true;
        };

        # must run before sops sets up keys
        boot.initrd.postDeviceCommands = ''
          cp -r ${testAssets + "/age-keys.txt"} /run/age-keys.txt
          chmod -R 700 /run/age-keys.txt
        '';

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
        sops.templates.test_default = {
          content = ''
            Test value: ${config.sops.placeholder.test_key}
          '';
          path = "/etc/externally/linked";
        };

        users.groups.somegroup = { };
        users.users.someuser = {
          isSystemUser = true;
          group = "somegroup";
        };
      };

    testScript = ''
      def assertEqual(exp: str, act: str) -> None:
          if exp != act:
              raise Exception(f"{exp!r} != {act!r}")


      start_all()
      machine.succeed("[ $(stat -c%U /run/secrets/rendered/test_template) = 'someuser' ]")
      machine.succeed("[ $(stat -c%G /run/secrets/rendered/test_template) = 'somegroup' ]")
      machine.succeed("[ $(stat -c%U /run/secrets/rendered/test_default) = 'root' ]")
      machine.succeed("[ $(stat -c%G /run/secrets/rendered/test_default) = 'root' ]")

      expected = """\
      This line is not modified.
      The next value will be replaced by test_value
      This line is also not modified.
      """
      rendered = machine.succeed("cat /run/secrets/rendered/test_template")

      expected_default = """\
      Test value: test_value
      """
      rendered_default = machine.succeed("cat /run/secrets/rendered/test_default")

      assertEqual(expected, rendered)
      assertEqual(expected_default, rendered_default)

      # Confirm that `test_default` was symlinked to the appropriate place.
      realpath = machine.succeed("realpath /etc/externally/linked").strip()
      assertEqual(realpath, "/run/secrets.d/1/rendered/test_default")
    '';
  };

  restart-and-reload = testers.runNixOSTest {
    name = "sops-restart-and-reload";
    nodes.machine =
      { config, ... }:
      {
        imports = [ ../modules/sops ];

        sops = {
          age.keyFile = "/run/age-keys.txt";
          defaultSopsFile = testAssets + "/secrets.yaml";
          secrets.test_key = {
            restartUnits = [
              "restart-unit.service"
              "reload-unit.service"
            ];
            reloadUnits = [ "reload-trigger.service" ];
          };

          templates.test_template = {
            content = ''
              this is a template with
              a secret: ${config.sops.placeholder.test_key}
            '';
            restartUnits = [
              "restart-unit.service"
              "reload-unit.service"
            ];
            reloadUnits = [ "reload-trigger.service" ];
          };
        };
        system.switch.enable = true;

        # must run before sops sets up keys
        boot.initrd.postDeviceCommands = ''
          cp -r ${testAssets + "/age-keys.txt"} /run/age-keys.txt
          chmod -R 700 /run/age-keys.txt
        '';

        systemd.services."restart-unit" = {
          description = "Restart unit";
          # not started on boot
          serviceConfig = {
            ExecStart = "/bin/sh -c 'echo ok > /restarted'";
          };
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
      def assertOutput(output, *expected_lines):
        expected_lines = list(expected_lines)

        # Remove unrelated fluff that shows up in the output of `switch-to-configuration`.
        prefix = "setting up /etc...\n"
        if output.startswith(prefix):
          output = output.removeprefix(prefix)

        actual_lines = output.splitlines(keepends=False)

        if actual_lines != expected_lines:
          raise Exception(f"{actual_lines} != {expected_lines}")

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

      # Cleanup the marker files.
      machine.succeed("rm /restarted /reloaded")

      # Ensure the template is changed
      machine.succeed(": > /run/secrets/rendered/test_template")

      # The template is changed, now something should happen
      machine.succeed("/run/current-system/bin/switch-to-configuration test")

      # Ensure something happened
      machine.succeed("test -f /restarted")
      machine.succeed("test -f /reloaded")

      # Cleanup the marker files.
      machine.succeed("rm /restarted /reloaded")

      with subtest("change detection"):
        machine.succeed("rm /run/secrets/test_key")
        machine.succeed("rm /run/secrets/rendered/test_template")
        out = machine.succeed("/run/current-system/bin/switch-to-configuration test")
        assertOutput(
          out,
          "adding secret: test_key",
          "adding rendered secret: test_template",
        )

        machine.succeed(": > /run/secrets/test_key")
        machine.succeed(": > /run/secrets/rendered/test_template")
        out = machine.succeed("/run/current-system/bin/switch-to-configuration test")
        assertOutput(
          out,
          "modifying secret: test_key",
          "modifying rendered secret: test_template",
        )

        machine.succeed(": > /run/secrets/another_key")
        machine.succeed(": > /run/secrets/rendered/another_template")
        out = machine.succeed("/run/current-system/bin/switch-to-configuration test")
        assertOutput(
          out,
          "removing secret: another_key",
          "removing rendered secret: another_template",
        )

      with subtest("dry activation"):
        machine.succeed("rm /run/secrets/test_key")
        machine.succeed("rm /run/secrets/rendered/test_template")
        machine.succeed(": > /run/secrets/another_key")
        machine.succeed(": > /run/secrets/rendered/another_template")
        out = machine.succeed("/run/current-system/bin/switch-to-configuration dry-activate")
        assertOutput(
          out,
          "would add secret: test_key",
          "would remove secret: another_key",
          "would add rendered secret: test_template",
          "would remove rendered secret: another_template",
        )

        # Verify that we did not actually activate the new configuration.
        machine.fail("test -f /run/secrets/test_key")
        machine.fail("test -f /run/secrets/rendered/test_template")
        machine.succeed("test -f /run/secrets/another_key")
        machine.succeed("test -f /run/secrets/rendered/another_template")

        # Now actually activate and sanity check the resulting secrets.
        machine.succeed("/run/current-system/bin/switch-to-configuration test")
        machine.succeed("test -f /run/secrets/test_key")
        machine.succeed("test -f /run/secrets/rendered/test_template")
        machine.fail("test -f /run/secrets/another_key")
        machine.fail("test -f /run/secrets/rendered/another_template")

        # Remove the restarted/reloaded indicators so we can confirm a
        # dry-activate doesn't trigger systemd units.
        machine.succeed("rm /restarted /reloaded")

        machine.succeed(": > /run/secrets/test_key")
        out = machine.succeed("/run/current-system/bin/switch-to-configuration dry-activate")
        assertOutput(
          out,
          "would modify secret: test_key",
        )
        machine.succeed("[ $(cat /run/secrets/test_key | wc -c) = 0 ]")

        machine.fail("test -f /restarted")  # not done in dry mode
        machine.fail("test -f /reloaded")  # not done in dry mode
    '';
  };

  user-passwords = userPasswordTest "sops-user-passwords" {
    # must run before sops sets up keys
    boot.initrd.postDeviceCommands = ''
      cp -r ${testAssets + "/age-keys.txt"} /run/age-keys.txt
      chmod -R 700 /run/age-keys.txt
    '';
  };
}
// lib.optionalAttrs (lib.versionAtLeast (lib.versions.majorMinor lib.version) "24.05") {
  user-passwords-sysusers = userPasswordTest "sops-user-passwords-sysusers" (
    { pkgs, ... }:
    {
      systemd.sysusers.enable = true;
      users.mutableUsers = true;
      system.etc.overlay.enable = true;
      boot.initrd.systemd.enable = true;
      boot.kernelPackages = pkgs.linuxPackages_latest;

      # must run before sops sets up keys
      systemd.services."sops-install-secrets-for-users".preStart = ''
        printf '${builtins.readFile (testAssets + "/age-keys.txt")}' > /run/age-keys.txt
        chmod -R 700 /run/age-keys.txt
      '';
    }
  );
}
// lib.optionalAttrs (lib.versionAtLeast (lib.versions.majorMinor lib.version) "24.11") {
  user-passwords-userborn = userPasswordTest "sops-user-passwords-userborn" (
    { pkgs, ... }:
    {
      services.userborn.enable = true;
      users.mutableUsers = false;
      system.etc.overlay.enable = true;
      boot.initrd.systemd.enable = true;
      boot.kernelPackages = pkgs.linuxPackages_latest;

      # must run before sops sets up keys
      systemd.services."sops-install-secrets-for-users".preStart = ''
        printf '${builtins.readFile (testAssets + "/age-keys.txt")}' > /run/age-keys.txt
        chmod -R 700 /run/age-keys.txt
      '';
    }
  );
}
