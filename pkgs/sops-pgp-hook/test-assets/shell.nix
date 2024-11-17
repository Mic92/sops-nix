# shell.nix
with import <nixpkgs> { };
mkShell {
  sopsPGPKeyDirs = [
    "./keys"
  ];
  sopsPGPKeys = [
    "./existing-key.gpg"
    "./non-existing-key.gpg"
  ];
  nativeBuildInputs = [
    (pkgs.callPackage ../../.. { }).sops-pgp-hook
  ];
}
