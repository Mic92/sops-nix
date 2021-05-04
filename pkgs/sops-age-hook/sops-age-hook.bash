_sopsAddKey() {
  if [[ -f "$key" ]]; then
    export SOPS_AGE_RECIPIENTS=''${SOPS_AGE_RECIPIENTS:+$SOPS_AGE_RECIPIENTS','}$(<$key)
  else
    echo "$key does not exist" >&2
  fi
}

sopsAgeHook() {
  local key dir
  for key in ${sopsAgeKeys-}; do
      _sopsAddKey "$key"
  done
  for dir in ${sopsAgeKeyDirs-}; do
    while IFS= read -r -d '' key; do
      _sopsAddKey "$key"
    done < <(find -L "$dir" -type f -name '*.txt' -print0)
  done
}

if [ -z "${shellHook-}" ]; then
  shellHook=sopsAgeHook
else
  shellHook="sopsAgeHook;${shellHook}"
fi
