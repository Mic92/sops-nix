# This file filters out all the broken packages from your package set.
# It's what gets built by CI, so if you correctly mark broken packages as
# broken your CI will not try to build them and the non-broken packages will
# be added to the cache.
{ pkgs ? import <nixpkgs> {} }:

pkgs.lib.filter (p:
  (builtins.isAttrs p)
  && !((builtins.hasAttr "meta" p)
    && (((builtins.hasAttr "broken" p.meta) && (p.meta.broken))
      || (builtins.hasAttr "available" p.meta && !p.meta.available))
  && !((builtins.hasAttr "disabled" p) && (p.disabled))))
  (pkgs.lib.collect (pkgs.lib.isDerivation) (import ./default.nix { inherit pkgs; }))
