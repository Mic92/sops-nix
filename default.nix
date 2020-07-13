{ pkgs ? import <nixpkgs> {} }: let
  vendorSha256 = "sha256-O0z+oEffOOZa/bn2gV9onLVbPBHsNDH2yq1CZPi8w58=";
in rec {
  sops-init-gpg-key = pkgs.callPackage ./pkgs/sops-init-gpg-key {};
  sops-install-secrets = pkgs.callPackage ./pkgs/sops-install-secrets {
    inherit vendorSha256;
  };
  sops-pgp-hook = pkgs.callPackage ./pkgs/sops-pgp-hook {};
  ssh-to-pgp = pkgs.callPackage ./pkgs/ssh-to-pgp {
    inherit vendorSha256;
  };
}
