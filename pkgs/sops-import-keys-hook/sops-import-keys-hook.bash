_sopsAddKey() {
  @gpg@ --quiet --import "$key"
  local fpr
  # only add the first fingerprint, this way we ignore subkeys
  fpr=$(@gpg@ --with-fingerprint --with-colons --show-key "$key" \
         | awk -F: '$1 == "fpr" { print $10; exit }')
}

sopsImportKeysHook() {
  local key dir
  if [ -n "${sopsCreateGPGHome}" ]; then
    export GNUPGHOME=${sopsGPGHome:-$(pwd)/.git/gnupg}
    mkdir -m 700 -p $GNUPGHOME
  fi
  for key in ${sopsPGPKeys-}; do
    if [[ -f "$key" ]]; then
        _sopsAddKey "$key"
    else
        echo "$key does not exists" >&2
    fi
  done
  for dir in ${sopsPGPKeyDirs-}; do
    while IFS= read -r -d '' key; do
      _sopsAddKey "$key"
    done < <(find -L "$dir" -type f \( -name '*.gpg' -o -name '*.asc' \) -print0)
  done
}

if [ -z "${shellHook-}" ]; then
  shellHook=sopsImportKeysHook
else
  shellHook="sopsImportKeysHook;${shellHook}"
fi
