{ buildGoModule, path, pkgs, vendorSha256 }:
buildGoModule {
  pname = "sops-install-secrets";
  version = "0.0.1";

  src = ../..;

  subPackages = [ "pkgs/sops-install-secrets" ];

  passthru.tests = import ./nixos-test.nix {
    makeTest = import (path + "/nixos/tests/make-test-python.nix");
    inherit pkgs;
  };

  inherit vendorSha256;

  meta = with stdenv.lib; {
    description = "Atomic secret provisioning based on sops";
    homepage = "https://github.com/Mic92/sops-nix";
    license = licenses.mit;
    maintainers = with maintainers; [ mic92 ];
    platforms = platforms.unix;
  };
}
