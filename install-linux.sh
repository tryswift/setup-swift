#!/usr/bin/env bash
# Installs a swift.org Linux toolchain. The tarball and its .sig are verified with GPG on
# EVERY run (see verify-gpg.sh) and extracted into INSTALL_DIR, a deterministic per-version path (stable compiler paths keep SwiftPM
# build caches valid). INSTALL_DIR is removed completely before extraction, so nothing previously
# on disk is ever executed. DOWNLOAD_DIR may hold a cached copy of the archive
# pair to skip the download; it is re-verified before use. Without DOWNLOAD_DIR
# (cache: false) nothing on disk is reused.
# Inputs (env): SWIFT_URL, SWIFT_FILE, INSTALL_DIR; optional DOWNLOAD_DIR, GITHUB_PATH, GITHUB_OUTPUT.
set -euo pipefail

url="${SWIFT_URL:?}"
file="${SWIFT_FILE:?}"
dest="${INSTALL_DIR:?}"
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=verify-gpg.sh
. "$here/verify-gpg.sh"

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

scratch="$(mktemp -d "${RUNNER_TEMP:-/tmp}/setup-swift.XXXXXX")"
trap 'rm -r -f "$scratch"' EXIT

download() { # url dest
  curl --fail --silent --show-error --location --retry 5 --retry-delay 5 --retry-all-errors \
    --connect-timeout 30 --output "$2" "$1" \
    || { echo "::error::Failed to download $1"; return 1; }
}

if [ -n "${DOWNLOAD_DIR:-}" ]; then
  mkdir -p "$DOWNLOAD_DIR"
  archive_dir="$DOWNLOAD_DIR"
else
  archive_dir="$scratch/dl"
  mkdir "$archive_dir"
fi

if [ -f "$archive_dir/$file" ] && [ -f "$archive_dir/$file.sig" ]; then
  echo "Found cached archive $archive_dir/$file; it will be re-verified"
  source=cache
else
  source=download
  echo "Downloading $url"
  download "$url" "$archive_dir/$file.partial"
  download "$url.sig" "$archive_dir/$file.sig"
  mv "$archive_dir/$file.partial" "$archive_dir/$file"
fi

# Fail closed: a tampered cache entry is NOT replaced by a fresh download.
verify_gpg_signature "$archive_dir/$file" "$archive_dir/$file.sig" "$scratch"

# Refuse anything but an absolute .../swift-verified/<version>/<platform> path before deleting it.
case "$dest" in
  /*/swift-verified/*/*) ;;
  *) echo "::error::Refusing unexpected install directory '$dest'"; exit 1 ;;
esac
case "$dest" in
  *..* | */./* | *//*) echo "::error::Refusing unexpected install directory '$dest'"; exit 1 ;;
esac
# Never reuse existing contents: wipe, then extract only the archive verified above.
rm -r -f -- "$dest"
mkdir -p "$dest"
tar -xzf "$archive_dir/$file" -C "$dest" --strip-components=1
[ -x "$dest/usr/bin/swift" ] || { echo "::error::$dest/usr/bin/swift is missing after extraction"; exit 1; }
if [ -n "${GITHUB_PATH:-}" ]; then echo "$dest/usr/bin" >> "$GITHUB_PATH"; fi
if [ -n "${GITHUB_OUTPUT:-}" ]; then echo "source=$source" >> "$GITHUB_OUTPUT"; fi
echo "Installed Swift toolchain at $dest"
