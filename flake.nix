{
  description = "Integrates sops into nixos";
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";

  nixConfig.extra-substituters = [ "https://cache.thalheim.io" ];
  nixConfig.extra-trusted-public-keys = [
    "cache.thalheim.io-1:R7msbosLEZKrxk/lKxf9BTjOOH7Ax3H0Qj0/6wiHOgc="
  ];
  outputs =
    {
      self,
      nixpkgs,
    }@inputs:
    let
      loadPrivateFlake =
        path:
        let
          flakeHash = builtins.readFile "${toString path}.narHash";
          flakePath = "path:${toString path}?narHash=${flakeHash}";
        in
        builtins.getFlake (builtins.unsafeDiscardStringContext flakePath);

      privateFlake = loadPrivateFlake ./dev/private;

      privateInputs = privateFlake.inputs;

      systems = [
        "x86_64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
        "aarch64-linux"
      ];

      eachSystem =
        f:
        builtins.listToAttrs (
          builtins.map (system: {
            name = system;
            value = f {
              pkgs = inputs.nixpkgs.legacyPackages.${system};
              inherit system;
            };
          }) systems
        );

    in
    # public outputs
    {
      overlays.default =
        final: prev:
        let
          localPkgs = import ./default.nix { pkgs = final; };
        in
        {
          inherit (localPkgs)
            sops-install-secrets
            sops-init-gpg-key
            sops-pgp-hook
            sops-import-keys-hook
            sops-ssh-to-age
            ;
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
      packages = eachSystem ({ pkgs, ... }: import ./default.nix { inherit pkgs; });
    }
    //
      # dev outputs
      {
        checks = eachSystem (
          { pkgs, system, ... }:
          let
            packages-stable = import ./default.nix {
              pkgs = privateInputs.nixpkgs-stable.legacyPackages.${system};
            };
            dropOverride = attrs: nixpkgs.lib.removeAttrs attrs [ "override" ];
            tests = dropOverride (pkgs.callPackage ./checks/nixos-test.nix { });
            tests-stable = dropOverride (
              privateInputs.nixpkgs-stable.legacyPackages.${system}.callPackage ./checks/nixos-test.nix { }
            );
            suffix-version =
              version: attrs:
              nixpkgs.lib.mapAttrs' (name: value: nixpkgs.lib.nameValuePair (name + version) value) attrs;
            suffix-stable = suffix-version "-24_05";
          in
          {
            home-manager = self.legacyPackages.${system}.homeConfigurations.sops.activation-script;
          }
          // (suffix-stable packages-stable)
          // nixpkgs.lib.optionalAttrs pkgs.stdenv.isLinux tests
          // nixpkgs.lib.optionalAttrs pkgs.stdenv.isLinux (suffix-stable tests-stable)
          // nixpkgs.lib.optionalAttrs pkgs.stdenv.isDarwin {
            darwin-sops =
              self.darwinConfigurations."sops-${pkgs.hostPlatform.darwinArch}".config.system.build.toplevel;
          }
        );

        darwinConfigurations.sops-arm64 = privateInputs.nix-darwin.lib.darwinSystem {
          modules = [
            ./checks/darwin.nix
            { nixpkgs.hostPlatform = "aarch64-darwin"; }
          ];
        };

        darwinConfigurations.sops-x86_64 = privateInputs.nix-darwin.lib.darwinSystem {
          modules = [
            ./checks/darwin.nix
            { nixpkgs.hostPlatform = "x86_64-darwin"; }
          ];
        };

        legacyPackages = eachSystem (
          { pkgs, ... }:
          {
            homeConfigurations.sops = privateInputs.home-manager.lib.homeManagerConfiguration {
              modules = [
                ./checks/home-manager.nix
              ];
              inherit pkgs;
            };
          }
        );

        apps = eachSystem (
          { pkgs, ... }:
          {
            update-dev-private-narHash = {
              type = "app";
              program = "${pkgs.writeShellScript "update-dev-private-narHash" ''
                nix --extra-experimental-features "nix-command flakes" flake lock ./dev/private
                nix --extra-experimental-features "nix-command flakes" hash path ./dev/private | tr -d '\n' > ./dev/private.narHash
              ''}";
            };
          }
        );

        devShells = eachSystem (
          { pkgs, ... }:
          {
            unit-tests = pkgs.callPackage ./pkgs/unit-tests.nix { };
            default = pkgs.callPackage ./shell.nix { };
          }
        );
      };
}
