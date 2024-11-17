{
  description = "Integrates sops into nixos";
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
  inputs.nixpkgs-stable.url = "github:NixOS/nixpkgs/release-24.05";

  inputs.nix-darwin.url = "github:LnL7/nix-darwin";
  inputs.nix-darwin.inputs.nixpkgs.follows = "nixpkgs";

  nixConfig.extra-substituters = ["https://cache.thalheim.io"];
  nixConfig.extra-trusted-public-keys = ["cache.thalheim.io-1:R7msbosLEZKrxk/lKxf9BTjOOH7Ax3H0Qj0/6wiHOgc="];
  outputs = {
    self,
    nixpkgs,
    nixpkgs-stable,
    nix-darwin,
  } @ inputs: let
    systems = [
      "x86_64-linux"
      "x86_64-darwin"
      "aarch64-darwin"
      "aarch64-linux"
    ];
    forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f system);
    suffix-version = version: attrs: nixpkgs.lib.mapAttrs' (name: value: nixpkgs.lib.nameValuePair (name + version) value) attrs;
    suffix-stable = suffix-version "-24_05";
  in {
    overlays.default = final: prev: let
      localPkgs = import ./default.nix {pkgs = final;};
    in {
      inherit (localPkgs) sops-install-secrets sops-init-gpg-key sops-pgp-hook sops-import-keys-hook sops-ssh-to-age;
      # backward compatibility
      inherit (prev) ssh-to-pgp;
    };
    nixosModules = {
      sops = ./modules/sops;
      default = self.nixosModules.sops;
    };
    homeManagerModules.sops = ./modules/home-manager/sops.nix;
    homeManagerModule = self.homeManagerModules.sops;
    darwinModules = {
      sops = ./modules/nix-darwin;
      default = self.darwinModules.sops;
    };

    darwinConfigurations.sops = nix-darwin.lib.darwinSystem {
      modules = [ ./checks/darwin.nix ];
      specialArgs = {
        inherit self;
        inherit inputs;
      };
    };

    packages = forAllSystems (system:
      import ./default.nix {
        pkgs = import nixpkgs {inherit system;};
      });
    checks = nixpkgs.lib.genAttrs ["x86_64-linux" "aarch64-linux"]
      (system: let
        tests = self.packages.${system}.sops-install-secrets.tests;
        packages-stable = import ./default.nix {
          pkgs = import nixpkgs-stable {inherit system;};
        };
        tests-stable = packages-stable.sops-install-secrets.tests;
      in tests //
         (suffix-stable tests-stable) //
         (suffix-stable packages-stable));

    devShells = forAllSystems (system: let
      pkgs = nixpkgs.legacyPackages.${system};
    in {
      unit-tests = pkgs.callPackage ./pkgs/unit-tests.nix {};
      default = pkgs.callPackage ./shell.nix {};
    });
  };
}
