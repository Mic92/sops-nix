{
  sops,
  fetchFromGitHub,
  buildGoModule,
  age-plugin-fido2-hmac,
  makeWrapper
}:

let
  version = "2024-11-23";
in
buildGoModule {
  pname = "sops-fido2-hmac";
  inherit version;
  src = fetchFromGitHub {
    owner = "brianmcgee";
    repo = "sops";
    rev = "0607eae847f1ae21205b5e2a919de6d5868f6395";
    sha256 = "sha256-mWsIg9TXGlA8EuFD7Pb0w8PsD3LvCMCy1X9OTITxvsU=";
  };
  vendorHash = "sha256-NS0b25NQEJle///iRHAG3uTC5p6rlGSyHVwEESki3p4=";

  subPackages = [ "cmd/sops" ];

  ldflags = [
    "-s"
    "-w"
    "-X github.com/getsops/sops/v3/version.Version=${version}"
  ];

  nativeBuildInputs = [ makeWrapper ];

  postInstall = ''
    wrapProgram $out/bin/sops --prefix PATH : ${age-plugin-fido2-hmac}/bin
  '';

  inherit (sops) meta;
}