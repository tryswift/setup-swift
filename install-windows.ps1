# Installs the swift.org Windows toolchain after requiring a valid Authenticode
# signature from the expected publisher. Inputs (env): SWIFT_VERSION.
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$v = $env:SWIFT_VERSION
# Subject (publisher) the installer must be signed by, see README.md.
$ExpectedSubject = 'CN="Swift Open Source", O="Swift Open Source", L=Cupertino, S=California, C=US'

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
if ($sig.SignerCertificate.Subject -ne $ExpectedSubject) {
  Write-Host "::error::$file is signed by '$($sig.SignerCertificate.Subject)', expected '$ExpectedSubject'"; exit 1
}
Write-Host "Authenticode signature verified for $file"

$p = Start-Process -FilePath $exe -ArgumentList '/install', '/quiet', '/norestart' -Wait -PassThru
if ($p.ExitCode -ne 0 -and $p.ExitCode -ne 3010) {
  Write-Host "::error::Swift installer exited with code $($p.ExitCode)"; exit 1
}

# swift.org's installer defaults to %LocalAppData%\Programs\Swift.
$root = Join-Path $env:LOCALAPPDATA 'Programs\Swift'
if (-not (Test-Path $root)) { Write-Host "::error::Swift was not installed under $root"; exit 1 }
Get-ChildItem $root -Recurse -Depth 2 -Directory | Select-Object -First 40 | ForEach-Object { Write-Host $_.FullName }

$toolchainBin = Get-ChildItem (Join-Path $root 'Toolchains') -Directory | Select-Object -First 1 | ForEach-Object { Join-Path $_.FullName 'usr\bin' }
$runtimeBin = Get-ChildItem (Join-Path $root 'Runtimes') -Directory | Select-Object -First 1 | ForEach-Object { Join-Path $_.FullName 'usr\bin' }
$sdkRoot = Get-ChildItem (Join-Path $root 'Platforms') -Directory | Select-Object -First 1 | ForEach-Object { Join-Path $_.FullName 'Windows.platform\Developer\SDKs\Windows.sdk' }
foreach ($d in @($toolchainBin, $runtimeBin, $sdkRoot)) {
  if (-not $d -or -not (Test-Path $d)) { Write-Host "::error::Expected install directory missing: $d"; exit 1 }
}
Add-Content -Path $env:GITHUB_PATH -Value $toolchainBin
Add-Content -Path $env:GITHUB_PATH -Value $runtimeBin
Add-Content -Path $env:GITHUB_ENV -Value "SDKROOT=$sdkRoot"
Add-Content -Path $env:GITHUB_OUTPUT -Value 'source=installer'
Remove-Item -Recurse -Force $work
