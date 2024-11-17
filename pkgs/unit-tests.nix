{
  pkgs ? import <nixpkgs> { },
}:
let
  sopsPkgs = import ../. { inherit pkgs; };
in
pkgs.stdenv.mkDerivation {
  name = "unit-tests";
  nativeBuildInputs = with pkgs; [
    bashInteractive
    gnupg
    util-linux
    nix
    sopsPkgs.sops-install-secrets.unittest
  ];
  # allow to prefetch shell dependencies in build phase
  dontUnpack = true;
  installPhase = ''
    echo $nativeBuildInputs > $out
  '';
  shellHook = ''
    set -x
    sudo TEST_ASSETS=$(realpath ./pkgs/sops-install-secrets/test-assets) \
      unshare --mount --fork sops-install-secrets.test
  '';
}
