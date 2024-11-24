{
  stdenv,
  gnupg,
  util-linux,
  nix,
  sops-install-secrets,
}:
stdenv.mkDerivation {
  name = "unittests";
  nativeBuildInputs = [
    gnupg
    util-linux
    nix
    sops-install-secrets.unittest
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
