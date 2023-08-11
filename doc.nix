{ nixosOptionsDoc, runCommand, fetchurl, pandoc, nixos, sops-nix-flake ? null }:

let
  eval = nixos [ ./modules/sops/default.nix ];
  options = nixosOptionsDoc {
    options = eval.options.sops;
  };
  rev = if sops-nix-flake != null then sops-nix-flake.rev or "master" else "master";
  
  md = (runCommand "options.md" { } ''
    cat >$out <<EOF
    # Sops-nix options

    EOF
    cat ${options.optionsCommonMark} >>$out
    sed -i -e 's!\[/nix/store/.*/modules/sops/\(.*\).*![sops-nix](https://github.com/Mic92/sops-nix/blob/${rev}/modules/sops/\1)!' "$out"
  '').overrideAttrs (_o: {
    # Work around https://github.com/hercules-ci/hercules-ci-agent/issues/168
    allowSubstitutes = true;
  });
  css = fetchurl {
    url = "https://gist.githubusercontent.com/killercup/5917178/raw/40840de5352083adb2693dc742e9f75dbb18650f/pandoc.css";
    sha256 = "sha256-SzSvxBIrylxBF6B/mOImLlZ+GvCfpWNLzGFViLyOeTk=";
  };
in
runCommand "sops.html" { nativeBuildInputs = [ pandoc ]; } ''
  mkdir $out
  cp ${css} $out/pandoc.css
  pandoc --css="pandoc.css" ${md} --to=html5 -s -f markdown+smart --metadata pagetitle="Sops options" -o $out/index.html
''
