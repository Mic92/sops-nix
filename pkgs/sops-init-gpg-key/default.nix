{ stdenv, lib, makeWrapper, gnupg, coreutils, utillinux, unixtools }:

stdenv.mkDerivation {
  name = "sops-init-gpg-key";
  version = "0.1.0";
  src = ./sops-init-gpg-key;
  dontUnpack = true;

  nativeBuildInputs = [ makeWrapper ];

  installPhase = ''
    install -m755 -D $src $out/bin/sops-init-gpg-key
    wrapProgram $out/bin/sops-init-gpg-key \
      --prefix PATH : ${lib.makeBinPath [
        coreutils utillinux gnupg unixtools.hostname
      ]}
  '';

  doInstallCheck = true;
  installCheckPhase = ''
    $out/bin/sops-init-gpg-key --hostname server01 --gpghome $TMPDIR/key
  '';
}
