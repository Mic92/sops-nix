{ pkgs ? import <nixpkgs> {} }: let
  vendorSha256 = "sha256-6WyyR1UvsBZDIgtZ7H9wsXe6M5MY2A/MR9M6c/31v/w=";

  buildGoModule = if pkgs.lib.versionOlder pkgs.go.version "1.18" then pkgs.buildGo118Module else pkgs.buildGoModule;
  sops-install-secrets = pkgs.callPackage ./pkgs/sops-install-secrets {
    inherit buildGoModule;
    inherit vendorSha256;
  };
in rec {
  inherit sops-install-secrets;
  sops-init-gpg-key = pkgs.callPackage ./pkgs/sops-init-gpg-key {};
  sops-pgp-hook = pkgs.lib.warn ''
    sops-pgp-hook is deprecated, use sops-import-keys-hook instead.
    Also see https://github.com/Mic92/sops-nix/issues/98
  '' pkgs.callPackage ./pkgs/sops-pgp-hook { };
  sops-import-keys-hook = pkgs.callPackage ./pkgs/sops-import-keys-hook { };

  # backwards compatibility
  inherit (pkgs) ssh-to-pgp;

  # used in the CI only
  sops-pgp-hook-test = pkgs.callPackage ./pkgs/sops-pgp-hook-test.nix {
    inherit vendorSha256;
  };
  unit-tests = pkgs.callPackage ./pkgs/unit-tests.nix {};
} // (pkgs.lib.optionalAttrs pkgs.stdenv.isLinux {
  lint = pkgs.callPackage ./pkgs/lint.nix {
    inherit sops-install-secrets;
  };

  cross-build = pkgs.callPackage ./pkgs/cross-build.nix {
    inherit sops-install-secrets;
  };
})
