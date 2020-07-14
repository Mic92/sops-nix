# sops-nix

![Test](https://github.com/Mic92/sops-nix/workflows/Test/badge.svg)
[![NixOS Test status](https://badge.buildkite.com/3be43a385ba06ddf53a7a39aa305290a3bf0b3f5e892ac9ad4.svg?branch=master)](https://buildkite.com/eve-1/nix-sops)

Atomic secret provisioning for NixOS based on [sops](https://github.com/mozilla/sops).

## How it works

Sops-nix decrypts secrets [sops files](https://github.com/mozilla/sops#2usage)
on the target machine to files specified in the NixOS configuration at
activation time. It also adjusts file permissions/owner/group. It uses either
host ssh keys or GPG keys for decryption. In future we will also support cloud
key management APIs such as AWS KMS, GCP KMS, Azure Key Vault.

## Features

- Compatible with all NixOS deployment frameworks: [NixOps](https://github.com/NixOS/nixops), nixos-rebuild, [krops](https://github.com/krebs/krops/), [morph](https://github.com/DBCDK/morph)
- Version-control friendly: Since all files are encrypted they can directly committed to version control. The format is readable in diffs and there are also ways of showing [git diffs in cleartext](https://github.com/mozilla/sops#showing-diffs-in-cleartext-in-git)
- CI friendly: Since nixops files can be added to the nix store as well without leaking secrets, machine definition can be build as a whole.
- Atomic upgrades: New secrets are written to a new directory which replaces the old directory in an atomic step.
- Rollback support: If sops files are added to Nix store, old secrets can be rolled back. This is optional.
- Fast: Unlike solutions implemented by NixOps, krops and morph there is no extra step required to upload secrets
- Different storage formats: Secrets can be stored in Yaml, JSON or binary.

## Usage example

### 1. Install nix-sops

TODO

### 2. Generate a GPG key for yourself

First generate yourself [a GPG key](https://docs.github.com/en/github/authenticating-to-github/generating-a-new-gpg-key) or use nix-sops
conversion tool to convert an existing ssh key (we only support RSA keys right now):

```
$ nix-shell -p ssh-to-pgp
$ ssh-to-pgp -private-key -i $HOME/.ssh/id_rsa | gpg --import --quiet
2504791468b153b8a3963cc97ba53d1919c5dfd4
# This exports the public key
$ ssh-to-pgp -i $HOME/.ssh/id_rsa -o $USER.asc
2504791468b153b8a3963cc97ba53d1919c5dfd4
```

If you get:

```
ssh-to-pgp: failed to parse private ssh key: ssh: this private key is passphrase protected
```

then your ssh key is encrypted with your password and you need to create a encrypted copy temporarily:

```
$ cp $HOME/.ssh/id_rsa /tmp/id_rsa
$ ssh-keygen -p -N "" -f /tmp/id_rsa
$ ssh-to-pgp -private-key -i /tmp/id_rsa | gpg --import --quiet
```

The hex string printed here is your GPG fingerprint that can be exported to `SOPS_PGP_FP`.

```
export SOPS_PGP_FP=2504791468b153b8a3963cc97ba53d1919c5dfd4
```

If you have generated a gnupg key directly you can get your fingerprint like this:

```
gpg --list-secret-keys --fingerprint
/tmp/tmp.JA07D1aVRD/pubring.kbx
-------------------------------
sec   rsa2048 1970-01-01 [SCE]
      9F89 C5F6 9A10 281A 8350  14B0 9C3D C61F 7520 87EF
uid           [ unknown] root <root@localhost>
```

The fingerprint here is `9F89 C5F6 9A10 281A 8350 14B0 9C3D C61F 7520 87EF`, you
need to remove the space in-between manually.

### 3. Get a PGP Public key for your machine

The easiest way to add new hosts is using ssh host keys (requires openssh to be enabled).
Since sops does not natively supports ssh keys yet, nix-sops supports a conversion tool
to store them as gpg keys.

```
$ nix-shell -p ssh-to-pgp
$ ssh root@server01 "cat /etc/ssh/ssh_host_rsa_key" | ssh-to-pgp -o server01.asc
# or with sudo
$ ssh youruser@server01 "sudo cat /etc/ssh/ssh_host_rsa_key" | ssh-to-pgp -o server01.asc
0fd60c8c3b664aceb1796ce02b318df330331003
# Or just read them locally (or in a ssh session)
$ ssh-to-pgp -i /etc/ssh/ssh_host_rsa_key -o server01.asc
0fd60c8c3b664aceb1796ce02b318df330331003
```

Also the hex string here is the fingerprint of your server's gpg key that can be exported
append to `SOPS_PGP_FP`:

```
export SOPS_PGP_FP=${SOPS_PGP_FP}:2504791468b153b8a3963cc97ba53d1919c5dfd4
```

If you prefer having a separate gnupg key, see [Use with gnupg instead of ssh keys](#use-with-gnupg-instead-of-ssh-keys).

### 4. Create a sops file

To create a sops file you need to set export `SOPS_PGP_FP` to include both the fingerprint 
of your personal gpg key (and your colleagues) and your servers:

```
export SOPS_PGP_FP="2504791468b153b8a3963cc97ba53d1919c5dfd4,2504791468b153b8a3963cc97ba53d1919c5dfd4"
```

sops-nix automates that with a hook for nix-shell and also takes care of importing all keys, allowing
public keys to be stored in git:

```
# shell.nix
with import <nixpkgs> {};
mkShell {
  # imports all files ending in .asc/.gpg and sets $SOPS_PGP_FP.
  sopsPGPKeyDirs = [ 
    "./keys/hosts"
    "./keys/users"
  ];
  # Also single files can be imported.
  #sopsPGPKeys = [ 
  #  "./keys/users/mic92.asc"
  #  "./keys/hosts/server01.asc"
  #];
  nativeBuildInputs = [
    (pkgs.callPackage <sops-nix> {}).sops-pgp-hook
  ];
}
```

Our directory structure looks like this:

```console
$ tree .
.
├── keys
│   ├── hosts
│   │   └── server01.asc
│   └── users
│       └── mic92.asc
```

After that you can open a new file with sops

```
nix-shell --run "sops secrets.yaml"
```

This will start your configured editor
In our example we put the following content in it:

```
example-key: example-value
```

As a result when saving the file the following content will be in it:

```
example-key: ENC[AES256_GCM,data:7QIOMLd2kZkeVVpH0Q==,iv:ROh+J59ZM6BtjZLhRj1Ylk6ROEvsiX6/UR8obHX8YcQ=,tag:QOiFoHKyGFBkhr9lcWBB3Q==,type:str]
sops:
    kms: []
    gcp_kms: []
    azure_kv: []
    lastmodified: '2020-07-13T09:09:14Z'
    mac: ENC[AES256_GCM,data:BCwTBxaW6qINVfixC32EEYrlqPvGz47wF+o/vNPqcwed1HPwZezlNy7Z4NFLbRcCLAELyeMqkJ+fi9XCWvnT3UvfwB45COpz/xZphURt3gyCVOyd9mT/s9cJ1O9vNy5iKblqCae2X0CTKee/GxJ0G725LDOL4r+oHM1+WWEInWo=,iv:S43qegidSqcaUaDjvQpEQj/qvF/OZcW32Yo05CfyTUs=,tag:npj5auJXZrg7jQwYSjC6Vg==,type:str]
    pgp:
    -   created_at: '2020-07-13T08:34:30Z'
        enc: |
            -----BEGIN PGP MESSAGE-----

            hQIMAysxjfMwMxADAQ//SyBLvbpyuoTGCZCtoJyaFzZ+vCKWZaD7dCZEURRyNKFV
            87wZyNO/rwtA1jP64Smqy0q2R8iZfoN0v5oVvtj2y5wFECs8Q5nONCVP4rs9nTRK
            n46w0v2UE2GqIWStFE7Mpv11qdZaMDoNGXq+n6s/uA2mwSYIVvzcWwhKvyKrMNrd
            iOlfCKl4QTaGgGupZqmT2S00AEMJzY5lohvtzAC1TlnXGXhetDyCHtkoN/NKZDU7
            m7j1/pvlIwxTQKeA3FKuxDJDYk+p3+W/EgwEchYDzjo+5A529J/tuIfXWBOF7BAV
            ZiVVWISTahky/ioOMatNBAttu0lBGlSkovkbqIVsbTG7nF1wzGdToCxZmwQveEj7
            0N8ZzocDkOXqS71LW+X2HYSeywxNUbg/S6MrHrZN8MOp5qnGztm8yrKW2gDDe+Nl
            nqJJ4lGg5CbODoDmhbPPof9tmWkykFmQSqmkjs4pcomcNthmcQvPVy75pnXEN9Wo
            0cDRnHtgROCJLqfv1AsXWkSxtmZRMMQ1yKJIPVFUHSPodgAoTyA81sHi66RypDOV
            KezX6sW8UuTZ7q1oPcJFpaaHrpIHDn+bqPGMfhu4NVXFusdb7MPxtxlKflhTdc8B
            xzlrB6+LdnCaeN+KqB6DOvmiPP3nC91zflO1SpMY3yUOnTFDKZG7wnVjidyIuMvS
            UAHk6rhsBEJleAn5f4AuBVWtWLuvS4t1g9Lhci3833f7XNp+GFNy05UOsmUo9upr
            cgqaa2teuy2cbUtzS6gLBbcMA7SEs5MDYHjq6le/pwKv
            =ZYPM
            -----END PGP MESSAGE-----
        fp: 0FD60C8C3B664ACEB1796CE02B318DF330331003
    -   created_at: '2020-07-13T08:34:30Z'
        enc: |
            -----BEGIN PGP MESSAGE-----

            hQIMAysxjfMwMxADARAAqbkG7+WZIDDHNjFp4mcabdGcKaTenJmAQKJjk4vnAWZD
            5Y6yInTldxldsFNvPcVmjZp/nM1otyH0MEHrurl5LX+BuUj8hRIE0ZFnNU0hNmyd
            toiwTE4GF1/otYFOPb9WnhDt+g6Y0ORuV/ZMSvP8PIu5/UnTeCkbZR/VudOvUq/m
            qF013M3q7UKssW4aReO2goFEhLjm8GfWksCuiGYKoHdJKzFAPYNhoxnxU3n43Oxp
            wz7QYFI0aA7RLZph70WjUNBun5+y4UyEJ8uNZ+cgVBeHQLqVdFUuejdzWK0d79Mr
            5D9fxgSsPMz7yUMMdPl0T4rrAsZ977pftI9+JofqMN+u9UzUJwfTjnbCxlob39/t
            bfORkanzU8BNUCxpHyyqau921AUtfcqV9Y9Hf+qwxgVRVKgfETOqN376A1nhrYsf
            Mhvmcsk/rDssiRSIu11/mZwifcpALnS8WgO5tK+e/454ANqsiEdSRVogWBTzcIIs
            trm/6kwsTl7COzK0ThUKIb6aOfb910JQKaYq93qWqF1fceIf49Ubz9NVZc80J0an
            OiAaVGS0IOGI1ua8zciY7m+rr1BlrqJFtUm7hd8C9fMaF8YdB2SXgW8/HPGL8uTd
            f9ASg9TMSxhr7wjdqWp4EXXxdB6p4FXai9XBbgAJ2tKcS6AV6QmRVMoITZ7uZpvS
            UAG4nIgey9A57C8DSnt5zVPtxAsjDNiMubLUnHzTEJEJyQH5j2E41teujycOOAye
            I/UHMfpxSgrFfS8JJHYrJO0JQq/maBZi/VzZCl/G3IMn
            =Xls9
            -----END PGP MESSAGE-----
        fp: 0FD60C8C3B664ACEB1796CE02B318DF330331003
    -   created_at: '2020-07-13T08:34:30Z'
        enc: |
            -----BEGIN PGP MESSAGE-----

            hQEMA5w9xh91IIfvAQf+I1FDo7rglcA6EF7jmQ0pq9FwYR/Dd9+4pu4mxUofQawj
            YsXPToVvyOKFrs1BZzW3Idyn5U/oXnkPN0qNK30DKir/wCt9OBqHHuhlo80OR2nS
            G2ZvHOJKEW3W5Hs2yT1e1MQxznI1lGFrsj6xgZAnKtK3Y6iy48XZ9pTw4Fxjkixw
            NppHtYrMj30mwV9XFAer0EfGlV2AIi70xBZ2inYAzPU2SpLEEoGyztjIeSS4VfhQ
            fnKSx3UjlVIix65s2ky0JqbL1wI+FPKNt2hWupW+M7en8BJ5VfAcbU7n0ZuQnaFx
            YPErw3agfhw1bNnqXh0y5aZ9sswt/Jy+IRkMJHLcqNJQAREdKgGmkW8wO2dngYYL
            IwLyChHJfcSnixboVcW5CIbfmIbOdgfEk2tdSiX1tJIA6qeeJz+D8UbR47nIdIw2
            ZoID5dEUiDgikopjdqWk+zk=
            =43hf
            -----END PGP MESSAGE-----
        fp: 9F89C5F69A10281A835014B09C3DC61F752087EF
    unencrypted_suffix: _unencrypted
    version: 3.5.0
```

### 5. Deploy 

If you derived your server public key from ssh, all you need in your configuration.nix is:

```nix
{
  imports = [ <sops-nix/modules/sops> ];
  # This will add secrets.yml to the nix store
  # You can avoid this by adding a string to the full path instead, i.e.
  # sops.defaultSopsFile = "/root/.sops/secrets.yaml";
  sops.defaultSopsFile = ./secrets.yaml;
  sops.secrets.example-key = {};
}
```

On `nixos-rebuild switch` this will make the key accessible 
via `/run/secret/example-key`:

```console
$ cat /run/secret/example-key
example-value
```

`/run/secret` is a symlink to `/etc/secret.d/1`:

```console
$ ls -la /run/secrets
lrwxrwxrwx 16 root 12 Jul  6:23  /run/secrets -> /run/secrets.d/1
```

## Permissions & Owner

TODO

## Symlinks to other directories

TODO

## Use with gnupg instead of ssh keys

If you prefer having a separate gnupg key, sops-nix also comes with a helper tool:

```
$ nix-shell -p sops-init-gpg-key
$ sops-init-gpg-key --hostname server01 --gpghome /tmp/newkey
You can use the following command to save it to a file:
cat > server01.asc <<EOF
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
fingerprint: E4CA86768F176AEB6C01554153AF8D7F149613B1
```

In this case you need to make upload the gpg key directory `/tmp/newkey` to your server.
