{ stdenv, buildGoModule, gnupg, vendorSha256, }:
buildGoModule {
  pname = "ssh-to-pgp";
  version = "0.0.1";

  src = ../..;

  subPackages = [ "pkgs/ssh-to-pgp" ];

  checkInputs = [ gnupg ];
  checkPhase = ''
    HOME=$TMPDIR go test ./pkgs/ssh-to-pgp
  '';

  doCheck = true;

  inherit vendorSha256;

  meta = with stdenv.lib; {
    description = "Convert ssh public/private keys to PGP";
    homepage = "https://github.com/Mic92/sops-nix";
    license = licenses.mit;
    maintainers = with maintainers; [ mic92 ];
    platforms = platforms.unix;
  };
}
