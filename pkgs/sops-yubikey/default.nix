{
  sops,
  fetchFromGitHub,
  buildGoModule,
  age-plugin-yubikey,
  makeWrapper
}:

let
  version = "2024-03-18";
in
buildGoModule {
  pname = "sops-yubikey";
  inherit version;
  src = fetchFromGitHub {
    owner = "Mic92";
    repo = "sops";
    rev = "5d8afa98f9848369b5c0b27dfb7c2afd68c76acf";
    sha256 = "sha256-+pv7eJhwa7CjUD7uIdU5drpzReAw/qrb9JjWBvISlag=";
  };
  vendorSha256 = "sha256-DeeQodjVu9QtT0p+zCnVbGSAdSLLt8Y9SiOvKuaQ730=";

  subPackages = [ "cmd/sops" ];

  ldflags = [
    "-s"
    "-w"
    "-X github.com/getsops/sops/v3/version.Version=${version}"
  ];

  nativeBuildInputs = [ makeWrapper ];

  postInstall = ''
    wrapProgram $out/bin/sops --prefix PATH : ${age-plugin-yubikey}/bin
  '';

  inherit (sops) meta;
}
