{
  pkgs ? import <nixpkgs> { },
}:
pkgs.mkShell {
  nativeBuildInputs = with pkgs; [
    bashInteractive
    go
    delve
    gnupg
    util-linux
    nix
    golangci-lint
  ];
  # delve does not compile with hardening enabled
  hardeningDisable = [ "all" ];
}
