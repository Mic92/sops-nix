{ pkgs, inputs, ... }:
inputs.treefmt-nix.lib.evalModule pkgs {
  projectRootFile = ".git/config";

  programs = {
    gofumpt.enable = true;

    nixfmt.enable = true;

    deadnix.enable = true;
    deno.enable = true;
    shellcheck.enable = true;
  };

  settings = {
    global.excludes = [
      "./pkgs/sops-install-secrets/test-assets/*"
      "*.narHash"
      # unsupported extensions
      "*.{asc,pub,gpg}"
      "*/secrets.{bin,json,ini,yaml}"
    ];

    formatter = {
      deadnix = {
        priority = 1;
      };
    };
  };
}
