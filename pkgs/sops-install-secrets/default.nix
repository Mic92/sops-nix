<<<<<<< Updated upstream
{ lib, buildGoModule, stdenv, vendorHash, go, callPackages }:
=======
{ lib, buildGoModule, path, pkgs, vendorHash, go, home-manager }:
>>>>>>> Stashed changes
buildGoModule {
  pname = "sops-install-secrets";
  version = "0.0.1";

  src = lib.sourceByRegex ../.. [ "go\.(mod|sum)" "pkgs" "pkgs/sops-install-secrets.*" ];

  subPackages = [ "pkgs/sops-install-secrets" ];

  # requires root privileges for tests
  doCheck = false;

<<<<<<< Updated upstream
  passthru.tests = callPackages ./nixos-test.nix { };
=======
  passthru = {
    hm-tests = (import ./hm-test.nix { inherit pkgs; inherit home-manager; }).run.all;
    tests = import ./nixos-test.nix {
      makeTest = import (path + "/nixos/tests/make-test-python.nix");
      inherit pkgs;
    };
  };
>>>>>>> Stashed changes

  outputs = [ "out" ] ++
  lib.lists.optionals (stdenv.isLinux) [ "unittest" ];

  postInstall = ''
    go test -c ./pkgs/sops-install-secrets
  '' + lib.optionalString (stdenv.isLinux) ''
    # *.test is only tested on linux. $unittest does not exist on darwin.
    install -D ./sops-install-secrets.test $unittest/bin/sops-install-secrets.test
    # newer versions of nixpkgs no longer require this step
    if command -v remove-references-to; then
      remove-references-to -t ${go} $unittest/bin/sops-install-secrets.test
    fi
  '';

  inherit vendorHash;

  meta = with lib; {
    description = "Atomic secret provisioning based on sops";
    homepage = "https://github.com/Mic92/sops-nix";
    license = licenses.mit;
    maintainers = with maintainers; [ mic92 ];
    platforms = platforms.linux ++ platforms.darwin;
  };
}
