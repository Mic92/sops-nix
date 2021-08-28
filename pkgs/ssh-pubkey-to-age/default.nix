{ stdenv, lib, buildGoModule, path, pkgs, vendorSha256, go }:
buildGoModule {
  pname = "ssh-pubkey-to-age";
  version = "0.0.1";

  src = ../..;

  subPackages = [ "pkgs/ssh-pubkey-to-age" ];

  inherit vendorSha256;

  meta = with lib; {
    description = "Converter that converts SSH public keys into age keys";
    homepage = "https://github.com/Mic92/sops-nix";
    license = licenses.mit;
    maintainers = with maintainers; [ mic92 ];
    platforms = platforms.linux;
  };
}
