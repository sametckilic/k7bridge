[CmdletBinding()]
param(
    [string]$DeviceHost = "192.168.1.154",
    [string]$DeviceUser = "mobile",
    [string]$Workflow = "gateway.yml",
    [int]$WaitMinutes = 15
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
$repositoryRoot = Split-Path -Parent $PSScriptRoot
Set-Location -LiteralPath $repositoryRoot

function Find-Git {
    $command = Get-Command git -ErrorAction SilentlyContinue
    if ($command) { return $command.Source }

    $bundled = Join-Path $env:USERPROFILE ".cache\codex-runtimes\codex-primary-runtime\dependencies\native\git\cmd\git.exe"
    if (Test-Path $bundled) { return $bundled }
    throw "Git bulunamadı."
}

function Read-GitHubCredential([string]$Git) {
    $result = "protocol=https`nhost=github.com`n`n" | & $Git credential fill
    if ($LASTEXITCODE -ne 0) { throw "GitHub kimlik bilgisi alınamadı." }

    $values = @{}
    foreach ($line in $result) {
        $separator = $line.IndexOf("=")
        if ($separator -gt 0) {
            $values[$line.Substring(0, $separator)] = $line.Substring($separator + 1)
        }
    }
    if (-not $values.password) { throw "GitHub oturumu bulunamadı. Önce bir kez git push yapın." }
    return $values.password
}

function Invoke-GitHubApi([string]$Uri, [string]$Token) {
    Invoke-RestMethod -Uri $Uri -Headers @{
        Authorization = "Bearer $Token"
        Accept = "application/vnd.github+json"
        "X-GitHub-Api-Version" = "2022-11-28"
        "User-Agent" = "K7Bridge-Deploy"
    }
}

$git = Find-Git
$remote = (& $git remote get-url origin).Trim()
if ($remote -notmatch "github\.com[/:](?<owner>[^/]+)/(?<repo>[^/.]+)(?:\.git)?$") {
    throw "GitHub origin adresi çözümlenemedi: $remote"
}
$owner = $Matches.owner
$repo = $Matches.repo
$branch = (& $git branch --show-current).Trim()
if (-not $branch) { $branch = "main" }
$token = Read-GitHubCredential $git
$api = "https://api.github.com/repos/$owner/$repo"
$deadline = (Get-Date).AddMinutes($WaitMinutes)
$run = $null

Write-Host "En güncel gateway build bekleniyor..."
do {
    $response = Invoke-GitHubApi "$api/actions/workflows/$Workflow/runs?branch=$branch&per_page=10" $token
    $run = $response.workflow_runs | Sort-Object created_at -Descending | Select-Object -First 1
    if ($run -and $run.status -eq "completed") { break }
    if ((Get-Date) -ge $deadline) { throw "Gateway build $WaitMinutes dakika içinde tamamlanmadı." }
    Start-Sleep -Seconds 5
} while ($true)

if ($run.conclusion -ne "success") {
    throw "Gateway build başarısız: $($run.html_url)"
}
Write-Host "Başarılı build bulundu: $($run.head_sha.Substring(0, 7))"

$temporary = Join-Path $env:TEMP "k7bridge-deploy-$PID"
New-Item -ItemType Directory -Force -Path $temporary | Out-Null
try {
    $artifacts = Invoke-GitHubApi "$api/actions/runs/$($run.id)/artifacts" $token
    $artifact = $artifacts.artifacts | Where-Object { $_.name -eq "K7BridgeGateway-rootless" -and -not $_.expired } | Select-Object -First 1
    if (-not $artifact) { throw "Gateway artifact bulunamadı veya süresi dolmuş." }

    $zip = Join-Path $temporary "gateway.zip"
    Invoke-WebRequest -Uri "$api/actions/artifacts/$($artifact.id)/zip" -OutFile $zip -Headers @{
        Authorization = "Bearer $token"
        Accept = "application/vnd.github+json"
        "X-GitHub-Api-Version" = "2022-11-28"
        "User-Agent" = "K7Bridge-Deploy"
    }
    Expand-Archive -LiteralPath $zip -DestinationPath $temporary -Force
    $package = Get-ChildItem $temporary -Recurse -File -Filter "*.deb" | Select-Object -First 1
    if (-not $package) { throw "Artifact içinde .deb bulunamadı." }
    if ($package.Name -notmatch "^[A-Za-z0-9._+-]+\.deb$") { throw "Güvensiz paket adı: $($package.Name)" }

    Write-Host "Paket telefona aktarılıyor: $($package.Name)"
    & scp $package.FullName "${DeviceUser}@${DeviceHost}:/var/mobile/$($package.Name)"
    if ($LASTEXITCODE -ne 0) { throw "SCP aktarımı başarısız." }

    Write-Host "Paket kuruluyor ve gateway yeniden başlatılıyor..."
    $remoteCommand = "sudo dpkg --install /var/mobile/$($package.Name) && (sudo launchctl bootout system/com.k7bridge.gateway 2>/dev/null || true) && (sudo killall k7bridged 2>/dev/null || true) && sudo launchctl bootstrap system /var/jb/Library/LaunchDaemons/com.k7bridge.gateway.plist && echo '--- Kurulan gateway ---' && dpkg -s com.example.k7bridge.gateway | grep -E 'Status|Version'"
    & ssh -t "${DeviceUser}@${DeviceHost}" $remoteCommand
    if ($LASTEXITCODE -ne 0) { throw "Telefondaki kurulum başarısız." }

    Write-Host "Gateway dağıtımı tamamlandı." -ForegroundColor Green
}
finally {
    $token = $null
    if (Test-Path $temporary) { Remove-Item -LiteralPath $temporary -Recurse -Force }
}
