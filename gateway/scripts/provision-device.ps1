param(
  [Parameter(Mandatory=$true)][string]$DeviceHost,
  [Parameter(Mandatory=$true)][string]$RelayUrl,
  [string]$SshUser = "mobile",
  [string]$OutputDirectory = ".k7bridge-identity"
)
$ErrorActionPreference = "Stop"
New-Item -ItemType Directory -Force -Path $OutputDirectory | Out-Null
$password = -join ((1..32) | ForEach-Object { [char](33 + (Get-Random -Maximum 90)) })
openssl req -x509 -newkey rsa:2048 -sha256 -days 825 -nodes -subj "/CN=k7bridge.local" -keyout "$OutputDirectory/key.pem" -out "$OutputDirectory/cert.pem"
openssl pkcs12 -export -out "$OutputDirectory/identity.p12" -inkey "$OutputDirectory/key.pem" -in "$OutputDirectory/cert.pem" -passout "pass:$password"
$fingerprint = (openssl x509 -in "$OutputDirectory/cert.pem" -outform DER | openssl dgst -sha256 -r).Split(' ')[0]
Set-Content -NoNewline "$OutputDirectory/identity.password" $password
Set-Content -NoNewline "$OutputDirectory/certificate.sha256" $fingerprint
Set-Content -NoNewline "$OutputDirectory/relay.url" $RelayUrl
ssh "$SshUser@$DeviceHost" "mkdir -p /var/mobile/Library/K7Bridge"
scp "$OutputDirectory/identity.p12" "$OutputDirectory/identity.password" "$OutputDirectory/certificate.sha256" "$OutputDirectory/relay.url" "${SshUser}@${DeviceHost}:/var/mobile/Library/K7Bridge/"
Write-Host "Identity installed. Restart com.k7bridge.gateway and read /var/mobile/Library/K7Bridge/pairing-url.txt"

