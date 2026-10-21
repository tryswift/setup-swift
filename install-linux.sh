#!/usr/bin/env bash
# Installs a swift.org Linux toolchain, requiring a valid GPG signature from a
# pinned swift.org release signing key. Skips the download when INSTALL_DIR was
# restored from the Actions cache (it was verified when first installed).
# Inputs (env): SWIFT_URL, SWIFT_FILE, INSTALL_DIR; optional GITHUB_PATH.
set -euo pipefail

url="${SWIFT_URL:?}"
file="${SWIFT_FILE:?}"
dir="${INSTALL_DIR:?}"
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Fingerprints from https://www.swift.org/install/linux/tarball/ ; see README.md.
# Automatic Signing Key #4, Swift 6.x Release Signing Key.
PINNED_FINGERPRINTS=(
  E813C892820A6FA13755B268F167DF1ACF9CE069
  52BB7E3DE28A71BE22EC05FFEF80A866B47A981F
)

sudo_cmd=()
[ "$(id -u)" -eq 0 ] || sudo_cmd=(sudo)

# Tools needed to verify and to run the toolchain; install only what is missing.
missing=()
# GCC development packages per swift.org's prerequisites for each Ubuntu release.
# shellcheck disable=SC1091
case "$(. /etc/os-release && echo "${VERSION_ID:-}")" in
  24.04) gcc_ver=13 ;;
  22.04) gcc_ver=12 ;;
  *) gcc_ver=10 ;;
esac
for pkg in curl gnupg2 binutils git libcurl4-openssl-dev libedit2 libsqlite3-0 libxml2-dev \
  libncurses-dev pkg-config tzdata uuid-dev zlib1g-dev "libgcc-${gcc_ver}-dev" "libstdc++-${gcc_ver}-dev"; do
  dpkg -s "$pkg" > /dev/null 2>&1 || missing+=("$pkg")
done
if [ "${#missing[@]}" -gt 0 ]; then
  echo "Installing missing packages: ${missing[*]}"
  "${sudo_cmd[@]}" apt-get update -qq
  "${sudo_cmd[@]}" env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends "${missing[@]}"
fi

if [ -x "$dir/usr/bin/swift" ]; then
  echo "Using cached toolchain at $dir"
  source=cache
else
  source=download
  work="$(mktemp -d "${RUNNER_TEMP:-/tmp}/setup-swift.XXXXXX")"
  trap 'rm -r -f "$work"' EXIT
  gnupg="$work/gnupg"
  mkdir -m 700 "$gnupg"

  download() { # url dest
    curl --fail --silent --show-error --location --retry 5 --retry-delay 5 --retry-all-errors \
      --connect-timeout 30 --output "$2" "$1" \
      || { echo "::error::Failed to download $1"; return 1; }
  }
  echo "Downloading $url"
  download "$url" "$work/$file"
  download "$url.sig" "$work/$file.sig"

  gpg --homedir "$gnupg" --batch --quiet --import "$here/swift-release-keys.asc"
  status="$(gpg --homedir "$gnupg" --batch --status-fd 1 --verify "$work/$file.sig" "$work/$file" 2> "$work/gpg.err")" || {
    cat "$work/gpg.err"
    echo "::error::GPG signature verification FAILED for $file"
    exit 1
  }
  # VALIDSIG's last field is the fingerprint of the signer's primary key.
  signer="$(awk '$2 == "VALIDSIG" {print $NF}' <<< "$status")"
  good="$(awk '$2 == "GOODSIG"' <<< "$status")"
  ok=0
  for fp in "${PINNED_FINGERPRINTS[@]}"; do
    if [ -n "$good" ] && [ "$signer" = "$fp" ]; then ok=1; fi
  done
  if [ "$ok" -ne 1 ]; then
    echo "::error::$file is not signed by a pinned Swift release key (signer: '${signer:-none}')"
    exit 1
  fi
  echo "Verified GPG signature of $file (VALIDSIG primary key $signer)"

  mkdir -p "$(dirname "$dir")"
  rm -r -f "$dir.partial"
  mkdir "$dir.partial"
  tar -xzf "$work/$file" -C "$dir.partial" --strip-components=1
  rm -r -f "$dir"
  mv "$dir.partial" "$dir"
fi

[ -x "$dir/usr/bin/swift" ] || { echo "::error::$dir/usr/bin/swift is missing after install"; exit 1; }
if [ -n "${GITHUB_PATH:-}" ]; then echo "$dir/usr/bin" >> "$GITHUB_PATH"; fi
if [ -n "${GITHUB_OUTPUT:-}" ]; then echo "source=$source" >> "$GITHUB_OUTPUT"; fi
