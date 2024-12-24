{ age-plugin-fido2-hmac
, runCommand
, makeWrapper
, lib
, age
}:

runCommand "age" {
  nativeBuildInputs = [ makeWrapper ];
} ''
  mkdir -p $out/bin
  makeWrapper ${age}/bin/age $out/bin/age \
    --prefix PATH : ${lib.makeBinPath [ age-plugin-fido2-hmac ]}
''