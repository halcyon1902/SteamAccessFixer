#requires -Version 5.1
<#
.SYNOPSIS
    Steam connectivity diagnostic and optional hosts override utility.

.DESCRIPTION
    Resolves a small, explicit list of Steam-related hostnames using DNS-over-HTTPS,
    checks TCP/443 reachability, and optionally writes successful results to the
    Windows hosts file.

.NOTES
    Author : Halcyon
    Version: 1.0.0
    Since  : 2026-10-10

    Hosts overrides can become stale as CDN addresses change. Use Apply only when
    you understand this limitation. A successful TCP/443 check does not guarantee
    that Steam will work correctly with a pinned address.
#>

[CmdletBinding()]
param(
    [ValidateSet('Menu','Apply','Restore','Diagnose')]
    [string]$Mode = 'Menu'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# force TLS 1.2+ (PS 5.1 / .NET Framework defaults to TLS 1.0, which DoH rejects)
# ---------------------------------------------------------------------------
try {
    $proto = [Net.SecurityProtocolType]::Tls12
    try { $proto = $proto -bor [Net.SecurityProtocolType]::Tls11 } catch { }
    [Net.ServicePointManager]::SecurityProtocol = $proto
} catch {
    Write-Warning "could not raise TLS version: $($_.Exception.Message)"
}

# ---------------------------------------------------------------------------
# metadata
# ---------------------------------------------------------------------------
$script:AppName    = 'steam-access-fixer'
$script:AppVersion = '1.0.0'
$script:AppAuthor  = 'Halcyon'
$script:AppSince   = '2026-10-10'
$script:AppBuiltOn = (Get-Date).ToString('yyyy-MM-dd')

# ---------------------------------------------------------------------------
# configuration
# ---------------------------------------------------------------------------
$script:HostsPath    = Join-Path $env:SystemRoot 'System32\drivers\etc\hosts'
$script:BackupPath   = Join-Path $env:SystemRoot 'System32\drivers\etc\hosts.bak_steam'
$script:ManagedStart = '# BEGIN SteamAccessFix managed entries'
$script:ManagedEnd   = '# END SteamAccessFix managed entries'
$script:Domains      = @(
    'store.steampowered.com'
    'steamcommunity.com'
    'api.steampowered.com'
    'checkout.steampowered.com'
    'login.steampowered.com'
    'cdn.cloudflare.steamstatic.com'
)

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
function Get-ConsoleWidth {
    try {
        $w = [Console]::WindowWidth
        if ($w -lt 40) { $w = 100 }
        return $w - 1
    } catch { return 100 }
}

function Write-Header {
    param([switch]$NoClear)
    if (-not $NoClear) { try { Clear-Host } catch { } }

    Write-Host ''
    Write-Host '  ' -NoNewline
    Write-Host $script:AppName -NoNewline -ForegroundColor $C.Text
    Write-Host '  ' -NoNewline
    Write-Host "v$($script:AppVersion)" -NoNewline -ForegroundColor $C.Dim
    Write-Host '  ·  ' -NoNewline -ForegroundColor $C.Dim
    Write-Host $script:AppAuthor -NoNewline -ForegroundColor $C.Dim
    Write-Host '  ·  ' -NoNewline -ForegroundColor $C.Dim
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

function Write-Result {
    param(
        [Parameter(Mandatory)][string]$Hostname,
        [Parameter(Mandatory)][string]$Address,
        [Parameter(Mandatory)][string]$Status,
        [Parameter(Mandatory)][string]$StatusColor
    )
    Write-Host '    ' -NoNewline
    Write-Host $Hostname.PadRight(38) -NoNewline -ForegroundColor $C.Text
    Write-Host $Address.PadRight(18) -NoNewline -ForegroundColor $C.Dim
    Write-Host $Status -ForegroundColor $StatusColor
}

function Write-ProgressBar {
    param(
        [Parameter(Mandatory)][int]$Done,
        [Parameter(Mandatory)][int]$Total,
        [Parameter(Mandatory)][double]$ElapsedSec,
        [Parameter(Mandatory)][string]$Current
    )

    $pct = if ($Total -gt 0) { [int](($Done / $Total) * 100) } else { 0 }
    $barW = 20
    $filled = [int]($barW * $pct / 100)
    $bar = ('#' * $filled) + ('.' * ($barW - $filled))
    $elapsed = '{0,5:0.0}s' -f $ElapsedSec

    $left = "  [$bar]  $($Done.ToString().PadLeft(2))/$Total  $elapsed  "

    $maxW = Get-ConsoleWidth
    $nameW = $maxW - $left.Length - 1
    if ($nameW -lt 10) { $nameW = 10 }
    $name = $Current
    if ($name.Length -gt $nameW) { $name = $name.Substring(0, $nameW) }

    $line = ($left + $name).PadRight($maxW)
    Write-Host "`r$line" -NoNewline -ForegroundColor $C.Dim
}

function Clear-ProgressBar {
    $w = Get-ConsoleWidth
    Write-Host "`r$(' ' * $w)`r" -NoNewline
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
    Write-Host '  ·  ' -NoNewline -ForegroundColor $C.Dim
    Write-Host "$Ok ok" -NoNewline -ForegroundColor $C.Ok
    Write-Host '  ·  ' -NoNewline -ForegroundColor $C.Dim
    Write-Host "$Warn warn" -NoNewline -ForegroundColor $C.Warn
    Write-Host '  ·  ' -NoNewline -ForegroundColor $C.Dim
    Write-Host "$Fail fail" -NoNewline -ForegroundColor $C.Fail
    Write-Host '  ·  ' -NoNewline -ForegroundColor $C.Dim
    Write-Host ('{0:0.0}s' -f $Seconds) -ForegroundColor $C.Dim
    Write-Host ''
}

function Test-Interactive {
    try {
        return -not [Console]::IsInputRedirected -and -not [Console]::IsOutputRedirected
    } catch {
        return $true
    }
}

function Write-Pause {
    param([string]$Message = 'press enter to continue')

    # Nếu stdin/out bị redirect (scheduled task, pipe) thì bỏ qua để không treo
    if (-not (Test-Interactive)) { return }

    Write-Host ''
    Write-Host '  ' -NoNewline -ForegroundColor $C.Dim
    Write-Host $Message -NoNewline -ForegroundColor $C.Dim
    Write-Host ' ...' -NoNewline -ForegroundColor $C.Dim

    try {
        # ReadKey block thật sự cho tới khi có phím; không bị nuốt bởi buffer
        $null = [Console]::ReadKey($true)
    }
    catch {
        # fallback nếu console không hỗ trợ ReadKey
        try { $null = Read-Host } catch { Start-Sleep -Seconds 3 }
    }
    Write-Host ''
}

function Write-Notice {
    param(
        [Parameter(Mandatory)][string]$Title,
        [Parameter(Mandatory)][string[]]$Lines
    )
    Write-Host ''
    Write-Host "  $Title" -ForegroundColor $C.Warn
    Write-Host ''
    foreach ($l in $Lines) { Write-Host "    $l" -ForegroundColor $C.Label }
    Write-Host ''
}

# ---------------------------------------------------------------------------
# privileges
# ---------------------------------------------------------------------------
function Test-IsAdministrator {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $p  = [Security.Principal.WindowsPrincipal]::new($id)
    return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Assert-Administrator {
    if (-not (Test-IsAdministrator)) {
        throw 'administrator privileges required'
    }
}

function Show-AdminRequired {
    Write-Host ''
    Write-Host '  --------------------------------------------------------------' -ForegroundColor $C.Fail
    Write-Host ''
    Write-Host '   administrator privileges required' -ForegroundColor $C.Fail
    Write-Host ''
    Write-Host '   This action writes to the Windows hosts file or' -ForegroundColor $C.Label
    Write-Host '   registers a SYSTEM-level scheduled task.' -ForegroundColor $C.Label
    Write-Host ''
    Write-Host '   => close this window' -ForegroundColor $C.Text
    Write-Host '   => right-click PowerShell' -NoNewline -ForegroundColor $C.Text
    Write-Host '  ·  ' -NoNewline -ForegroundColor $C.Dim
    Write-Host 'Run as administrator' -ForegroundColor $C.Warn
    Write-Host '   => run this script again' -ForegroundColor $C.Text
    Write-Host ''
    Write-Host '  --------------------------------------------------------------' -ForegroundColor $C.Fail
}

# ---------------------------------------------------------------------------
# DNS over HTTPS — runspace-based so we can animate + surface real errors
# ---------------------------------------------------------------------------
function Resolve-DnsOverHttps {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Domain,
        [scriptblock]$OnTick,
        [switch]$DebugErrors
    )

    $providers = @(
        @{ Name = 'cloudflare'; Uri = 'https://cloudflare-dns.com/dns-query?name={0}&type=A' }
        @{ Name = 'google';     Uri = 'https://dns.google/resolve?name={0}&type=A' }
    )

    $errors = [System.Collections.Generic.List[string]]::new()

    foreach ($p in $providers) {
        $ps = $null
        try {
            $uri = $p.Uri -f [uri]::EscapeDataString($Domain)

            $ps = [powershell]::Create()
            $null = $ps.AddScript({
                param($u)
                [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
                Invoke-RestMethod -Method Get -Uri $u `
                    -Headers @{ Accept = 'application/dns-json' } `
                    -TimeoutSec 6 -ErrorAction Stop
            }).AddArgument($uri)

            $handle = $ps.BeginInvoke()
            $sw = [System.Diagnostics.Stopwatch]::StartNew()
            while (-not $handle.IsCompleted -and $sw.ElapsedMilliseconds -lt 7000) {
                if ($OnTick) { & $OnTick $sw.Elapsed.TotalSeconds }
                Start-Sleep -Milliseconds 80
            }

            if (-not $handle.IsCompleted) {
                try { $ps.Stop() } catch { }
                $errors.Add("$($p.Name): timeout")
                continue
            }

            $output = $ps.EndInvoke($handle)
            $errRec = $ps.Streams.Error

            if ($errRec -and $errRec.Count -gt 0) {
                $errors.Add("$($p.Name): $($errRec[0].ToString())")
                continue
            }

            $json = $output | Select-Object -First 1
            if ($null -eq $json) {
                $errors.Add("$($p.Name): empty response")
                continue
            }
            if ($json.Status -ne 0) {
                $errors.Add("$($p.Name): dns status=$($json.Status)")
                continue
            }
            if (-not $json.Answer) {
                $errors.Add("$($p.Name): no answer section")
                continue
            }

            $addresses = @(
                $json.Answer |
                    Where-Object { $_.type -eq 1 -and $_.data -match '^\d{1,3}(\.\d{1,3}){3}$' } |
                    ForEach-Object { [string]$_.data } |
                    Select-Object -Unique
            )
            if ($addresses.Count -gt 0) { return $addresses }

            $errors.Add("$($p.Name): answer had no A records")
        }
        catch {
            $errors.Add("$($p.Name): $($_.Exception.Message)")
        }
        finally {
            if ($ps) { try { $ps.Dispose() } catch { } }
        }
    }

    if ($DebugErrors -or $env:STEAMFIX_DEBUG) {
        Write-Host ''
        foreach ($e in $errors) {
            Write-Host "      · $e" -ForegroundColor DarkGray
        }
    }

    return @()
}

# ---------------------------------------------------------------------------
# system DNS fallback (in case DoH blocked by firewall/proxy)
# ---------------------------------------------------------------------------
function Resolve-DnsFallback {
    param([Parameter(Mandatory)][string]$Domain)
    try {
        $ips = [System.Net.Dns]::GetHostAddresses($Domain) |
            Where-Object { $_.AddressFamily -eq 'InterNetwork' } |
            ForEach-Object { $_.IPAddressToString } |
            Select-Object -Unique
        return @($ips)
    }
    catch {
        return @()
    }
}

# ---------------------------------------------------------------------------
# TCP/443 probe (async + pollable)
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
            if ($OnTick) { & $OnTick $sw.Elapsed.TotalSeconds }
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
# per-domain resolution
# ---------------------------------------------------------------------------
function Resolve-Domain {
    param(
        [Parameter(Mandatory)][string]$Domain,
        [Parameter(Mandatory)][int]$Index,
        [Parameter(Mandatory)][int]$Total
    )

    $tick = {
        param($elapsed)
        Write-ProgressBar -Done ($Index - 1) -Total $Total -ElapsedSec $elapsed -Current $Domain
    }

    $addresses = @(Resolve-DnsOverHttps -Domain $Domain -OnTick $tick)

    # fall back to system DNS if DoH came back empty
    if ($addresses.Count -eq 0) {
        $addresses = @(Resolve-DnsFallback -Domain $Domain)
        if ($addresses.Count -gt 0) {
            Write-Host ''
            Write-Host '      (dns-over-https failed — using system dns)' -ForegroundColor DarkGray
        }
    }

    if ($addresses.Count -eq 0) {
        Clear-ProgressBar
        Write-Result -Hostname $Domain -Address '--' -Status 'dns error' -StatusColor $C.Fail
        return [pscustomobject]@{ Domain = $Domain; IPAddress = $null; Port443 = $false; Kind = 'fail' }
    }

    foreach ($ip in $addresses) {
        $tcpTick = {
            param($elapsed)
            Write-ProgressBar -Done ($Index - 1) -Total $Total -ElapsedSec $elapsed -Current "$Domain ($ip)"
        }

        if (Test-Tcp443 -IPAddress $ip -OnTick $tcpTick) {
            Clear-ProgressBar
            Write-Result -Hostname $Domain -Address $ip -Status 'ok' -StatusColor $C.Ok
            return [pscustomobject]@{ Domain = $Domain; IPAddress = $ip; Port443 = $true; Kind = 'ok' }
        }
    }

    Clear-ProgressBar
    Write-Result -Hostname $Domain -Address $addresses[0] -Status 'warn' -StatusColor $C.Warn
    return [pscustomobject]@{ Domain = $Domain; IPAddress = $addresses[0]; Port443 = $false; Kind = 'warn' }
}

# ---------------------------------------------------------------------------
# full scan
# ---------------------------------------------------------------------------
function Invoke-DomainScan {
    $total = $script:Domains.Count
    $ok = 0; $warn = 0; $fail = 0
    $all = [System.Collections.Generic.List[object]]::new()

    Write-Section "scanning $total hosts"
    Write-ProgressBar -Done 0 -Total $total -ElapsedSec 0 -Current 'initializing'

    $scanSw = [System.Diagnostics.Stopwatch]::StartNew()

    for ($i = 0; $i -lt $total; $i++) {
        $r = Resolve-Domain -Domain $script:Domains[$i] -Index ($i + 1) -Total $total
        $all.Add($r)
        switch ($r.Kind) {
            'ok'    { $ok++ }
            'warn'  { $warn++ }
            default { $fail++ }
        }
        Write-ProgressBar -Done ($i + 1) -Total $total -ElapsedSec 0 -Current 'done'
    }

    Clear-ProgressBar
    $scanSw.Stop()

    Write-Summary -Total $total -Ok $ok -Warn $warn -Fail $fail -Seconds $scanSw.Elapsed.TotalSeconds

    return $all.ToArray()
}

# ---------------------------------------------------------------------------
# hosts file helpers
# ---------------------------------------------------------------------------
function Remove-ManagedHostsEntries {
    param([Parameter(Mandatory)][string[]]$Lines)

    $output = [System.Collections.Generic.List[string]]::new()
    $inside = $false

    foreach ($line in $Lines) {
        if ($line.Trim() -eq $script:ManagedStart) { $inside = $true; continue }
        if ($inside) {
            if ($line.Trim() -eq $script:ManagedEnd) { $inside = $false }
            continue
        }

        if ($line -match '^\s*\d{1,3}(\.\d{1,3}){3}\s+\S*steampowered\.com\b' -or
            $line -match '^\s*\d{1,3}(\.\d{1,3}){3}\s+\S*steamcommunity\.com\b' -or
            $line -match '^\s*\d{1,3}(\.\d{1,3}){3}\s+\S*steamstatic\.com\b' -or
            $line -match '^\s*#\s*--- Steam Access Fix Block ---') {
            continue
        }

        $output.Add($line)
    }

    if ($inside) { throw 'managed hosts block is malformed (end marker missing); no changes written' }
    return $output.ToArray()
}

function Write-HostsFileSafely {
    param([Parameter(Mandatory)][string[]]$Lines)

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
        } else {
            [System.IO.File]::Move($tmp, $script:HostsPath)
        }
    }
    catch {
        throw "could not update hosts file (no lock-bypass attempted): $($_.Exception.Message)"
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
    if (Test-IsAdministrator) {
        Write-Field 'privileges' 'administrator' $C.Ok
    } else {
        Write-Field 'privileges' 'standard user' $C.Warn
    }
    Write-Field 'session' (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')

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

    if (-not (Test-Path -LiteralPath $script:BackupPath)) {
        Copy-Item -LiteralPath $script:HostsPath -Destination $script:BackupPath -ErrorAction Stop
        Write-Field 'backup' "created: $($script:BackupPath)" $C.Ok
    } else {
        Write-Field 'backup' "existing: $($script:BackupPath)" $C.Warn
    }

    $scan = @(Invoke-DomainScan)
    $valid = @($scan | Where-Object { $_.IPAddress -and $_.Port443 })

    if ($valid.Count -eq 0) {
        Write-Section 'aborted'
        Write-Host '    no host passed the tcp/443 check' -ForegroundColor $C.Fail
        Write-Host '    hosts file was not modified' -ForegroundColor $C.Warn
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
    foreach ($r in $valid) { $new.Add("$($r.IPAddress)`t$($r.Domain)") }
    $new.Add($script:ManagedEnd)

    Write-HostsFileSafely -Lines $new.ToArray()
    Write-Field 'write' 'atomic (temp + replace)' $C.Ok

    Write-Section 'post-apply'
    ipconfig /flushdns | Out-Null
    Write-Field 'dns cache' 'flushed' $C.Ok
    Write-Host ''
    Write-Host '    note: CDN IPs change often; use "restore" if connectivity degrades.' -ForegroundColor $C.Dim
    Write-Host ''
}

function Invoke-Restore {
    Assert-Administrator
    Write-Header
    Write-Section 'restore'

    if (Test-Path -LiteralPath $script:BackupPath -PathType Leaf) {
        Write-Field 'backup' "found: $($script:BackupPath)" $C.Ok

        $rt = "$($script:HostsPath).restore.tmp"
        Copy-Item -LiteralPath $script:BackupPath -Destination $rt -Force
        try {
            [System.IO.File]::Replace($rt, $script:HostsPath, $null, $true)
            Remove-Item -LiteralPath $script:BackupPath -Force
            Write-Field 'restored' 'from backup' $C.Ok
        }
        catch {
            throw "restore failed (backup preserved): $($_.Exception.Message)"
        }
        finally {
            if (Test-Path -LiteralPath $rt) {
                Remove-Item -LiteralPath $rt -Force -ErrorAction SilentlyContinue
            }
        }
    } else {
        Write-Field 'backup' 'none — stripping managed entries in place' $C.Warn
        $cur = @(Get-Content -LiteralPath $script:HostsPath -ErrorAction Stop)
        $clean = @(Remove-ManagedHostsEntries -Lines $cur)
        Write-HostsFileSafely -Lines $clean
        Write-Field 'managed entries' 'removed' $C.Ok
    }

    Write-Section 'post-restore'
    ipconfig /flushdns | Out-Null
    Write-Field 'dns cache' 'flushed' $C.Ok
    Write-Host ''
}

function Register-WeeklyTask {
    Assert-Administrator
    Write-Header
    Write-Section 'register scheduled task'

    $ps = Join-Path $PSHOME 'powershell.exe'
    if (-not (Test-Path -LiteralPath $ps)) {
        $ps = (Get-Command powershell.exe -ErrorAction Stop).Source
    }
    Write-Field 'powershell' $ps

    $scriptPath = $PSCommandPath
    if ([string]::IsNullOrWhiteSpace($scriptPath) -or -not (Test-Path -LiteralPath $scriptPath)) {
        throw 'save this script as a .ps1 file before registering the scheduled task'
    }
    Write-Field 'script' $scriptPath

    $argStr = "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$scriptPath`" -Mode Apply"
    $act  = New-ScheduledTaskAction -Execute $ps -Argument $argStr
    $trg  = New-ScheduledTaskTrigger -Weekly -DaysOfWeek Sunday -At 3:00AM
    $prin = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    $set  = New-ScheduledTaskSettingsSet -StartWhenAvailable

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
        $adminTag = if ($isAdmin) { '' } else { '   (admin)' }
        $adminTagColor = $C.Warn

        Write-Host '  commands' -ForegroundColor $C.Dim
        Write-Host ''

        Write-Host '    1  diagnose    ' -NoNewline -ForegroundColor $C.Text
        Write-Host 'resolve hostnames and probe tcp/443' -ForegroundColor $C.Dim

        Write-Host '    2  apply       ' -NoNewline -ForegroundColor $C.Text
        Write-Host 'scan and write validated entries to hosts' -NoNewline -ForegroundColor $C.Dim
        if (-not $isAdmin) { Write-Host $adminTag -ForegroundColor $adminTagColor } else { Write-Host '' }

        Write-Host '    3  restore     ' -NoNewline -ForegroundColor $C.Text
        Write-Host 'restore backup / remove managed entries' -NoNewline -ForegroundColor $C.Dim
        if (-not $isAdmin) { Write-Host $adminTag -ForegroundColor $adminTagColor } else { Write-Host '' }

        Write-Host '    4  schedule    ' -NoNewline -ForegroundColor $C.Text
        Write-Host 'register a weekly scheduled task' -NoNewline -ForegroundColor $C.Dim
        if (-not $isAdmin) { Write-Host $adminTag -ForegroundColor $adminTagColor } else { Write-Host '' }

        Write-Host '    5  exit        ' -NoNewline -ForegroundColor $C.Text
        Write-Host 'quit' -ForegroundColor $C.Dim

        Write-Host ''
        Write-Host '  status: ' -NoNewline -ForegroundColor $C.Dim
        if ($isAdmin) {
            Write-Host 'administrator' -ForegroundColor $C.Ok
        } else {
            Write-Host 'standard user' -ForegroundColor $C.Warn
        }
        Write-Host ''

        $choice = Read-Host '  command'

        switch ($choice) {
            '1' { Invoke-Diagnose; Write-Pause }
            '2' {
                if (-not $isAdmin) { Show-AdminRequired; Write-Pause }
                else { Invoke-Apply; Write-Pause }
            }
            '3' {
                if (-not $isAdmin) { Show-AdminRequired; Write-Pause }
                else { Invoke-Restore; Write-Pause }
            }
            '4' {
                if (-not $isAdmin) { Show-AdminRequired; Write-Pause }
                else { Register-WeeklyTask; Write-Pause }
            }
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
    switch ($Mode) {
        'Menu'     { Show-Menu }
        'Diagnose' { Invoke-Diagnose }
        'Apply'    { Invoke-Apply }
        'Restore'  { Invoke-Restore }
    }
}
catch {
    Write-Host ''
    Write-Host '  error: ' -NoNewline -ForegroundColor $C.Fail
    Write-Host $_.Exception.Message -ForegroundColor $C.Label
    Write-Host ''

    # Menu mode → giữ cửa sổ để user đọc; scheduled/pipe mode → thoát luôn
    if ($Mode -eq 'Menu' -or (Test-Interactive)) {
        Write-Host '  press any key to close' -NoNewline -ForegroundColor $C.Dim
        Write-Host ' ...' -NoNewline -ForegroundColor $C.Dim
        try { $null = [Console]::ReadKey($true) } catch { Start-Sleep -Seconds 5 }
        Write-Host ''
    }
    exit 1
}