#Requires -Version 5.1
<#
    install-alist.ps1
    Download / install AList on Windows, configure temp dir + port, register an
    auto-start scheduled task, start it, and verify with /ping.

    ASCII-only on purpose: PowerShell 5.1 parses BOM-less UTF-8 sources as ANSI,
    which silently mangles any non-ASCII literal (including Chinese paths).

    Usage:
        powershell -NoProfile -ExecutionPolicy Bypass -File install-alist.ps1
        powershell ... -File install-alist.ps1 -InstallDir D:\alist -Port 5244
#>
[CmdletBinding()]
param(
    [string]$InstallDir = '',
    [int]$Port = 5244,
    [string]$ZipPath = '',
    [string]$BindAddress = '127.0.0.1',
    [switch]$NoTask
)

$ErrorActionPreference = 'Continue'

# Prefer a data drive (AList spools whole files into temp_dir) but never assume
# D: exists - plenty of machines only have C:.
if (-not $InstallDir) {
    if (Test-Path -LiteralPath 'D:\') { $InstallDir = 'D:\alist' }
    elseif (Test-Path -LiteralPath 'E:\') { $InstallDir = 'E:\alist' }
    else { $InstallDir = (Join-Path $env:SystemDrive 'AList') }
}
$InstallDir = [IO.Path]::GetFullPath($InstallDir).TrimEnd('\')

# ---------- self-elevate ----------
$id = [Security.Principal.WindowsIdentity]::GetCurrent()
$pr = New-Object Security.Principal.WindowsPrincipal($id)
if (-not $pr.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    $args2 = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $PSCommandPath,
               '-InstallDir', $InstallDir, '-Port', $Port, '-BindAddress', $BindAddress)
    if ($ZipPath) { $args2 += @('-ZipPath', $ZipPath) }
    if ($NoTask) { $args2 += '-NoTask' }
    Start-Process -FilePath 'powershell.exe' -ArgumentList $args2 -Verb RunAs
    exit
}

$DataDir = Join-Path $InstallDir 'data'
$TempDir = Join-Path $InstallDir 'temp'
$Exe = Join-Path $InstallDir 'alist.exe'
$CfgFile = Join-Path $DataDir 'config.json'
$LogOut = Join-Path $InstallDir 'server.out.txt'
$LogErr = Join-Path $InstallDir 'server.err.txt'

function Step($m) { Write-Host ('[*] ' + $m) }
function Ok($m) { Write-Host ('[+] ' + $m) }
function Bad($m) { Write-Host ('[!] ' + $m) }

# ---------- dirs ----------
Step ('install dir: ' + $InstallDir)
foreach ($d in @($InstallDir, $DataDir, $TempDir)) {
    if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
}
& icacls $InstallDir /grant ('{0}\{1}:(OI)(CI)F' -f $env:USERDOMAIN, $env:USERNAME) | Out-Null

# ---------- binary ----------
if (-not (Test-Path -LiteralPath $Exe)) {
    $zip = $ZipPath
    if (-not $zip -or -not (Test-Path -LiteralPath $zip)) {
        $hits = Get-ChildItem -Path @($InstallDir, $PSScriptRoot) -Filter 'alist*windows*.zip' -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($hits) { $zip = $hits.FullName }
    }
    if (-not $zip -or -not (Test-Path -LiteralPath $zip)) {
        $zip = Join-Path $InstallDir 'alist-windows-amd64.zip'
        Step 'alist.exe not found, trying to download the latest release ...'
        try {
            Invoke-WebRequest -Uri 'https://github.com/AlistGo/alist/releases/latest/download/alist-windows-amd64.zip' `
                -OutFile $zip -UseBasicParsing -TimeoutSec 900
            Ok ('downloaded ' + (Get-Item -LiteralPath $zip).Length + ' bytes')
        } catch {
            Bad ('download failed: ' + $_.Exception.Message)
            Bad 'Download the zip manually from https://github.com/AlistGo/alist/releases'
            Bad ('Put it in ' + $InstallDir + ' (name it alist-windows-amd64.zip) and run this script again.')
            exit 1
        }
    }
    Step ('extracting ' + $zip)
    try { Expand-Archive -LiteralPath $zip -DestinationPath $InstallDir -Force -ErrorAction Stop }
    catch { Bad ('extract failed: ' + $_.Exception.Message); exit 1 }
}
if (-not (Test-Path -LiteralPath $Exe)) { Bad 'alist.exe still missing'; exit 1 }
Ok ('alist.exe: ' + (Get-Item -LiteralPath $Exe).Length + ' bytes')

# ---------- first run to generate config.json ----------
if (-not (Test-Path -LiteralPath $CfgFile)) {
    Step 'first run to generate config.json ...'
    $p = Start-Process -FilePath $Exe -ArgumentList @('server', '--data', $DataDir) `
        -WorkingDirectory $InstallDir -WindowStyle Hidden -PassThru `
        -RedirectStandardOutput $LogOut -RedirectStandardError $LogErr
    Start-Sleep -Seconds 8
    try { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue } catch {}
    Start-Sleep -Seconds 2
}
if (-not (Test-Path -LiteralPath $CfgFile)) { Bad 'config.json was not generated'; exit 1 }

# ---------- patch config ----------
Step ('patching config: temp_dir=' + $TempDir + '  http_port=' + $Port + '  address=' + $BindAddress)
try {
    $conf = Get-Content -LiteralPath $CfgFile -Raw -Encoding UTF8 | ConvertFrom-Json
    $conf.temp_dir = $TempDir
    if ($conf.scheme) {
        $conf.scheme.http_port = $Port
        # AList defaults to 0.0.0.0, i.e. the whole LAN can reach the Web UI and
        # the WebDAV endpoint. Loopback-only is the safe default; pass
        # -BindAddress 0.0.0.0 if you really want remote access.
        if ($BindAddress) { $conf.scheme.address = $BindAddress }
    }
    $json = $conf | ConvertTo-Json -Depth 12
    # No BOM: Go's encoding/json rejects a leading BOM.
    [IO.File]::WriteAllText($CfgFile, $json, (New-Object System.Text.UTF8Encoding($false)))
    Ok 'config patched'
} catch { Bad ('config patch failed: ' + $_.Exception.Message) }

# ---------- admin password ----------
Step 'setting admin password ...'
$chars = 'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789'
# One RNG, filled once. The obvious one-liner
#     -join (1..16 | % { $chars[([System.Random]::new()).Next(0,$chars.Length)] })
# is a trap: [System.Random]::new() re-seeds from Environment.TickCount, and a
# tight loop gets the SAME seed repeatedly, so the "random" password comes out
# as 16 identical characters.
$rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
$pwBytes = New-Object byte[] 16
$rng.GetBytes($pwBytes)
$pw = -join ($pwBytes | ForEach-Object { $chars[$_ % $chars.Length] })
$rng.Dispose()
& $Exe admin set $pw --data $DataDir 2>&1 | ForEach-Object { Write-Host ('    ' + $_) }
$credFile = Join-Path $InstallDir 'ALIST-CREDENTIALS.txt'
@(
    'AList login',
    ('URL      : http://127.0.0.1:' + $Port),
    ('WebDAV   : http://127.0.0.1:' + $Port + '/dav'),
    ('Username : admin'),
    ('Password : ' + $pw),
    ('DataDir  : ' + $DataDir),
    ('TempDir  : ' + $TempDir),
    '',
    'KEEP THIS FILE PRIVATE. Do not commit it to a public repository.'
) | Set-Content -LiteralPath $credFile -Encoding UTF8
Ok ('credentials saved to ' + $credFile)

# ---------- scheduled task ----------
if (-not $NoTask) {
    Step 'registering auto-start task "AList" ...'
    try {
        $act = New-ScheduledTaskAction -Execute $Exe -Argument ('server --data "' + $DataDir + '"') -WorkingDirectory $InstallDir
        $trg = New-ScheduledTaskTrigger -AtLogOn
        $prn = New-ScheduledTaskPrincipal -UserId ($env:USERDOMAIN + '\' + $env:USERNAME) -LogonType Interactive -RunLevel Highest
        Register-ScheduledTask -TaskName 'AList' -Action $act -Trigger $trg -Principal $prn -Force | Out-Null
        Ok 'task registered'
    } catch { Bad ('task registration failed: ' + $_.Exception.Message) }
}

# ---------- start ----------
Step 'starting AList ...'
$existing = Get-Process -Name 'alist' -ErrorAction SilentlyContinue
if ($existing) {
    Ok 'AList already running'
    & $Exe restart --data $DataDir 2>&1 | Out-Null
    Start-Sleep -Seconds 5
} else {
    Start-Process -FilePath $Exe -ArgumentList @('server', '--data', $DataDir) `
        -WorkingDirectory $InstallDir -WindowStyle Hidden `
        -RedirectStandardOutput $LogOut -RedirectStandardError $LogErr | Out-Null
    Start-Sleep -Seconds 8
}

# ---------- verify ----------
Step 'verifying ...'
try {
    $r = Invoke-WebRequest -Uri ('http://127.0.0.1:' + $Port + '/ping') -UseBasicParsing -TimeoutSec 15
    Ok ('/ping -> ' + [int]$r.StatusCode + ' ' + $r.Content)
} catch {
    Bad ('/ping failed: ' + $_.Exception.Message)
    Write-Host '--- listeners on port ---'
    Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue | Where-Object { $_.LocalPort -eq $Port } | Format-Table -AutoSize | Out-String | Write-Host
    foreach ($f in @($LogErr, (Join-Path $DataDir 'log\log.log'))) {
        if (Test-Path -LiteralPath $f) {
            Write-Host ('--- tail ' + $f + ' ---')
            Get-Content -LiteralPath $f -Tail 30 | ForEach-Object { Write-Host ('    ' + $_) }
        }
    }
    exit 1
}

Write-Host ''
Ok 'DONE'
Write-Host ('    Web UI   : http://127.0.0.1:' + $Port)
Write-Host ('    WebDAV   : http://127.0.0.1:' + $Port + '/dav')
Write-Host ('    Account  : admin / ' + $pw + '   (also in ' + $credFile + ')')
Write-Host ''