{ stdenv
, runCommand
, buildEnv
, lib
, fetchgit
, removeReferencesTo
, go
}:
let

  parseGoMod = import ./parser.nix;

  removeExpr = refs: ''remove-references-to ${lib.concatMapStrings (ref: " -t ${ref}") refs}'';

  buildGoApplication =
    { modules
    , src
    , pwd ? null
    , CGO_ENABLED ? "0"
    , nativeBuildInputs ? [ ]
    , allowGoReference ? false
    , meta ? { }
    , passthru ? { }
    , ...
    }@attrs:
    let
      modulesStruct = builtins.fromTOML (builtins.readFile modules);

      goMod = parseGoMod (builtins.readFile "${builtins.toString pwd}/go.mod");
      localReplaceCommands =
        let
          localReplaceAttrs = lib.filterAttrs (n: v: lib.hasAttr "path" v) goMod.replace;
          commands = (
            lib.mapAttrsToList
              (name: value: (
                ''
                  mkdir -p $(dirname vendor/${name})
                  ln -s ${pwd + "/${value.path}"} vendor/${name}
                ''
              ))
              localReplaceAttrs);
        in
        if pwd != null then commands else [ ];

      vendorEnv = runCommand "vendor-env"
        {
          nativeBuildInputs = [ go ];
          json = builtins.toJSON modulesStruct;

          sources = builtins.toJSON (lib.mapAttrs
            (goPackagePath: meta:
              let
                src = fetchgit {
                  inherit (meta.fetch) url sha256 rev;
                  fetchSubmodules = true;
                };
                srcPath = "${src}/${meta.relPath or ""}";
              in
              srcPath)
            modulesStruct);

          passAsFile = [ "json" "sources" ];
        }
        (
          ''
            mkdir vendor

            export GOCACHE=$TMPDIR/go-cache
            export GOPATH="$TMPDIR/go"

            go run ${./symlink.go}
            ${lib.concatStringsSep "\n" localReplaceCommands}

            find vendor

            mv vendor $out
          ''
        );

      removeReferences = [ ] ++ lib.optional (!allowGoReference) go;

      package = go.stdenv.mkDerivation (attrs // {
        nativeBuildInputs = [ removeReferencesTo go ] ++ nativeBuildInputs;

        inherit (go) GOOS GOARCH;
        inherit CGO_ENABLED;

        GO_NO_VENDOR_CHECKS = "1";

        GO111MODULE = "on";
        GOFLAGS = "-mod=vendor";

        configurePhase = attrs.configurePhase or ''
          runHook preConfigure

          export GOCACHE=$TMPDIR/go-cache
          export GOPATH="$TMPDIR/go"
          export GOSUMDB=off
          export GOPROXY=off
          cd "$modRoot"
          if [ -n "${vendorEnv}" ]; then
              rm -rf vendor
              ln -s ${vendorEnv} vendor
          fi

          runHook postConfigure
        '';

        buildPhase = attrs.buildPhase or ''
          runHook preBuild

          buildGoDir() {
            local d; local cmd;
            cmd="$1"
            d="$2"
            . $TMPDIR/buildFlagsArray
            echo "$d" | grep -q "\(/_\|examples\|Godeps\|testdata\)" && return 0
            [ -n "$excludedPackages" ] && echo "$d" | grep -q "$excludedPackages" && return 0
            local OUT
            if ! OUT="$(go $cmd $buildFlags "''${buildFlagsArray[@]}" -v -p $NIX_BUILD_CORES $d 2>&1)"; then
              if ! echo "$OUT" | grep -qE '(no( buildable| non-test)?|build constraints exclude all) Go (source )?files'; then
                echo "$OUT" >&2
                return 1
              fi
            fi
            if [ -n "$OUT" ]; then
              echo "$OUT" >&2
            fi
            return 0
          }

          getGoDirs() {
            local type;
            type="$1"
            if [ -n "$subPackages" ]; then
              echo "$subPackages" | sed "s,\(^\| \),\1./,g"
            else
              find . -type f -name \*$type.go -exec dirname {} \; | grep -v "/vendor/" | sort --unique
            fi
          }

          if (( "''${NIX_DEBUG:-0}" >= 1 )); then
            buildFlagsArray+=(-x)
          fi

          if [ ''${#buildFlagsArray[@]} -ne 0 ]; then
            declare -p buildFlagsArray > $TMPDIR/buildFlagsArray
          else
            touch $TMPDIR/buildFlagsArray
          fi
          if [ -z "$enableParallelBuilding" ]; then
              export NIX_BUILD_CORES=1
          fi
          for pkg in $(getGoDirs ""); do
            echo "Building subPackage $pkg"
            buildGoDir install "$pkg"
          done
        '' + lib.optionalString (stdenv.hostPlatform != stdenv.buildPlatform) ''
          # normalize cross-compiled builds w.r.t. native builds
          (
            dir=$GOPATH/bin/${go.GOOS}_${go.GOARCH}
            if [[ -n "$(shopt -s nullglob; echo $dir/*)" ]]; then
              mv $dir/* $dir/..
            fi
            if [[ -d $dir ]]; then
              rmdir $dir
            fi
          )
        '' + ''
          runHook postBuild
        '';

        doCheck = attrs.doCheck or true;
        checkPhase = attrs.checkPhase or ''
          runHook preCheck

          for pkg in $(getGoDirs test); do
            buildGoDir test "$pkg"
          done

          runHook postCheck
        '';

        installPhase = attrs.installPhase or ''
          runHook preInstall

          mkdir -p $out
          dir="$GOPATH/bin"
          [ -e "$dir" ] && cp -r $dir $out

          runHook postInstall
        '';

        preFixup = (attrs.preFixup or "") + ''
          find $out/{bin,libexec,lib} -type f 2>/dev/null | xargs -r ${removeExpr removeReferences} || true
        '';

        strictDeps = true;

        disallowedReferences = lib.optional (!allowGoReference) go;

        passthru = passthru // { inherit go vendorEnv; };

        meta = { platforms = go.meta.platforms or lib.platforms.all; } // meta;
      });

    in
    package;

in
buildGoApplication
