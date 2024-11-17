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
  sopsCreateGPGHome = "1";
  nativeBuildInputs = [
    (pkgs.callPackage ../../.. { }).sops-import-keys-hook
  ];
}
