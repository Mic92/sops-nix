{ stdenv, lib, buildGoApplication, path, pkgs, go }:
buildGoApplication {
  pname = "sops-install-secrets";
  version = "0.0.1";

  src = ../..;
  modules = ../../gomod2nix.toml;

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
    # newer versions of nixpkgs no longer require this step
    if command -v remove-references-to; then
      remove-references-to -t ${go} $unittest/bin/sops-install-secrets.test
    fi
  '';

  meta = with lib; {
    description = "Atomic secret provisioning based on sops";
    homepage = "https://github.com/Mic92/sops-nix";
    license = licenses.mit;
    maintainers = with maintainers; [ mic92 ];
    platforms = platforms.linux;
  };
}
