{ pkgs, home-manager }:

let

  lib = import "${home-manager}/modules/lib/stdlib-extended.nix" pkgs.lib;

  nmtSrc = fetchTarball {
    url = "https://git.sr.ht/~rycee/nmt/archive/v0.5.1.tar.gz";
    sha256 = "0qhn7nnwdwzh910ss78ga2d00v42b0lspfd7ybl61mpfgz3lmdcj";
  };

  modules = import "${home-manager}/modules/modules.nix" {
    inherit lib pkgs;
    check = false;
  } ++ [{
    # Bypass <nixpkgs> reference inside modules/modules.nix to make the test
    # suite more pure.
    _module.args.pkgsPath = pkgs.path;

    # Fix impurities. Without these some of the user's environment
    # will leak into the tests through `builtins.getEnv`.
    xdg.enable = true;
    home = {
      username = "hm-user";
      homeDirectory = "/home/hm-user";
      stateVersion = lib.mkDefault "18.09";
    };

    # Avoid including documentation since this will cause
    # unnecessary rebuilds of the tests.
    manual.manpages.enable = lib.mkDefault false;

    # imports = [ ./asserts.nix ./big-test.nix ./stubs.nix ];
  }];

in import nmtSrc {
  inherit lib pkgs modules;
  testedAttrPath = [ "home" "activationPackage" ];
  tests = {
    default = (import ./hm-tests/basic.nix);
  };
}
