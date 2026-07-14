[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$outputRoot = Join-Path $repoRoot 'outputs\gateway-local'
New-Item -ItemType Directory -Force -Path $outputRoot | Out-Null

function Convert-ToWslPath([string]$Path) {
    $full = [System.IO.Path]::GetFullPath($Path)
    if ($full -notmatch '^([A-Za-z]):\\(.*)$') { throw "Windows yolu WSL yoluna cevrilemedi: $full" }
    $drive = $Matches[1].ToLowerInvariant()
    $tail = $Matches[2].Replace('\', '/')
    return "/mnt/$drive/$tail"
}

$wslRepo = Convert-ToWslPath $repoRoot
$wslOutput = Convert-ToWslPath $outputRoot
$wslScript = "$wslRepo/scripts/build-gateway-local.sh"
$gitSha = (& git -C $repoRoot rev-parse HEAD).Trim()

& wsl.exe -d Ubuntu -u root -- bash $wslScript $wslRepo $wslOutput $gitSha
if ($LASTEXITCODE -ne 0) { throw "Yerel gateway build basarisiz oldu ($LASTEXITCODE)." }

$packages = @(Get-ChildItem -LiteralPath $outputRoot -Filter '*.deb')
if ($packages.Count -ne 1) { throw "Tek bir .deb bekleniyordu; bulunan: $($packages.Count)" }
Write-Host "Gateway paketi hazir: $($packages[0].FullName)"
