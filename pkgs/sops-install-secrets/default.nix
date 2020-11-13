{ stdenv, buildGoModule, path, pkgs, vendorSha256, go }:
buildGoModule {
  pname = "sops-install-secrets";
  version = "0.0.1";

  src = ../..;

  subPackages = [ "pkgs/sops-install-secrets" ];

  # requires root privileges for tests
  doCheck = false;

  passthru.tests = import ./nixos-test.nix {
    makeTest = import (path + "/nixos/tests/make-test-python.nix");
    inherit pkgs;
  };

  outputs = [ "out" "unittest" ];

  postBuild = ''
    go test -c ./pkgs/sops-install-secrets
    install -D ./sops-install-secrets.test $unittest/bin/sops-install-secrets.test
    remove-references-to -t ${go} $unittest/bin/sops-install-secrets.test
  '';

  inherit vendorSha256;

  meta = with stdenv.lib; {
    description = "Atomic secret provisioning based on sops";
    homepage = "https://github.com/Mic92/sops-nix";
    license = licenses.mit;
    maintainers = with maintainers; [ mic92 ];
    platforms = platforms.linux;
  };
}
