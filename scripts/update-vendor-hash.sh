#!/usr/bin/env nix-shell
#!nix-shell -i bash -p nix -p coreutils -p gnused -p gawk
# shellcheck shell=bash

set -exuo pipefail

failedbuild=$(nix build --impure --expr '(with import <nixpkgs> {}; pkgs.callPackage ./. { vendorHash = ""; }).sops-install-secrets' 2>&1 || true)
echo "$failedbuild"
checksum=$(echo "$failedbuild" | awk '/got:.*sha256/ { print $2 }')
sed -i -e "s|vendorHash ? \".*\"|vendorHash ? \"$checksum\"|" default.nix
