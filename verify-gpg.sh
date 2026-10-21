#!/usr/bin/env bash
# Shared GPG policy, sourced by install-linux.sh and install-sdks.sh.
#
# verify_gpg_signature <file> <detached .sig> <scratch dir>
# Requires exactly one GOODSIG and one VALIDSIG whose primary-key fingerprint is pinned,
# and rejects expired/revoked keys, expired/bad/errored signatures and unknown keys.
# Keys come only from swift-release-keys.asc, imported into a fresh GNUPGHOME.

# Fingerprints from https://www.swift.org/install/linux/tarball/ ; see README.md.
# Automatic Signing Key #4, Swift 6.x Release Signing Key.
PINNED_FINGERPRINTS=(
  E813C892820A6FA13755B268F167DF1ACF9CE069
  52BB7E3DE28A71BE22EC05FFEF80A866B47A981F
)

verify_gpg_signature() {
  local file="$1" sig="$2" scratch="$3" here gnupg status signer fp ok=0
  here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  gnupg="$(mktemp -d "$scratch/gnupg.XXXXXX")"
  chmod 700 "$gnupg"
  gpg --homedir "$gnupg" --batch --quiet --import "$here/swift-release-keys.asc"
  status="$(gpg --homedir "$gnupg" --batch --status-fd 1 --verify "$sig" "$file" 2> "$gnupg/gpg.err")" || {
    cat "$gnupg/gpg.err"
    echo "::error::GPG signature verification FAILED for $(basename "$file")"
    return 1
  }
  if grep -q -E '^\[GNUPG:\] (EXPKEYSIG|REVKEYSIG|EXPSIG|BADSIG|ERRSIG|NO_PUBKEY) ' <<< "$status"; then
    echo "::error::Unacceptable GPG status for $(basename "$file") (expired, revoked, bad or unknown key)"
    return 1
  fi
  if [ "$(grep -c -E '^\[GNUPG:\] GOODSIG ' <<< "$status")" -ne 1 ] \
    || [ "$(grep -c -E '^\[GNUPG:\] VALIDSIG ' <<< "$status")" -ne 1 ]; then
    echo "::error::Expected exactly one good signature on $(basename "$file")"
    return 1
  fi
  # VALIDSIG's last field is the fingerprint of the signer's primary key.
  signer="$(awk '$2 == "VALIDSIG" {print $NF}' <<< "$status")"
  for fp in "${PINNED_FINGERPRINTS[@]}"; do
    if [ "$signer" = "$fp" ]; then ok=1; fi
  done
  if [ "$ok" -ne 1 ]; then
    echo "::error::$(basename "$file") is not signed by a pinned Swift release key (signer: '${signer:-none}')"
    return 1
  fi
  echo "Verified GPG signature of $(basename "$file") (VALIDSIG primary key $signer)"
}
