{ pkgs ? import <nixpkgs> {}
, sudo ? "sudo"
}:
let
  sopsPkgs = import ./. { inherit pkgs; };
in pkgs.stdenv.mkDerivation {
  name = "env";
  nativeBuildInputs = with pkgs; [
    bashInteractive
    gnupg
    utillinux
    nix
    sopsPkgs.sops-pgp-hook-test
    sopsPkgs.sops-import-keys-hook-test
  ] ++ pkgs.lib.optional (pkgs.stdenv.isLinux) sopsPkgs.sops-install-secrets.unittest;
  # allow to prefetch shell dependencies in build phase
  dontUnpack = true;
  installPhase = ''
    echo $nativeBuildInputs > $out
  '';
  shellHook = ''
    set -x
    NIX_PATH=nixpkgs=${toString pkgs.path} TEST_ASSETS=$(realpath ./pkgs/sops-pgp-hook/test-assets) \
      sops-pgp-hook.test
    NIX_PATH=nixpkgs=${toString pkgs.path} TEST_ASSETS=$(realpath ./pkgs/sops-import-keys-hook/test-assets) \
      sops-import-keys-hook.test
    ${pkgs.lib.optionalString (pkgs.stdenv.isLinux) ''
      ${sudo} TEST_ASSETS=$(realpath ./pkgs/sops-install-secrets/test-assets) \
        unshare --mount --fork sops-install-secrets.test
    ''}
  '';
}
