{
  description = "Integrates sops into nixos";
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
  inputs.nixpkgs-22_05.url = "github:NixOS/nixpkgs/release-22.05";
  nixConfig.extra-substituters = ["https://cache.garnix.io"];
  nixConfig.extra-trusted-public-keys = ["cache.garnix.io:CTFPyKSLcx5RMJKfLo5EEPUObbA78b0YQ2DTCJXqr9g="];
  outputs = {
    self,
    nixpkgs,
    nixpkgs-22_05
  }: let
    systems = [
      "x86_64-linux"
      "x86_64-darwin"
      "aarch64-darwin"
      "aarch64-linux"
    ];
    forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f system);
    suffix-version = version: attrs: nixpkgs.lib.mapAttrs' (name: value: nixpkgs.lib.nameValuePair (name + version) value) attrs;
    suffix-22_05 = suffix-version "-22_05";
  in {
    overlay = final: prev: let
      localPkgs = import ./default.nix {pkgs = final;};
    in {
      inherit (localPkgs) sops-install-secrets sops-init-gpg-key sops-pgp-hook sops-import-keys-hook sops-ssh-to-age;
      # backward compatibility
      inherit (prev) ssh-to-pgp;
    };
    nixosModules.sops = import ./modules/sops;
    nixosModule = self.nixosModules.sops;
    packages = forAllSystems (system:
      import ./default.nix {
        pkgs = import nixpkgs {inherit system;};
      });
    checks = nixpkgs.lib.genAttrs ["x86_64-linux" "aarch64-linux"]
      (system: let
        tests = self.packages.${system}.sops-install-secrets.tests;
        packages-22_05 = import ./default.nix {
          pkgs = import nixpkgs-22_05 {inherit system;};
        };
        tests-22_05 = packages-22_05.sops-install-secrets.tests;
      in tests //
         (suffix-22_05 tests-22_05) //
         (suffix-22_05 packages-22_05));

    defaultPackage = forAllSystems (system: self.packages.${system}.sops-init-gpg-key);
    devShell = forAllSystems (
      system:
        nixpkgs.legacyPackages.${system}.callPackage ./shell.nix {}
    );
    devShells = forAllSystems (system: {
      unit-tests = nixpkgs.legacyPackages.${system}.callPackage ./pkgs/unit-tests.nix {};
    });
  };
}
