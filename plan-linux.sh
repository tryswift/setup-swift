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
case "${ID:-}-${VERSION_ID:-}" in
  ubuntu-20.04) dir_platform=ubuntu2004; file_platform=ubuntu20.04 ;;
  ubuntu-24.04) dir_platform=ubuntu2404; file_platform=ubuntu24.04 ;;
  ubuntu-22.04) dir_platform=ubuntu2204; file_platform=ubuntu22.04 ;;
  *)
    echo "::error::Unsupported Linux distribution '${ID:-?} ${VERSION_ID:-?}'; setup-swift supports Ubuntu 20.04, 22.04 and 24.04"
    exit 1
    ;;
esac

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

{
  echo "url=${base}/${file}"
  echo "file=${file}"
  echo "download-dir=${root}/swift-archives/${v}-${arch}-${dir_platform}"
  echo "cache-key=swift-toolchain-${v}-${dir_platform}-${arch}-archive-v2"
} >> "${GITHUB_OUTPUT:?}"
