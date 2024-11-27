{
  description = "private inputs";
  inputs.nixpkgs-stable.url = "github:NixOS/nixpkgs/release-24.05";

  inputs.treefmt-nix.url = "github:numtide/treefmt-nix";
  inputs.treefmt-nix.inputs.nixpkgs.follows = "nixpkgs-stable";

  inputs.nix-darwin.url = "github:LnL7/nix-darwin";
  inputs.nix-darwin.inputs.nixpkgs.follows = "nixpkgs-stable";

  inputs.home-manager.url = "github:nix-community/home-manager";
  inputs.home-manager.inputs.nixpkgs.follows = "nixpkgs-stable";

  outputs = _: { };
}
