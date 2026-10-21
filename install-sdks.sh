#!/usr/bin/env bash
# Installs Swift SDK bundles (static-linux, wasm, android) matching the toolchain.
# Each bundle's sha256 must equal the value pinned in sdk-checksums.txt; when gpg is
# available the published .sig must also verify against the pinned swift.org keys.
# Inputs (env): SWIFT_VERSION, SWIFT_SDKS (comma/space separated), optional ANDROID_NDK_HOME.
set -euo pipefail

v="${SWIFT_VERSION:?}"
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
requested="${SWIFT_SDKS//,/ }"

sha256_of() {
  if command -v sha256sum > /dev/null; then sha256sum "$1" | cut -d' ' -f1; else shasum -a 256 "$1" | cut -d' ' -f1; fi
}

work="$(mktemp -d "${RUNNER_TEMP:-/tmp}/setup-swift-sdk.XXXXXX")"
trap 'rm -r -f "$work"' EXIT

gpg_ok=0
if command -v gpg > /dev/null; then
  mkdir -m 700 "$work/gnupg"
  gpg --homedir "$work/gnupg" --batch --quiet --import "$here/swift-release-keys.asc"
  gpg_ok=1
fi

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
  curl --fail --silent --show-error --location --retry 5 --retry-delay 5 --retry-all-errors \
    --connect-timeout 30 --output "$work/$file" "$url" \
    || { echo "::error::Failed to download $url"; exit 1; }
  actual="$(sha256_of "$work/$file")"
  if [ "$actual" != "$expected" ]; then
    echo "::error::sha256 mismatch for $file: expected $expected, got $actual"
    exit 1
  fi
  echo "sha256 OK for $file"
  if [ "$gpg_ok" -eq 1 ]; then
    curl --fail --silent --show-error --location --retry 5 --retry-delay 5 --retry-all-errors \
      --output "$work/$file.sig" "$url.sig" || { echo "::error::Failed to download $url.sig"; exit 1; }
    status="$(gpg --homedir "$work/gnupg" --batch --status-fd 1 --verify "$work/$file.sig" "$work/$file" 2> /dev/null)" \
      || { echo "::error::GPG verification failed for $file"; exit 1; }
    signer="$(awk '$2 == "VALIDSIG" {print $NF}' <<< "$status")"
    case "$signer" in
      E813C892820A6FA13755B268F167DF1ACF9CE069 | 52BB7E3DE28A71BE22EC05FFEF80A866B47A981F) echo "GPG OK for $file ($signer)" ;;
      *) echo "::error::$file signed by unpinned key '${signer:-none}'"; exit 1 ;;
    esac
  fi

  # Local archives need no --checksum; integrity was verified above.
  swift sdk install "$work/$file"

  if [ "$kind" = android ]; then
    ndk="${ANDROID_NDK_HOME:-${ANDROID_NDK_LATEST_HOME:-${ANDROID_NDK_ROOT:-}}}"
    if [ -z "$ndk" ] || [ ! -d "$ndk" ]; then
      echo "::error::The Android SDK needs the Android NDK. Set ANDROID_NDK_HOME (GitHub-hosted Ubuntu and macOS images provide ANDROID_NDK_LATEST_HOME)."
      exit 1
    fi
    bundle="$(find "${HOME}/.swiftpm/swift-sdks" "${HOME}/Library/org.swift.swiftpm/swift-sdks" -maxdepth 1 -name "swift-${v}-RELEASE_android.artifactbundle" 2> /dev/null | head -1 || true)"
    setup="$(find "${bundle:-/nonexistent}" -maxdepth 3 -name 'setup-android-sdk.sh' 2> /dev/null | head -1 || true)"
    if [ -n "$setup" ]; then
      echo "Linking NDK sysroot with $setup (ANDROID_NDK_HOME=$ndk)"
      ANDROID_NDK_HOME="$ndk" bash "$setup"
    else
      echo "Android SDK bundle has no setup-android-sdk.sh; relying on ANDROID_NDK_HOME=$ndk"
    fi
    if [ -n "${GITHUB_ENV:-}" ]; then echo "ANDROID_NDK_HOME=$ndk" >> "$GITHUB_ENV"; fi
  fi
done

echo "Installed Swift SDKs:"
swift sdk list
if [ -n "${GITHUB_OUTPUT:-}" ]; then
  { echo "sdks<<EOF_SDKS"; swift sdk list; echo "EOF_SDKS"; } >> "$GITHUB_OUTPUT"
fi
