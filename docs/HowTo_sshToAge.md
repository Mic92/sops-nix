# How-To: `sops-nix` with an age key

This guide assumes you are starting from scratch and are on Linux.

Nix Darwin users -- check appropriate hidden sections to ensure compatibility.

If you already know

## 1. Generate a base key

This key will be used for you to edit secrets. Be careful not to overwrite an existing key you might be using for other purposes (ex. a github credential).

```bash
ssh-keygen -t ed25519 # optional: add `-f [path/to/your/key]
```

## 2. Derive an age key:

```bash
# Convert an ssh ed25519 key to an age key
mkdir -p ~/.config/sops/age
nix-shell -p ssh-to-age --run "ssh-to-age \
  -private-key -i ~/.ssh/id_ed25519 \
  > ~/.config/sops/age/keys.txt"
```

<details>
<summary>Troubleshooting: encrypted ssh key </summary>
If you get the following,
```console
ssh-to-age: failed to parse private ssh key: ssh: this private key is passphrase protected
```
then your SSH key is encrypted with your password and you will need to create an unencrypted copy temporarily.
```console
$ cp $HOME/.ssh/id_rsa /tmp/id_rsa
$ ssh-keygen -p -N "" -f /tmp/id_rsa
$ nix-shell -p gnupg -p ssh-to-pgp --run "ssh-to-pgp -private-key -i /tmp/id_rsa | gpg --import --quiet"
$ rm /tmp/id_rsa
```

</details>

<details><summary>Troubleshooting: Nix Darwin paths</summary>

When using `nix-darwin` save the `age` key to `$HOME/Library/Application Support/sops/age/keys.txt` or set a [custom](https://github.com/getsops/sops#23encrypting-using-age) configuration directory.

```bash
# Modified to use stock nix-darwin path
mkdir -p ~/.config/sops/age
nix-shell -p ssh-to-age --run "ssh-to-age \
  -private-key -i ~/.ssh/id_ed25519 \
  > $HOME/Library/Application Support/sops/age/keys.txt"
```

</details>


## 3. Find an `age` public key

Derive `age` public key directly from the source ssh key:


```bash
nix-shell -p ssh-to-age --run "ssh-to-age < ~/.ssh/id_ed25519.pub"
# Expected output:
# age[key....................................................]
```

## Create a sops file

```yaml
keys:
  - &server_arpanet age12zlz6lvcdk6eqaewfylg35w0syh58sm7gh53q5vvn7hd7c6nngyseftjxl
creation_rules:
  - path_regex: secrets/[^/]+\.(yaml|json|env|ini)$
    key_groups:
    - pgp:
      age:
      - *server_arpanet
  - path_regex: secrets/azmidi/[^/]+\.(yaml|json|env|ini)$
    key_groups:
    - pgp:
      - *admin_alice
      - *server_azmidi
      age:
      - *admin_bob
```

## 4. Add your first Secret

```bash
# In the same directory as your .sops.yaml

# Passing paths is possible via --config, 
#  but a path_regex must match relative to your $(pwd)

# This will open `secrets/example.yml` in your $EDITOR and encrypt the saved file on exit
sops edit secrets/public-ips.yml
```

Example yaml:

```yaml
my-server:
  public-ip:
    "1.2.3.4"
```

## 5. Add secrets to your config

For the ssh-to-age use case, the config is simple:

```nix
# /etc/nixos/getSecrets.nix
{
  # This will add secrets/public-ips.yaml to the nix store
  # You can avoid this by adding a string to the full path instead, i.e.
  # sops.defaultSopsFile = "/root/.sops/secrets/public-ips.yaml";
  sops.defaultSopsFile = ./secrets/public-ips.yaml;

  # This will automatically import SSH keys as age keys
  sops.age.sshKeyPaths = [ "/etc/ssh/ssh_host_ed25519_key" ];

  # This is using an age key that is expected to already be in the filesystem
  sops.age.keyFile = "/var/lib/sops-nix/key.txt";

  # This will generate a new key if the key specified above does not exist
  sops.age.generateKey = true;

  # This is the actual specification of the secrets.
  sops.secrets.my-server = {};
  sops.secrets."myservice/my_subdir/my_secret" = {};
}
```

Example usage:

```nix
# /etc/nixos/staticHosts.nix
{config, ...}:{
  networking.hosts = {
    "${config.sops.secrets.ips.my-server.public-ip}" = [ "my.site.org" ];
  };
}
```

Don't forget to include the files above in your config!

```nix
# /etc/nixos/configuration.nix
{
  imports = [
    ./getSecrets.nix
    ./staticHosts.nix
    # ... rest of your imports
  ]
  # ... rest of your config
}
```

## 6. Deploy

Rebuild your system:

```bash
nixos-rebuild switch # --flake .
```

This will make the keys accessible under `/run/secrets/`.

If you followed this guide exactly, youll find the following files:

- `/run/secrets/my-server/[secret]`
- `/run/secrets/myservice/my_subdir/[secret]`

Validate that they are available in plaintext woth a simple `cat` (you might need to prefix `sudo` depending on permissions):

```bash
cat /run/secrets/my-server
# Expected output:
# example-value

cat /run/secrets/myservice/my_subdir/my_secret
# Expected output:
# password1
```

`/run/secrets` is a symlink to `/run/secrets.d/{number}`:

```bash
ls -la /run/secrets
# Expected output:
# lrwxrwxrwx 16 root 12 Jul  6:23  /run/secrets -> /run/secrets.d/1
```

## Further Reading

If you've made it this far -- check out the [In-Depth Usage Guide](./InDepthUsage.md) for more details.