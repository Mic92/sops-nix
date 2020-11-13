{ pkgs ? import <nixpkgs> {} }: let
  vendorSha256 = "sha256-O0z+oEffOOZa/bn2gV9onLVbPBHsNDH2yq1CZPi8w58=";

  sops-install-secrets = pkgs.callPackage ./pkgs/sops-install-secrets {
    inherit vendorSha256;
  };
in rec {
  sops-init-gpg-key = pkgs.callPackage ./pkgs/sops-init-gpg-key {};
  sops-pgp-hook = pkgs.callPackage ./pkgs/sops-pgp-hook { };
  inherit sops-install-secrets;

  ssh-to-pgp = pkgs.callPackage ./pkgs/ssh-to-pgp {
    inherit vendorSha256;
  };

  inherit (sops-install-secrets);

  # used in the CI only
  sops-pgp-hook-test = pkgs.buildGoModule {
    name = "sops-pgp-hook-test";
    src = ./.;
    inherit vendorSha256;
    buildPhase = ''
      go test -c ./pkgs/sops-pgp-hook
      install -D sops-pgp-hook.test $out/bin/sops-pgp-hook.test
    '';
  };

  unit-tests = pkgs.callPackage ./unit-tests.nix {};

  lint = ssh-to-pgp.overrideAttrs (old: {
    name = "golangci-lint";
    nativeBuildInputs = old.nativeBuildInputs ++ [ pkgs.golangci-lint ];
    buildPhase = ''
      HOME=$TMPDIR golangci-lint run
    '';
    installPhase = ''
      touch $out
    '';
    fixupPhase = ":";
  });

# integration tests
} // pkgs.lib.optionalAttrs (pkgs.stdenv.isLinux) sops-install-secrets.tests
