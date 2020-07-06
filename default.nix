{ pkgs ? import <nixpkgs> {} }: {
  sops-init-gpg-key = pkgs.callPackage ./pkgs/sops-init-gpg-key {};
  sops-install-secrets = pkgs.callPackage ./pkgs/sops-install-secrets {};
  sops-shell-hook = pkgs.callPackage ./pkgs/sops-shell-hook {};
}
