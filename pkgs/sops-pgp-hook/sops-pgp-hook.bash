_sopsAddKey() {
  @gpg@ --quiet --import "$key"
  local fpr
  fpr=$(@gpg@ --with-fingerprint --with-colons --show-key "$key" \
         | awk -F: '$1 == "fpr" { print $10;}')
  export SOPS_PGP_FP=''${SOPS_PGP_FP}''${SOPS_PGP_FP:+','}$fpr
}

sopsPGPHook() {
  local key dir
  for key in $sopsPGPKeys; do
    _sopsAddKey "$key"
  done
  for dir in $sopsPGPKeyDirs; do
    while IFS= read -r -d '' key; do
      _sopsAddKey "$key"
    done < <(find "$dir" -type f -name '*.gpg' -o -name '*.asc' -print0)
  done
}

if [ -z "${shellHook-}" ]; then
  shellHook=sopsPGPHook
fi
