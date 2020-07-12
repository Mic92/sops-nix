{ pkgs ? import <nixpkgs> {} }: let
  vendorSha256 = "sha256-O0z+oEffOOZa/bn2gV9onLVbPBHsNDH2yq1CZPi8w58=";
in rec {
  sops-init-gpg-key = pkgs.callPackage ./pkgs/sops-init-gpg-key {};
  sops-install-secrets = pkgs.callPackage ./pkgs/sops-install-secrets {
    inherit vendorSha256;
  };
  sops-shell-hook = pkgs.callPackage ./pkgs/sops-shell-hook {};
  ssh-to-pgp = pkgs.callPackage ./pkgs/ssh-to-pgp {
    inherit vendorSha256;
  };

  nixos-tests-ssh-keys = sops-install-secrets.tests.ssh-keys;
  nixos-tests-pgp-keys = sops-install-secrets.tests.pgp-keys;
}
