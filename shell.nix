{ pkgs ? import <nixpkgs> {} }:
pkgs.mkShell {
  nativeBuildInputs = with pkgs; [
    bashInteractive
    go
    delve
    gnupg
    utillinux
    nix
  ];
  # delve does not compile with hardening enabled
  hardeningDisable = [ "all" ];
}
