{ buildGoModule, vendorSha256 }:

buildGoModule {
  name = "sops-pgp-hook-test";
  src = ../.;
  inherit vendorSha256;
  buildPhase = ''
    go test -c ./pkgs/sops-pgp-hook
    install -D sops-pgp-hook.test $out/bin/sops-pgp-hook.test
  '';
}
