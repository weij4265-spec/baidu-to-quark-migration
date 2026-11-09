#Requires -Version 5.1
<#
    probe-webdav.ps1
    Sanity-check that the AList WebDAV endpoint accepts writes, then measure
    real read/upload throughput and per-file overhead.

    Reads credentials from ../config.txt (UTF-8).

    ASCII-only on purpose (PowerShell 5.1 mis-parses BOM-less UTF-8 sources).
#>
$ErrorActionPreference = 'Continue'

$cfgFile = Join-Path $PSScriptRoot 'config.txt'
if (-not (Test-Path -LiteralPath $cfgFile)) {
    Write-Host ('[!] config.txt not found. Copy config.example.txt to config.txt and edit it: ' + $cfgFile)
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
$base = ([string]$cfg['ALIST_URL']).TrimEnd('/')
$user = [string]$cfg['ALIST_USER']
$pass = [string]$cfg['ALIST_PASS']
if (-not $base -or -not $user) { Write-Host '[!] ALIST_URL / ALIST_USER missing in config.txt'; exit 1 }

$log = Join-Path $PSScriptRoot 'probe-result.txt'
$lines = New-Object System.Collections.Generic.List[string]
function W($s) { $lines.Add([string]$s); Write-Host ([string]$s) }

$authB = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($user + ':' + $pass))
Add-Type -AssemblyName System.Net.Http -ErrorAction SilentlyContinue
$h = New-Object System.Net.Http.HttpClient
$h.Timeout = [TimeSpan]::FromMinutes(60)

function NewReq($method, $url) {
    $m = [System.Net.Http.HttpMethod]::new($method)
    $r = [System.Net.Http.HttpRequestMessage]::new($m, $url)
    $r.Headers.Add('Authorization', 'Basic ' + $authB)
    return $r
}
function PutBytes($url, [byte[]]$data) {
    $r = NewReq 'PUT' $url
    $c = [System.Net.Http.ByteArrayContent]::new($data)
    $c.Headers.ContentLength = $data.Length
    $r.Content = $c
    return $h.SendAsync($r).GetAwaiter().GetResult()
}

W '== AList WebDAV probe =='
W ('time   : ' + (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))
W ('endpoint: ' + $base)
W ''

# ---------- 1. write permission ----------
W '--- write permission (MKCOL / PUT / GET / DELETE) ---'
try {
    $r = NewReq 'MKCOL' ($base + '/_probe_/')
    $resp = $h.SendAsync($r).GetAwaiter().GetResult()
    W ('  MKCOL : ' + [int]$resp.StatusCode)

    $payload = [Text.Encoding]::UTF8.GetBytes('alist webdav probe')
    $resp2 = PutBytes ($base + '/_probe_/a.txt') $payload
    W ('  PUT   : ' + [int]$resp2.StatusCode)

    $r3 = NewReq 'GET' ($base + '/_probe_/a.txt')
    $resp3 = $h.SendAsync($r3).GetAwaiter().GetResult()
    $txt = $resp3.Content.ReadAsStringAsync().GetAwaiter().GetResult()
    W ('  GET   : ' + [int]$resp3.StatusCode + '  body=' + $txt)

    $r4 = NewReq 'DELETE' ($base + '/_probe_/a.txt')
    $resp4 = $h.SendAsync($r4).GetAwaiter().GetResult()
    W ('  DELETE: ' + [int]$resp4.StatusCode)
    W '  >>> WRITE OK'
} catch {
    W ('  >>> WRITE FAILED: ' + $_.Exception.Message)
}
W ''

# ---------- 2. per-file overhead ----------
W '--- per-file overhead (10 unique 4KB PUTs) ---'
try {
    $r = NewReq 'MKCOL' ($base + '/_probe_/sm/')
    $null = $h.SendAsync($r).GetAwaiter().GetResult()
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $ok = 0
    for ($k = 0; $k -lt 10; $k++) {
        $body = 'f' + $k + '-' + [Guid]::NewGuid().ToString() + ('x' * 4000)
        $d = [Text.Encoding]::UTF8.GetBytes($body)
        $resp = PutBytes ($base + '/_probe_/sm/f' + $k + '.txt') $d
        if ([int]$resp.StatusCode -lt 300) { $ok++ }
    }
    $sw.Stop()
    $tot = $sw.Elapsed.TotalSeconds; if ($tot -le 0) { $tot = 0.001 }
    W ('  ' + $ok + '/10 OK  ' + [math]::Round($tot, 2) + ' s total  =  ' + [math]::Round($tot / 10 * 1000, 0) + ' ms/file')
    W ('  >>> 100k small files would spend ' + [math]::Round(100000 * ($tot / 10) / 3600, 1) + ' h on handshakes alone')
} catch { W ('  per-file test failed: ' + $_.Exception.Message) }
W ''

# ---------- 3. throughput ----------
W '--- throughput ---'
$srcFile = $cfg['TEST_FILE']
if (-not $srcFile -or -not (Test-Path -LiteralPath $srcFile)) {
    $srcDir = $cfg['SOURCE_DIR']
    if ($srcDir -and (Test-Path -LiteralPath $srcDir)) {
        W ('  scanning for a >=20MB file under ' + $srcDir)
        $c = Get-ChildItem -LiteralPath $srcDir -Recurse -Depth 3 -File -Force -ErrorAction SilentlyContinue |
            Where-Object { $_.Length -ge 20MB -and $_.Length -le 400MB } | Select-Object -First 1
        if ($c) { $srcFile = $c.FullName }
    }
}
if ($srcFile -and (Test-Path -LiteralPath $srcFile)) {
    W ('  source: ' + $srcFile)
    W '  NOTE: the next step reads up to 20 MB from the source. If SOURCE_DIR is'
    W '        a CloudDrive2 network mount, a stalled read blocks this script'
    W '        with no timeout - set TEST_FILE to a LOCAL file to avoid that.'
    try {
        $limit = 20971520
        $ms = New-Object System.IO.MemoryStream
        $fs = [System.IO.File]::OpenRead($srcFile)
        $buf = New-Object byte[] 1048576
        $swA = [Diagnostics.Stopwatch]::StartNew()
        while ($ms.Length -lt $limit) {
            $n = $fs.Read($buf, 0, $buf.Length)
            if ($n -le 0) { break }
            $ms.Write($buf, 0, $n)
        }
        $swA.Stop(); $fs.Close()
        $data = $ms.ToArray()
        $rs = $swA.Elapsed.TotalSeconds; if ($rs -le 0) { $rs = 0.001 }
        W ('  READ   (src->PC): ' + [math]::Round($data.Length / 1MB, 2) + ' MB / ' + [math]::Round($rs, 2) + ' s = ' + [math]::Round(($data.Length / 1MB) / $rs, 2) + ' MB/s')

        $swB = [Diagnostics.Stopwatch]::StartNew()
        $resp = PutBytes ($base + '/_probe_/speed.bin') $data
        $swB.Stop()
        $us = $swB.Elapsed.TotalSeconds; if ($us -le 0) { $us = 0.001 }
        $mbps = ($data.Length / 1MB) / $us
        W ('  UPLOAD (PC->dst): ' + [math]::Round($data.Length / 1MB, 2) + ' MB / ' + [math]::Round($us, 2) + ' s = ' + [math]::Round($mbps, 2) + ' MB/s  status=' + [int]$resp.StatusCode)
        W ('  >>> 1 TB at this rate: ' + [math]::Round(1048576 / $mbps / 3600, 1) + ' hours')
    } catch { W ('  throughput failed: ' + $_.Exception.Message) }
} else { W '  no test file available (set TEST_FILE or SOURCE_DIR in config.txt)' }
W ''

# ---------- cleanup ----------
W '--- cleanup ---'
foreach ($u in @('/_probe_/speed.bin', '/_probe_/sm/', '/_probe_/')) {
    try {
        $r = NewReq 'DELETE' ($base + $u)
        $resp = $h.SendAsync($r).GetAwaiter().GetResult()
        W ('  DELETE ' + $u + ' -> ' + [int]$resp.StatusCode)
    } catch { W ('  DELETE ' + $u + ' failed') }
}

W ''
W '=== DONE ==='
try { $lines | Out-File -LiteralPath $log -Encoding UTF8 } catch {}
Write-Host ''
Write-Host ('Result: ' + $log)
# (no pause here - the .bat wrapper handles it)