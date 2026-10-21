#!/usr/bin/env bash
# Installs Swift SDK bundles (static-linux, wasm, android) matching the toolchain.
# Each bundle's sha256 must equal the value pinned in sdk-checksums.txt; when gpg is
# available the published .sig must also verify (verify-gpg.sh policy).
# Inputs (env): SWIFT_VERSION, SWIFT_SDKS (comma/space separated), optional ANDROID_NDK_HOME.
set -euo pipefail

v="${SWIFT_VERSION:?}"
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=verify-gpg.sh
. "$here/verify-gpg.sh"
requested="${SWIFT_SDKS//,/ }"

sha256_of() {
  if command -v sha256sum > /dev/null; then sha256sum "$1" | cut -d' ' -f1; else shasum -a 256 "$1" | cut -d' ' -f1; fi
}

work="$(mktemp -d "${RUNNER_TEMP:-/tmp}/setup-swift-sdk.XXXXXX")"
trap 'rm -r -f "$work"' EXIT

fetch() { # url dest
  curl --fail --silent --show-error --location --retry 5 --retry-delay 5 --retry-all-errors \
    --connect-timeout 30 --output "$2" "$1" || { echo "::error::Failed to download $1"; return 1; }
}

# Directories where SwiftPM may keep installed SDK bundles (platform dependent).
sdk_stores=("${HOME}/.swiftpm/swift-sdks" "${HOME}/.config/swiftpm/swift-sdks" "${HOME}/Library/org.swift.swiftpm/swift-sdks")

for kind in $requested; do
  case "$kind" in
    static-linux) dir=static-sdk; file="swift-${v}-RELEASE_static-linux-0.1.0.artifactbundle.tar.gz" ;;
    wasm) dir=wasm-sdk; file="swift-${v}-RELEASE_wasm.artifactbundle.tar.gz" ;;
    android) dir=android-sdk; file="swift-${v}-RELEASE_android.artifactbundle.tar.gz" ;;
    *) echo "::error::Unknown swift-sdks entry '$kind' (expected static-linux, wasm or android)"; exit 1 ;;
  esac
  expected="$(awk -v v="$v" -v k="$kind" '$1 == v && $2 == k {print $3}' "$here/sdk-checksums.txt")"
  if [ -z "$expected" ]; then
    echo "::error::No pinned checksum for the '$kind' SDK at Swift $v; add it to sdk-checksums.txt (see README)"
    exit 1
  fi
  url="https://download.swift.org/swift-${v}-release/${dir}/swift-${v}-RELEASE/${file}"
  echo "Downloading $url"
  fetch "$url" "$work/$file"
  actual="$(sha256_of "$work/$file")"
  if [ "$actual" != "$expected" ]; then
    echo "::error::sha256 mismatch for $file: expected $expected, got $actual"
    exit 1
  fi
  echo "sha256 OK for $file"
  if command -v gpg > /dev/null; then
    fetch "$url.sig" "$work/$file.sig"
    verify_gpg_signature "$work/$file" "$work/$file.sig" "$work"
  else
    echo "::warning::gpg not found; relying on the pinned sha256 only for $file"
  fi

  bundle_name="swift-${v}-RELEASE_$([ "$kind" = static-linux ] && echo static-linux-0.1.0 || echo "$kind").artifactbundle"
  if [ "$kind" = android ]; then
    # A pre-existing bundle (stale or planted) must never be the source of the helper script.
    for store in "${sdk_stores[@]}"; do
      if [ -e "$store/$bundle_name" ] || [ -L "$store/$bundle_name" ]; then
        echo "::error::$store/$bundle_name already exists; remove it so the verified bundle is installed"
        exit 1
      fi
    done
  fi

  # Local archives need no --checksum; integrity was verified above.
  swift sdk install "$work/$file"

  if [ "$kind" = android ]; then
    ndk="${ANDROID_NDK_HOME:-${ANDROID_NDK_LATEST_HOME:-${ANDROID_NDK_ROOT:-}}}"
    if [ -z "$ndk" ] || [ ! -d "$ndk" ]; then
      echo "::error::The Android SDK needs the Android NDK. Set ANDROID_NDK_HOME (GitHub-hosted Ubuntu and macOS images provide ANDROID_NDK_LATEST_HOME)."
      exit 1
    fi
    # The helper in the installed bundle must be byte-identical to the one in the verified archive.
    member="$(tar -tzf "$work/$file" | grep -E '(^|/)scripts/setup-android-sdk\.sh$' || true)"
    if [ "$(grep -c . <<< "$member")" -gt 1 ]; then
      echo "::error::Android bundle contains several setup-android-sdk.sh files"
      exit 1
    fi
    if [ -n "$member" ]; then
      mkdir "$work/helper"
      tar -xzf "$work/$file" -C "$work/helper" "$member"
      installed=()
      for store in "${sdk_stores[@]}"; do
        [ -d "$store/$bundle_name" ] && installed+=("$store/$bundle_name")
      done
      if [ "${#installed[@]}" -ne 1 ]; then
        echo "::error::Expected exactly one installed $bundle_name, found ${#installed[@]}"
        exit 1
      fi
      setup="${installed[0]}/${member#*/}"
      if [ -L "$setup" ] || [ ! -f "$setup" ] || ! cmp -s "$setup" "$work/helper/$member"; then
        echo "::error::Installed setup-android-sdk.sh does not match the verified archive"
        exit 1
      fi
      echo "Linking NDK sysroot with $setup (ANDROID_NDK_HOME=$ndk)"
      ANDROID_NDK_HOME="$ndk" bash "$setup"
    else
      echo "Android SDK bundle has no setup-android-sdk.sh; relying on ANDROID_NDK_HOME=$ndk"
    fi
    if [ -n "${GITHUB_ENV:-}" ]; then
      { echo "ANDROID_NDK_HOME=$ndk"; echo "ANDROID_NDK_ROOT=$ndk"; } >> "$GITHUB_ENV"
    fi
  fi
  rm -f "$work/$file" "$work/$file.sig"
done

echo "Installed Swift SDKs:"
swift sdk list
if [ -n "${GITHUB_OUTPUT:-}" ]; then
  { echo "sdks<<EOF_SDKS"; swift sdk list; echo "EOF_SDKS"; } >> "$GITHUB_OUTPUT"
fi
