#!/usr/bin/env bash
# Installs a swift.org macOS toolchain .pkg after requiring a notarized package
# signed by the Swift Open Source Developer ID team.
# Inputs (env): SWIFT_VERSION; optional GITHUB_PATH / GITHUB_ENV;
# VERIFY_ONLY=1 stops after the signature check (used for local testing).
set -euo pipefail

v="${SWIFT_VERSION:?}"
# Leaf certificate rotates, so pin the Developer ID team (V9AUD2URP3), see README.md.
EXPECTED_SIGNER="Developer ID Installer: Swift Open Source (V9AUD2URP3)"

work="$(mktemp -d "${RUNNER_TEMP:-/tmp}/setup-swift.XXXXXX")"
trap 'rm -r -f "$work"' EXIT
pkg="$work/swift-${v}-RELEASE-osx.pkg"
url="https://download.swift.org/swift-${v}-release/xcode/swift-${v}-RELEASE/swift-${v}-RELEASE-osx.pkg"

# A cached .pkg is copied into this run's private directory and checked there, like a download: the
# cache directory can be rewritten between a check and a use, the private copy cannot.
cached=""
[ -z "${INSTALLER_CACHE_DIR:-}" ] || cached="$INSTALLER_CACHE_DIR/$(basename "$pkg")"
from_cache=""
if [ -n "$cached" ] && [ -f "$cached" ]; then
  echo "Found cached package $cached; it will be re-verified"
  cp "$cached" "$pkg"
  from_cache=1
else
  echo "Downloading $url"
  curl --fail --silent --show-error --location --retry 5 --retry-delay 5 --retry-all-errors \
    --connect-timeout 30 --output "$pkg" "$url" \
    || { echo "::error::Failed to download $url"; exit 1; }
fi

sig="$(pkgutil --check-signature "$pkg")" || { echo "$sig"; echo "::error::pkgutil signature check failed"; exit 1; }
echo "$sig"
grep -qF "1. $EXPECTED_SIGNER" <<< "$sig" \
  || { echo "::error::Package is not signed by '$EXPECTED_SIGNER'"; exit 1; }
grep -qF "Notarization: trusted by the Apple notary service" <<< "$sig" \
  || { echo "::error::Package is not notarized"; exit 1; }
# Only bytes that just passed the check go into the cache; actions/cache saves the directory after
# the job. A cached copy that fails the check fails the job rather than being replaced.
if [ -n "$cached" ] && [ -z "$from_cache" ]; then
  mkdir -p "$INSTALLER_CACHE_DIR"
  cp "$pkg" "$cached"
fi
if [ -n "${VERIFY_ONLY:-}" ]; then echo "VERIFY_ONLY set: signature OK, not installing"; exit 0; fi

# Prefer the per-user domain (no root needed); fall back to the system domain.
if installer -pkg "$pkg" -target CurrentUserHomeDirectory; then
  tc_root="${HOME}/Library/Developer/Toolchains"
else
  sudo installer -pkg "$pkg" -target /
  tc_root="/Library/Developer/Toolchains"
fi

tc="$tc_root/swift-${v}-RELEASE.xctoolchain"
[ -d "$tc" ] || { echo "::error::Expected toolchain not found at $tc"; exit 1; }
id="$(plutil -extract CFBundleIdentifier raw -o - "$tc/Info.plist")"
echo "Installed $tc ($id)"
source=pkg
[ -z "$from_cache" ] || source=cache
if [ -n "${GITHUB_OUTPUT:-}" ]; then echo "source=$source" >> "$GITHUB_OUTPUT"; fi
if [ -n "${GITHUB_ENV:-}" ]; then echo "TOOLCHAINS=$id" >> "$GITHUB_ENV"; fi
if [ -n "${GITHUB_PATH:-}" ]; then echo "$tc/usr/bin" >> "$GITHUB_PATH"; fi
