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

## Example

The easiest way to add new hosts is using ssh host keys (requires openssh to be enabled).
Since sops does not natively supports ssh keys yet, nix-sops supports a conversion tool
to store them as gpg keys.

```
$ nix-shell -p ssh-to-gpg
# One can use ssh-keyscan over the network
$ ./result/bin/ssh-keyscan -t rsa server01 | ./result/bin/ssh-to-pgp -pubkey - > hosts/server01.gpg
# via ssh command:
$ ssh "cat /etc/ssh/ssh_host_rsa_key.pub" | ./result/bin/ssh-to-gpg -pubkey - > hosts/server01.gpg
# Or just read them locally
$ ./result/bin/ssh-to-pgp -pubkey /etc/ssh/ssh_host_rsa_key.pub > hosts/server01.gpg
```

```
{}: {

}
```
