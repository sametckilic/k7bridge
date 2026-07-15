[CmdletBinding()]
param(
    [string]$DeviceHost = 'k7bridge-phone',
    [string]$DeviceUser = 'mobile'
)

$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path

& powershell.exe -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'build-gateway-local.ps1')
if ($LASTEXITCODE -ne 0) { throw "Yerel gateway build basarisiz oldu ($LASTEXITCODE)." }

$packages = @(Get-ChildItem -LiteralPath (Join-Path $repoRoot 'outputs\gateway-local') -Filter '*.deb')
if ($packages.Count -ne 1) { throw "Tek bir .deb bekleniyordu; bulunan: $($packages.Count)" }
$package = $packages[0]
if ($package.Name -notmatch '^[A-Za-z0-9._+-]+\.deb$') { throw "Guvenli olmayan paket adi: $($package.Name)" }

Write-Host "Paket telefona aktariliyor: $($package.Name)"
& scp.exe -o StrictHostKeyChecking=accept-new $package.FullName "${DeviceUser}@${DeviceHost}:/var/mobile/$($package.Name)"
if ($LASTEXITCODE -ne 0) { throw "SCP aktarimi basarisiz oldu ($LASTEXITCODE)." }

$waitForGateway = 'ready=0; attempt=0; while [ "$attempt" -lt 70 ]; do if sudo launchctl print system/com.k7bridge.gateway 2>/dev/null | grep -q state.=.running; then ready=1; break; fi; attempt=$((attempt+1)); sleep 3; done; if [ "$ready" -ne 1 ]; then sudo launchctl print system/com.k7bridge.gateway 2>&1 | head -30; exit 1; fi'
$remote = "sudo dpkg --install /var/mobile/$($package.Name) && $waitForGateway && dpkg -s com.example.k7bridge.gateway | grep -E 'Status|Version' && sudo launchctl print system/com.k7bridge.gateway | grep state.="
Write-Host 'Paket kuruluyor...'
& ssh.exe -t "${DeviceUser}@${DeviceHost}" $remote
if ($LASTEXITCODE -ne 0) { throw "Telefondaki kurulum basarisiz oldu ($LASTEXITCODE)." }

Write-Host 'Yerel gateway build ve dagitim tamamlandi.' -ForegroundColor Green
