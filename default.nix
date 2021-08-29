{ pkgs ? import <nixpkgs> {} }: let
  vendorSha256 = "sha256-YFy0eIIwrOvAiA+CJNVqY1AgswnPOzxq+GsA82XrT3M=";

  sops-install-secrets = pkgs.callPackage ./pkgs/sops-install-secrets {
    inherit vendorSha256;
  };
in rec {
  sops-init-gpg-key = pkgs.callPackage ./pkgs/sops-init-gpg-key {};
  sops-pgp-hook = pkgs.lib.warn ''
    sops-pgp-hook is deprecated, use sops-import-keys-hook instead.
    Also see https://github.com/Mic92/sops-nix/issues/98
  '' pkgs.callPackage ./pkgs/sops-pgp-hook { };
  sops-import-keys-hook = pkgs.callPackage ./pkgs/sops-import-keys-hook { };
  inherit sops-install-secrets;

  # backwards compatibility
  inherit (pkgs) ssh-to-pgp;

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

  lint = sops-install-secrets.overrideAttrs (old: {
    name = "golangci-lint";
    nativeBuildInputs = old.nativeBuildInputs ++ [ pkgs.golangci-lint ];
    buildPhase = ''
      HOME=$TMPDIR golangci-lint run --timeout 360s
    '';
    doCheck = false;
    installPhase = ''
      touch $out $unittest
    '';
    fixupPhase = ":";
  });

  cross-build = sops-install-secrets.overrideAttrs (old: {
    name = "cross-build";
    nativeBuildInputs = old.nativeBuildInputs ++ [ pkgs.gox ];
    buildPhase = ''
      (cd pkgs/sops-install-secrets && gox -os linux)
    '';
    doCheck = false;
    installPhase = ''
      touch $out $unittest
    '';
    fixupPhase = ":";
  });

# integration tests
} // pkgs.lib.optionalAttrs (pkgs.stdenv.isLinux) sops-install-secrets.tests
