{ sops-install-secrets, gox }:

sops-install-secrets.overrideAttrs (old: {
  name = "cross-build";
  nativeBuildInputs = old.nativeBuildInputs ++ [ gox ];
  buildPhase = ''
    (cd pkgs/sops-install-secrets && gox -os linux)
  '';
  doCheck = false;
  installPhase = ''
    touch $out $unittest
  '';
  fixupPhase = ":";
})
