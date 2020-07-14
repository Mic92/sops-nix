_sopsAddKey() {
  @gpg@ --quiet --import "$key"
  local fpr
  fpr=$(@gpg@ --with-fingerprint --with-colons --show-key "$key" \
         | awk -F: '$1 == "fpr" { print $10;}')
  if [[ $fpr != "" ]]; then
      export SOPS_PGP_FP=''${SOPS_PGP_FP}''${SOPS_PGP_FP:+','}$fpr
  fi
}

sopsPGPHook() {
  local key dir
  for key in $sopsPGPKeys; do
    if [[ -f "$key" ]]; then
        _sopsAddKey "$key"
    else
        echo "$key does not exists" >&2
    fi
  done
  for dir in $sopsPGPKeyDirs; do
    while IFS= read -r -d '' key; do
      _sopsAddKey "$key"
    done < <(find -L "$dir" -type f \( -name '*.gpg' -o -name '*.asc' \) -print0)
  done
}

if [ -z "${shellHook-}" ]; then
  shellHook=sopsPGPHook
fi
