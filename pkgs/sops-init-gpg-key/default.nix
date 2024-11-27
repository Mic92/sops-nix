{
  stdenv,
  lib,
  makeWrapper,
  gnupg,
  coreutils,
  util-linux,
  unixtools,
}:

stdenv.mkDerivation {
  name = "sops-init-gpg-key";
  version = "0.1.0";
  src = ./sops-init-gpg-key;
  dontUnpack = true;

  nativeBuildInputs = [ makeWrapper ];

  installPhase = ''
    install -m755 -D $src $out/bin/sops-init-gpg-key
    wrapProgram $out/bin/sops-init-gpg-key \
      --prefix PATH : ${
        lib.makeBinPath [
          coreutils
          util-linux
          gnupg
          unixtools.hostname
        ]
      }
  '';

  doInstallCheck = true;
  installCheckPhase = ''
    $out/bin/sops-init-gpg-key --hostname server01 --gpghome $TMPDIR/key
  '';
}
