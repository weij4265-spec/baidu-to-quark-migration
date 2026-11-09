#Requires -Version 5.1
<#
    status.ps1
    Bring the environment back up and report its state:
      1. ping AList (start it if it is not running)
      2. start CloudDrive2 if it is not running
      3. wait for the mounted drive to appear
      4. list the mounted top-level folders

    No self-elevation on purpose: AList and CloudDrive2 should run as the
    logged-in user, exactly as they do when started from the Start menu.

    ASCII-only source; config.txt is read as UTF-8.
#>
$ErrorActionPreference = 'Continue'

$here = $PSScriptRoot
$cfgFile = Join-Path $here 'config.txt'
$out = New-Object System.Collections.Generic.List[string]
$outFile = Join-Path $here 'status.txt'
function P($s) { $out.Add([string]$s); Write-Host ([string]$s) }
function Flush() { try { $out | Out-File -LiteralPath $outFile -Encoding UTF8 } catch {} }

$cfg = @{}
if (Test-Path -LiteralPath $cfgFile) {
    Get-Content -LiteralPath $cfgFile -Encoding UTF8 | ForEach-Object {
        $line = $_.Trim()
        if ($line -and -not $line.StartsWith('#') -and $line.Contains('=')) {
            $i = $line.IndexOf('=')
            $cfg[$line.Substring(0, $i).Trim()] = $line.Substring($i + 1).Trim()
        }
    }
}

$alistUrl = $cfg['ALIST_URL']
$mountHint = $cfg['SOURCE_DIR']
$mountDrive = ''
if ($mountHint -match '^([A-Za-z]):') { $mountDrive = $Matches[1].ToUpper() + ':' }

P '== environment status =='
P ('time: ' + (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))
P ''

# ---------- 1. AList ----------
P '--- AList ---'
$pingUrl = ''
if ($alistUrl) {
    try {
        $u = [Uri]$alistUrl
        $pingUrl = $u.Scheme + '://' + $u.Host + ':' + $u.Port + '/ping'
    } catch {}
    P ('  endpoint: ' + $alistUrl)
}

$alive = $false
if ($pingUrl) {
    try {
        $r = Invoke-WebRequest -Uri $pingUrl -UseBasicParsing -TimeoutSec 5
        P ('  /ping -> ' + [int]$r.StatusCode + '  ALIVE')
        $alive = $true
    } catch {
        P '  /ping -> no response'
    }
}

if (-not $alive) {
    # ALIST_EXE in config.txt wins; otherwise probe the usual spots. Do not
    # assume D: exists - install-alist.ps1 falls back to C:\AList on machines
    # without a second drive.
    $cands = New-Object System.Collections.Generic.List[string]
    $cfgExe = [string]$cfg['ALIST_EXE']
    if ($cfgExe) { $cands.Add($cfgExe) }
    foreach ($root in @('D:\', 'E:\', 'C:\')) {
        if (Test-Path -LiteralPath $root) {
            $cands.Add((Join-Path $root 'alist\alist.exe'))
            $cands.Add((Join-Path $root 'AList\alist.exe'))
        }
    }
    if ($env:LOCALAPPDATA) { $cands.Add((Join-Path $env:LOCALAPPDATA 'AList\alist.exe')) }
    if ($env:ProgramFiles) { $cands.Add((Join-Path $env:ProgramFiles 'alist\alist.exe')) }
    if (${env:ProgramFiles(x86)}) { $cands.Add((Join-Path ${env:ProgramFiles(x86)} 'alist\alist.exe')) }
    $exe = $null
    foreach ($c in $cands) { if (Test-Path -LiteralPath $c) { $exe = $c; break } }
    if (-not $exe) {
        P '  alist.exe not found. Looked in:'
        foreach ($c in $cands) { P ('    ' + $c) }
        P '  >>> run install-alist.bat, or set ALIST_EXE=<full path to alist.exe> in config.txt'
    }
    if ($exe) {
        $data = Join-Path (Split-Path -Parent $exe) 'data'
        P ('  starting: ' + $exe + ' server --data ' + $data)
        $outLog = Join-Path (Split-Path -Parent $exe) 'server.out.txt'
        $errLog = Join-Path (Split-Path -Parent $exe) 'server.err.txt'
        Start-Process -FilePath $exe -ArgumentList @('server', '--data', $data) `
            -WorkingDirectory (Split-Path -Parent $exe) -WindowStyle Hidden `
            -RedirectStandardOutput $outLog -RedirectStandardError $errLog | Out-Null
        Start-Sleep -Seconds 10
        if ($pingUrl) {
            try {
                $r = Invoke-WebRequest -Uri $pingUrl -UseBasicParsing -TimeoutSec 10
                P ('  /ping -> ' + [int]$r.StatusCode + '  ALIVE now')
                $alive = $true
            } catch { P '  still not responding after start' }
        }
    }
}
P ''

# ---------- 2. CloudDrive2 ----------
P '--- CloudDrive2 ---'
$cd2 = Get-Process -Name 'CloudDrive' -ErrorAction SilentlyContinue
if ($cd2) {
    P ('  running, PID ' + $cd2.Id)
} else {
    $exe2 = $null
    $cd2Cands = New-Object System.Collections.Generic.List[string]
    $cfgCd2 = [string]$cfg['CLOUDDRIVE_EXE']
    if ($cfgCd2) { $cd2Cands.Add($cfgCd2) }
    if ($env:ProgramFiles) { $cd2Cands.Add((Join-Path $env:ProgramFiles 'CloudDrive\CloudDrive.exe')) }
    if (${env:ProgramFiles(x86)}) { $cd2Cands.Add((Join-Path ${env:ProgramFiles(x86)} 'CloudDrive\CloudDrive.exe')) }
    if ($env:LOCALAPPDATA) { $cd2Cands.Add((Join-Path $env:LOCALAPPDATA 'Programs\CloudDrive\CloudDrive.exe')) }
    $cd2Cands.Add('C:\Program Files\CloudDrive\CloudDrive.exe')
    foreach ($c in $cd2Cands) {
        if ($c -and (Test-Path -LiteralPath $c)) { $exe2 = $c; break }
    }
    if ($exe2) {
        P ('  not running, starting ' + $exe2)
        Start-Process -FilePath $exe2 | Out-Null
        Start-Sleep -Seconds 15
    } else {
        P '  not running and CloudDrive.exe not found'
        P '  >>> install CloudDrive2, or set CLOUDDRIVE_EXE=<full path> in config.txt'
    }
}
P ''

# ---------- 3. mounted drive ----------
P ('--- mounted drive (' + $mountDrive + ') ---')
if (-not $mountDrive) { P '  SOURCE_DIR in config.txt does not start with a drive letter'; Flush; exit 1 }

$ok = $false
for ($i = 0; $i -lt 12; $i++) {
    if (Test-Path -LiteralPath ($mountDrive + '\')) { $ok = $true; break }
    Start-Sleep -Seconds 5
}

if ($ok) {
    P ('  ' + $mountDrive + '\ EXISTS')
    try {
        $items = Get-ChildItem -LiteralPath ($mountDrive + '\') -Force -ErrorAction Stop
        P ('  top-level entries: ' + $items.Count)
        foreach ($it in $items) {
            if ($it.PSIsContainer) {
                P ('    [DIR] ' + $it.Name)
            } else {
                P ('    ' + $it.Length.ToString().PadLeft(12) + '  ' + $it.Name)
            }
        }
    } catch { P ('  list failed: ' + $_.Exception.Message) }
} else {
    P ('  ' + $mountDrive + '\ still NOT available after ~60s')
    P '  >>> open CloudDrive2 and check that the mount point exists and is connected'
}
P ''

# ---------- 4. source folder ----------
P '--- source folder from config.txt ---'
$src = $cfg['SOURCE_DIR']
if ($src -and (Test-Path -LiteralPath $src)) {
    P ('  OK  ' + $src)
    try {
        $c = Get-ChildItem -LiteralPath $src -Force -ErrorAction Stop
        P ('  entries: ' + $c.Count)
        $c | Select-Object -First 15 | ForEach-Object {
            if ($_.PSIsContainer) { P ('    [DIR] ' + $_.Name) } else { P ('    ' + $_.Length + '  ' + $_.Name) }
        }
    } catch { P ('  list failed: ' + $_.Exception.Message) }
} else {
    P ('  MISSING: ' + $src)
}

P ''
P ('=== done. state: alist=' + $alive + ' mount=' + $ok + ' ===')
P ('   report: ' + $outFile)
Flush
exit 0