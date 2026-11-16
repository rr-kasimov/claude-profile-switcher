# Installs Claude Profile Switcher for the current Windows user (no administrator rights needed).
#   powershell -ExecutionPolicy Bypass -File install.ps1             install or update
#   powershell -ExecutionPolicy Bypass -File install.ps1 -Uninstall  remove (saved sign-ins stay)
# It can also be removed from Windows Settings > Apps > Installed apps.
param([switch]$Uninstall)
$setup = Join-Path $PSScriptRoot 'windows\setup.ps1'
if ($Uninstall) {
    & $setup -Uninstall -Silent -Source $PSScriptRoot
} else {
    $version = (Get-Content -Raw (Join-Path $PSScriptRoot 'VERSION')).Trim()
    & $setup -Install -Source $PSScriptRoot -Version $version
}
exit $LASTEXITCODE
