{ ... }:

{
  nix.gc = {
    automatic = true;
    frequency = "monthly";
    options = "--delete-older-than 30d";
  };

  test.stubs.nix = { name = "nix"; };

  nmt.script = ''
  '';
}
