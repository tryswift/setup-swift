# try! Swift Setup (`tryswift/setup-swift`)

[![CI](https://github.com/tryswift/setup-swift/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/tryswift/setup-swift/actions/workflows/ci.yml)
![Ubuntu x86_64 | aarch64](https://img.shields.io/badge/Ubuntu-x86__64%20%7C%20aarch64-E95420?logo=ubuntu&logoColor=white)
![macOS](https://img.shields.io/badge/macOS-Apple%20silicon%20%7C%20Intel-000000?logo=apple&logoColor=white)
![Windows x86_64 | arm64](https://img.shields.io/badge/Windows-x86__64%20%7C%20arm64-0078D4?logo=windows&logoColor=white)
![Swift SDKs](https://img.shields.io/badge/Swift%20SDKs-static%20Linux%20%7C%20Wasm%20%7C%20Android-F05138?logo=swift&logoColor=white)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![try! Swift Tokyo](https://img.shields.io/badge/try!%20Swift-Tokyo-F05138?logo=swift&logoColor=white)](https://tryswift.jp)

A composite GitHub Action that installs an exact [swift.org](https://www.swift.org) toolchain and
**verifies the toolchain it installs before use** (Linux: GPG, macOS: Apple signature and team, Windows: Authenticode;
see [How verification works](#how-verification-works)). It never runs a pre-existing `swift` unless you opt in with
`use-preinstalled` (unverified). It contains no Node.js code (only `bash` steps, plus `actions/cache`).

```yaml
- uses: actions/checkout@v7
- uses: tryswift/setup-swift@v1
  with:
    swift-version: "6.4.1"
```

`@v1` follows the latest 1.x release. To pin, use a release tag (`@v1.1.0`) or, for the strongest guarantee,
the commit SHA that tag points at.

On Windows, arm64 needs the `+NoAsserts` toolchain ([swiftlang/swift#92379](https://github.com/swiftlang/swift/issues/92379)),
and a CI build can leave out the debugger, its Python and the Android platform to shorten the install:

```yaml
jobs:
  build:
    strategy:
      matrix:
        os: [windows-latest, windows-11-arm]
    runs-on: ${{ matrix.os }}
    steps:
      - uses: actions/checkout@v7
      - uses: tryswift/setup-swift@v1
        with:
          swift-version: "6.4.1"
          windows-toolchain-variant: noasserts
          windows-minimal: true
      - run: swift build
```

## Inputs

| Input | Required | Default | Description |
| --- | --- | --- | --- |
| `swift-version` | yes | | Exact toolchain version, e.g. `6.4.1` or `6.3.3`. Ranges and `latest` are not supported. |
| `swift-sdks` | no | | Cross-compilation Swift SDKs to install after the toolchain: `static-linux`, `wasm`, `android` (comma or space separated). |
| `use-preinstalled` | no | `false` | **Unverified opt-in.** If `swift` on `PATH` already reports exactly `swift-version`, run and use it instead of installing. By default no pre-existing binary is ever executed. |
| `windows-toolchain-variant` | no | `asserts` | Windows only. `asserts` keeps the installer's default `+Asserts` toolchain; `noasserts` installs the `+NoAsserts` one instead. Use `noasserts` on win-arm64, where the `+Asserts` `swift-package.exe` fails to start ([swiftlang/swift#92379](https://github.com/swiftlang/swift/issues/92379)). |
| `windows-minimal` | no | `false` | Windows only. `true` leaves out what a CI build does not use: the debugger (`OptionsInstallDBG`), its embedded Python (`OptionsInstallPy`) and the Android platform (`OptionsInstallAndroidPlatform`). The IDE feature stays: without it `swift.exe` fails to start (`ERROR_SXS_CANT_GEN_ACTCTX`). |
| `cache` | no | `true` | Cache the downloaded Linux toolchain archive and its `.sig` with `actions/cache`. The archive is re-verified with GPG on every run and extracted into a clean per-version directory; `false` reuses nothing on disk. The macOS `.pkg` and the Windows installer are not cached: restoring them from the Actions cache measured slower than downloading them from swift.org. |

## Outputs

| Output | Description |
| --- | --- |
| `version` | Version reported by `swift --version`. |
| `swift-path` | Directory containing the active `swift` binary. |
| `source` | `preinstalled` (opt-in only), `cache`, `download` (Linux), `pkg` (macOS) or `installer` (Windows). |
| `sdks` | `swift sdk list` output after installing `swift-sdks`. |

The action fails if `swift --version` does not report exactly the requested version afterwards.

## Behaviour and supported platforms

By default the action ignores any Swift already on the machine and installs the verified toolchain, which is put
first on `PATH`. With `use-preinstalled: true` a matching `swift` on `PATH` is used as is (and a warning is
emitted); that toolchain is **not verified** by this action.

| Platform | Artifact | Verification |
| --- | --- | --- |
| Ubuntu 20.04 / 22.04 / 24.04, x86_64 and aarch64 | `swift-<v>-RELEASE-ubuntuNN.NN[-aarch64].tar.gz` | GPG `.sig` against pinned swift.org keys |
| macOS (any runner) | `swift-<v>-RELEASE-osx.pkg` | `pkgutil --check-signature`, notarization, pinned Developer ID team |
| Windows, x86_64 and arm64 | `swift-<v>-RELEASE-windows10[-arm64].exe` | Authenticode `Valid` and signer subject (Apple Inc.) |
| Swift SDKs (`static-linux`, `wasm`, `android`) on any host | `swift-<v>-RELEASE_<kind>.artifactbundle.tar.gz` | sha256 pinned in `sdk-checksums.txt`, plus GPG `.sig` when `gpg` exists |

Other Linux distributions and architectures fail with an explicit error. Not every version is
published for every platform (for example, newer releases have no Ubuntu 20.04 build); a missing
download fails with the URL that was tried.

Linux: the tarball and `.sig` are kept in `$RUNNER_TOOL_CACHE/swift-archives/...` and cached (key: version,
platform, arch). Every run, including a cache hit, copies them to a private snapshot, re-verifies the snapshot with
GPG, and extracts that same snapshot into `$RUNNER_TEMP/setup-swift/<version>/<arch>-<platform>`, which is added to
`PATH`. The path is stable across runs so SwiftPM build caches (which record the compiler path) stay valid. Before
extraction the directory is validated (exactly that shape, no `..`, and no symlink in any component from
`RUNNER_TEMP` down, checked again just before use) and removed entirely, so nothing previously on disk is reused.
A cache entry that fails verification fails the job instead of being re-downloaded. Isolation model:
`RUNNER_TEMP` is private to one runner instance and emptied for every job on GitHub-hosted runners, so earlier or
concurrent jobs cannot plant or wipe the toolchain. Self-hosted runners must not share `RUNNER_TEMP` between
concurrently running jobs, and must run jobs of different trust levels on separate runner instances. Missing build prerequisites (`libcurl4-openssl-dev`,
`libxml2-dev`, the GCC dev packages, ...) are installed with `apt-get` only if absent - from the package lists the runner image ships, refreshed only if that fails, and, apart from `curl` and `gnupg2`, in the background while the archive is fetched, verified and extracted. The archive is extracted with `pigz` when the runner has it.

macOS: the package is installed into the user domain (`~/Library/Developer/Toolchains`), falling back to
`sudo installer -target /`. `TOOLCHAINS` is exported with the toolchain's bundle identifier and its
`usr/bin` is prepended to `PATH`. The install path is deterministic (like the Linux and Windows ones), so SwiftPM build caches stay valid. macOS installs are not cached.

Windows: the installer runs silently (`/install /quiet`) into `%LocalAppData%\Programs\Swift`; the toolchain and
runtime `bin` directories are added to `PATH` and `SDKROOT` is set. Visual Studio (C++ tools, Windows SDK),
preinstalled on GitHub's Windows runners, is still required. Windows installs are not cached. The directories for the requested version must not exist before the
installer runs, and exactly one matching `Toolchains`, `Runtimes` and `Platforms` directory is selected. With
`windows-toolchain-variant: noasserts` the installer is passed `OptionsInstallAssertsToolchain=0
OptionsInstallNoAssertsToolchain=1`, and the toolchain directory selected must be the `+NoAsserts` one.

## Swift SDKs (static Linux, WebAssembly, Android)

```yaml
- uses: tryswift/setup-swift@v1
  with:
    swift-version: "6.4.1"
    swift-sdks: wasm android
```

Each bundle is downloaded by the action (never by `swift sdk install <url>`), compared with the sha256 in
[`sdk-checksums.txt`](sdk-checksums.txt), GPG-verified against the pinned keys when `gpg` is installed, and
installed from the local file. For Android, the `setup-android-sdk.sh` helper that is run must be byte-identical to
the one inside the verified archive, and a pre-existing bundle of the same name is rejected. A version with no entry fails with a clear message. Afterwards use the
SDK id or triple from `swift sdk list`, e.g. `swift build --swift-sdk swift-6.4.1-RELEASE_wasm`,
`--swift-sdk x86_64-swift-linux-musl`, or `--swift-sdk aarch64-unknown-linux-android28 --static-swift-stdlib`.

Android also needs the Android NDK. The action uses `ANDROID_NDK_HOME`, else `ANDROID_NDK_LATEST_HOME`
(set on GitHub-hosted Ubuntu and macOS images), runs the bundle's `setup-android-sdk.sh` to link the
NDK sysroot, and exports `ANDROID_NDK_HOME`. The NDK must be new enough for the SDK (the Swift 6.4 SDK
needs r30; `macos-latest` currently ships r27 and fails to link, install a newer NDK first and set
`ANDROID_NDK_HOME`). The action does not download an NDK.

### Updating the SDK checksums

For a new Swift version, take the `--checksum` values printed on the swift.org install pages
(<https://www.swift.org/install/linux/>, the WebAssembly and Android getting-started articles) or compute
`shasum -a 256` of each bundle after confirming its `.sig` verifies against the pinned keys, then add
`<version> <kind> <sha256>` lines to `sdk-checksums.txt`.

## How verification works

Linux. The tarball and its `.sig` are downloaded, a temporary `GNUPGHOME` is created, and only the keys in
[`swift-release-keys.asc`](swift-release-keys.asc) are imported. `gpg --verify --status-fd` must report
exactly one `GOODSIG` and one `VALIDSIG` (and no `EXPKEYSIG`, `REVKEYSIG`, `EXPSIG`, `BADSIG`, `ERRSIG` or
`NO_PUBKEY`), and the primary-key fingerprint in `VALIDSIG` must equal one of the fingerprints pinned in
[`verify-gpg.sh`](verify-gpg.sh), shared by the toolchain and SDK installers. There is no trust-on-first-use and no network key fetch.

macOS. `pkgutil --check-signature` must succeed, the package must be notarized, and the leaf certificate
must be `Developer ID Installer: Swift Open Source (V9AUD2URP3)`. The team ID is pinned rather than the
certificate hash because the leaf certificate is renewed.

Windows. `Get-AuthenticodeSignature` must report `Valid` and the signer subject must match
`CN=Apple Inc., [OU=...,] O=Apple Inc., L=Cupertino, S=California, C=US` (swift.org's Windows installers are
signed by Apple; the OU group id is not pinned). swift.org publishes no detached `.sig` for 6.x Windows
installers. This pin is weaker than the GPG pin: any Apple-signed binary would pass.

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
4. Update `PINNED_FINGERPRINTS` in `verify-gpg.sh` and the table above, then run CI.

## Security notes

- Pin the action by commit SHA in sensitive workflows.
- The Linux cache holds only the downloaded archive and signature, which are re-verified on every run, so a
  poisoned cache fails the job rather than running attacker code. CI covers this (`fail-closed` job).
- Report vulnerabilities as described in [SECURITY.md](SECURITY.md).

## Development

CI (`.github/workflows/ci.yml`) runs shellcheck, actionlint, installs 6.4.1 and 6.3.3 on
`ubuntu-22.04`, `ubuntu-24.04`, `ubuntu-24.04-arm`, `macos-latest` and `windows-latest`, checks the Linux
cache-hit path, builds hello world with the static Linux, WebAssembly and Android SDKs, and builds hello world with
the `+NoAsserts` toolchain on `windows-latest` and `windows-11-arm`. Not covered by CI: Ubuntu 20.04 (no 6.x
tarballs for recent versions), the `+Asserts` toolchain on Windows arm64 (swiftlang/swift#92379), running
WebAssembly output.

## About

This action is maintained by [try! Swift](https://tryswift.co), the community behind the try! Swift
conferences. If you build with Swift, join the community in person at
**[try! Swift Tokyo](https://tryswift.jp)**.
