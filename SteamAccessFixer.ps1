#requires -Version 5.1
<#
.SYNOPSIS
    Steam connectivity diagnostic and optional hosts override utility.

.DESCRIPTION
    Resolves a curated list of Steam-related hostnames (storefront, Akamai CDN,
    Cloudflare CDN) via DNS-over-HTTPS or DNS-over-TLS, verifies each candidate
    IP with a real SNI-TLS handshake (certificate validated), and optionally
    writes successful results to the Windows hosts file.

.PARAMETER Mode
    Menu (default), Diagnose, Apply, Restore.

.PARAMETER DohProvider
    auto (default) iterates every configured provider; any other value pins it.

.PARAMETER DohFormat
    json or wire, used only with -DohProvider custom.

.PARAMETER DotServer
    Optional DoT resolver hostname (e.g. one.one.one.one).

.NOTES
    Author : Halcyon
    Version: 2.0.0
    Since  : 2026-10-10
#>

[CmdletBinding()]
param(
    [ValidateSet('Menu', 'Fix', 'Apply', 'Restore', 'Diagnose')]
    [string]$Mode = 'Menu',

    [ValidateSet('auto', 'cloudflare', 'google', 'adguard', 'quad9',
        'nextdns', 'mullvad', 'dns.sb', 'opendns',
        'controld', 'cleanbrowsing', 'custom')]
    [string]$DohProvider = 'auto',

    [string]$DohUri,

    [ValidateSet('json', 'wire')]
    [string]$DohFormat = 'json',

    [string]$DotServer
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($DohProvider -eq 'custom' -and [string]::IsNullOrWhiteSpace($DohUri)) {
    throw '-DohProvider custom requires -DohUri'
}

try {
    $proto = [Net.SecurityProtocolType]::Tls12
    try { $proto = $proto -bor [Net.SecurityProtocolType]::Tls11 } catch { }
    [Net.ServicePointManager]::SecurityProtocol = $proto
}
catch {
    Write-Warning "could not raise TLS version: $($_.Exception.Message)"
}

# ---------------------------------------------------------------------------
# metadata
# ---------------------------------------------------------------------------
$script:AppName = 'steam-access-fixer'
$script:AppVersion = '1.2.1'
$script:AppAuthor = 'Halcyon'
$script:AppSince = '2026-10-10'
$script:AppBuiltOn = (Get-Date).ToString('yyyy-MM-dd')

# ---------------------------------------------------------------------------
# configuration
# ---------------------------------------------------------------------------
$script:HostsPath = Join-Path $env:SystemRoot 'System32\drivers\etc\hosts'
$script:BackupPath = Join-Path $env:SystemRoot 'System32\drivers\etc\hosts.bak_steam'
$script:ManagedStart = '# BEGIN SteamAccessFix managed entries'
$script:ManagedEnd = '# END SteamAccessFix managed entries'

$script:Domains = @(
    'store.steampowered.com'
    'steamcommunity.com'
    'api.steampowered.com'
    'checkout.steampowered.com'
    'login.steampowered.com'
    'help.steampowered.com'
    'cdn.akamai.steamstatic.com'
    'community.akamai.steamstatic.com'
    'shared.akamai.steamstatic.com'
    'avatars.akamai.steamstatic.com'
    'steamcdn-a.akamaihd.net'
    'steamcommunity-a.akamaihd.net'
    'steamstore-a.akamaihd.net'
    'steamuserimages-a.akamaihd.net'
    'steamvideo-a.akamaihd.net'
    'cdn.cloudflare.steamstatic.com'
    'client-update.akamai.steamstatic.com'
    'media.steampowered.com'
    'content1.steampowered.com'
    'content2.steampowered.com'
    'content3.steampowered.com'
    'content4.steampowered.com'
)

$script:DohProviders = [ordered]@{
    cloudflare    = @{ Base = 'https://cloudflare-dns.com/dns-query'; Format = 'json' }
    google        = @{ Base = 'https://dns.google/resolve'; Format = 'json' }
    adguard       = @{ Base = 'https://dns.adguard-dns.com/resolve'; Format = 'json' }
    quad9         = @{ Base = 'https://dns.quad9.net:5053/dns-query'; Format = 'json' }
    mullvad       = @{ Base = 'https://dns.mullvad.net/dns-query'; Format = 'wire' }
    nextdns       = @{ Base = 'https://dns.nextdns.io/dns-query'; Format = 'wire' }
    'dns.sb'      = @{ Base = 'https://doh.sb/dns-query'; Format = 'wire' }
    opendns       = @{ Base = 'https://doh.opendns.com/dns-query'; Format = 'wire' }
    controld      = @{ Base = 'https://dns.controld.com/p0'; Format = 'wire' }
    cleanbrowsing = @{ Base = 'https://doh.cleanbrowsing.org/doh/family-filter/'; Format = 'wire' }
}

$script:DohProviderName = $DohProvider
$script:DohCustomUri = $DohUri
$script:DohCustomFormat = $DohFormat
$script:DotServer = $DotServer

$script:BadCidrs = @(
    '0.0.0.0/8', '10.0.0.0/8', '100.64.0.0/10', '127.0.0.0/8',
    '169.254.0.0/16', '172.16.0.0/12', '192.168.0.0/16', '224.0.0.0/4',
    '123.16.0.0/12', '42.112.0.0/13', '113.160.0.0/11', '118.68.0.0/14',
    '210.245.0.0/16', '203.113.128.0/18', '125.212.128.0/17',
    '14.160.0.0/11', '27.64.0.0/11'
)

# ---------------------------------------------------------------------------
# performance tuning
# ---------------------------------------------------------------------------
$script:DohTimeoutMs = 2500   # per-provider HTTP timeout
$script:DohOverallTimeout = 3500   # wall-clock limit for parallel batch
$script:TlsTimeoutMs = 4000   # per-candidate TLS handshake
$script:ProviderDeadThreshold = 3   # fail N times with 0 success -> skip

# ---------------------------------------------------------------------------
# runtime state
# ---------------------------------------------------------------------------
$script:IPv6Available = $false
$script:ProviderHealth = @{}
$script:Activity = @{
    Enabled   = $false
    Idx       = 0
    Total     = 0
    Domain    = ''
    Phase     = ''
    Detail    = ''
    TickStart = [DateTime]::UtcNow
    Spinner   = @('|', '/', '-', '\')
}
# shared state for cert-validation callback (avoid scope issues)
$script:TlsState = @{
    Errors = [System.Net.Security.SslPolicyErrors]::None
    Cert   = $null
}

# ---------------------------------------------------------------------------
# palette
# ---------------------------------------------------------------------------
$C = @{
    Text  = 'White'
    Dim   = 'DarkGray'
    Ok    = 'Green'
    Warn  = 'Yellow'
    Fail  = 'Red'
    Label = 'Gray'
}

# ---------------------------------------------------------------------------
# console primitives
# ---------------------------------------------------------------------------
function Write-Header {
    param([switch]$NoClear)
    if (-not $NoClear) { try { Clear-Host } catch { } }
    Write-Host ''
    Write-Host '  ' -NoNewline
    Write-Host $script:AppName -NoNewline -ForegroundColor $C.Text
    Write-Host '  ' -NoNewline
    Write-Host "v$($script:AppVersion)" -NoNewline -ForegroundColor $C.Dim
    Write-Host '  -  ' -NoNewline -ForegroundColor $C.Dim
    Write-Host $script:AppAuthor -NoNewline -ForegroundColor $C.Dim
    Write-Host '  -  ' -NoNewline -ForegroundColor $C.Dim
    Write-Host $script:AppBuiltOn -ForegroundColor $C.Dim
    Write-Host '  ' -NoNewline
    Write-Host ('-' * 62) -ForegroundColor $C.Dim
}

function Write-Section {
    param([Parameter(Mandatory)][string]$Name)
    Write-Host ''
    Write-Host "  $Name" -ForegroundColor $C.Dim
    Write-Host ''
}

function Write-Field {
    param(
        [Parameter(Mandatory)][string]$Label,
        [Parameter(Mandatory)][string]$Value,
        [string]$Color = $C.Text
    )
    Write-Host '    ' -NoNewline
    Write-Host $Label.PadRight(14) -NoNewline -ForegroundColor $C.Label
    Write-Host $Value -ForegroundColor $Color
}

function Write-Summary {
    param(
        [Parameter(Mandatory)][int]$Total,
        [Parameter(Mandatory)][int]$Ok,
        [Parameter(Mandatory)][int]$Warn,
        [Parameter(Mandatory)][int]$Fail,
        [Parameter(Mandatory)][double]$Seconds
    )
    Write-Host ''
    Write-Host '  ' -NoNewline
    Write-Host "$Total hosts" -NoNewline -ForegroundColor $C.Text
    Write-Host '  -  ' -NoNewline -ForegroundColor $C.Dim
    Write-Host "$Ok ok" -NoNewline -ForegroundColor $C.Ok
    Write-Host '  -  ' -NoNewline -ForegroundColor $C.Dim
    Write-Host "$Warn warn" -NoNewline -ForegroundColor $C.Warn
    Write-Host '  -  ' -NoNewline -ForegroundColor $C.Dim
    Write-Host "$Fail fail" -NoNewline -ForegroundColor $C.Fail
    Write-Host '  -  ' -NoNewline -ForegroundColor $C.Dim
    Write-Host ('{0:0.0}s' -f $Seconds) -ForegroundColor $C.Dim
    Write-Host ''
}

function Test-Interactive {
    try { return -not [Console]::IsInputRedirected -and -not [Console]::IsOutputRedirected }
    catch { return $true }
}

function Write-Pause {
    param([string]$Message = 'press enter to continue')
    if (-not (Test-Interactive)) { return }
    Write-Host ''
    Write-Host '  ' -NoNewline -ForegroundColor $C.Dim
    Write-Host $Message -NoNewline -ForegroundColor $C.Dim
    Write-Host ' ...' -NoNewline -ForegroundColor $C.Dim
    try { $null = [Console]::ReadKey($true) }
    catch { try { $null = Read-Host } catch { Start-Sleep -Seconds 3 } }
    Write-Host ''
}

# ---------------------------------------------------------------------------
# live activity reporter (Write-Progress supplemental to Write-Host logs)
# ---------------------------------------------------------------------------
function Initialize-Activity {
    param([int]$Total)
    $script:Activity.Idx = 0
    $script:Activity.Total = $Total
    $script:Activity.Domain = ''
    $script:Activity.Phase = ''
    $script:Activity.Detail = ''
    $script:Activity.TickStart = [DateTime]::UtcNow
}

function Set-Activity {
    param(
        [int]$Index = -1,
        [string]$Domain,
        [string]$Phase,
        [string]$Detail
    )
    if ($Index -ge 0) { $script:Activity.Idx = $Index }
    if ($PSBoundParameters.ContainsKey('Domain')) { $script:Activity.Domain = $Domain }
    if ($PSBoundParameters.ContainsKey('Phase')) {
        $script:Activity.Phase = $Phase
        $script:Activity.TickStart = [DateTime]::UtcNow
    }
    if ($PSBoundParameters.ContainsKey('Detail')) { $script:Activity.Detail = $Detail }
    Render-Activity
}

function Tick-Activity { Render-Activity }

function Render-Activity {
    if (-not $script:Activity.Enabled) { return }
    try {
        $spinIdx = [int]((([DateTime]::UtcNow - $script:Activity.TickStart).TotalMilliseconds / 120)) % $script:Activity.Spinner.Length
        $spin = $script:Activity.Spinner[$spinIdx]
        $elapsed = ([DateTime]::UtcNow - $script:Activity.TickStart).TotalSeconds
        $pct = if ($script:Activity.Total -gt 0) {
            [math]::Max(0, [math]::Min(100, [int](($script:Activity.Idx / $script:Activity.Total) * 100)))
        }
        else { 0 }
        $act = "Steam Access Fixer  [{0}/{1}]" -f $script:Activity.Idx, $script:Activity.Total
        $sub = "$spin  $($script:Activity.Domain)  -  $($script:Activity.Phase)"
        if ($script:Activity.Detail) { $sub += " - $($script:Activity.Detail)" }
        $sub += "  ({0:0.0}s)" -f $elapsed
        Write-Progress -Id 1 -Activity $act -Status $sub -PercentComplete $pct
    }
    catch { }
}

function Complete-Activity {
    try { Write-Progress -Id 1 -Activity 'Steam Access Fixer' -Completed } catch { }
}

# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------
function Get-SafeProp {
    param($Object, [Parameter(Mandatory)][string]$Name)
    if ($null -eq $Object) { return $null }
    $p = $Object.PSObject.Properties[$Name]
    if ($null -eq $p) { return $null }
    return $p.Value
}

function Test-IsUsableIP {
    param([string]$IP)
    if ([string]::IsNullOrWhiteSpace($IP)) { return $false }
    try { $addr = [ipaddress]::Parse($IP) } catch { return $false }
    if ($addr.AddressFamily -ne 'InterNetwork') { return $false }
    $ip = $addr.GetAddressBytes()
    foreach ($cidr in $script:BadCidrs) {
        $parts = $cidr.Split('/')
        $net = [ipaddress]::Parse($parts[0]).GetAddressBytes()
        $bits = [int]$parts[1]
        $bytes = [int][math]::Floor($bits / 8)
        $rem = $bits % 8
        $ok = $true
        for ($i = 0; $i -lt $bytes; $i++) {
            if ($ip[$i] -ne $net[$i]) { $ok = $false; break }
        }
        if ($ok -and $rem -gt 0) {
            $m = (0xFF -shl (8 - $rem)) -band 0xFF
            if (($ip[$bytes] -band $m) -ne ($net[$bytes] -band $m)) { $ok = $false }
        }
        if ($ok) { return $false }
    }
    return $true
}

# ---------------------------------------------------------------------------
# TLS result factory + failure color
# ---------------------------------------------------------------------------
function New-TlsResult {
    param(
        [bool]$Ok = $false,
        [string]$Reason = 'unknown',
        [string]$Detail = ''
    )
    [pscustomobject]@{ Ok = $Ok; Reason = $Reason; Detail = $Detail }
}

function Get-FailureColor {
    param([string]$Reason)
    if ($Reason -eq 'ok') { return $C.Ok }
    switch -Wildcard ($Reason) {
        'tcp-*' { return $C.Fail }
        'tls-rst' { return $C.Fail }
        'tls-timeout' { return $C.Fail }
        'tls-handshake' { return $C.Warn }
        'tls-cert*' { return $C.Warn }
        'tls-*' { return $C.Warn }
        default { return $C.Warn }
    }
}

# ---------------------------------------------------------------------------
# privileges / environment probes
# ---------------------------------------------------------------------------
function Test-IsAdministrator {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $p = [Security.Principal.WindowsPrincipal]::new($id)
    return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Assert-Administrator {
    if (-not (Test-IsAdministrator)) { throw 'administrator privileges required' }
}

function Show-AdminRequired {
    Write-Host ''
    Write-Host '  --------------------------------------------------------------' -ForegroundColor $C.Fail
    Write-Host ''
    Write-Host '   administrator privileges required' -ForegroundColor $C.Fail
    Write-Host ''
    Write-Host '   => close this window' -ForegroundColor $C.Text
    Write-Host '   => right-click PowerShell' -NoNewline -ForegroundColor $C.Text
    Write-Host '  -  ' -NoNewline -ForegroundColor $C.Dim
    Write-Host 'Run as administrator' -ForegroundColor $C.Warn
    Write-Host '   => run this script again' -ForegroundColor $C.Text
    Write-Host ''
    Write-Host '  --------------------------------------------------------------' -ForegroundColor $C.Fail
}

function Get-SelfPath {
    if ($PSCommandPath -and (Test-Path -LiteralPath $PSCommandPath)) {
        return (Resolve-Path -LiteralPath $PSCommandPath).Path
    }
    try {
        $p = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
        if ($p -and (Test-Path -LiteralPath $p)) { return $p }
    }
    catch { }
    return $null
}

function Test-IPv6Available {
    try {
        $addrs = [System.Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces() |
        Where-Object { $_.OperationalStatus -eq 'Up' -and
            $_.NetworkInterfaceType -ne 'Loopback' } |
        ForEach-Object { $_.GetIPProperties().UnicastAddresses } |
        Where-Object { $_.Address.AddressFamily -eq 'InterNetworkV6' -and
            -not $_.Address.IsLinkLocal -and
            -not $_.Address.IsLoopback -and
            -not $_.Address.IsIPv4MappedToIPv6 }
        return ($addrs.Count -gt 0)
    }
    catch { return $false }
}

function Get-OrCreateBackup {
    if (Test-Path -LiteralPath $script:BackupPath) { return $script:BackupPath }
    Copy-Item -LiteralPath $script:HostsPath -Destination $script:BackupPath -ErrorAction Stop
    return $script:BackupPath
}

# ---------------------------------------------------------------------------
# auto elevation
# ---------------------------------------------------------------------------
function Ensure-AdminOrElevate {
    param([string]$ModeArg)
    if (Test-IsAdministrator) { return $true }
    $self = Get-SelfPath
    if (-not $self) {
        Write-Host ''
        Write-Host '  ERROR: cannot determine script path' -ForegroundColor $C.Fail
        Write-Pause
        return $false
    }
    Write-Host ''
    Write-Host '  Requesting administrator privileges...' -ForegroundColor $C.Warn
    Write-Host '  Click "Yes" on the Windows UAC prompt.' -ForegroundColor $C.Dim
    Start-Sleep -Milliseconds 900
    try {
        Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList @(
            '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$self`"", '-Mode', $ModeArg
        ) -Wait | Out-Null
    }
    catch {
        Write-Host '  Elevation cancelled by user.' -ForegroundColor $C.Fail
        Write-Pause
    }
    return $false
}

# ---------------------------------------------------------------------------
# DNS configuration (Fix mode)
# ---------------------------------------------------------------------------
function Get-ActiveInterfaces {
    Get-NetAdapter -ErrorAction SilentlyContinue |
    Where-Object { $_.Status -eq 'Up' -and -not $_.Virtual } |
    Select-Object -ExpandProperty InterfaceIndex
}

function Backup-DnsSettings {
    $state = @{
        Timestamp  = (Get-Date).ToString('o')
        Interfaces = @()
    }
    foreach ($idx in (Get-ActiveInterfaces)) {
        $iface = Get-NetAdapter -InterfaceIndex $idx -ErrorAction SilentlyContinue
        if (-not $iface) { continue }
        $v4 = Get-DnsClientServerAddress -InterfaceIndex $idx -AddressFamily IPv4 -ErrorAction SilentlyContinue
        $v6 = Get-DnsClientServerAddress -InterfaceIndex $idx -AddressFamily IPv6 -ErrorAction SilentlyContinue
        $state.Interfaces += @{
            InterfaceIndex = $idx
            Name           = $iface.Name
            ServerV4       = @($v4.ServerAddresses | Where-Object { $_ })
            ServerV6       = @($v6.ServerAddresses | Where-Object { $_ })
        }
    }
    $dir = Join-Path $env:ProgramData 'SteamAccessFixer'
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -Path $dir -ItemType Directory -Force | Out-Null
    }
    $file = Join-Path $dir 'dns-backup.json'
    $state | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $file -Encoding UTF8
    return $file
}

function Restore-DnsSettings {
    param([Parameter(Mandatory)][string]$BackupFile)
    if (-not (Test-Path -LiteralPath $BackupFile)) {
        throw "dns backup not found: $BackupFile"
    }
    $state = Get-Content -LiteralPath $BackupFile -Raw | ConvertFrom-Json
    foreach ($iface in $state.Interfaces) {
        try {
            if ($iface.ServerV4 -and @($iface.ServerV4).Count -gt 0) {
                Set-DnsClientServerAddress -InterfaceIndex $iface.InterfaceIndex `
                    -ServerAddresses @($iface.ServerV4) -ErrorAction SilentlyContinue
            }
            else {
                Set-DnsClientServerAddress -InterfaceIndex $iface.InterfaceIndex `
                    -ResetServerAddresses -ErrorAction SilentlyContinue
            }
            if ($iface.ServerV6 -and @($iface.ServerV6).Count -gt 0) {
                Set-DnsClientServerAddress -InterfaceIndex $iface.InterfaceIndex `
                    -ServerAddresses @($iface.ServerV6) -ErrorAction SilentlyContinue
            }
        }
        catch { }
    }
    ipconfig /flushdns | Out-Null
}

function Set-DnsForAll {
    param(
        [Parameter(Mandatory)][string]$Primary,
        [Parameter(Mandatory)][string]$Secondary
    )
    $dns = @($Primary, $Secondary)
    foreach ($idx in (Get-ActiveInterfaces)) {
        Set-DnsClientServerAddress -InterfaceIndex $idx `
            -ServerAddresses $dns -ErrorAction Stop
    }
}

function Enable-DoHForServer {
    param(
        [Parameter(Mandatory)][string]$Server,
        [Parameter(Mandatory)][string]$Template
    )
    & netsh dns add encryption "server=$Server" "dohtemplate=$Template" `
        "autoupgrade=yes" "udpfallback=no" 2>&1 | Out-Null

    foreach ($idx in (Get-ActiveInterfaces)) {
        $iface = Get-NetAdapter -InterfaceIndex $idx -ErrorAction SilentlyContinue
        if (-not $iface -or -not $iface.InterfaceGuid) { continue }
        $base = "HKLM:\SYSTEM\CurrentControlSet\Services\Dnscache\InterfaceSpecificParameters\$($iface.InterfaceGuid)\DohInterfaceSettings\Doh"
        $key = Join-Path $base $Server
        try {
            if (-not (Test-Path -LiteralPath $key)) {
                New-Item -Path $key -Force -ErrorAction Stop | Out-Null
            }
            Set-ItemProperty -Path $key -Name 'DohFlags' -Value ([uint64]1) `
                -Type QWord -Force -ErrorAction Stop
        }
        catch { }
    }
}

function Test-SteamReachable {
    $result = [pscustomobject]@{ Ok = $false; Reason = 'unknown'; Detail = '' }
    try {
        $ips = @([System.Net.Dns]::GetHostAddresses('store.steampowered.com') |
            Where-Object { $_.AddressFamily -eq 'InterNetwork' } |
            ForEach-Object { $_.IPAddressToString } |
            Select-Object -Unique)
        if ($ips.Count -eq 0) {
            $result.Reason = 'dns-fail'
            $result.Detail = 'no A records for store.steampowered.com'
            return $result
        }
        $firstFail = $null
        foreach ($ip in $ips) {
            $tls = Test-SniTls -IPAddress $ip -Hostname 'store.steampowered.com' -TimeoutMs 4000
            if ($tls.Ok) {
                $result.Ok = $true
                $result.Reason = 'ok'
                $result.Detail = "ip $ip, TLS ok"
                return $result
            }
            if (-not $firstFail) { $firstFail = $tls }
        }
        $result.Reason = $firstFail.Reason
        $result.Detail = "$($firstFail.Detail) (tried $($ips.Count) ip)"
        return $result
    }
    catch {
        $result.Reason = 'error'
        $result.Detail = $_.Exception.Message
        return $result
    }
}

function Invoke-Fix {
    if (-not (Ensure-AdminOrElevate -ModeArg 'Fix')) { return }

    Write-Header
    Write-Section 'step 1 - backup current dns settings'

    $interfaces = @(Get-ActiveInterfaces)
    if ($interfaces.Count -eq 0) {
        Write-Host '  no active network interfaces found.' -ForegroundColor $C.Fail
        Write-Pause
        return
    }

    $backupFile = Backup-DnsSettings
    Write-Field 'backup' $backupFile $C.Ok
    foreach ($idx in $interfaces) {
        $iface = Get-NetAdapter -InterfaceIndex $idx -ErrorAction SilentlyContinue
        if ($iface) {
            $v4 = Get-DnsClientServerAddress -InterfaceIndex $idx -AddressFamily IPv4 -ErrorAction SilentlyContinue
            $cur = if ($v4.ServerAddresses -and $v4.ServerAddresses.Count -gt 0) {
                $v4.ServerAddresses -join ', '
            } else { '(dhcp)' }
            Write-Field $iface.Name $cur $C.Dim
        }
    }

    # --- detect stale hosts entries ---
    $staleEntries = @()
    try {
        $hostsLines = @(Get-Content -LiteralPath $script:HostsPath -ErrorAction SilentlyContinue)
        $staleEntries = @($hostsLines | Where-Object {
            $_ -match '^\s*\d{1,3}(\.\d{1,3}){3}\s+\S*steam' -or
            $_ -match '^\s*::1?\s+\S*steam'
        })
    } catch { }

    if ($staleEntries.Count -gt 0) {
        Write-Section 'step 1b - stale steam entries detected'
        Write-Host "    found $($staleEntries.Count) steam entry(ies) in hosts file" -ForegroundColor $C.Warn
        Write-Host '    (these will break DNS change if left alone)' -ForegroundColor $C.Dim
        foreach ($e in ($staleEntries | Select-Object -First 3)) {
            Write-Host "      $($e.Trim())" -ForegroundColor $C.Dim
        }
        if ($staleEntries.Count -gt 3) {
            Write-Host "      ... and $($staleEntries.Count - 3) more" -ForegroundColor $C.Dim
        }
    }

    # --- provider menu ---
    Write-Section 'step 2 - choose dns provider'
    Write-Host '    1  cloudflare  (1.1.1.1)      recommended' -ForegroundColor $C.Text
    Write-Host '    2  google      (8.8.8.8)      fallback' -ForegroundColor $C.Text
    Write-Host '    3  quad9       (9.9.9.9)      privacy-focused' -ForegroundColor $C.Text
    Write-Host '    4  cancel' -ForegroundColor $C.Dim
    Write-Host ''
    $choice = Read-Host '  choose [1-4]'

    $providers = @{
        '1' = [pscustomobject]@{ Name='cloudflare'; Primary='1.1.1.1'; Secondary='1.0.0.1';         Template='https://cloudflare-dns.com/dns-query' }
        '2' = [pscustomobject]@{ Name='google';     Primary='8.8.8.8'; Secondary='8.8.4.4';         Template='https://dns.google/dns-query' }
        '3' = [pscustomobject]@{ Name='quad9';      Primary='9.9.9.9'; Secondary='149.112.112.112'; Template='https://dns.quad9.net/dns-query' }
    }
    if (-not $providers.ContainsKey($choice)) {
        Write-Host ''
        Write-Host '  cancelled.' -ForegroundColor $C.Dim
        Write-Pause
        return
    }
    $a = $providers[$choice]

    # --- apply dns ---
    Write-Section "step 3 - applying $($a.Name) dns"
    try {
        Set-DnsForAll -Primary $a.Primary -Secondary $a.Secondary
        Write-Field 'dns' "$($a.Primary), $($a.Secondary)" $C.Ok
    } catch {
        Write-Field 'dns' "failed: $($_.Exception.Message)" $C.Fail
        Write-Pause
        return
    }

    $build   = [System.Environment]::OSVersion.Version.Build
    $isWin11 = $build -ge 22000
    if ($isWin11) {
        try {
            Enable-DoHForServer -Server $a.Primary   -Template $a.Template
            Enable-DoHForServer -Server $a.Secondary -Template $a.Template
            Write-Field 'doh' 'automatic (win11)' $C.Ok
        } catch {
            Write-Field 'doh' "skipped: $($_.Exception.Message)" $C.Warn
        }
    } else {
        Write-Field 'doh' 'not available (win10)' $C.Dim
    }

    # --- remove stale hosts entries if managed by us ---
    if ($staleEntries.Count -gt 0) {
        Write-Section 'step 4 - removing stale hosts entries'
        try {
            $cur   = @(Get-Content -LiteralPath $script:HostsPath -ErrorAction Stop)
            $clean = @(Remove-ManagedHostsEntries -Lines $cur)
            if ($clean.Count -ne $cur.Count) {
                Write-HostsFileSafely -Lines $clean
                Write-Field 'hosts' "$($cur.Count - $clean.Count) entry(ies) removed" $C.Ok
            } else {
                Write-Field 'hosts' 'unmanaged entries present (not touched)' $C.Warn
                Write-Host '    edit C:\Windows\System32\drivers\etc\hosts manually' -ForegroundColor $C.Dim
                Write-Host '    to remove any steam lines by hand' -ForegroundColor $C.Dim
            }
        } catch {
            Write-Field 'hosts' "cleanup failed: $($_.Exception.Message)" $C.Warn
        }
    }

    ipconfig /flushdns | Out-Null
    Write-Field 'cache' 'flushed' $C.Ok

    # --- done ---
    Write-Section 'done'
    Write-Host '    dns changed to ' -NoNewline -ForegroundColor $C.Dim
    Write-Host "$($a.Name) ($($a.Primary), $($a.Secondary))" -ForegroundColor $C.Ok
    Write-Host ''
    Write-Host '    next steps:' -ForegroundColor $C.Text
    Write-Host '      1. close Steam completely (tray icon -> Exit)' -ForegroundColor $C.Dim
    Write-Host '      2. reopen Steam' -ForegroundColor $C.Dim
    Write-Host '      3. if Steam still fails: run this tool again,' -ForegroundColor $C.Dim
    Write-Host '         try option 2 (google) or 3 (quad9)' -ForegroundColor $C.Dim
    Write-Host ''
    Write-Host '    to undo: choose "restore" in main menu' -ForegroundColor $C.Dim
    Write-Host ''
    Write-Pause
}

# ---------------------------------------------------------------------------
# provider health tracker
# ---------------------------------------------------------------------------
function Initialize-ProviderHealth {
    $script:ProviderHealth = @{}
    $script:ProviderDead = @{}
    foreach ($name in $script:DohProviders.Keys) {
        $script:ProviderHealth[$name] = @{
            Success = 0; Fail = 0
            Errors = [System.Collections.Generic.List[string]]::new()
        }
        $script:ProviderDead[$name] = $false
    }
    $script:ProviderHealth['system'] = @{
        Success = 0; Fail = 0
        Errors = [System.Collections.Generic.List[string]]::new()
    }
    $script:ProviderDead['system'] = $false
    if ($script:DotServer) {
        $script:ProviderHealth['dot'] = @{
            Success = 0; Fail = 0
            Errors = [System.Collections.Generic.List[string]]::new()
        }
        $script:ProviderDead['dot'] = $false
    }
}

function Register-ProviderResult {
    param([string]$Provider, [bool]$Success, [string]$ErrorMsg = '')
    if (-not $script:ProviderHealth.ContainsKey($Provider)) { return }
    $h = $script:ProviderHealth[$Provider]
    if ($Success) {
        $h.Success++
    }
    else {
        $h.Fail++
        if ($ErrorMsg -and $h.Errors.Count -lt 3) { $h.Errors.Add($ErrorMsg) }
        if ($h.Success -eq 0 -and $h.Fail -ge $script:ProviderDeadThreshold -and
            $script:ProviderDead.ContainsKey($Provider)) {
            $script:ProviderDead[$Provider] = $true
        }
    }
}

# ---------------------------------------------------------------------------
# DNS wire helpers
# ---------------------------------------------------------------------------
function New-DnsQueryPacket {
    param([string]$Domain, [int]$Id, [int]$QType = 1)
    $ms = [System.IO.MemoryStream]::new()
    $bw = [System.IO.BinaryWriter]::new($ms)
    $bw.Write([uint16]$Id)
    $bw.Write([uint16]0x0100)
    $bw.Write([uint16]1)
    $bw.Write([uint16]0); $bw.Write([uint16]0); $bw.Write([uint16]0)
    foreach ($label in $Domain.Split('.')) {
        $b = [Text.Encoding]::ASCII.GetBytes($label)
        $bw.Write([byte]$b.Length); $bw.Write($b)
    }
    $bw.Write([byte]0)
    $bw.Write([uint16]$QType)
    $bw.Write([uint16]1)
    $bw.Flush()
    return $ms.ToArray()
}

function ConvertTo-Base64Url {
    param([byte[]]$Bytes)
    return ([Convert]::ToBase64String($Bytes)).Replace('+', '-').Replace('/', '_').TrimEnd('=')
}

function Skip-DnsName {
    param([byte[]]$Data, [int]$Offset)
    while ($Offset -lt $Data.Length) {
        $len = $Data[$Offset]
        if ($len -eq 0) { return $Offset + 1 }
        if (($len -band 0xC0) -eq 0xC0) { return $Offset + 2 }
        $Offset += 1 + $len
    }
    throw 'malformed dns name'
}

function ConvertFrom-DnsWireAnswer {
    param([byte[]]$Data, [int]$QType = 1)
    if ($null -eq $Data -or $Data.Length -lt 12) { return @() }
    $qd = ($Data[4] -shl 8) -bor $Data[5]
    $an = ($Data[6] -shl 8) -bor $Data[7]
    $off = 12
    for ($q = 0; $q -lt $qd; $q++) {
        $off = Skip-DnsName -Data $Data -Offset $off
        $off += 4
    }
    $list = [System.Collections.Generic.List[string]]::new()
    for ($a = 0; $a -lt $an -and $off -lt $Data.Length; $a++) {
        $off = Skip-DnsName -Data $Data -Offset $off
        if ($off + 10 -gt $Data.Length) { break }
        $type = ($Data[$off] -shl 8) -bor $Data[$off + 1]
        $rdLen = ($Data[$off + 8] -shl 8) -bor $Data[$off + 9]
        $off += 10
        if ($type -eq 1 -and $QType -eq 1 -and $rdLen -eq 4 -and $off + 4 -le $Data.Length) {
            $list.Add("$($Data[$off]).$($Data[$off+1]).$($Data[$off+2]).$($Data[$off+3])")
        }
        elseif ($type -eq 28 -and $QType -eq 28 -and $rdLen -eq 16 -and $off + 16 -le $Data.Length) {
            $b = [byte[]]::new(16)
            [Array]::Copy($Data, $off, $b, 0, 16)
            try {
                $ipv6 = [System.Net.IPAddress]::new($b)
                if (-not $ipv6.IsLinkLocal -and -not $ipv6.IsLoopback -and
                    -not $ipv6.IsIPv4MappedToIPv6) {
                    $list.Add($ipv6.ToString())
                }
            }
            catch { }
        }
        $off += $rdLen
    }
    return $list.ToArray()
}

# ---------------------------------------------------------------------------
# DoH — async, retry, QType-aware
# ---------------------------------------------------------------------------
function Invoke-DohQuery {
    param(
        [Parameter(Mandatory)][string]$Domain,
        [Parameter(Mandatory)][string]$Base,
        [Parameter(Mandatory)][ValidateSet('json', 'wire')][string]$Format,
        [int]$TimeoutMs = 4000,
        [int]$QType = 1,
        [int]$MaxAttempts = 2,
        [scriptblock]$OnTick
    )

    $typeStr = if ($QType -eq 28) { 'AAAA' } else { 'A' }
    $enc = [uri]::EscapeDataString($Domain)

    if ($Format -eq 'json') {
        $uri = "$Base" + "?name=$enc&type=$typeStr"
        $accept = 'application/dns-json'
    }
    else {
        $id = Get-Random -Minimum 1 -Maximum 65535
        $q = New-DnsQueryPacket -Domain $Domain -Id $id -QType $QType
        $uri = "$Base" + '?dns=' + (ConvertTo-Base64Url -Bytes $q)
        $accept = 'application/dns-message'
    }

    if (-not ('System.Net.Http.HttpClient' -as [type])) {
        Add-Type -AssemblyName System.Net.Http -ErrorAction Stop
    }

    $lastErr = $null
    $bytes = $null

    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        $handler = [System.Net.Http.HttpClientHandler]::new()
        $handler.AllowAutoRedirect = $false
        $client = [System.Net.Http.HttpClient]::new($handler)
        $client.Timeout = [TimeSpan]::FromMilliseconds($TimeoutMs + 1500)
        $client.DefaultRequestHeaders.TryAddWithoutValidation('Accept', $accept) | Out-Null
        $client.DefaultRequestHeaders.TryAddWithoutValidation('User-Agent', 'SteamAccessFixer/1.2.1') | Out-Null
        try {
            $task = $client.GetByteArrayAsync([uri]$uri)
            $sw = [System.Diagnostics.Stopwatch]::StartNew()
            while (-not $task.IsCompleted) {
                if ($sw.ElapsedMilliseconds -gt $TimeoutMs + 500) { throw 'http timeout' }
                if ($OnTick) { $null = & $OnTick }
                Start-Sleep -Milliseconds 60
            }
            if ($task.IsFaulted) {
                $ex = $task.Exception.GetBaseException()
                throw "http: $($ex.Message)"
            }
            if ($task.IsCanceled) { throw 'http cancelled' }
            $bytes = $task.Result
            $lastErr = $null
        }
        catch {
            $lastErr = $_.Exception.Message
            $bytes = $null
        }
        finally {
            $client.Dispose()
        }

        if ($bytes -and $bytes.Length -gt 0) { break }
        if ($attempt -lt $MaxAttempts) { Start-Sleep -Milliseconds (200 * $attempt) }
    }

    if (-not $bytes -or $bytes.Length -eq 0) {
        if ($lastErr) { throw $lastErr }
        throw 'empty body'
    }

    if ($Format -eq 'json') {
        $body = [System.Text.Encoding]::UTF8.GetString($bytes)
        if ([string]::IsNullOrWhiteSpace($body)) { throw 'empty body' }
        if ($body.TrimStart().StartsWith('<')) { throw 'html response (isp intercepted)' }
        try { $json = $body | ConvertFrom-Json -ErrorAction Stop }
        catch { throw 'invalid json' }
        $st = Get-SafeProp $json 'Status'
        if ($null -eq $st) { throw 'unexpected json (no Status)' }
        if ($st -ne 0) { throw "dns status=$st" }
        $ans = Get-SafeProp $json 'Answer'
        if ($null -eq $ans) { throw 'no answer section' }
        $addrs = @($ans | ForEach-Object {
                $t = Get-SafeProp $_ 'type'; $d = [string](Get-SafeProp $_ 'data')
                if ($t -eq 1 -and $QType -eq 1 -and $d -match '^\d{1,3}(\.\d{1,3}){3}$' -and (Test-IsUsableIP $d)) {
                    $d
                }
                elseif ($t -eq 28 -and $QType -eq 28) {
                    try {
                        $p = [ipaddress]::Parse($d)
                        if ($p.AddressFamily -eq 'InterNetworkV6' -and
                            -not $p.IsLinkLocal -and -not $p.IsLoopback -and
                            -not $p.IsIPv4MappedToIPv6) { $d }
                    }
                    catch { }
                }
            } | Where-Object { $_ } | Select-Object -Unique)
        if ($addrs.Count -gt 0) { return $addrs }
        throw 'no usable records'
    }
    else {
        if ($bytes.Length -lt 12) { throw 'bad wire response' }
        $addrs = @(ConvertFrom-DnsWireAnswer -Data $bytes -QType $QType | Select-Object -Unique)
        if ($addrs.Count -gt 0) { return $addrs }
        throw 'no usable records'
    }
}

function Resolve-DnsOverHttps {
    param(
        [Parameter(Mandatory)][string]$Domain,
        [string]$Provider,
        [string]$CustomUri,
        [string]$CustomFormat = 'json',
        [int]$QType = 1,
        [scriptblock]$OnTick
    )

    if (-not $Provider) { $Provider = $script:DohProviderName }
    if (-not $Provider) { $Provider = 'auto' }

    $order = if ($Provider -eq 'auto') { @($script:DohProviders.Keys) } else { @($Provider) }

    # ----- filter dead providers -----
    $active = [System.Collections.Generic.List[string]]::new()
    foreach ($name in $order) {
        if ($Provider -eq 'auto' -and
            $script:ProviderDead.ContainsKey($name) -and
            $script:ProviderDead[$name]) { continue }
        $active.Add($name)
    }
    # if every provider is marked dead, fall back to trying all
    if ($active.Count -eq 0) {
        foreach ($name in $order) { $active.Add($name) }
    }

    $results = [System.Collections.Generic.List[object]]::new()
    $reachable = [System.Collections.Generic.List[string]]::new()

    if ($active.Count -eq 0) {
        return [pscustomobject]@{ Results = @(); Reachable = @() }
    }

    # ----- build parallel requests -----
    $jobs = [System.Collections.Generic.List[object]]::new()
    $client = $null
    $handler = $null

    try {
        if (-not ('System.Net.Http.HttpClient' -as [type])) {
            Add-Type -AssemblyName System.Net.Http -ErrorAction Stop
        }
        $handler = [System.Net.Http.HttpClientHandler]::new()
        $handler.AllowAutoRedirect = $false
        $client = [System.Net.Http.HttpClient]::new($handler)
        $client.Timeout = [TimeSpan]::FromMilliseconds($script:DohOverallTimeout)
        $client.DefaultRequestHeaders.TryAddWithoutValidation('User-Agent', 'SteamAccessFixer/1.2.2') | Out-Null

        $enc = [uri]::EscapeDataString($Domain)
        $typeStr = if ($QType -eq 28) { 'AAAA' } else { 'A' }

        foreach ($name in $active) {
            if ($name -eq 'custom') {
                if ([string]::IsNullOrWhiteSpace($CustomUri)) { $CustomUri = $script:DohCustomUri }
                if (-not $CustomUri) {
                    Register-ProviderResult -Provider 'custom' -Success $false -ErrorMsg 'missing -DohUri'
                    continue
                }
                $cfg = @{ Base = $CustomUri; Format = $CustomFormat }
            }
            else {
                if (-not $script:DohProviders.Contains($name)) { continue }
                $cfg = $script:DohProviders[$name]
            }

            if ($cfg.Format -eq 'json') {
                $uri = "$($cfg.Base)?name=$enc&type=$typeStr"
                $accept = 'application/dns-json'
            }
            else {
                $id = Get-Random -Minimum 1 -Maximum 65535
                $q = New-DnsQueryPacket -Domain $Domain -Id $id -QType $QType
                $uri = "$($cfg.Base)?dns=" + (ConvertTo-Base64Url -Bytes $q)
                $accept = 'application/dns-message'
            }

            $req = [System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::Get, $uri)
            $req.Headers.TryAddWithoutValidation('Accept', $accept) | Out-Null

            $jobs.Add([pscustomobject]@{
                    Name    = $name
                    Format  = $cfg.Format
                    Request = $req
                    Task    = $client.SendAsync($req)
                })
        }

        # ----- wait for all tasks with tick -----
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $timeout = $script:DohOverallTimeout + 500
        while ($true) {
            $pending = 0
            foreach ($j in $jobs) { if (-not $j.Task.IsCompleted) { $pending++ } }
            if ($pending -eq 0) { break }
            if ($sw.ElapsedMilliseconds -gt $timeout) { break }
            if ($OnTick) { $null = & $OnTick }
            Start-Sleep -Milliseconds 80
        }

        # ----- parse results -----
        foreach ($j in $jobs) {
            if (-not $j.Task.IsCompleted -or $j.Task.IsFaulted -or $j.Task.IsCanceled) {
                Register-ProviderResult -Provider $j.Name -Success $false -ErrorMsg 'timeout'
                continue
            }
            try {
                $resp = $j.Task.Result
                if (-not $resp.IsSuccessStatusCode) {
                    Register-ProviderResult -Provider $j.Name -Success $false `
                        -ErrorMsg ("http {0}" -f [int]$resp.StatusCode)
                    continue
                }
                $bytes = $resp.Content.ReadAsByteArrayAsync().GetAwaiter().GetResult()
                if (-not $bytes -or $bytes.Length -eq 0) {
                    Register-ProviderResult -Provider $j.Name -Success $false -ErrorMsg 'empty body'
                    continue
                }

                $addrs = $null
                if ($j.Format -eq 'json') {
                    $body = [System.Text.Encoding]::UTF8.GetString($bytes)
                    if ($body.TrimStart().StartsWith('<')) { throw 'html response' }
                    $json = $body | ConvertFrom-Json -ErrorAction Stop
                    $st = Get-SafeProp $json 'Status'
                    if ($st -ne 0) { throw "dns status=$st" }
                    $ans = Get-SafeProp $json 'Answer'
                    if ($null -eq $ans) { throw 'no answer' }
                    $addrs = @($ans | ForEach-Object {
                            $t = Get-SafeProp $_ 'type'; $d = [string](Get-SafeProp $_ 'data')
                            if ($t -eq 1 -and $QType -eq 1 -and $d -match '^\d{1,3}(\.\d{1,3}){3}$' -and (Test-IsUsableIP $d)) {
                                $d
                            }
                            elseif ($t -eq 28 -and $QType -eq 28) {
                                try {
                                    $p = [ipaddress]::Parse($d)
                                    if ($p.AddressFamily -eq 'InterNetworkV6' -and
                                        -not $p.IsLinkLocal -and -not $p.IsLoopback -and
                                        -not $p.IsIPv4MappedToIPv6) { $d }
                                }
                                catch { }
                            }
                        } | Where-Object { $_ } | Select-Object -Unique)
                }
                else {
                    if ($bytes.Length -lt 12) { throw 'bad wire response' }
                    $addrs = @(ConvertFrom-DnsWireAnswer -Data $bytes -QType $QType | Select-Object -Unique)
                }

                if ($addrs -and $addrs.Count -gt 0) {
                    $reachable.Add($j.Name)
                    Register-ProviderResult -Provider $j.Name -Success $true
                    foreach ($ip in $addrs) {
                        $results.Add([pscustomobject]@{ Provider = $j.Name; IPAddress = $ip })
                    }
                }
                else {
                    Register-ProviderResult -Provider $j.Name -Success $false -ErrorMsg 'no usable records'
                }
            }
            catch {
                Register-ProviderResult -Provider $j.Name -Success $false -ErrorMsg $_.Exception.Message
            }
        }
    }
    finally {
        foreach ($j in $jobs) {
            try { $j.Request.Dispose() } catch { }
        }
        if ($client) { try { $client.Dispose() }  catch { } }
        if ($handler) { try { $handler.Dispose() } catch { } }
    }

    return [pscustomobject]@{
        Results   = $results.ToArray()
        Reachable = $reachable.ToArray()
    }
}

# ---------------------------------------------------------------------------
# DoT
# ---------------------------------------------------------------------------
function Resolve-DnsOverTls {
    param(
        [Parameter(Mandatory)][string]$Domain,
        [Parameter(Mandatory)][string]$Server,
        [int]$Port = 853,
        [int]$TimeoutMs = 6000,
        [int]$QType = 1,
        [scriptblock]$OnTick
    )
    $id = Get-Random -Minimum 1 -Maximum 65535
    $q = New-DnsQueryPacket -Domain $Domain -Id $id -QType $QType
    $client = $null; $ssl = $null
    try {
        $client = [System.Net.Sockets.TcpClient]::new()
        $t = $client.ConnectAsync($Server, $Port)
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        while (-not $t.IsCompleted) {
            if ($sw.ElapsedMilliseconds -gt $TimeoutMs) { throw 'connect timeout' }
            if ($OnTick) { $null = & $OnTick }
            Start-Sleep -Milliseconds 50
        }
        if (-not $client.Connected) { throw 'connect failed' }

        $ssl = [System.Net.Security.SslStream]::new($client.GetStream(), $false)
        $authTask = $ssl.AuthenticateAsClientAsync($Server)
        $sw.Restart()
        while (-not $authTask.IsCompleted) {
            if ($sw.ElapsedMilliseconds -gt $TimeoutMs) { throw 'tls timeout' }
            if ($OnTick) { $null = & $OnTick }
            Start-Sleep -Milliseconds 50
        }
        if ($authTask.IsFaulted) { throw $authTask.Exception.GetBaseException().Message }

        $len = [byte[]]@([byte](($q.Length -shr 8) -band 0xFF), [byte]($q.Length -band 0xFF))
        $ssl.Write($len, 0, 2)
        $ssl.Write($q, 0, $q.Length)
        $ssl.Flush()
        $hdr = [byte[]]::new(2); $read = 0
        while ($read -lt 2) { $n = $ssl.Read($hdr, $read, 2 - $read); if ($n -le 0) { throw 'closed' }; $read += $n }
        $rl = ($hdr[0] -shl 8) -bor $hdr[1]
        if ($rl -le 0 -or $rl -gt 8192) { throw "bad length $rl" }
        $resp = [byte[]]::new($rl); $read = 0
        while ($read -lt $rl) { $n = $ssl.Read($resp, $read, $rl - $read); if ($n -le 0) { throw 'closed mid-response' }; $read += $n }
        return @(ConvertFrom-DnsWireAnswer -Data $resp -QType $QType | Select-Object -Unique)
    }
    finally {
        if ($ssl) { try { $ssl.Dispose() }    catch { } }
        if ($client) { try { $client.Dispose() } catch { } }
    }
}

# ---------------------------------------------------------------------------
# system DNS fallback
# ---------------------------------------------------------------------------
function Resolve-DnsFallback {
    param([Parameter(Mandatory)][string]$Domain)
    try {
        $ips = [System.Net.Dns]::GetHostAddresses($Domain) |
        Where-Object { $_.AddressFamily -eq 'InterNetwork' } |
        ForEach-Object { $_.IPAddressToString } |
        Select-Object -Unique
        $clean = @($ips | Where-Object { Test-IsUsableIP $_ })
        return $clean
    }
    catch { return @() }
}

# ---------------------------------------------------------------------------
# TCP/443 — quick probe (legacy)
# ---------------------------------------------------------------------------
function Test-Tcp443 {
    param(
        [Parameter(Mandatory)][string]$IPAddress,
        [scriptblock]$OnTick,
        [int]$TimeoutMs = 3000
    )
    $client = $null
    try {
        $client = [System.Net.Sockets.TcpClient]::new()
        $task = $client.ConnectAsync($IPAddress, 443)
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        while (-not $task.IsCompleted -and $sw.ElapsedMilliseconds -lt $TimeoutMs) {
            if ($OnTick) { $null = & $OnTick }
            Start-Sleep -Milliseconds 80
        }
        return ($task.IsCompleted -and -not $task.IsFaulted -and -not $task.IsCanceled -and $client.Connected)
    }
    catch { return $false }
    finally {
        if ($client) {
            try { $client.Close() } catch { }
            try { $client.Dispose() } catch { }
        }
    }
}

# ---------------------------------------------------------------------------
# SNI-TLS verification with structured failure diagnosis
# Reason ∈ ok | tcp-* | tls-rst | tls-timeout | tls-cert | tls-handshake | fatal
# ---------------------------------------------------------------------------
function Test-SniTls {
    param(
        [Parameter(Mandatory)][string]$IPAddress,
        [Parameter(Mandatory)][string]$Hostname,
        [int]$TimeoutMs = 5000,
        [scriptblock]$OnTick
    )
    $client = $null
    $ssl = $null
    $r = New-TlsResult

    try {
        $client = [System.Net.Sockets.TcpClient]::new()
        $task = $client.ConnectAsync($IPAddress, 443)
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        while (-not $task.IsCompleted) {
            if ($sw.ElapsedMilliseconds -gt $TimeoutMs) {
                $r.Reason = 'tcp-timeout'; $r.Detail = "connect > ${TimeoutMs}ms"
                return $r
            }
            if ($OnTick) { $null = & $OnTick }
            Start-Sleep -Milliseconds 50
        }
        if ($task.IsFaulted -or $task.IsCanceled -or -not $client.Connected) {
            $inner = if ($task.Exception) { $task.Exception.GetBaseException() } else { $null }
            $sock = $inner -as [System.Net.Sockets.SocketException]
            if ($sock) {
                $r.Reason = switch ($sock.SocketErrorCode) {
                    'ConnectionRefused' { 'tcp-refused' }
                    'ConnectionReset' { 'tcp-reset' }
                    'TimedOut' { 'tcp-timeout' }
                    'HostUnreachable' { 'tcp-unreach' }
                    default { 'tcp-error' }
                }
                $r.Detail = $sock.Message
            }
            else {
                $r.Reason = 'tcp-error'
                $r.Detail = if ($inner) { $inner.Message } else { 'connect failed' }
            }
            return $r
        }

        # reset shared TLS state
        $script:TlsState.Errors = [System.Net.Security.SslPolicyErrors]::None
        $script:TlsState.Cert = $null

        $callback = [System.Net.Security.RemoteCertificateValidationCallback] {
            param($sender, $certificate, $chain, $errors)
            $script:TlsState.Errors = $errors
            $script:TlsState.Cert = $certificate
            return $true
        }

        $ssl = [System.Net.Security.SslStream]::new($client.GetStream(), $false, $callback)
        $ssl.ReadTimeout = $TimeoutMs
        $ssl.WriteTimeout = $TimeoutMs
        $tlsTask = $ssl.AuthenticateAsClientAsync($Hostname)
        $sw.Restart()
        while (-not $tlsTask.IsCompleted) {
            if ($sw.ElapsedMilliseconds -gt $TimeoutMs) {
                $r.Reason = 'tls-timeout'; $r.Detail = "handshake > ${TimeoutMs}ms"
                return $r
            }
            if ($OnTick) { $null = & $OnTick }
            Start-Sleep -Milliseconds 50
        }
        if ($tlsTask.IsFaulted) {
            $ex = $tlsTask.Exception.GetBaseException()
            $walked = $ex; $sockEx = $null
            for ($i = 0; $i -lt 5 -and $walked; $i++) {
                if ($walked -is [System.Net.Sockets.SocketException]) { $sockEx = $walked; break }
                $walked = $walked.InnerException
            }
            if ($sockEx) {
                $r.Reason = switch ($sockEx.SocketErrorCode) {
                    'ConnectionReset' { 'tls-rst' }
                    'TimedOut' { 'tls-timeout' }
                    default { 'tls-sockerr' }
                }
                $r.Detail = $sockEx.Message
                return $r
            }
            $r.Reason = 'tls-handshake'
            $r.Detail = ($ex.Message -split "`n")[0]
            if ($ex.InnerException) { $r.Detail += " ($($ex.InnerException.Message))" }
            return $r
        }
        if ($tlsTask.IsCanceled) { $r.Reason = 'tls-cancel'; return $r }
        $null = $tlsTask.GetAwaiter().GetResult()

        # classify captured cert errors
        $errs = $script:TlsState.Errors
        $cert = $script:TlsState.Cert

        if ($errs -eq [System.Net.Security.SslPolicyErrors]::None) {
            $r.Ok = $true; $r.Reason = 'ok'; $r.Detail = 'TLS+CN ok'
            return $r
        }

        $parts = [System.Collections.Generic.List[string]]::new()
        if (($errs -band [System.Net.Security.SslPolicyErrors]::RemoteCertificateNameMismatch) -ne 0) {
            $parts.Add('name-mismatch')
        }
        if (($errs -band [System.Net.Security.SslPolicyErrors]::RemoteCertificateNotAvailable) -ne 0) {
            $parts.Add('no-cert')
        }
        if (($errs -band [System.Net.Security.SslPolicyErrors]::RemoteCertificateChainErrors) -ne 0) {
            $isExpired = $false
            try {
                if ($cert) {
                    $c2 = [System.Security.Cryptography.X509Certificates.X509Certificate2]$cert
                    $now = [DateTime]::UtcNow
                    if ($c2.NotAfter.ToUniversalTime() -lt $now -or $c2.NotBefore.ToUniversalTime() -gt $now) {
                        $isExpired = $true
                    }
                }
            }
            catch { }
            if ($isExpired) { $parts.Add('expired') } else { $parts.Add('chain') }
        }
        if ($parts.Count -eq 0) { $parts.Add('unknown') }

        $r.Reason = 'tls-cert'
        $r.Detail = $parts -join ','
        if ($cert) {
            try {
                $c2 = [System.Security.Cryptography.X509Certificates.X509Certificate2]$cert
                $cn = $c2.GetNameInfo(
                    [System.Security.Cryptography.X509Certificates.X509NameType]::SimpleName, $false)
                if ($cn) { $r.Detail += " (server CN: $cn)" }
            }
            catch { }
        }
        return $r
    }
    catch {
        $r.Reason = 'fatal'
        $r.Detail = $_.Exception.Message
        return $r
    }
    finally {
        if ($ssl) { try { $ssl.Dispose() }    catch { } }
        if ($client) { try { $client.Dispose() } catch { } }
    }
}

function Test-Http80 {
    param(
        [Parameter(Mandatory)][string]$IPAddress,
        [Parameter(Mandatory)][string]$Hostname,
        [int]$TimeoutMs = 4000
    )
    $client = $null
    try {
        $client = [System.Net.Sockets.TcpClient]::new()
        $task = $client.ConnectAsync($IPAddress, 80)
        if (-not $task.Wait($TimeoutMs)) { return $false }
        if (-not $client.Connected) { return $false }
        $stream = $client.GetStream()
        $stream.ReadTimeout = $TimeoutMs
        $req = "GET / HTTP/1.1`r`nHost: $Hostname`r`nUser-Agent: SteamAccessFixer/1.2.2`r`nConnection: close`r`n`r`n"
        $bytes = [Text.Encoding]::ASCII.GetBytes($req)
        $stream.Write($bytes, 0, $bytes.Length)
        $buf = [byte[]]::new(256)
        $n = $stream.Read($buf, 0, 256)
        if ($n -le 0) { return $false }
        $resp = [Text.Encoding]::ASCII.GetString($buf, 0, $n)
        return ($resp -match '^HTTP/\d\.\d\s+(200|204|206|301|302|304|400|403|404)')
    }
    catch { return $false }
    finally {
        if ($client) { try { $client.Dispose() } catch { } }
    }
}

# ---------------------------------------------------------------------------
# per-domain resolution
# ---------------------------------------------------------------------------
function Resolve-Domain {
    param([string]$Domain, [int]$Index, [int]$Total)

    $pool = [System.Collections.Generic.List[object]]::new()
    $reachable = [System.Collections.Generic.List[string]]::new()
    $OnTick = { Tick-Activity }

    # header
    Write-Host ''
    Write-Host '    ' -NoNewline
    Write-Host ("[{0,3}/{1}]" -f $Index, $Total) -NoNewline -ForegroundColor $C.Label
    Write-Host " $Domain" -ForegroundColor $C.Text

    # DoT (optional)
    if ($script:DotServer) {
        Set-Activity -Phase 'dot' -Detail $script:DotServer
        try {
            $ips = @(Resolve-DnsOverTls -Domain $Domain -Server $script:DotServer -TimeoutMs 3000 -OnTick $OnTick)
            if ($ips.Count -gt 0) {
                $reachable.Add('dot')
                Register-ProviderResult -Provider 'dot' -Success $true
                foreach ($ip in $ips) { $pool.Add([pscustomobject]@{ Provider = 'dot'; IPAddress = $ip }) }
            }
        }
        catch {
            Register-ProviderResult -Provider 'dot' -Success $false -ErrorMsg $_.Exception.Message
        }
    }

    # DoH
    $doh = Resolve-DnsOverHttps -Domain $Domain -OnTick $OnTick
    foreach ($r in $doh.Results) { $pool.Add($r) }
    foreach ($p in $doh.Reachable) { $reachable.Add($p) }

    # fallback system DNS
    $usedFallback = $false
    if ($pool.Count -eq 0) {
        $usedFallback = $true
        Set-Activity -Phase 'fallback' -Detail 'system dns'
        $ips = @(Resolve-DnsFallback -Domain $Domain)
        if ($ips.Count -gt 0) {
            $reachable.Add('system')
            Register-ProviderResult -Provider 'system' -Success $true
        }
        foreach ($ip in $ips) { $pool.Add([pscustomobject]@{ Provider = 'system'; IPAddress = $ip }) }
    }

    if ($pool.Count -eq 0) {
        Write-Host '             ' -NoNewline -ForegroundColor $C.Dim
        Write-Host '=> fail (dns)' -ForegroundColor $C.Fail
        return [pscustomobject]@{ Domain = $Domain; IPAddress = $null; IPv6 = $null; Port443 = $false; Kind = 'fail' }
    }

    Write-Host '             ' -NoNewline -ForegroundColor $C.Dim
    Write-Host ("resolve: {0} candidate(s), {1} resolver(s) reachable" -f $pool.Count, $reachable.Count) -ForegroundColor $C.Dim

    Set-Activity -Phase 'verifying' -Detail "$($pool.Count) candidates"
    $byIp = $pool | Group-Object -Property IPAddress | Sort-Object { - ($_.Count) }
    $minVotes = if ($script:DohProviderName -eq 'auto' -and $reachable.Count -ge 3) { 2 } else { 1 }

    $passing = [System.Collections.Generic.List[object]]::new()
    $failReasons = [System.Collections.Generic.List[string]]::new()

    foreach ($g in $byIp) {
        $ip = $g.Name
        $providers = @($g.Group | ForEach-Object { $_.Provider } | Select-Object -Unique)
        $provCount = $providers.Count
        $provLabel = $providers -join ','

        if ($provCount -lt $minVotes) {
            Write-Host '             ' -NoNewline -ForegroundColor $C.Dim
            Write-Host ("v4 {0,-16}" -f $ip) -NoNewline -ForegroundColor $C.Dim
            Write-Host (" ({0}v) " -f $provCount) -NoNewline -ForegroundColor $C.Dim
            Write-Host "skip (need $minVotes votes)" -ForegroundColor $C.Dim
            continue
        }

        Set-Activity -Phase "tls $ip" -Detail "$provCount vote(s)"
        $tls = Test-SniTls -IPAddress $ip -Hostname $Domain -TimeoutMs $script:TlsTimeoutMs -OnTick $OnTick
        if ($null -eq $tls -or -not ($tls.PSObject.Properties['Ok'])) {
            $tls = New-TlsResult -Ok $false -Reason 'internal' -Detail 'Test-SniTls returned invalid object'
        }

        Write-Host '             ' -NoNewline -ForegroundColor $C.Dim
        Write-Host ("v4 {0,-16}" -f $ip) -NoNewline -ForegroundColor $C.Dim
        Write-Host (" ({0}v) " -f $provCount) -NoNewline -ForegroundColor $C.Dim
        if ($tls.Ok) {
            Write-Host 'ok' -ForegroundColor $C.Ok
            $passing.Add([pscustomobject]@{
                    IPAddress     = $ip
                    Providers     = $provLabel
                    ProviderCount = $provCount
                })
            break                        # <-- EARLY EXIT
        }
        else {
            $color = Get-FailureColor -Reason $tls.Reason
            Write-Host $tls.Reason -NoNewline -ForegroundColor $color
            if ($tls.Detail) { Write-Host " ($($tls.Detail))" -ForegroundColor $C.Dim }
            else { Write-Host '' }
            $failReasons.Add("$ip`: $($tls.Reason) - $($tls.Detail)")
        }
    }

    if ($passing.Count -eq 0) {
        # HTTP/80 fallback — CDN content often served over plain HTTP
        Write-Host '             ' -NoNewline -ForegroundColor $C.Dim
        Write-Host 'fallback: http/80' -ForegroundColor $C.Dim
        $httpPass = [System.Collections.Generic.List[object]]::new()
        foreach ($g in $byIp) {
            Set-Activity -Phase "http $($g.Name)" -Detail 'port 80'
            if (Test-Http80 -IPAddress $g.Name -Hostname $Domain) {
                $provCount = @($g.Group | ForEach-Object { $_.Provider } | Select-Object -Unique).Count
                $httpPass.Add([pscustomobject]@{
                        IPAddress     = $g.Name
                        Providers     = ($g.Group | ForEach-Object { $_.Provider } | Select-Object -Unique) -join ','
                        ProviderCount = $provCount
                    })
                Write-Host '             ' -NoNewline -ForegroundColor $C.Dim
                Write-Host ("v4 {0,-16}" -f $g.Name) -NoNewline -ForegroundColor $C.Dim
                Write-Host (" ({0}v) " -f $provCount) -NoNewline -ForegroundColor $C.Dim
                Write-Host 'ok (http)' -ForegroundColor $C.Warn
            }
        }
        if ($httpPass.Count -gt 0) {
            $bestHttp = $httpPass | Sort-Object ProviderCount -Descending | Select-Object -First 1
            Write-Host '             ' -NoNewline -ForegroundColor $C.Dim
            Write-Host '=> ' -NoNewline -ForegroundColor $C.Dim
            Write-Host "http-only $($bestHttp.IPAddress)" -NoNewline -ForegroundColor $C.Warn
            Write-Host ' (client download may still work)' -ForegroundColor $C.Dim
            return [pscustomobject]@{
                Domain        = $Domain
                IPAddress     = $bestHttp.IPAddress
                IPv6          = $null
                Port443       = $false
                Kind          = 'http-only'
                ProviderCount = $bestHttp.ProviderCount
            }
        }
        Write-Host '             ' -NoNewline -ForegroundColor $C.Dim
        Write-Host '=> warn (no tls, no http)' -ForegroundColor $C.Warn
        return [pscustomobject]@{ Domain = $Domain; IPAddress = $byIp[0].Name; IPv6 = $null; Port443 = $false; Kind = 'warn' }
    }

    $best = $passing | Sort-Object -Property @{ Expression = 'ProviderCount'; Descending = $true } | Select-Object -First 1

    # IPv6 (AAAA) — only if system has IPv6
    $bestV6 = $null
    if ($script:IPv6Available) {
        $firstProvider = ($best.Providers -split ',')[0]
        $v6Provider = if ($firstProvider -in @('dot', 'system')) { 'cloudflare' } else { $firstProvider }
        Set-Activity -Phase 'ipv6' -Detail "AAAA via $v6Provider"
        try {
            $doh6 = Resolve-DnsOverHttps -Domain $Domain -Provider $v6Provider -QType 28 -OnTick $OnTick
            $v6Groups = @($doh6.Results | Group-Object IPAddress | Sort-Object { - ($_.Count) })
            foreach ($g6 in $v6Groups) {
                Set-Activity -Phase "tls6 $($g6.Name)" -Detail 'AAAA'
                $tls6 = Test-SniTls -IPAddress $g6.Name -Hostname $Domain -OnTick $OnTick
                if ($null -eq $tls6 -or -not ($tls6.PSObject.Properties['Ok'])) {
                    $tls6 = New-TlsResult
                }
                if ($tls6.Ok) { $bestV6 = $g6.Name; break }
            }
        }
        catch { }
    }

    $suffix = if ($usedFallback) { ' (system dns)' } else {
        " ({0} of {1} reachable)" -f $best.ProviderCount, $reachable.Count
    }
    if ($bestV6) { $suffix += ' +v6' }
    Write-Host '             ' -NoNewline -ForegroundColor $C.Dim
    Write-Host '=> ' -NoNewline -ForegroundColor $C.Dim
    Write-Host "ok $($best.IPAddress)" -NoNewline -ForegroundColor $C.Ok
    Write-Host $suffix -ForegroundColor $C.Dim

    return [pscustomobject]@{
        Domain        = $Domain
        IPAddress     = $best.IPAddress
        IPv6          = $bestV6
        Port443       = $true
        Kind          = 'ok'
        ProviderCount = $best.ProviderCount
    }
}

# ---------------------------------------------------------------------------
# full scan
# ---------------------------------------------------------------------------
function Invoke-DomainScan {
    $total = $script:Domains.Count
    $ok = 0; $warn = 0; $fail = 0
    $all = [System.Collections.Generic.List[object]]::new()

    Initialize-ProviderHealth
    Initialize-Activity -Total $total

    Write-Section "scanning $total hosts"
    $scanSw = [System.Diagnostics.Stopwatch]::StartNew()

    for ($i = 0; $i -lt $total; $i++) {
        $domain = $script:Domains[$i]
        Set-Activity -Index ($i + 1) -Domain $domain -Phase 'starting' -Detail ''
        $r = Resolve-Domain -Domain $domain -Index ($i + 1) -Total $total
        $all.Add($r)
        switch ($r.Kind) {
            'ok' { $ok++ }
            'warn' { $warn++ }
            'http-only' { $warn++ }
            default { $fail++ }
        }
    }

    Complete-Activity
    $scanSw.Stop()
    Write-Summary -Total $total -Ok $ok -Warn $warn -Fail $fail -Seconds $scanSw.Elapsed.TotalSeconds
    Show-ScanReport -Results $all.ToArray()
    return $all.ToArray()
}

function Show-ScanReport {
    param($Results)
    Write-Host '  provider health' -ForegroundColor $C.Dim
    Write-Host ''
    Write-Host ('    {0,-14} {1,5} {2,5}  {3}' -f 'provider', 'ok', 'fail', 'last error') -ForegroundColor $C.Dim
    Write-Host ('    {0,-14} {1,5} {2,5}  {3}' -f ('-' * 14), ('-' * 5), ('-' * 5), ('-' * 40)) -ForegroundColor $C.Dim
    foreach ($name in ($script:ProviderHealth.Keys | Sort-Object)) {
        $h = $script:ProviderHealth[$name]
        if ($h.Success -eq 0 -and $h.Fail -eq 0) { continue }
        $color = if ($h.Success -gt 0 -and $h.Fail -eq 0) { $C.Ok }
        elseif ($h.Success -gt 0) { $C.Warn }
        else { $C.Fail }
        $err = if ($h.Errors.Count -gt 0) { [string]$h.Errors[0] } else { '' }
        if ($err.Length -gt 40) { $err = $err.Substring(0, 37) + '...' }
        Write-Host ('    {0,-14} {1,5} {2,5}  {3}' -f $name, $h.Success, $h.Fail, $err) -ForegroundColor $color
    }

    $fails = @($Results | Where-Object { $_.Kind -ne 'ok' })
    if ($fails.Count -gt 0) {
        Write-Host ''
        Write-Host '  diagnosis' -ForegroundColor $C.Dim
        Write-Host ''
        if ($fails.Count -eq $Results.Count) {
            Write-Host '    all hosts failed TLS verification.' -ForegroundColor $C.Fail
            Write-Host '    this is the signature of ISP-level blocking.' -ForegroundColor $C.Fail
            Write-Host ''
            Write-Host '    hosts-file override will NOT fix this.' -ForegroundColor $C.Warn
            Write-Host '    alternatives:' -ForegroundColor $C.Dim
            Write-Host '      - VPN (WireGuard / OpenVPN)           <- reliable' -ForegroundColor $C.Dim
            Write-Host '      - DPI bypass (GoodbyeDPI / zapret)    <- VN-specific' -ForegroundColor $C.Dim
            Write-Host '      - DoH set at OS level (Settings > DNS)' -ForegroundColor $C.Dim
            Write-Host ''
        }
        else {
            Write-Host ("    {0} of {1} hosts failed." -f $fails.Count, $Results.Count) -ForegroundColor $C.Warn
            Write-Host '    partial override still worth applying for working hosts.' -ForegroundColor $C.Dim
            Write-Host ''
        }
        $breakdown = $fails | Group-Object Kind | ForEach-Object { "$($_.Name)=$($_.Count)" }
        Write-Host ("    reason breakdown: $($breakdown -join ', ')") -ForegroundColor $C.Dim
        Write-Host ''
    }
}

# ---------------------------------------------------------------------------
# hosts file helpers
# ---------------------------------------------------------------------------
function Remove-ManagedHostsEntries {
    param([AllowEmptyCollection()][string[]]$Lines)
    $output = [System.Collections.Generic.List[string]]::new()
    $inside = $false
    foreach ($line in @($Lines)) {
        if ($null -eq $line) { continue }
        if ($line.Trim() -eq $script:ManagedStart) { $inside = $true; continue }
        if ($inside) {
            if ($line.Trim() -eq $script:ManagedEnd) { $inside = $false }
            continue
        }
        if ($line -match '^\s*\d{1,3}(\.\d{1,3}){3}\s+\S*steampowered\.com\b' -or
            $line -match '^\s*\d{1,3}(\.\d{1,3}){3}\s+\S*steamcommunity\.com\b' -or
            $line -match '^\s*\d{1,3}(\.\d{1,3}){3}\s+\S*steamstatic\.com\b' -or
            $line -match '^\s*#\s*--- Steam Access Fix Block ---') { continue }
        $output.Add($line)
    }
    if ($inside) { throw 'managed hosts block is malformed (end marker missing); no changes written' }
    return $output.ToArray()
}

function Write-HostsFileSafely {
    param([AllowEmptyCollection()][string[]]$Lines)
    Assert-Administrator
    if (-not (Test-Path -LiteralPath $script:HostsPath -PathType Leaf)) {
        throw "hosts file not found: $($script:HostsPath)"
    }
    $dir = Split-Path -Parent $script:HostsPath
    $tmp = Join-Path $dir ("hosts.steamfix.{0}.tmp" -f [guid]::NewGuid().ToString('N'))
    $enc = [System.Text.UTF8Encoding]::new($false)
    try {
        [System.IO.File]::WriteAllLines($tmp, $Lines, $enc)
        if ([System.IO.File]::Exists($script:HostsPath)) {
            [System.IO.File]::Replace($tmp, $script:HostsPath, $null, $true)
        }
        else {
            [System.IO.File]::Move($tmp, $script:HostsPath)
        }
    }
    catch {
        throw "could not update hosts file: $($_.Exception.Message)"
    }
    finally {
        if (Test-Path -LiteralPath $tmp) {
            Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
        }
    }
}

# ---------------------------------------------------------------------------
# actions
# ---------------------------------------------------------------------------
function Invoke-Diagnose {
    Write-Header
    Write-Section 'environment'
    Write-Field 'hosts file' $script:HostsPath
    Write-Field 'backup'     $script:BackupPath
    if (Test-IsAdministrator) { Write-Field 'privileges' 'administrator' $C.Ok }
    else { Write-Field 'privileges' 'standard user' $C.Warn }
    Write-Field 'doh'        $(if ($script:DohProviderName -eq 'auto') { 'auto' } else { $script:DohProviderName })
    if ($script:DotServer) { Write-Field 'dot' $script:DotServer }
    Write-Field 'ipv6'       $(if ($script:IPv6Available) { 'available' } else { 'not present' }) $C.Dim
    Write-Field 'session'    (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    Invoke-DomainScan | Out-Null
}

function Invoke-Apply {
    Assert-Administrator
    Write-Header
    Write-Section 'preflight'

    if (-not (Test-Path -LiteralPath $script:HostsPath -PathType Leaf)) {
        Write-Field 'hosts' "missing: $($script:HostsPath)" $C.Fail
        throw 'hosts file not found'
    }
    Write-Field 'hosts' 'located' $C.Ok

    $bak = Get-OrCreateBackup
    if ((Get-Item -LiteralPath $bak).CreationTime -lt (Get-Date).AddSeconds(-5)) {
        Write-Field 'backup' "existing: $bak" $C.Warn
    }
    else {
        Write-Field 'backup' "created: $bak" $C.Ok
    }

    if ($script:IPv6Available) {
        Write-Field 'ipv6' 'enabled - will resolve AAAA too' $C.Dim
    }

    $scan = @(Invoke-DomainScan)
    $valid = @($scan | Where-Object { $_.IPAddress -and ($_.Port443 -or $_.Kind -eq 'http-only') })

    if ($valid.Count -eq 0) {
        Write-Section 'aborted'
        Write-Host '    no host passed TLS verification' -ForegroundColor $C.Fail
        Write-Host '    hosts file was NOT modified' -ForegroundColor $C.Warn
        Write-Host ''
        return
    }

    Write-Section 'writing hosts overrides'

    $cur = @(Get-Content -LiteralPath $script:HostsPath -ErrorAction Stop)
    $clean = @(Remove-ManagedHostsEntries -Lines $cur)
    Write-Field 'existing' "$($cur.Count) lines"
    Write-Field 'stripped' "$($cur.Count - $clean.Count) managed/legacy entries"

    $new = [System.Collections.Generic.List[string]]::new()
    foreach ($l in $clean) { $new.Add($l) }
    if ($new.Count -gt 0 -and $new[$new.Count - 1] -ne '') { $new.Add('') }

    $new.Add($script:ManagedStart)
    foreach ($r in $valid) {
        $new.Add("$($r.IPAddress)`t$($r.Domain)")
        if ($r.IPv6) { $new.Add("$($r.IPv6)`t$($r.Domain)") }
    }
    $new.Add($script:ManagedEnd)

    Write-HostsFileSafely -Lines $new.ToArray()
    Write-Field 'write' 'atomic (temp + replace)' $C.Ok

    # verify not silently reverted by AV/Defender
    Start-Sleep -Milliseconds 600
    $verify = Get-Content -LiteralPath $script:HostsPath -Raw
    $missing = @($valid | Where-Object {
            $verify -notmatch [regex]::Escape("$($_.IPAddress)`t$($_.Domain)")
        })
    if ($missing.Count -gt 0) {
        Write-Field 'verify' "$($missing.Count) entries MISSING (AV revert?)" $C.Fail
        Write-Host '    tip: add hosts file to antivirus exclusion list' -ForegroundColor $C.Dim
    }
    else {
        Write-Field 'verify' "$($valid.Count) entries present" $C.Ok
    }

    Write-Section 'post-apply'
    ipconfig /flushdns | Out-Null
    Write-Field 'dns cache' 'flushed' $C.Ok

    Write-Host ''
    Write-Host '    next steps:' -ForegroundColor $C.Text
    Write-Host '      1. exit Steam completely (tray icon -> Exit)' -ForegroundColor $C.Dim
    Write-Host '      2. reopen Steam' -ForegroundColor $C.Dim
    Write-Host '      3. if still failing: run Diagnose, check provider health' -ForegroundColor $C.Dim
    Write-Host ''
}

function Invoke-Restore {
    if (-not (Ensure-AdminOrElevate -ModeArg 'Restore')) { return }

    Write-Header
    Write-Section 'restore'

    # --- DNS ---
    $dnsBackup = Join-Path (Join-Path $env:ProgramData 'SteamAccessFixer') 'dns-backup.json'
    if (Test-Path -LiteralPath $dnsBackup) {
        try {
            Restore-DnsSettings -BackupFile $dnsBackup
            Write-Field 'dns' 'restored from backup' $C.Ok
        }
        catch {
            Write-Field 'dns' "restore failed: $($_.Exception.Message)" $C.Fail
        }
    }
    else {
        Write-Field 'dns' 'no backup present (unchanged)' $C.Dim
    }

    # --- hosts ---
    if (Test-Path -LiteralPath $script:BackupPath -PathType Leaf) {
        Write-Field 'backup' "found: $($script:BackupPath)" $C.Ok
        $rt = "$($script:HostsPath).restore.tmp"
        Copy-Item -LiteralPath $script:BackupPath -Destination $rt -Force
        try {
            [System.IO.File]::Replace($rt, $script:HostsPath, $null, $true)
            Write-Field 'hosts' 'restored from backup (backup preserved)' $C.Ok
        }
        catch {
            Write-Field 'hosts' "restore failed: $($_.Exception.Message)" $C.Fail
        }
        finally {
            if (Test-Path -LiteralPath $rt) {
                Remove-Item -LiteralPath $rt -Force -ErrorAction SilentlyContinue
            }
        }
    }
    else {
        Write-Field 'hosts' 'no backup - stripping managed entries' $C.Dim
        $cur = @(Get-Content -LiteralPath $script:HostsPath -ErrorAction Stop)
        $clean = @(Remove-ManagedHostsEntries -Lines $cur)
        Write-HostsFileSafely -Lines $clean
        Write-Field 'hosts' 'managed entries removed' $C.Ok
    }

    Write-Section 'post-restore'
    ipconfig /flushdns | Out-Null
    Write-Field 'dns cache' 'flushed' $C.Ok
    Write-Host ''
    Write-Pause
}

function Register-WeeklyTask {
    Assert-Administrator
    Write-Header
    Write-Section 'register scheduled task'
    $selfPath = Get-SelfPath
    if (-not $selfPath) {
        throw 'cannot determine script/exe path; run SteamAccessFixer from a file'
    }
    if ($selfPath -match '\.exe$') {
        Write-Field 'launcher' "exe: $selfPath" $C.Ok
        $act = New-ScheduledTaskAction -Execute $selfPath -Argument '-Mode Apply'
    }
    else {
        $ps = Join-Path $PSHOME 'powershell.exe'
        if (-not (Test-Path -LiteralPath $ps)) {
            $ps = (Get-Command powershell.exe -ErrorAction Stop).Source
        }
        Write-Field 'launcher' "ps1: $selfPath" $C.Ok
        $argStr = "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$selfPath`" -Mode Apply"
        $act = New-ScheduledTaskAction -Execute $ps -Argument $argStr
    }
    $trg = New-ScheduledTaskTrigger -Weekly -DaysOfWeek Sunday -At 3:00AM
    $prin = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    $set = New-ScheduledTaskSettingsSet -StartWhenAvailable
    Register-ScheduledTask -TaskName 'SteamAccessFixer' `
        -Action $act -Trigger $trg -Principal $prin -Settings $set `
        -Description 'Diagnose Steam DNS and apply configured hosts overrides.' `
        -Force | Out-Null
    Write-Field 'task' 'SteamAccessFixer registered' $C.Ok
    Write-Field 'schedule' 'sundays 03:00 (SYSTEM)' $C.Ok
    Write-Host ''
}

# ---------------------------------------------------------------------------
# menu
# ---------------------------------------------------------------------------
function Show-Menu {
    while ($true) {
        Write-Header
        $isAdmin = Test-IsAdministrator
        Write-Host '  commands' -ForegroundColor $C.Dim
        Write-Host ''
        Write-Host '    1  fix steam   ' -NoNewline -ForegroundColor $C.Ok
        Write-Host 'auto-change dns to fix steam  (recommended)' -ForegroundColor $C.Dim
        Write-Host '    2  diagnose    ' -NoNewline -ForegroundColor $C.Text
        Write-Host 'check why steam fails' -ForegroundColor $C.Dim
        Write-Host '    3  apply hosts ' -NoNewline -ForegroundColor $C.Text
        Write-Host 'write verified ips into hosts file  (advanced)' -ForegroundColor $C.Dim
        Write-Host '    4  restore     ' -NoNewline -ForegroundColor $C.Text
        Write-Host 'revert all changes (dns + hosts)' -ForegroundColor $C.Dim
        Write-Host '    5  exit        ' -NoNewline -ForegroundColor $C.Text
        Write-Host 'quit' -ForegroundColor $C.Dim
        Write-Host ''
        Write-Host '  status: ' -NoNewline -ForegroundColor $C.Dim
        if ($isAdmin) { Write-Host 'administrator' -ForegroundColor $C.Ok }
        else { Write-Host 'standard user (auto-elevates when needed)' -ForegroundColor $C.Dim }
        Write-Host ''
        $choice = Read-Host '  choose [1-5]'
        switch ($choice) {
            '1' { Invoke-Fix }
            '2' { Invoke-Diagnose; Write-Pause }
            '3' { Invoke-Apply; Write-Pause }
            '4' { Invoke-Restore }
            '5' { return }
            default {
                Write-Host ''
                Write-Host '  unknown command' -ForegroundColor $C.Warn
                Start-Sleep -Milliseconds 700
            }
        }
    }
}

# ---------------------------------------------------------------------------
# entry point
# ---------------------------------------------------------------------------
try {
    $script:Activity.Enabled = Test-Interactive
    $script:IPv6Available = Test-IPv6Available

    switch ($Mode) {
        'Menu' { Show-Menu }
        'Fix' { Invoke-Fix }
        'Diagnose' { Invoke-Diagnose }
        'Apply' { Invoke-Apply }
        'Restore' { Invoke-Restore }
    }
}
catch {
    Write-Host ''
    Write-Host '  error: ' -NoNewline -ForegroundColor $C.Fail
    Write-Host $_.Exception.Message -ForegroundColor $C.Label
    Write-Host ''
    if ($Mode -eq 'Menu' -or (Test-Interactive)) {
        Write-Host '  press any key to close' -NoNewline -ForegroundColor $C.Dim
        Write-Host ' ...' -NoNewline -ForegroundColor $C.Dim
        try { $null = [Console]::ReadKey($true) } catch { Start-Sleep -Seconds 5 }
        Write-Host ''
    }
    exit 1
}
