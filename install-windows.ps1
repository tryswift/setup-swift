# Installs the swift.org Windows toolchain after requiring a valid Authenticode
# signature from the expected publisher. Inputs (env): SWIFT_VERSION,
# WINDOWS_TOOLCHAIN_VARIANT (asserts | noasserts).
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$v = $env:SWIFT_VERSION
# The installer's two toolchain features. "asserts" leaves the installer at its default; "noasserts"
# swaps the +Asserts toolchain for the +NoAsserts one, whose swift-package.exe starts on win-arm64
# where the +Asserts one does not (https://github.com/swiftlang/swift/issues/92379).
$variant = if ($env:WINDOWS_TOOLCHAIN_VARIANT) { $env:WINDOWS_TOOLCHAIN_VARIANT } else { 'asserts' }
switch ($variant) {
  'asserts' { $installerOptions = @(); $variantSuffix = $null }
  'noasserts' {
    $installerOptions = @('OptionsInstallAssertsToolchain=0', 'OptionsInstallNoAssertsToolchain=1')
    $variantSuffix = 'NoAsserts'
  }
  default { Write-Host "::error::windows-toolchain-variant must be asserts or noasserts, got '$variant'"; exit 1 }
}
# windows-minimal: the installer features a CI build does not use - the debugger, its Python and the
# Android platform, a second SDK. Not the IDE feature: without it swift.exe fails to start with
# ERROR_SXS_CANT_GEN_ACTCTX (14001), measured on 6.4.1 with each feature left out on its own.
switch ($env:WINDOWS_MINIMAL) {
  { $_ -in @('', 'false') } { }
  'true' {
    $installerOptions += @('OptionsInstallDBG=0', 'OptionsInstallPy=0', 'OptionsInstallAndroidPlatform=0')
  }
  default { Write-Host "::error::windows-minimal must be true or false, got '$env:WINDOWS_MINIMAL'"; exit 1 }
}
# Publisher the installer must be signed by, see README.md. swift.org's Windows installers are signed
# with an Apple Inc. certificate whose OU (an Apple internal group id) is deliberately not pinned.
$ExpectedSubject = '^CN=Apple Inc\., (OU=[^,]+, )?O=Apple Inc\., L=Cupertino, S=California, C=US$'

$arch = if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { 'windows10-arm64' } else { 'windows10' }
$file = "swift-$v-RELEASE-$arch.exe"
$url = "https://download.swift.org/swift-$v-release/$arch/swift-$v-RELEASE/$file"
$work = Join-Path ($env:RUNNER_TEMP ?? $env:TEMP) "setup-swift-$([guid]::NewGuid())"
New-Item -ItemType Directory -Path $work | Out-Null
$exe = Join-Path $work $file

Write-Host "Downloading $url"
$ok = $false
foreach ($i in 1..5) {
  try { Invoke-WebRequest -Uri $url -OutFile $exe -UseBasicParsing; $ok = $true; break }
  catch { Write-Host "Attempt $i failed: $($_.Exception.Message)"; Start-Sleep -Seconds 5 }
}
if (-not $ok) { Write-Host "::error::Failed to download $url"; exit 1 }

$sig = Get-AuthenticodeSignature -FilePath $exe
Write-Host "Authenticode status: $($sig.Status); signer: $($sig.SignerCertificate.Subject)"
if ($sig.Status -ne 'Valid') {
  Write-Host "::error::Authenticode signature of $file is not valid ($($sig.Status))"; exit 1
}
if ($sig.SignerCertificate.Subject -notmatch $ExpectedSubject) {
  Write-Host "::error::$file is signed by '$($sig.SignerCertificate.Subject)', expected '$ExpectedSubject'"; exit 1
}
Write-Host "Authenticode signature verified for $file"

# swift.org's installer defaults to %LocalAppData%\Programs\Swift. Directories for the requested
# version must not exist beforehand, so only what this verified installer wrote is selected.
$root = Join-Path $env:LOCALAPPDATA 'Programs\Swift'
$vre = [regex]::Escape($v)
# With noasserts the one toolchain directory has to be the +NoAsserts one: an installer that ignored the
# options would otherwise pass the exactly-one check below with the toolchain nobody asked for.
$toolchainPattern = if ($variantSuffix) { "^$vre\+$variantSuffix$" } else { "^$vre(\+[A-Za-z0-9]+)?$" }
$versionPattern = "^$vre$"

function Find-VersionDirs([string]$sub, [string]$pattern) {
  $dir = Join-Path $root $sub
  if (-not (Test-Path $dir)) { return @() }
  return @(Get-ChildItem $dir -Directory | Where-Object { $_.Name -match $pattern })
}
function Select-One([string]$sub, [string]$pattern) {
  $found = Find-VersionDirs $sub $pattern
  if ($found.Count -ne 1) {
    Write-Host "::error::Expected exactly one $sub directory for Swift $v under $root, found $($found.Count)"; exit 1
  }
  return $found[0].FullName
}

foreach ($pair in @(@('Toolchains', $toolchainPattern), @('Runtimes', $versionPattern), @('Platforms', $versionPattern))) {
  if ((Find-VersionDirs $pair[0] $pair[1]).Count -gt 0) {
    Write-Host "::error::$root\$($pair[0]) already contains Swift $v; refusing to reuse a pre-existing directory"; exit 1
  }
}

$p = Start-Process -FilePath $exe -ArgumentList (@('/install', '/quiet', '/norestart') + $installerOptions) -Wait -PassThru
if ($p.ExitCode -ne 0 -and $p.ExitCode -ne 3010) {
  Write-Host "::error::Swift installer exited with code $($p.ExitCode)"; exit 1
}
if (-not (Test-Path $root)) { Write-Host "::error::Swift was not installed under $root"; exit 1 }

$toolchainBin = Join-Path (Select-One 'Toolchains' $toolchainPattern) 'usr\bin'
$runtimeBin = Join-Path (Select-One 'Runtimes' $versionPattern) 'usr\bin'
$sdkRoot = Join-Path (Select-One 'Platforms' $versionPattern) 'Windows.platform\Developer\SDKs\Windows.sdk'
foreach ($d in @($toolchainBin, $runtimeBin, $sdkRoot)) {
  if (-not (Test-Path $d)) { Write-Host "::error::Expected install directory missing: $d"; exit 1 }
}
Add-Content -Path $env:GITHUB_PATH -Value $toolchainBin
Add-Content -Path $env:GITHUB_PATH -Value $runtimeBin
Add-Content -Path $env:GITHUB_ENV -Value "SDKROOT=$sdkRoot"
Add-Content -Path $env:GITHUB_OUTPUT -Value 'source=installer'
Remove-Item -Recurse -Force $work
