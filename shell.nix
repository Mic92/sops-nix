{ pkgs ? import <nixpkgs> {} }:
pkgs.mkShell {
  nativeBuildInputs = with pkgs; [
    bashInteractive
    go
    delve
    gnupg
    utillinux
    nixFlakes
    golangci-lint
  ];
  # delve does not compile with hardening enabled
  hardeningDisable = [ "all" ];
}
