# `sops-nix` In-Depth Usage

This is a collection of useful walkthroughs in no particular order. Reference the table of contents as you need.

- [Get a public key from a target machine](#get-a-public-key-from-a-target-machine)

- [Set secret permission/owner and allow services to access it](#Set-secret-permission-/-owner-and-allow-services-to-access-it)

- [Restarting/reloading systemd units on secret change](#Restarting-/-reloading-systemd-units-on-secret-change)

- [Symlinks to other directories](#symlinks-to-other-directories)

- [Setting a user's password](#setting-a-users-password)

- [Different file formats](#different-file-formats)

-[Emit plain file for yaml and json formats](#emit-plain-file-for-yaml-and-json-formats)

- [Use with home manager](#use-with-home-manager)

- [Use with GPG instead of SSH keys](#use-with-gpg-instead-of-ssh-keys)

- [Share secrets between different users](#share-secrets-between-different-users)

- [Migrate from pass/krops](#migrate-from-passkrops)

- [Real-world examples](#real-world-examples)

- [Known limitations](#known-limitations)

- [Templates](#templates)

## Get a public key from a target machine

The easiest way to add new machines is by using SSH host keys (this requires OpenSSH to be enabled).  

If you are using `age`, the `ssh-to-age` tool can be used to convert any SSH Ed25519 public key to the `age` format:
```console
$ nix-shell -p ssh-to-age --run 'ssh-keyscan example.com | ssh-to-age'
age1rgffpespcyjn0d8jglk7km9kfrfhdyev6camd3rck6pn8y47ze4sug23v3
$ nix-shell -p ssh-to-age --run 'cat /etc/ssh/ssh_host_ed25519_key.pub | ssh-to-age'
age1rgffpespcyjn0d8jglk7km9kfrfhdyev6camd3rck6pn8y47ze4sug23v3
```

For GPG, since sops does not natively support SSH keys yet, sops-nix supports a conversion tool (`ssh-to-pgp`) to store them as GPG keys:

```console
$ ssh root@server01 "cat /etc/ssh/ssh_host_rsa_key" | nix-shell -p ssh-to-pgp --run "ssh-to-pgp -o server01.asc"
# or with sudo
$ ssh youruser@server01 "sudo cat /etc/ssh/ssh_host_rsa_key" | nix-shell -p ssh-to-pgp --run "ssh-to-pgp -o server01.asc"
0fd60c8c3b664aceb1796ce02b318df330331003
# or just read them locally/over ssh
$ nix-shell -p ssh-to-pgp --run "ssh-to-pgp -i /etc/ssh/ssh_host_rsa_key -o server01.asc"
0fd60c8c3b664aceb1796ce02b318df330331003
```

The output of these commands is the identifier for the server's key, which can be added to your `.sops.yaml`:

```yaml
keys:
  - &admin_alice 2504791468b153b8a3963cc97ba53d1919c5dfd4
  - &admin_bob age12zlz6lvcdk6eqaewfylg35w0syh58sm7gh53q5vvn7hd7c6nngyseftjxl
  - &server_azmidi 0fd60c8c3b664aceb1796ce02b318df330331003
  - &server_nosaxa age1rgffpespcyjn0d8jglk7km9kfrfhdyev6camd3rck6pn8y47ze4sug23v3
creation_rules:
  - path_regex: secrets/[^/]+\.(yaml|json|env|ini)$
    key_groups:
    - pgp:
      - *admin_alice
      - *server_azmidi
      age:
      - *admin_bob
      - *server_nosaxa
  - path_regex: secrets/azmidi/[^/]+\.(yaml|json|env|ini)$
    key_groups:
    - pgp:
      - *admin_alice
      - *server_azmidi
      age:
      - *admin_bob
```

If you prefer having a separate GPG key, see [Use with GPG instead of SSH keys](#use-with-GPG-instead-of-SSH-keys).


## Set secret permission/owner and allow services to access it

By default secrets are owned by `root:root`. Furthermore
the parent directory `/run/secrets.d` is only owned by
`root` and the `keys` group has read access to it:

``` console
$ ls -la /run/secrets.d/1
total 24
drwxr-x--- 2 root keys   0 Jul 12  6:23 .
drwxr-x--- 3 root keys   0 Jul 12  6:23 ..
-r-------- 1 root root  20 Jul 12  6:23 example-secret
```

The secrets option has further parameter to change secret permission.
Consider the following nixos configuration example:

```nix
{
  # Permission modes are in octal representation (same as chmod),
  # the digits represent: user|group|others
  # 7 - full (rwx)
  # 6 - read and write (rw-)
  # 5 - read and execute (r-x)
  # 4 - read only (r--)
  # 3 - write and execute (-wx)
  # 2 - write only (-w-)
  # 1 - execute only (--x)
  # 0 - none (---)
  sops.secrets.example-secret.mode = "0440";
  # Either a user id or group name representation of the secret owner
  # It is recommended to get the user name from `config.users.users.<?name>.name` to avoid misconfiguration
  sops.secrets.example-secret.owner = config.users.users.nobody.name;
  # Either the group id or group name representation of the secret group
  # It is recommended to get the group name from `config.users.users.<?name>.group` to avoid misconfiguration
  sops.secrets.example-secret.group = config.users.users.nobody.group;
}
```

<details>
<summary>This example configures secrets for buildkite, a CI agent;
the service needs a token and a SSH private key to function.</summary>

```nix
{ pkgs, config, ... }:
{
  services.buildkite-agents.builder = {
    enable = true;
    tokenPath = config.sops.secrets.buildkite-token.path;
    privateSshKeyPath = config.sops.secrets.buildkite-ssh-key.path;

    runtimePackages = [
      pkgs.gnutar
      pkgs.bash
      pkgs.nix
      pkgs.gzip
      pkgs.git
    ];

  };

  sops.secrets.buildkite-token.owner = config.users.buildkite-agent-builder.name;
  sops.secrets.buildkite-ssh-key.owner = config.users.buildkite-agent-builder.name;
}
```

</details>

## Restarting/reloading systemd units on secret change

It is possible to restart or reload units when a secret changes or is newly initialized.

This behavior can be configured per-secret:
```nix
{
  sops.secrets."home-assistant-secrets.yaml" = {
    restartUnits = [ "home-assistant.service" ];
    # there is also `reloadUnits` which acts like a `reloadTrigger` in a NixOS systemd service
  };
}
```

## Symlinks to other directories

Some services might expect files in certain locations.
Using the `path` option a symlink to this directory can
be created:

```nix
{
  sops.secrets."home-assistant-secrets.yaml" = {
    owner = "hass";
    path = "/var/lib/hass/secrets.yaml";
  };
}
```

```console
$ ls -la /var/lib/hass/secrets.yaml
lrwxrwxrwx 1 root root 40 Jul 19 22:36 /var/lib/hass/secrets.yaml -> /run/secrets/home-assistant-secrets.yaml
```

## Setting a user's password

sops-nix has to run after NixOS creates users (in order to specify what users own a secret.)
This means that it's not possible to set `users.users.<name>.hashedPasswordFile` to any secrets managed by sops-nix.
To work around this issue, it's possible to set `neededForUsers = true` in a secret.
This will cause the secret to be decrypted to `/run/secrets-for-users` instead of `/run/secrets` before NixOS creates users.
As users are not created yet, it's not possible to set an owner for these secrets.

The password must be stored as a hash for this to work, which can be created with the command `mkpasswd`
```console
$ echo "password" | mkpasswd -s
$y$j9T$WFoiErKnEnMcGq0ruQK4K.$4nJAY3LBeBsZBTYSkdTOejKU6KlDmhnfUV3Ll1K/1b.
```

```nix
{ config, ... }: {
  sops.secrets.my-password.neededForUsers = true;

  users.users.mic92 = {
    isNormalUser = true;
    hashedPasswordFile = config.sops.secrets.my-password.path;
  };
}
```

**Note:** If you are using Impermanence, the key used for secret decryption (`sops.age.keyFile`, or the host SSH keys) must be in a persisted directory,
loaded early enough during boot. For example:

```nix
sops.age.keyFile = "/nix/persist/var/lib/sops-nix/key.txt";
```

or:

```nix
fileSystems."/etc/ssh".neededForBoot = true;
```

## Different file formats

At the moment we support the following file formats: YAML, JSON, INI, dotenv and binary.

sops-nix allows specifying multiple sops files in different file formats:

```nix
{
  imports = [ <sops-nix/modules/sops> ];
  # The default sops file used for all secrets can be controlled using `sops.defaultSopsFile`
  sops.defaultSopsFile = ./secrets.yaml;
  # If you use something different from YAML, you can also specify it here:
  #sops.defaultSopsFormat = "yaml";
  sops.secrets.github_token = {
    # The sops file can be also overwritten per secret...
    sopsFile = ./other-secrets.json;
    # ... as well as the format
    format = "json";
  };
}
```

### YAML

Open a new file with sops ending in `.yaml`:

```console
$ sops secrets.yaml
```

Then, put in the following content:

```yaml
github_token: 4a6c73f74928a9c4c4bc47379256b72e598e2bd3
ssh_key: |
  -----BEGIN OPENSSH PRIVATE KEY-----
  b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAAMwAAAAtzc2gtZW
  QyNTUxOQAAACDENhLwQI4v/Ecv65iCMZ7aZAL+Sdc0Cqyjkd012XwJzQAAAJht4at6beGr
  egAAAAtzc2gtZWQyNTUxOQAAACDENhLwQI4v/Ecv65iCMZ7aZAL+Sdc0Cqyjkd012XwJzQ
  AAAEBizgX7v+VMZeiCtWRjpl95dxqBWUkbrPsUSYF3DGV0rsQ2EvBAji/8Ry/rmIIxntpk
  Av5J1zQKrKOR3TXZfAnNAAAAE2pvZXJnQHR1cmluZ21hY2hpbmUBAg==
  -----END OPENSSH PRIVATE KEY-----
```

You can include it like this in your `configuration.nix`:

```nix
{
  sops.defaultSopsFile = ./secrets.yaml;
  # YAML is the default 
  #sops.defaultSopsFormat = "yaml";
  sops.secrets.github_token = {
    format = "yaml";
    # can be also set per secret
    sopsFile = ./secrets.yaml;
  };
}
```

### JSON

Open a new file with sops ending in `.json`:

```console
$ sops secrets.json
```

Then, put in the following content:

``` json
{
  "github_token": "4a6c73f74928a9c4c4bc47379256b72e598e2bd3",
  "ssh_key": "-----BEGIN OPENSSH PRIVATE KEY-----\\nb3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAAMwAAAAtzc2gtZW\\nQyNTUxOQAAACDENhLwQI4v/Ecv65iCMZ7aZAL+Sdc0Cqyjkd012XwJzQAAAJht4at6beGr\\negAAAAtzc2gtZWQyNTUxOQAAACDENhLwQI4v/Ecv65iCMZ7aZAL+Sdc0Cqyjkd012XwJzQ\\nAAAEBizgX7v+VMZeiCtWRjpl95dxqBWUkbrPsUSYF3DGV0rsQ2EvBAji/8Ry/rmIIxntpk\\nAv5J1zQKrKOR3TXZfAnNAAAAE2pvZXJnQHR1cmluZ21hY2hpbmUBAg==\\n-----END OPENSSH PRIVATE KEY-----\\n"
}
```

You can include it like this in your `configuration.nix`:

```nix
{
  sops.defaultSopsFile = ./secrets.json;
  # YAML is the default 
  sops.defaultSopsFormat = "json";
  sops.secrets.github_token = {
    format = "json";
    # can be also set per secret
    sopsFile = ./secrets.json;
  };
}
```

### Binary

This format allows to encrypt an arbitrary binary format that can't be put into
JSON/YAML files. Unlike the other two formats, for binary files, one file corresponds to one secret.

To encrypt an binary file use the following command:

``` console
$ sops -e /etc/krb5/krb5.keytab > krb5.keytab
# an example of what this might result in:
$ head krb5.keytab
{
        "data": "ENC[AES256_GCM,data:bIsPHrjrl9wxvKMcQzaAbS3RXCI2h8spw2Ee+KYUTsuousUBU6OMIdyY0wqrX3eh/1BUtl8H9EZciCTW29JfEJKfi3ackGufBH+0wp6vLg7r,iv:TlKiOmQUeH3+NEdDUMImg1XuXg/Tv9L6TmPQrraPlCQ=,tag:dVeVvRM567NszsXKK9pZvg==,type:str]",
        "sops": {
                "kms": null,
                "gcp_kms": null,
                "azure_kv": null,
                "lastmodified": "2020-07-06T06:21:06Z",
                "mac": "ENC[AES256_GCM,data:ISjUzaw/5mNiwypmUrOk2DAZnlkbnhURHmTTYA3705NmRsSyUh1PyQvCuwglmaHscwl4GrsnIz4rglvwx1zYa+UUwanR0+VeBqntHwzSNiWhh7qMAQwdUXmdCNiOyeGy6jcSDsXUeQmyIWH6yibr7hhzoQFkZEB7Wbvcw6Sossk=,iv:UilxNvfHN6WkEvfY8ZIJCWijSSpLk7fqSCWh6n8+7lk=,tag:HUTgyL01qfVTCNWCTBfqXw==,type:str]",
                "pgp": [
                        {

```

It can be decrypted again like this:

``` console
$ sops -d krb5.keytab > /tmp/krb5.keytab
```

This is how it can be included in your `configuration.nix`:

```nix
{
  sops.secrets.krb5-keytab = {
    format = "binary";
    sopsFile = ./krb5.keytab;
  };
}
```

## Emit plain file for yaml and json formats

By default, sops-nix extracts a single key from yaml and json files. If you
need the plain file instead of extracting a specific key from the input document,
you can set `key` to an empty string.

For example, the input document `my-config.yaml` likes this:

```yaml
my-secret1: ENC[AES256_GCM,data:tkyQPQODC3g=,iv:yHliT2FJ74EtnLIeeQtGbOoqVZnF0q5HiXYMJxYx6HE=,tag:EW5LV4kG4lcENaN2HIFiow==,type:str]
my-secret2: ENC[AES256_GCM,data:tkyQPQODC3g=,iv:yHliT2FJ74EtnLIeeQtGbOoqVZnF0q5HiXYMJxYx6HE=,tag:EW5LV4kG4lcENaN2HIFiow==,type:str]
sops:
    kms: []
    gcp_kms: []
    azure_kv: []
    hc_vault: []
...
```

This is how it can be included in your NixOS module:

```nix
{
  sops.secrets.my-config = {
    format = "yaml";
    sopsFile = ./my-config.yaml;
    key = "";
  };
}
```

Then, it will be mounted as `/run/secrets/my-config`:

```yaml
my-secret1: hello
my-secret2: hello
```

## Use with home manager

sops-nix also provides a home-manager module.
This module provides a subset of features provided by the system-wide sops-nix since features like the creation of the ramfs and changing the owner of the secrets are not available for non-root users.

The home-manager module requires systemd/user as it runs a service called `sops-nix.service` rather than an activation script.
While the sops-nix _system_ module decrypts secrets to the system non-persistent `/run/secrets`, the _home-manager_ module places them in the users non-persistent `$XDG_RUNTIME_DIR/secrets.d`.
Additionally secrets are symlinked to the users home at `$HOME/.config/sops-nix/secrets` which are referenced for the `.path` value in sops-nix.
This requires that the home-manager option `home.homeDirectory` is set to determine the home-directory on evaluation.  It will have to be manually set if home-manager is configured as stand-alone or on non NixOS systems.

Depending on whether you use home-manager system-wide or stand-alone using a home.nix, you have to import it in a different way.
This example shows the `flake` approach from the recommended example [Install: Flakes (current recommendation)](#Flakes (current recommendation))

```nix
{
  # NixOS system-wide home-manager configuration
  home-manager.sharedModules = [
    inputs.sops-nix.homeManagerModules.sops
  ];
}
```

```nix
{
  # Configuration via home.nix
  imports = [
    inputs.sops-nix.homeManagerModules.sops
  ];
}
```

This example show the `channel` approach from the example [Install: nix-channel](#nix-channel). All other methods work as well. 

```nix
{
  # NixOS system-wide home-manager configuration
  home-manager.sharedModules = [
    <sops-nix/modules/home-manager/sops.nix>
  ];
}
```

```nix
{
  # Configuration via home.nix
  imports = [
    <sops-nix/modules/home-manager/sops.nix>
  ];
}
```

The actual sops configuration is in the `sops` namespace in your home.nix (or in the `home-manager.users.<name>` namespace when using home-manager system-wide):
```nix
{
  sops = {
    age.keyFile = "/home/user/.age-key.txt"; # must have no password!
    # It's also possible to use a ssh key, but only when it has no password:
    #age.sshKeyPaths = [ "/home/user/path-to-ssh-key" ];
    defaultSopsFile = ./secrets.yaml;
    secrets.test = {
      # sopsFile = ./secrets.yml.enc; # optionally define per-secret files

      # %r gets replaced with a runtime directory, use %% to specify a '%'
      # sign. Runtime dir is $XDG_RUNTIME_DIR on linux and $(getconf
      # DARWIN_USER_TEMP_DIR) on darwin.
      path = "%r/test.txt"; 
    };
  };
}
```

The secrets are decrypted in a systemd user service called `sops-nix`, so other services needing secrets must order after it:
```nix
{
  systemd.user.services.mbsync.Unit.After = [ "sops-nix.service" ];
}
```

### Qubes Split GPG support

If you are using Qubes with the [Split GPG](https://www.qubes-os.org/doc/split-gpg),
then you can configure sops to utilize the `qubes-gpg-client-wrapper` with the `sops.gnupg.qubes-split-gpg` options.
The example above updated looks like this:
```nix
{
  sops = {
    gnupg.qubes-split-gpg = {
      enable = true;
      domain = "vault-gpg";
    };
    defaultSopsFile = ./secrets.yaml;
    secrets.test = {
      # sopsFile = ./secrets.yml.enc; # optionally define per-secret files

      # %r gets replaced with a runtime directory, use %% to specify a '%'
      # sign. Runtime dir is $XDG_RUNTIME_DIR on linux and $(getconf
      # DARWIN_USER_TEMP_DIR) on darwin.
      path = "%r/test.txt";
    };
  };
}
```

## Use with GPG instead of SSH keys

If you prefer having a separate GPG key, sops-nix also comes with a helper tool, `sops-init-gpg-key`:

```console
$ nix run github:Mic92/sops-nix#sops-init-gpg-key -- --hostname server01 --gpghome /tmp/newkey
# You can use the following command to save it to a file:
$ cat > server01.asc <<EOF
-----BEGIN PGP PUBLIC KEY BLOCK-----

mQENBF8L/iQBCACroEaUfvPBMMorNepNQmideOtNztALejgEJ5wZmxabck+qC1Gb
NWe3tmvChXVHgL7DzodSUfX1PuIjTTeRr2clMXtISPFIsBlRQb4MiErZfsardITM
n4WScg8sTb4nnqEOJiRknwAhBryIjH8kkCXxKlYK67re281dIK4dKBMIolFADlyv
wyHurJ7NPpHxR2WXHcIqXX1DaT6RvGQvZHMpfctob8k/QD4CyV6QwG5IVACQ/tuC
bEUggrkGw+g+XdeieUfWbRsHM4C4pv8BNwA/EYD5d0eKI+rshSPoTT+hcGn8Uh8w
MVQ8PVs6jWMMOAF1JH/stoPr9Yha+TGbMRi5ABEBAAG0GHNlcnZlcjAxIDxyb290
QHNlcnZlcjAxPokBTgQTAQgAOBYhBOTKhnaPF2rrbAFVQVOvjX8UlhOxBQJfC/4k
AhsvBQsJCAcCBhUKCQgLAgQWAgMBAh4BAheAAAoJEFOvjX8UlhOx1XIH/jUOrSR2
wuoqFiHcqaDPgXmTVJk8QanVkmiP3tk0mz5rRKrDX2eX5GnHqYR4PfpjUYNzedQE
sGyTjl7+DvglWJ2Q8m3yD/9+1agBmeqEVQlKqwL6Sc3bI4WBwHaxwVDo/bNwMs0w
o8ngOs1jPd3LfQdfG/rE1NolpHm4LWqYj0D2zEGqozLXVBx2wiuwmm6OKX4U4EHR
UwKax+VZYA+J9oFDN+kOy/yR+bKnOvg5eyOv2ZrK5BKceSBhDTOclMIWTL2cGxcL
jsq4N7fobs4TbwFPxRUi/T9ldXi0LXeGhTl9stImTtj3bL+4Y734TipvB5UvzCDK
CkjjwEvD5MYdGDE=
=uvIf
-----END PGP PUBLIC KEY BLOCK-----
EOF
# fingerprint: E4CA86768F176AEB6C01554153AF8D7F149613B1
```

You can choose between a RSA GPG key (default, like in the example above) or a
Curve25519 based one by adding `--keytype Curve25519` like so:

```console
$ nix run github:Mic92/sops-nix#sops-init-gpg-key -- --hostname server01 --gpghome /tmp/newkey --keytype Curve25519
You can use the following command to save it to a file:
cat > server01.asc <<EOF
-----BEGIN PGP PUBLIC KEY BLOCK-----

mDMEY7dJExYJKwYBBAHaRw8BAQdAloRZFyqNh3nIDtyUQKaBSMJOtLkbNeg+4TPg
BG5TduG0OG5peC1hLmhvbWUua3VldGVtZWllci5kZSA8cm9vdEBuaXgtYS5ob21l
Lmt1ZXRlbWVpZXIuZGU+iJMEExYKADsWIQREE2hPxiNijOo+CSmrLxbGte+J7wUC
Y7dJEwIbAwULCQgHAgIiAgYVCgkICwIEFgIDAQIeBwIXgAAKCRCrLxbGte+J79LX
AQDtLfQFDKm04ORIk28DrzTBbMTFQEW21dGBXk7ykBx4jQD/ZOnt1RPnB9mzMc8L
wIS3oI8D9719DjoS9hrHnJ4xvge4OARjt0kTEgorBgEEAZdVAQUBAQdA0t1X35pN
ic+etscIIkHjKUwrXhbTgWrARgXUuEMwwz8DAQgHiHgEGBYKACAWIQREE2hPxiNi
jOo+CSmrLxbGte+J7wUCY7dJEwIbDAAKCRCrLxbGte+J7+0NAQCfj95TSyPEFKz3
eLJ1aCA1bZZV/rkhHd+OwX1MFL3mKQD9GMPgvMzDIoofycDzMY2ttJgkRJfq+zOZ
juXFQdUkMgY=
=pf3V
-----END PGP PUBLIC KEY BLOCK-----
EOF
fingerprint: 4413684FC623628CEA3E0929AB2F16C6B5EF89EF
F0477297E369CD1D189DD901278D1535AB473B9E
```

In both cases, you must upload the GPG key directory `/tmp/newkey` onto the server.
If you uploaded it to `/var/lib/sops` than your sops configuration will look like this:

```nix
{
  # Make sure that `/var/lib/sops` is owned by root and is not world-readable/writable
  sops.gnupg.home = "/var/lib/sops";
  # disable importing host ssh keys
  sops.gnupg.sshKeyPaths = [];
}
```

However be aware that this will also run GnuPG on your server including the
GnuPG daemon. [GnuPG is in general not great software](https://latacora.micro.blog/2019/07/16/the-pgp-problem.html) and might break in
hilarious ways. If you experience problems, you are on your own. If you want a
more stable and predictable solution go with SSH keys or one of the KMS services.


## Share secrets between different users

Secrets can be shared between different users by creating different files
pointing to the same sops key but with different permissions. In the following
example the `drone` secret is exposed as `/run/secrets/drone-server` for
`drone-server` and as `/run/secrets/drone-agent` for `drone-agent`:

```nix
{
  sops.secrets.drone-server = {
    owner = config.systemd.services.drone-server.serviceConfig.User;
    key = "drone";
  };
  sops.secrets.drone-agent = {
    owner = config.systemd.services.drone-agent.serviceConfig.User;
    key = "drone";
  };
}
```

## Migrate from pass/krops

If you have used [pass](https://www.passwordstore.org) before (e.g. in
[krops](https://github.com/krebs/krops)) than you can use the following one-liner
to convert all your secrets to a YAML structure:

```console
$ for i in *.gpg; do echo "$(basename $i .gpg): |\n$(pass $(dirname $i)/$(basename $i .gpg)| sed 's/^/  /')"; done
```

Copy the output to the editor you have opened with sops.

## Real-world examples

The [nix-community infra](https://github.com/nix-community/infra) makes extensive usage of sops-nix.
Each host has a [secrets.yaml](https://github.com/nix-community/infra/tree/master/hosts/build01) containing secrets for the host.
Also Samuel Leathers explains his personal setup in this [blog article](https://samleathers.com/posts/2022-02-11-my-new-network-and-sops.html).

## Known limitations

### Initrd secrets

sops-nix does not fully support initrd secrets.
This is because `nixos-rebuild switch` installs
the bootloader before running sops-nix's activation hook.  
As a workaround, it is possible to run `nixos-rebuild test`
before `nixos-rebuild switch` to provision initrd secrets
before actually using them in the initrd.
In the future, we hope to extend NixOS to allow keys to be
provisioned in the bootloader install phase.

### Using secrets at evaluation time

It is not possible to use secrets at evaluation time of nix code. This is
because sops-nix decrypts secrets only in the activation phase of nixos i.e. in
`nixos-rebuild switch` on the target machine. If you rely on this feature for
some secrets, you should also include solutions that allow secrets to be stored
securely in your version control, e.g.
[git-agecrypt](https://github.com/vlaci/git-agecrypt). These types of solutions
can be used together with sops-nix.

## Templates

If your setup requires embedding secrets within a configuration file, the `template` feature of `sops-nix` provides a seamless way to do this. 

Here's how to use it:

1. **Define Your Secret**

   Specify the secrets you intend to use. This will be encrypted and managed securely by `sops-nix`.

   ```nix
   {
     sops.secrets.your-secret = { };
   }
   ```

2. **Use Templates for Configuration with Secrets**

   Create a template for your configuration file and utilize the placeholder where you'd like the secret to be inserted. 
   During the activation phase, `sops-nix` will substitute the placeholder with the actual secret content.

   ```nix
   {
     sops.templates."your-config-with-secrets.toml".content = ''
       password = "${config.sops.placeholder.your-secret}"
     '';
   }
   ```

   You can also define ownership properties for the configuration file:

   ```nix
   { 
     sops.templates."your-config-with-secrets.toml".owner = "serviceuser";
   }
   ```

3. **Reference the Rendered Configuration in Services**

   When defining a service (e.g., using `systemd`), refer to the rendered configuration (with secrets in place) by leveraging the `.path` attribute.

   ```nix
   {
     systemd.services.myservice = {
       # ... (any other service attributes)

       serviceConfig = {
         ExecStart = "${pkgs.myservice}/bin/myservice --config ${config.sops.templates."your-config-with-secrets.toml".path}";
         User = "serviceuser";
       };
     };
   }
   ```