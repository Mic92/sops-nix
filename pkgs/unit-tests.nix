{
  pkgs ? import <nixpkgs> { },
}:
let
  sopsPkgs = import ../. { inherit pkgs; };
in
pkgs.writeShellApplication {
  name = "unit-tests";
  runtimeInputs = [
    pkgs.gnupg
    pkgs.nix
  ] ++ pkgs.lib.optionals pkgs.stdenv.isLinux [
    pkgs.util-linux
  ];
  text = ''
    NIX_PATH=nixpkgs=${pkgs.path} TEST_ASSETS="$PWD/pkgs/sops-pgp-hook/test-assets" ${sopsPkgs.sops-pgp-hook-test}/bin/sops-pgp-hook.test -test.v
    ${pkgs.lib.optionalString pkgs.stdenv.isLinux ''
      sudo TEST_ASSETS="$PWD/pkgs/sops-install-secrets/test-assets" unshare --mount --fork ${sopsPkgs.sops-install-secrets.unittest}/bin/sops-install-secrets.test -test.v
    ''}
  '';
}
