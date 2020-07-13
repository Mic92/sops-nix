# sops-nix

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
$ ssh-to-pgp -privkey $HOME/.ssh/id_rsa | gpg --import --quiet
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
$ ssh-to-pgp -privkey /tmp/id_rsa | gpg --import --quiet
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

### 3. Get a GPG key for your machine

The easiest way to add new hosts is using ssh host keys (requires openssh to be enabled).
Since sops does not natively supports ssh keys yet, nix-sops supports a conversion tool
to store them as gpg keys.

```
$ nix-shell -p ssh-to-gpg
# One can use ssh-keyscan over the network
$ ssh-keyscan -t rsa server01 | ssh-to-pgp -pubkey - > server01.asc
# server01:22 SSH-2.0-OpenSSH_8.2
0fd60c8c3b664aceb1796ce02b318df330331003
# via ssh command:
$ ssh server01 "cat /etc/ssh/ssh_host_rsa_key.pub" | ssh-to-gpg -pubkey - > hosts/server01.asc
0fd60c8c3b664aceb1796ce02b318df330331003
# Or just read them locally (or in a ssh session)
$ ssh-to-pgp -pubkey /etc/ssh/ssh_host_rsa_key.pub > server01.asc
0fd60c8c3b664aceb1796ce02b318df330331003
```

Also the hex string here is the fingerprint of your server's gpg key that can be exported
append to `SOPS_PGP_FP`:

```
export SOPS_PGP_FP=${SOPS_PGP_FP}:2504791468b153b8a3963cc97ba53d1919c5dfd4
```

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
  sopsGPGKeyDirs = [ 
    "./keys/hosts"
    "./keys/users"
  ];
  # Also single files can be imported.
  #sopsGPGKeys = [ 
  #  "./keys/users/mic92.asc"
  #  "./keys/hosts/server01.asc"
  #];
  nativeBuildInputs = [
    (pkgs.callPackage <sops-nix> {}).sops-shell-hook
    sops
    ## you may also need gnupg
    # gnupg
  ];
}
```

After that you can create a new file with sops

```
sops secrets.yaml
```
