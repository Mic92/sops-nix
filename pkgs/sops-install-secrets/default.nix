{ buildGoModule }:
buildGoModule {
  pname = "sops-install-secrets";
  version = "0.0.1";

  hardeningDisable = [ "all" ];

  src = ../..;

  subPackages = [ "pkgs/sops-install-secrets" ];

  vendorSha256 = "sha256-O0z+oEffOOZa/bn2gV9onLVbPBHsNDH2yq1CZPi8w58=";
}
