#!/usr/bin/env bash
# Derives the download URL, install directory and cache key for a Linux toolchain.
# Inputs (env): SWIFT_VERSION. Writes key=value lines to $GITHUB_OUTPUT.
set -euo pipefail

v="${SWIFT_VERSION:?SWIFT_VERSION is required}"
if [[ ! "$v" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]]; then
  echo "::error::swift-version must be an exact version like 6.4.1, got '$v'"
  exit 1
fi

# shellcheck disable=SC1091
. /etc/os-release
# Any Ubuntu release maps to swift.org's naming (ubuntu2604 / ubuntu26.04), so new releases work
# without a code change; a version swift.org does not publish fails at download time.
if [ "${ID:-}" = ubuntu ] && [[ "${VERSION_ID:-}" =~ ^[0-9]{2}\.[0-9]{2}$ ]]; then
  dir_platform="ubuntu${VERSION_ID//./}"
  file_platform="ubuntu${VERSION_ID}"
else
  echo "::error::Unsupported Linux distribution '${ID:-?} ${VERSION_ID:-?}'; setup-swift supports Ubuntu releases published on swift.org"
  exit 1
fi

case "$(uname -m)" in
  x86_64) arch=x86_64; arch_suffix="" ;;
  aarch64 | arm64) arch=aarch64; arch_suffix="-aarch64" ;;
  *)
    echo "::error::Unsupported architecture '$(uname -m)'"
    exit 1
    ;;
esac

base="https://download.swift.org/swift-${v}-release/${dir_platform}${arch_suffix}/swift-${v}-RELEASE"
file="swift-${v}-RELEASE-${file_platform}${arch_suffix}.tar.gz"
root="${RUNNER_TOOL_CACHE:-${RUNNER_TEMP:-/tmp}}"
# The toolchain lives under RUNNER_TEMP: private to this runner instance and emptied for every job.
case "${RUNNER_TEMP:-}" in
  /*) ;;
  *) echo "::error::RUNNER_TEMP must be set to an absolute path"; exit 1 ;;
esac

{
  echo "url=${base}/${file}"
  echo "file=${file}"
  echo "install-dir=${RUNNER_TEMP}/setup-swift/${v}/${arch}-${dir_platform}"
  echo "download-dir=${root}/swift-archives/${v}-${arch}-${dir_platform}"
  echo "cache-key=swift-toolchain-${v}-${dir_platform}-${arch}-archive-v2"
} >> "${GITHUB_OUTPUT:?}"
