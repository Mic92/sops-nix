{
  description = "Integrates sops into nixos";
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
  outputs = { self, nixpkgs }: let
    systems = [
      "x86_64-linux"
      "i686-linux"
      "x86_64-darwin"
      "aarch64-linux"
      "armv6l-linux"
      "armv7l-linux"
    ];
    forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f system);
  in {
    overlay = final: prev:
      let
        localPkgs = import ./default.nix { pkgs = final; };
      in {
        inherit (localPkgs) sops-install-secrets sops-init-gpg-key sops-pgp-hook;
        # backward compatibility
        inherit (prev) ssh-to-pgp;
      };
    nixosModules.sops = import ./modules/sops;
    nixosModule = self.nixosModules.sops;
    packages = forAllSystems (system: import ./default.nix {
      pkgs = import nixpkgs { inherit system; };
    });
    defaultPackage = forAllSystems (system: self.packages.${system}.sops-init-gpg-key);
  };
}
