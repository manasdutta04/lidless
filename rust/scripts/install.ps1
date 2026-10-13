# Windows: builds the `lidless` CLI from source, installs it to
# %LOCALAPPDATA%\Programs\Lidless, adds that folder to the user PATH, and
# runs `lidless setup` (Task Scheduler recovery tasks; Windows asks for
# administrator approval once for the lid-close permission).
# For the tray app, download the installer from GitHub Releases.
$ErrorActionPreference = "Stop"
Set-Location (Join-Path $PSScriptRoot "..")

if (-not (Get-Command cargo -ErrorAction SilentlyContinue)) {
  Write-Error "Rust is required: https://rustup.rs"
}

Write-Host "Building lidless (release)…"
cargo build -p lidless --release
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

$dest = Join-Path $env:LOCALAPPDATA "Programs\Lidless"
New-Item -ItemType Directory -Force -Path $dest | Out-Null
Copy-Item "target\release\lidless.exe" (Join-Path $dest "lidless.exe") -Force
Write-Host "✓ Installed $dest\lidless.exe"

$userPath = [Environment]::GetEnvironmentVariable("Path", "User")
if ($userPath -notlike "*$dest*") {
  [Environment]::SetEnvironmentVariable("Path", "$userPath;$dest", "User")
  $env:Path = "$env:Path;$dest"
  Write-Host "✓ Added $dest to your PATH (open a new terminal to use it)"
}

& (Join-Path $dest "lidless.exe") setup
Write-Host ""
& (Join-Path $dest "lidless.exe") doctor
Write-Host ""
Write-Host "Try: lidless start 2h   (keep the computer on a ventilated surface while the lid is closed)"
