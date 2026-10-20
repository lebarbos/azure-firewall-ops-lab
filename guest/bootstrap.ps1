$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$logDir = 'C:\fwlab'
$logPath = Join-Path $logDir 'bootstrap.log'
$marker = '__BOOTSTRAP_MARKER__'
$markerPath = '__BOOTSTRAP_MARKER_PATH__'
$rdpRemoteAddresses = '__RDP_REMOTE_ADDRESSES__'

try {
    New-Item -Path $logDir -ItemType Directory -Force | Out-Null
    Start-Transcript -Path $logPath -Append | Out-Null

    Install-WindowsFeature Web-Server -IncludeManagementTools | Out-Null

    $hostName = [System.Net.WebUtility]::HtmlEncode($env:COMPUTERNAME)
    $ipAddress = (Get-NetIPAddress -AddressFamily IPv4 |
        Where-Object { $_.IPAddress -notlike '169.254.*' -and $_.IPAddress -ne '127.0.0.1' } |
        Sort-Object InterfaceMetric |
        Select-Object -First 1 -ExpandProperty IPAddress)
    $safeIp = [System.Net.WebUtility]::HtmlEncode($ipAddress)
    $html = @"
<!doctype html>
<html lang="pt-BR">
<head>
  <meta charset="utf-8">
  <title>Azure Firewall lab</title>
</head>
<body>
  <h1>HTTP pronto</h1>
  <p>Host: $hostName</p>
  <p>IP: $safeIp</p>
  <p>Esta pagina confirma o IIS local; o exercicio confirma o caminho pelo firewall.</p>
</body>
</html>
"@
    Set-Content -LiteralPath 'C:\inetpub\wwwroot\index.html' -Value $html -Encoding UTF8

    foreach ($ruleName in @('Lab-HTTP', 'Lab-ICMPv4', 'Lab-RDP-Spokes-Bastion')) {
        $existingRule = Get-NetFirewallRule -Name $ruleName -ErrorAction SilentlyContinue
        if ($existingRule) {
            Remove-NetFirewallRule -Name $ruleName
        }
    }

    New-NetFirewallRule -Name 'Lab-HTTP' -DisplayName 'Lab HTTP inbound' -Direction Inbound -Protocol TCP -LocalPort 80 -Action Allow -Profile Any | Out-Null
    New-NetFirewallRule -Name 'Lab-ICMPv4' -DisplayName 'Lab ICMPv4 echo request inbound' -Direction Inbound -Protocol ICMPv4 -IcmpType 8 -Action Allow -Profile Any | Out-Null

    Set-ItemProperty -Path 'HKLM:\System\CurrentControlSet\Control\Terminal Server' -Name fDenyTSConnections -Value 0
    New-NetFirewallRule -Name 'Lab-RDP-Spokes-Bastion' -DisplayName 'Lab RDP from spokes and Bastion' -Direction Inbound -Protocol TCP -LocalPort 3389 -RemoteAddress ($rdpRemoteAddresses -split ',') -Action Allow -Profile Any | Out-Null

    Set-Service W3SVC -StartupType Automatic
    Start-Service W3SVC

    $response = Invoke-WebRequest -Uri 'http://127.0.0.1/' -UseBasicParsing -TimeoutSec 20
    if ($response.StatusCode -ne 200 -or $response.Content -notmatch [regex]::Escape($env:COMPUTERNAME)) {
        throw 'HTTP localhost did not return this hostname.'
    }

    Set-Content -LiteralPath $markerPath -Value $marker -Encoding ASCII
    Write-Output "$marker host=$env:COMPUTERNAME ip=$ipAddress http=200"
    Stop-Transcript | Out-Null
    exit 0
} catch {
    $message = "LAB_BOOTSTRAP_FAILED $($_.Exception.Message)"
    Write-Output $message
    try {
        Add-Content -LiteralPath $logPath -Value $message -Encoding ASCII
        Stop-Transcript | Out-Null
    } catch {
        Write-Output 'LAB_BOOTSTRAP_FAILED could not write final log entry.'
    }
    exit 1
}
