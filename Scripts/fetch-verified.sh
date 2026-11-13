# Sourced by setup scripts after changing to the project root.
fetch_verified() {
  local url="$1" destination="$2" checksum="$3"
  local partial="$destination.partial"
  if ! printf '%s  %s\n' "$checksum" "$destination" | shasum -a 256 -c - >/dev/null 2>&1; then
    if ! printf '%s  %s\n' "$checksum" "$partial" | shasum -a 256 -c - >/dev/null 2>&1; then
      curl --fail --location --retry 3 --retry-all-errors --continue-at - "$url" -o "$partial"
      if ! printf '%s  %s\n' "$checksum" "$partial" | shasum -a 256 -c -; then
        rm -f "$partial"
        return 1
      fi
    fi
    mv "$partial" "$destination"
  fi
  chmod 600 "$destination"
}
