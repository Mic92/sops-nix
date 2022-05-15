{
  description = "Integrates sops into nixos";
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
  inputs.nixpkgs-21_11.url = "github:NixOS/nixpkgs/release-21.11";
  nixConfig.extra-substituters = ["https://cache.garnix.io"];
  nixConfig.extra-trusted-public-keys = ["cache.garnix.io:CTFPyKSLcx5RMJKfLo5EEPUObbA78b0YQ2DTCJXqr9g="];
  outputs = {
    self,
    nixpkgs,
    nixpkgs-21_11
  }: let
    systems = [
      "x86_64-linux"
      "i686-linux"
      "x86_64-darwin"
      "aarch64-darwin"
      "aarch64-linux"
      "armv6l-linux"
      "armv7l-linux"
    ];
    forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f system);
    suffix-21_11 = attrs: nixpkgs.lib.mapAttrs' (name: value: nixpkgs.lib.nameValuePair (name + "-21_11") value) attrs;
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
        packages-21_11 = import ./default.nix {
          pkgs = import nixpkgs-21_11 {inherit system;};
        };
        tests-21_11 = packages-21_11.sops-install-secrets.tests;
      in tests // (suffix-21_11 tests-21_11) // (suffix-21_11 packages-21_11));

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
