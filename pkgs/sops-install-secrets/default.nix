{ buildGoModule }:
buildGoModule {
  pname = "sops-install-secrets";
  version = "0.0.1";

  hardeningDisable = [ "all" ];

  src = ./.;

  vendorSha256 = "1ky7xzsx12d8m4kvqkayqzybkf3s0w21d6m8qlhvrm00fmyidkxj";
  shellHook = ''
    unset GOFLAGS
  '';
}
