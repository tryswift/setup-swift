# setup-swift

A composite GitHub Action that installs an exact [swift.org](https://www.swift.org) toolchain and
**verifies it before use**. It contains no Node.js code (only `bash` steps, plus `actions/cache`).

```yaml
- uses: actions/checkout@v7
- uses: tryswift/setup-swift@v1
  with:
    swift-version: "6.4.1"
```

## Inputs

| Input | Required | Default | Description |
| --- | --- | --- | --- |
| `swift-version` | yes | | Exact toolchain version, e.g. `6.4.1` or `6.3.3`. Ranges and `latest` are not supported. |
| `cache` | no | `true` | Cache the extracted Linux toolchain with `actions/cache`. |

## Outputs

| Output | Description |
| --- | --- |
| `version` | Version reported by `swift --version`. |
| `swift-path` | Directory containing the active `swift` binary. |
| `source` | `preinstalled`, `cache`, `download` (Linux) or `pkg` (macOS). |

The action fails if `swift --version` does not report exactly the requested version afterwards.

## Behaviour and supported platforms

If `swift --version` already reports the requested version (some runner images preinstall one),
that toolchain is used and nothing is downloaded.

| Platform | Artifact | Verification |
| --- | --- | --- |
| Ubuntu 20.04 / 22.04 / 24.04, x86_64 and aarch64 | `swift-<v>-RELEASE-ubuntuNN.NN[-aarch64].tar.gz` | GPG `.sig` against pinned swift.org keys |
| macOS (any runner) | `swift-<v>-RELEASE-osx.pkg` | `pkgutil --check-signature`, notarization, pinned Developer ID team |

Other Linux distributions and architectures fail with an explicit error. Not every version is
published for every platform (for example, newer releases have no Ubuntu 20.04 build); a missing
download fails with the URL that was tried.

Linux: the toolchain is extracted to `$RUNNER_TOOL_CACHE/swift/<version>/<arch>-<platform>`, added to
`PATH` and cached (key: version, platform, arch). A cache hit skips the download; the toolchain was
verified when it was first installed. Missing build prerequisites (`libcurl4-openssl-dev`,
`libxml2-dev`, the GCC dev packages, ...) are installed with `apt-get` only if absent.

macOS: the package is installed into the user domain (`~/Library/Developer/Toolchains`), falling back to
`sudo installer -target /`. `TOOLCHAINS` is exported with the toolchain's bundle identifier and its
`usr/bin` is prepended to `PATH`. macOS installs are not cached.

## How verification works

Linux. The tarball and its `.sig` are downloaded, a temporary `GNUPGHOME` is created, and only the keys in
[`swift-release-keys.asc`](swift-release-keys.asc) are imported. `gpg --verify --status-fd` must report
`GOODSIG`, and the primary-key fingerprint in `VALIDSIG` must equal one of the fingerprints pinned in
[`install-linux.sh`](install-linux.sh). There is no trust-on-first-use and no network key fetch.

macOS. `pkgutil --check-signature` must succeed, the package must be notarized, and the leaf certificate
must be `Developer ID Installer: Swift Open Source (V9AUD2URP3)`. The team ID is pinned rather than the
certificate hash because the leaf certificate is renewed.

### Pinned keys

`swift-release-keys.asc` was exported from <https://www.swift.org/keys/all-keys.asc> (served gzip
compressed; use `curl --compressed`). The fingerprints were cross-checked against
<https://www.swift.org/install/linux/tarball/>:

| Key | Fingerprint |
| --- | --- |
| Swift Automatic Signing Key #4 | `E813 C892 820A 6FA1 3755  B268 F167 DF1A CF9C E069` |
| Swift 6.x Release Signing Key | `52BB 7E3D E28A 71BE 22EC  05FF EF80 A866 B47A 981F` |

### Updating the keys

1. Read the current fingerprints on <https://www.swift.org/install/linux/tarball/>.
2. `curl --compressed -O https://www.swift.org/keys/all-keys.asc`, import it into a scratch `GNUPGHOME`
   and confirm the new fingerprints match the web page.
3. Export the keys: `gpg --armor --export <FPR> ... > swift-release-keys.asc`.
4. Update `PINNED_FINGERPRINTS` in `install-linux.sh` and the table above, then run CI.

## Security notes

- Pin the action by commit SHA in sensitive workflows.
- The Linux cache stores an already-verified toolchain; caches are scoped per branch by GitHub, but a
  workflow that can write the cache can plant a toolchain. Set `cache: false` if that matters to you.
- Report vulnerabilities as described in [SECURITY.md](SECURITY.md).

## Development

CI (`.github/workflows/ci.yml`) runs shellcheck, actionlint, and installs 6.4.1 and 6.3.3 on
`ubuntu-22.04`, `ubuntu-24.04`, `ubuntu-24.04-arm` and `macos-latest`, then checks the cache-hit path.
