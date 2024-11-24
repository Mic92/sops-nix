{
  pkgs ? import <nixpkgs> { },
  vendorHash ? "sha256-xHScXL3i2oxJSJsvOC+KqLCA5Psu3ht7DQNrh0rB1rA=",
}:
let
  sops-init-gpg-key = pkgs.callPackage ./pkgs/sops-init-gpg-key { };
in
{
  sops-install-secrets = pkgs.callPackage ./pkgs/sops-install-secrets {
    inherit vendorHash;
  };
  inherit sops-init-gpg-key;
  default = sops-init-gpg-key;

  sops-import-keys-hook = pkgs.callPackage ./pkgs/sops-import-keys-hook { };

  # backwards compatibility
  inherit (pkgs) ssh-to-pgp;
}
