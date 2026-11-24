{ cfg, lib }:

sopsCall:

let
  # sops >=3.10.0 now unconditionally searches
  # for an SSH key in $HOME/.ssh/, introduced in #1692 [0]. Since in the
  # activation script $HOME is never set, it just spits out a slew a
  # warnings [1].
  #
  # [0] https://github.com/Mic92/sops-nix/issues/764
  # [1] https://github.com/getsops/sops/pull/1692
  environment = cfg.environment // {
    HOME = "/var/empty";
    PATH = lib.makeBinPath cfg.age.plugins;
  };
in
''
  (
  ${lib.concatStringsSep "\n" (lib.mapAttrsToList (n: v: "  export ${n}='${v}'") environment)}
    ${sopsCall}
  )
''
