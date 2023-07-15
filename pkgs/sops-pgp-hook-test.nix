{ buildGoModule, vendorHash }:

buildGoModule {
  name = "sops-pgp-hook-test";
  src = ../.;
  inherit vendorHash;
  buildPhase = ''
    go test -c ./pkgs/sops-pgp-hook
    install -D sops-pgp-hook.test $out/bin/sops-pgp-hook.test
  '';
}
