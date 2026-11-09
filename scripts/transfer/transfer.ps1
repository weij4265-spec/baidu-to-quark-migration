#Requires -Version 5.1
<#
    transfer.ps1   (EXPERIMENTAL - pilot on a small folder first)

    Stream-copy a folder tree from a local/mounted path into an AList WebDAV
    endpoint, without writing a local staging copy.

      src  -->  read stream  -->  HTTPS PUT  -->  AList  -->  destination cloud

    CONCURRENCY MATTERS. Measured on one home line (Quark via AList):
        4 x 8 MB sequential  = 1.98 MB/s
        4 x 8 MB in parallel = 5.64 MB/s   (2.84x)
    The upload cap is per connection, not per line, so this script keeps
    PARALLEL uploads in flight (default 4).

    Features:
      * two phases: scan the tree + MKCOL every directory, then upload
      * N uploads in flight; a failed file is retried up to 3 times
      * resume: skips files whose remote size already matches (RESUME_CHECK=0
        turns the extra HEAD off for a fresh full run - it costs one round trip
        per file)
      * ASCII-only source (PowerShell 5.1 mis-parses BOM-less UTF-8 sources);
        Chinese paths belong in ../config.txt, which is read as UTF-8.

    Config keys used: ALIST_URL, ALIST_USER, ALIST_PASS, SOURCE_DIR,
                      DEST_SUBDIR, MAX_FILES, MAX_FILE_MB, PARALLEL, RESUME_CHECK

    NOTE ON MEMORY: phase 1 keeps the whole file list in memory (~200 bytes per
    file). 100k files is fine; millions would not be.
#>
$ErrorActionPreference = 'Continue'

$here = $PSScriptRoot
$root = Split-Path -Parent $here
$cfgFile = Join-Path $root 'config.txt'
$logFile = Join-Path $root 'transfer.log'

if (-not (Test-Path -LiteralPath $cfgFile)) {
    Write-Host ('[!] config.txt not found: ' + $cfgFile)
    # (no pause here - the .bat wrapper handles it)
    exit 1
}

$cfg = @{}
Get-Content -LiteralPath $cfgFile -Encoding UTF8 | ForEach-Object {
    $line = $_.Trim()
    if ($line -and -not $line.StartsWith('#') -and $line.Contains('=')) {
        $i = $line.IndexOf('=')
        $cfg[$line.Substring(0, $i).Trim()] = $line.Substring($i + 1).Trim()
    }
}

# Cast to [string] first: if the key is absent $cfg[...] is $null, and
# $null.TrimEnd() throws before the validation below ever runs.
$base = ([string]$cfg['ALIST_URL']).TrimEnd('/')
$user = [string]$cfg['ALIST_USER']
$pass = [string]$cfg['ALIST_PASS']
$srcDir = [string]$cfg['SOURCE_DIR']
$destSub = ([string]$cfg['DEST_SUBDIR']).Trim('/')

$maxFiles = 0;  if ($cfg['MAX_FILES'])    { $maxFiles = [int]$cfg['MAX_FILES'] }
$maxFileMB = 0; if ($cfg['MAX_FILE_MB'])  { $maxFileMB = [double]$cfg['MAX_FILE_MB'] }
$parallel = 4;  if ($cfg['PARALLEL'])     { $parallel = [int]$cfg['PARALLEL'] }
if ($parallel -lt 1) { $parallel = 1 }
if ($parallel -gt 16) { $parallel = 16 }
$resumeCheck = $true
if ([string]$cfg['RESUME_CHECK'] -eq '0') { $resumeCheck = $false }

if (-not $base -or -not $user -or -not $srcDir) {
    Write-Host '[!] ALIST_URL / ALIST_USER / SOURCE_DIR must be set in config.txt'
    # (no pause here - the .bat wrapper handles it)
    exit 1
}
if (-not $pass) { Write-Host '[!] ALIST_PASS is empty - AList will answer 401' }
if (-not (Test-Path -LiteralPath $srcDir)) {
    Write-Host ('[!] SOURCE_DIR not found: ' + $srcDir)
    # (no pause here - the .bat wrapper handles it)
    exit 1
}

# ---------------- http ----------------
# .NET Framework defaults DefaultConnectionLimit to 2, which would silently
# cap a 4-way run at 2 sockets.
[System.Net.ServicePointManager]::DefaultConnectionLimit = [Math]::Max(8, $parallel * 2)
[System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12
$authB = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($user + ':' + $pass))
Add-Type -AssemblyName System.Net.Http -ErrorAction SilentlyContinue
$h = New-Object System.Net.Http.HttpClient
$h.Timeout = [TimeSpan]::FromHours(6)

function NewReq($method, $url) {
    $m = [System.Net.Http.HttpMethod]::new($method)
    $r = [System.Net.Http.HttpRequestMessage]::new($m, $url)
    $r.Headers.Add('Authorization', 'Basic ' + $authB)
    return $r
}
function EscPath([string]$rel) {
    if (-not $rel) { return '' }
    $segs = $rel -split '[\\/]+' | Where-Object { $_ -ne '' }
    return (($segs | ForEach-Object { [Uri]::EscapeDataString($_) }) -join '/')
}

# ---------------- logging ----------------
$sw = New-Object System.IO.StreamWriter($logFile, $true, (New-Object System.Text.UTF8Encoding($false)))
$sw.AutoFlush = $true
function Log($s) { $sw.WriteLine([string]$s); Write-Host ([string]$s) }

Log ''
Log ('===== run start ' + (Get-Date).ToString('yyyy-MM-dd HH:mm:ss') + ' =====')
Log ('src     : ' + $srcDir)
Log ('dest    : ' + $base + '/' + $destSub)
Log ('caps    : maxFiles=' + $maxFiles + '  maxFileMB=' + $maxFileMB + '  parallel=' + $parallel + '  resumeCheck=' + $resumeCheck)

$stopwatch = [Diagnostics.Stopwatch]::StartNew()
$stats = @{ ok = 0; skip = 0; fail = 0; bytes = [long]0 }
$failedList = New-Object System.Collections.Generic.List[string]

# ---------------- dir creation ----------------
$created = New-Object System.Collections.Generic.HashSet[string]
function Ensure-Dir([string]$rawRel) {
    if (-not $rawRel) { return }
    $parts = $rawRel -split '/' | Where-Object { $_ -ne '' }
    $cum = ''
    foreach ($p in $parts) {
        if ($cum) { $cum = $cum + '/' + $p } else { $cum = $p }
        if ($created.Contains($cum)) { continue }
        $r = $null
        $resp = $null
        try {
            $r = NewReq 'MKCOL' ($base + '/' + (EscPath $cum) + '/')
            $resp = $h.SendAsync($r).GetAwaiter().GetResult()
            $code = [int]$resp.StatusCode
            [void]$created.Add($cum)
            if ($code -ge 400 -and $code -ne 405) { Log ('  MKCOL ' + $cum + ' -> ' + $code) }
        } catch {
            Log ('  MKCOL ' + $cum + ' failed: ' + $_.Exception.Message)
            throw
        } finally {
            if ($resp) { try { $resp.Dispose() } catch {} }
            if ($r) { try { $r.Dispose() } catch {} }
        }
    }
}

# ---------------- phase 1: scan + create dirs ----------------
Log '--- phase 1: scan source tree, create remote directories ---'
$files = New-Object System.Collections.ArrayList
$totalBytes = [long]0
$stack = New-Object System.Collections.Stack
$stack.Push(@{ p = $srcDir; rel = '' })
$dirCount = 0

while ($stack.Count -gt 0) {
    $node = $stack.Pop()
    $dirRel = $node.rel
    if ($destSub) { if ($dirRel) { $dirRel = $destSub + '/' + $dirRel } else { $dirRel = $destSub } }

    try { Ensure-Dir $dirRel }
    catch { Log ('  cannot create dir ' + $dirRel + ' - files below it will fail'); continue }
    $dirCount++

    try { $items = Get-ChildItem -LiteralPath $node.p -Force -ErrorAction Stop }
    catch {
        # A network mount that hiccups here must not kill the whole run.
        Log ('  cannot list ' + $node.p + ' : ' + $_.Exception.Message)
        continue
    }

    foreach ($item in $items) {
        if ($item.PSIsContainer) {
            $childRel = if ($node.rel) { $node.rel + '/' + $item.Name } else { $item.Name }
            $stack.Push(@{ p = $item.FullName; rel = $childRel })
            continue
        }
        if ($maxFileMB -gt 0 -and $item.Length -gt ($maxFileMB * 1MB)) {
            Log ('  SKIP too big (' + [math]::Round($item.Length / 1MB, 1) + ' MB) ' + $item.Name)
            continue
        }
        $fileRel = if ($node.rel) { $node.rel + '/' + $item.Name } else { $item.Name }
        $targetRel = if ($destSub) { $destSub + '/' + $fileRel } else { $fileRel }
        [void]$files.Add(@{ Src = $item.FullName; Rel = $targetRel; Len = [long]$item.Length })
        $totalBytes += $item.Length
        if ($maxFiles -gt 0 -and $files.Count -ge $maxFiles) { break }
    }
    if ($maxFiles -gt 0 -and $files.Count -ge $maxFiles) { break }
}

Log ('  directories: ' + $dirCount + '   files: ' + $files.Count + '   size: ' + [math]::Round($totalBytes / 1MB, 1) + ' MB')
if ($files.Count -eq 0) { Log '  nothing to upload - check SOURCE_DIR'; $sw.Close(); exit 0 }

# ---------------- phase 2: concurrent upload ----------------
# One in-flight unit = one async PUT plus the objects that must stay alive
# until it completes (request, content wrapper, file stream).
function Start-Upload($entry, [int]$attempt) {
    $url = $base + '/' + (EscPath $entry.Rel)

    if ($resumeCheck) {
        $rh = $null
        $respH = $null
        try {
            $rh = NewReq 'HEAD' $url
            $respH = $h.SendAsync($rh).GetAwaiter().GetResult()
            if ([int]$respH.StatusCode -eq 200) {
                $rlen = $respH.Content.Headers.ContentLength
                if ($null -ne $rlen -and [long]$rlen -eq $entry.Len) { return 'skip' }
            }
        } catch { }
        finally {
            if ($respH) { try { $respH.Dispose() } catch {} }
            if ($rh) { try { $rh.Dispose() } catch {} }
        }
    }

    $fs = $null
    $content = $null
    $req = $null
    try {
        $fs = [System.IO.File]::Open($entry.Src, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        $content = [System.Net.Http.StreamContent]::new($fs)
        $content.Headers.ContentLength = $fs.Length
        $req = NewReq 'PUT' $url
        $req.Content = $content
        $task = $h.SendAsync($req)
        return [pscustomobject]@{
            Task = $task; Req = $req; Content = $content; Fs = $fs
            Entry = $entry; Attempt = $attempt; Url = $url
        }
    } catch {
        if ($fs) { try { $fs.Dispose() } catch {} }
        if ($content) { try { $content.Dispose() } catch {} }
        if ($req) { try { $req.Dispose() } catch {} }
        throw
    }
}

function Close-Unit($unit) {
    if ($unit.Req) { try { $unit.Req.Dispose() } catch {} }
    if ($unit.Content) { try { $unit.Content.Dispose() } catch {} }
    if ($unit.Fs) { try { $unit.Fs.Dispose() } catch {} }
}

Log ''
Log ('--- phase 2: uploading with ' + $parallel + ' in flight ---')

$pending = New-Object System.Collections.ArrayList
$next = 0
$lastLog = [Diagnostics.Stopwatch]::StartNew()
$logEvery = 50

while ($next -lt $files.Count -or $pending.Count -gt 0) {
    # keep the pipe full
    while ($pending.Count -lt $parallel -and $next -lt $files.Count) {
        $entry = $files[$next]
        $next++
        try { $unit = Start-Upload $entry 1 }
        catch {
            $stats.fail++
            $failedList.Add($entry.Rel + '  [open-failed: ' + $_.Exception.Message + ']')
            Log ('  FAIL ' + $entry.Rel + '  open-failed: ' + $_.Exception.Message)
            continue
        }
        if ($unit -is [string] -and $unit -eq 'skip') { $stats.skip++; continue }
        [void]$pending.Add($unit)
    }

    if ($pending.Count -eq 0) { break }

    $taskArr = New-Object 'System.Threading.Tasks.Task[]' $pending.Count
    for ($k = 0; $k -lt $pending.Count; $k++) { $taskArr[$k] = $pending[$k].Task }
    $which = [System.Threading.Tasks.Task]::WaitAny($taskArr, 60000)
    if ($which -lt 0) { Log '  ... still waiting (no upload completed in 60 s)'; continue }

    $unit = $pending[$which]
    $pending.RemoveAt($which)

    $code = -1
    $errMsg = ''
    try {
        $resp = $unit.Task.GetAwaiter().GetResult()
        $code = [int]$resp.StatusCode
        try { $resp.Dispose() } catch {}
    } catch { $errMsg = $_.Exception.Message }
    Close-Unit $unit

    $entry = $unit.Entry
    if ($code -ge 200 -and $code -lt 300) {
        $stats.ok++
        $stats.bytes += $entry.Len
    } elseif ($unit.Attempt -lt 3) {
        # Back off briefly, then put it back in flight.
        Start-Sleep -Seconds (2 * $unit.Attempt)
        try { $retry = Start-Upload $entry ($unit.Attempt + 1) }
        catch {
            $stats.fail++
            $failedList.Add($entry.Rel + '  [reopen-failed: ' + $_.Exception.Message + ']')
            Log ('  FAIL ' + $entry.Rel + '  reopen-failed')
            $retry = $null
        }
        if ($retry -is [string] -and $retry -eq 'skip') { $stats.skip++ }
        elseif ($retry) { [void]$pending.Add($retry) }
        Log ('  retry ' + $unit.Attempt + ' ' + $(if ($code -gt 0) { 'http' + $code } else { 'err ' + $errMsg }) + ' ' + $entry.Rel)
    } else {
        $stats.fail++
        $failedList.Add($entry.Rel + '  [' + $(if ($code -gt 0) { 'http' + $code } else { 'err ' + $errMsg }) + ']')
        Log ('  FAIL ' + $entry.Rel + '  ' + $(if ($code -gt 0) { 'http' + $code } else { $errMsg }))
    }

    $handled = $stats.ok + $stats.skip + $stats.fail
    if (($handled % $logEvery) -eq 0 -or $lastLog.Elapsed.TotalSeconds -ge 60) {
        $pct = 0
        if ($totalBytes -gt 0) { $pct = [math]::Round(100 * $stats.bytes / $totalBytes, 1) }
        $rate = 0
        if ($stopwatch.Elapsed.TotalSeconds -gt 0) { $rate = [math]::Round(($stats.bytes / 1MB) / $stopwatch.Elapsed.TotalSeconds, 2) }
        Log ('  progress: ' + $handled + '/' + $files.Count + ' handled  ok=' + $stats.ok + ' skip=' + $stats.skip + ' fail=' + $stats.fail +
             '  ' + [math]::Round($stats.bytes / 1MB, 1) + ' MB (' + $pct + '%)  ' + $rate + ' MB/s  elapsed=' + [math]::Round($stopwatch.Elapsed.TotalMinutes, 1) + ' min')
        $lastLog = [Diagnostics.Stopwatch]::StartNew()
    }
}

$stopwatch.Stop()
Log ''
Log '===== summary ====='
Log ('  uploaded : ' + $stats.ok + '  (' + [math]::Round($stats.bytes / 1MB, 1) + ' MB)')
Log ('  skipped  : ' + $stats.skip)
Log ('  failed   : ' + $stats.fail)
Log ('  elapsed  : ' + [math]::Round($stopwatch.Elapsed.TotalMinutes, 1) + ' min')
if ($stats.bytes -gt 0 -and $stopwatch.Elapsed.TotalSeconds -gt 0) {
    Log ('  avg up   : ' + [math]::Round(($stats.bytes / 1MB) / $stopwatch.Elapsed.TotalSeconds, 2) + ' MB/s')
}
if ($failedList.Count -gt 0) {
    Log '  failed list (first 50):'
    $failedList | Select-Object -First 50 | ForEach-Object { Log ('    ' + $_) }
    Log ('  full failure detail: ' + $logFile)
}
Log ('  log      : ' + $logFile)
Log '===== run end ====='
$sw.Flush(); $sw.Close()
# (no pause here - the .bat wrapper handles it)