{
  pkgs ? import <nixpkgs> { },
}:
pkgs.mkShell {
  nativeBuildInputs = with pkgs; [
    go
    delve
    util-linux
    gnupg
  ];
}
