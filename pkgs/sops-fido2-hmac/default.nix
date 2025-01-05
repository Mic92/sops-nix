{
  lib,
  sops,
  runCommand,
  makeWrapper,
  age-plugin-fido2-hmac
}:
runCommand "sops" {
  nativeBuildInputs = [ makeWrapper ];
} ''
  mkdir -p $out/bin
  makeWrapper ${sops}/bin/sops $out/bin/sops \
    --prefix PATH : ${lib.makeBinPath [ age-plugin-fido2-hmac ]}
''