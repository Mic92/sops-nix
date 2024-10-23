<<<<<<< Updated upstream
{ pkgs ? import <nixpkgs> {}
, vendorHash ? "sha256-wd25uVUm3ISDjafy+4vImmLyObagEEeE+Ci8PbvaYD8="
=======
{ 
  home-manager ? import <home-manager> {},
  pkgs ? import <nixpkgs> {}, 
  vendorHash ? "sha256-CvIJqgqRk0fpU5lp3NO7bQC9vSU5a8SGnT3XsNLPpok="
>>>>>>> Stashed changes
}: let
  sops-install-secrets = pkgs.callPackage ./pkgs/sops-install-secrets {
    inherit vendorHash;
    inherit home-manager;
  };
in rec {
  inherit sops-install-secrets;
  sops-init-gpg-key = pkgs.callPackage ./pkgs/sops-init-gpg-key {};
  default = sops-init-gpg-key;

  sops-pgp-hook = pkgs.lib.warn ''
    sops-pgp-hook is deprecated, use sops-import-keys-hook instead.
    Also see https://github.com/Mic92/sops-nix/issues/98
  '' pkgs.callPackage ./pkgs/sops-pgp-hook { };
  sops-import-keys-hook = pkgs.callPackage ./pkgs/sops-import-keys-hook { };

  # backwards compatibility
  inherit (pkgs) ssh-to-pgp;

  # used in the CI only
  sops-pgp-hook-test = pkgs.callPackage ./pkgs/sops-pgp-hook-test.nix {
    inherit vendorHash;
  };
  unit-tests = pkgs.callPackage ./pkgs/unit-tests.nix { inherit home-manager; };
} // (pkgs.lib.optionalAttrs pkgs.stdenv.isLinux {
  lint = pkgs.callPackage ./pkgs/lint.nix {
    inherit sops-install-secrets;
  };

  cross-build = pkgs.callPackage ./pkgs/cross-build.nix {
    inherit sops-install-secrets;
  };
})
