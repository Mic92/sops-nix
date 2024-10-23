{
  description = "Integrates sops into nixos";

  inputs = {
    home-manager.url =  "github:nix-community/home-manager";
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    nixpkgs-stable.url = "github:NixOS/nixpkgs/release-24.05";
  };

  nixConfig = {
    extra-substituters = ["https://cache.thalheim.io"];
    extra-trusted-public-keys = ["cache.thalheim.io-1:R7msbosLEZKrxk/lKxf9BTjOOH7Ax3H0Qj0/6wiHOgc="];
  };

  outputs = {
    self,
    home-manager,
    nixpkgs,
    nixpkgs-stable,
    ...
  }: let
    inherit (nixpkgs.lib) genAttrs mapAttrs' nameValuePair;

    mkFlakePkgs = pkgs: import ./default.nix { inherit home-manager pkgs; };

    forAllSystems = f: genAttrs systems (system: f system);
    systems = [
      "x86_64-linux"
      "x86_64-darwin"
      "aarch64-darwin"
      "aarch64-linux"
    ];

    suffix-stable = suffix-version "-24_05";
    suffix-version = version: attrs: mapAttrs' (name: value: nameValuePair (name + version) value) attrs;
  in {
    checks = genAttrs ["x86_64-linux" "aarch64-linux"]
      (system: let
        tests = self.packages.${system}.sops-install-secrets.tests;
        packages-stable = mkFlakePkgs (import nixpkgs-stable {inherit system;});
        tests-stable = packages-stable.sops-install-secrets.tests;
      in tests //
        (suffix-stable tests-stable) //
        (suffix-stable packages-stable));

    devShells = forAllSystems (system: let
      pkgs = nixpkgs.legacyPackages.${system};
    in {
      unit-tests = pkgs.callPackage ./pkgs/unit-tests.nix { inherit home-manager; };
      default = pkgs.callPackage ./shell.nix {};
      hm-tests = self.packages.${system}.sops-install-secrets.hm-tests;
    });

    homeManagerModule = self.homeManagerModules.sops;
    homeManagerModules.sops = import ./modules/home-manager/sops.nix;
    
    nixosModules = {
      sops = import ./modules/sops;
      default = self.nixosModules.sops;
    };

    overlays.default = final: prev: let
      localPkgs = mkFlakePkgs final;
    in {
      inherit (localPkgs) sops-install-secrets sops-init-gpg-key sops-pgp-hook sops-import-keys-hook sops-ssh-to-age;
      # backward compatibility
      inherit (prev) ssh-to-pgp;
    };
    
    packages = forAllSystems (system: mkFlakePkgs (import nixpkgs {inherit system;}));
  };
}
