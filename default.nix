{ pkgs ? import <nixpkgs> {} }: let
  vendorSha256 = "sha256-nqA2zzCsWXCllpsss0tjjo4ivi3MVuEM3W6dEZc5KAc=";

  buildGoModule = if pkgs.lib.versionOlder pkgs.go.version "1.17" then pkgs.buildGo117Module else pkgs.buildGoModule;
  sops-install-secrets = pkgs.callPackage ./pkgs/sops-install-secrets {
    inherit buildGoModule;
    inherit vendorSha256;
  };
in rec {
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
  inherit sops-install-secrets;

  lint = pkgs.callPackage ./pkgs/lint.nix {
    inherit sops-install-secrets;
  };

  cross-build = pkgs.callPackage ./pkgs/cross-build.nix {
    inherit sops-install-secrets;
  };
})
