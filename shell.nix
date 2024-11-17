{
  mkShell,
  bashInteractive,
  go,
  delve,
  gnupg,
  util-linux,
  nix,
  golangci-lint,
}:
mkShell {
  nativeBuildInputs = [
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
