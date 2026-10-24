#!/usr/bin/env bash
# Installs a swift.org Linux toolchain. The tarball and its .sig are verified with GPG on
# EVERY run (see verify-gpg.sh) and extracted from a private snapshot (the very bytes that were verified) into INSTALL_DIR, a stable
# per-version path under RUNNER_TEMP (stable compiler paths keep SwiftPM build caches valid).
# INSTALL_DIR is removed completely first, so nothing previously on disk is ever executed. DOWNLOAD_DIR may hold a cached copy of the archive
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
  26.04) gcc_ver=15 ;;
  24.04) gcc_ver=13 ;;
  22.04) gcc_ver=12 ;;
  *) gcc_ver=10 ;;
esac
for pkg in curl gnupg2 binutils git libcurl4-openssl-dev libedit2 libsqlite3-0 libxml2-dev \
  libncurses-dev pkg-config tzdata uuid-dev zlib1g-dev "libgcc-${gcc_ver}-dev" "libstdc++-${gcc_ver}-dev"; do
  dpkg -s "$pkg" > /dev/null 2>&1 || missing+=("$pkg")
done
# The package lists a runner image ships are tried first, and refreshed only when that fails: the
# refresh is most of what installing a couple of packages costs.
apt_install() {
  "${sudo_cmd[@]}" env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends "$@" \
    || { "${sudo_cmd[@]}" apt-get update -qq \
      && "${sudo_cmd[@]}" env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends "$@"; }
}

# curl and gnupg2 download and verify the toolchain, so they have to be there first. Everything else
# is needed only to run it, and is installed in the background while the archive is fetched,
# verified and extracted, then waited for at the end.
needed_now=()
later=()
for pkg in "${missing[@]}"; do
  case "$pkg" in curl | gnupg2) needed_now+=("$pkg") ;; *) later+=("$pkg") ;; esac
done
if [ "${#needed_now[@]}" -gt 0 ]; then
  echo "Installing missing packages: ${needed_now[*]}"
  apt_install "${needed_now[@]}"
fi

scratch="$(mktemp -d "${RUNNER_TEMP:-/tmp}/setup-swift.XXXXXX")"
trap 'rm -r -f "$scratch"' EXIT

apt_pid=""
if [ "${#later[@]}" -gt 0 ]; then
  echo "Installing missing packages in the background: ${later[*]}"
  apt_install "${later[@]}" > "$scratch/apt.log" 2>&1 &
  apt_pid=$!
fi

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

# Work on a private snapshot: the cache path can be rewritten by others between verification
# and extraction, so verify and extract the very same copy.
snap="$scratch/snapshot"
mkdir "$snap"
cp "$archive_dir/$file" "$snap/$file"
cp "$archive_dir/$file.sig" "$snap/$file.sig"

# Fail closed: a tampered cache entry is NOT replaced by a fresh download.
verify_gpg_signature "$snap/$file" "$snap/$file.sig" "$scratch"

# The install directory must be exactly $RUNNER_TEMP/setup-swift/<version>/<platform>, with no
# symlink anywhere from RUNNER_TEMP down (checked again right before use).
case "${RUNNER_TEMP:-}" in
  /*) ;;
  *) echo "::error::RUNNER_TEMP must be set to an absolute path"; exit 1 ;;
esac
case "$dest" in
  "$RUNNER_TEMP"/setup-swift/*/*) ;;
  *) echo "::error::Refusing unexpected install directory '$dest'"; exit 1 ;;
esac
case "$dest" in
  *..* | */./* | *//* | */) echo "::error::Refusing unexpected install directory '$dest'"; exit 1 ;;
esac

assert_no_symlinks() { # path: every component from RUNNER_TEMP down must not be a symlink
  local cur="$RUNNER_TEMP" rest part
  [ ! -L "$cur" ] || { echo "::error::$cur is a symlink"; return 1; }
  rest="${1#"$RUNNER_TEMP"/}"
  while [ -n "$rest" ]; do
    part="${rest%%/*}"
    cur="$cur/$part"
    if [ -L "$cur" ]; then echo "::error::$cur is a symlink; refusing to install through it"; return 1; fi
    case "$rest" in */*) rest="${rest#*/}" ;; *) rest="" ;; esac
  done
}

(umask 077 && mkdir -p "$(dirname "$dest")")
assert_no_symlinks "$dest"
# Never reuse existing contents: wipe, then extract only the snapshot verified above.
rm -r -f -- "$dest"
mkdir "$dest"
assert_no_symlinks "$dest"
# pigz where the runner has it: inflation stays single-threaded, but pigz reads, writes and
# checksums on threads of its own.
if command -v pigz > /dev/null; then
  tar -I pigz -xf "$snap/$file" -C "$dest" --strip-components=1 --no-same-owner
else
  tar -xzf "$snap/$file" -C "$dest" --strip-components=1 --no-same-owner
fi
rm -r -f -- "$snap"
[ -x "$dest/usr/bin/swift" ] || { echo "::error::$dest/usr/bin/swift is missing after extraction"; exit 1; }
if [ -n "$apt_pid" ] && ! wait "$apt_pid"; then
  cat "$scratch/apt.log"
  echo "::error::Installing the packages the toolchain needs failed: ${later[*]}"
  exit 1
fi
if [ -n "${GITHUB_PATH:-}" ]; then echo "$dest/usr/bin" >> "$GITHUB_PATH"; fi
if [ -n "${GITHUB_OUTPUT:-}" ]; then echo "source=$source" >> "$GITHUB_OUTPUT"; fi
echo "Installed Swift toolchain at $dest"
