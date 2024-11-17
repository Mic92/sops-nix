{
  description = "private inputs";
  inputs.nixpkgs-stable.url = "github:NixOS/nixpkgs/release-24.05";

  inputs.treefmt-nix.url = "github:numtide/treefmt-nix";
  inputs.treefmt-nix.inputs.nixpkgs.follows = "nixpkgs-stable";

  outputs = _: { };
}
