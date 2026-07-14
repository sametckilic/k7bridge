[CmdletBinding()]
param(
    [string]$DeviceHost = 'k7bridge-phone',
    [string]$DeviceUser = 'mobile',
    [switch]$RestartAudioProbe
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

$audioRestart = if ($RestartAudioProbe) { " && sudo killall -9 mediaserverd" } else { "" }
$remote = "sudo dpkg --install /var/mobile/$($package.Name) && sleep 3 && dpkg -s com.example.k7bridge.gateway | grep -E 'Status|Version' && sudo launchctl print system/com.k7bridge.gateway | grep -E 'state =|last exit code'${audioRestart}"
Write-Host 'Paket kuruluyor...'
& ssh.exe -t "${DeviceUser}@${DeviceHost}" $remote
if ($LASTEXITCODE -ne 0) { throw "Telefondaki kurulum basarisiz oldu ($LASTEXITCODE)." }

Write-Host 'Yerel gateway build ve dagitim tamamlandi.' -ForegroundColor Green
