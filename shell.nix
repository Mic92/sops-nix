{ pkgs ? import <nixpkgs> {} }:
pkgs.mkShell {
  nativeBuildInputs = with pkgs; [
    bashInteractive
    go
    delve
    gnupg
    util-linux
    nixFlakes
    golangci-lint
  ];
  # delve does not compile with hardening enabled
  hardeningDisable = [ "all" ];
}
