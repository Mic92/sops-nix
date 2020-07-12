{ buildGoModule, path, pkgs }:
buildGoModule {
  pname = "sops-install-secrets";
  version = "0.0.1";

  hardeningDisable = [ "all" ];

  src = ../..;

  subPackages = [ "pkgs/sops-install-secrets" ];

  passthru.tests = import ./nixos-test.nix {
    makeTest = import (path + "/nixos/tests/make-test-python.nix");
    inherit pkgs;
  };

  vendorSha256 = "sha256-O0z+oEffOOZa/bn2gV9onLVbPBHsNDH2yq1CZPi8w58=";
}
