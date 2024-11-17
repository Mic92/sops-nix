{ pkgs, inputs, ... }:
inputs.treefmt-nix.lib.evalModule pkgs {
  projectRootFile = ".git/config";

  programs = {
    nixfmt.enable = true;

    deadnix.enable = true;
    deno.enable = true;
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
