with import <nixpkgs> {};
mkShell {
  nativeBuildInputs = [
    bashInteractive
    go
    delve
    gnupg
  ];
  hardeningDisable = [ "all" ];
}
