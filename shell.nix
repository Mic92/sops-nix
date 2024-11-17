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

    (pkgs.writeScriptBin "update-dev-private-narHash" ''
      nix --extra-experimental-features "nix-command flakes" flake lock ./dev/private
      nix --extra-experimental-features "nix-command flakes" hash path ./dev/private | tr -d '\n' > ./dev/private.narHash
    '')
  ];
  # delve does not compile with hardening enabled
  hardeningDisable = [ "all" ];
}
