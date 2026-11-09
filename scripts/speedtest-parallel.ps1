#Requires -Version 5.1
<#
    speedtest-parallel.ps1  (v3)

    Question: is the upload cap per-connection (parallelism helps) or the
    line itself (it does not)?

    v3 changes vs v2:
      - DOES NOT READ THE CLOUDDRIVE MOUNT AT ALL. v2 hung forever inside
        FileStream.Read on B:\ (a network mount, no IO timeout). Payloads are
        now generated in RAM, so this test only touches AList + the network.
      - Payloads differ between round 1 and round 2 (GUID tag in the first
        bytes), otherwise hash-based instant-upload would fake a speedup.
      - ServicePointManager.DefaultConnectionLimit raised; the .NET default
        of 2 idle connections would silently serialize a 4-way test.
      - Progress is flushed after every single step, so a hang is visible.

    ASCII-only source; config.txt is read as UTF-8.
#>
$ErrorActionPreference = 'Continue'

$here = $PSScriptRoot
$cfgFile = Join-Path $here 'config.txt'
$out = New-Object System.Collections.Generic.List[string]
$outFile = Join-Path $here 'speedtest-para-result.txt'
function P($s) { $out.Add([string]$s); Write-Host ([string]$s); Flush }
function Flush() { try { $out | Out-File -LiteralPath $outFile -Encoding UTF8 } catch {} }

P '== upload concurrency test v3 (RAM payloads, mount not touched) =='
P ('time: ' + (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))

try {
    # ---------------- config ----------------
    P '--- stage 1: config ---'
    if (-not (Test-Path -LiteralPath $cfgFile)) { P '[!] config.txt missing'; exit 1 }
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
    if (-not $base -or -not $user) { P '[!] ALIST_URL / ALIST_USER missing'; exit 1 }
    P ('  endpoint: ' + $base)

    # The whole point of this test is >= 4 sockets in flight. .NET Framework
    # defaults DefaultConnectionLimit to 2, which would serialise it.
    [System.Net.ServicePointManager]::DefaultConnectionLimit = 64
    [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12
    $authB = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($user + ':' + $pass))
    Add-Type -AssemblyName System.Net.Http -ErrorAction Stop
    $h = New-Object System.Net.Http.HttpClient
    $h.Timeout = [TimeSpan]::FromMinutes(10)
    P ('  http client ready (DefaultConnectionLimit=' + [System.Net.ServicePointManager]::DefaultConnectionLimit + ')')

    function NewReq($method, $url) {
        $m = [System.Net.Http.HttpMethod]::new($method)
        $r = [System.Net.Http.HttpRequestMessage]::new($m, $url)
        $r.Headers.Add('Authorization', 'Basic ' + $authB)
        return $r
    }

    # ---------------- payloads (pure RAM, no disk, no mount) ----------------
    P '--- stage 2: build 8 distinct payloads in RAM ---'
    $mb = 8388608
    $rnd = New-Object System.Random
    $pay = @{}
    foreach ($round in @('seq', 'par')) {
        for ($i = 0; $i -lt 4; $i++) {
            $buf = New-Object byte[] $mb
            $rnd.NextBytes($buf)
            # 32-byte unique tag at the front: guarantees a different hash from
            # every other payload, so Quark cannot instant-upload round 2.
            $tag = [Text.Encoding]::ASCII.GetBytes(($round + '-' + $i + '-' + [Guid]::NewGuid().ToString('N')))
            [Array]::Copy($tag, 0, $buf, 0, $tag.Length)
            $pay[$round + $i] = $buf
            P ('  built ' + $round + $i + '  ' + [math]::Round($buf.Length / 1MB, 1) + ' MB')
        }
    }
    $roundMB = 4 * $mb / 1MB
    P ('  per round: ' + [math]::Round($roundMB, 1) + ' MB')

    function PutKey($key, $name) {
        $url = $base + '/_st/' + $name + '.bin'
        $req = NewReq 'PUT' $url
        # Static ::new(), NOT New-Object: New-Object binds an array argument as
        # -ArgumentList and would unroll 8388608 bytes into 8388608 parameters.
        $content = [System.Net.Http.ByteArrayContent]::new($pay[$key])
        $content.Headers.ContentLength = $pay[$key].Length
        $req.Content = $content
        return $h.SendAsync($req)
    }

    # ---------------- folder ----------------
    P '--- stage 3: MKCOL /_st/ ---'
    $r = NewReq 'MKCOL' ($base + '/_st/')
    $resp = $h.SendAsync($r).GetAwaiter().GetResult()
    P ('  MKCOL -> ' + [int]$resp.StatusCode)

    # ---------------- round 1 ----------------
    P '--- stage 4: ROUND 1 sequential (4 x 8 MB) ---'
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $codes = @()
    for ($i = 0; $i -lt 4; $i++) {
        $res = (PutKey ('seq' + $i) ('seq' + $i)).GetAwaiter().GetResult()
        $codes += [int]$res.StatusCode
        P ('  seq' + $i + ' -> ' + [int]$res.StatusCode + '  (elapsed ' + [math]::Round($sw.Elapsed.TotalSeconds, 1) + ' s)')
    }
    $sw.Stop()
    $seqSec = [math]::Max($sw.Elapsed.TotalSeconds, 0.001)
    $seqRate = $roundMB / $seqSec
    P ('  statuses: ' + ($codes -join ', '))
    P ('  ' + [math]::Round($roundMB, 1) + ' MB / ' + [math]::Round($seqSec, 2) + ' s = ' + [math]::Round($seqRate, 2) + ' MB/s')

    # ---------------- round 2 ----------------
    P '--- stage 5: ROUND 2 concurrent x4 (4 x 8 MB) ---'
    $sw2 = [Diagnostics.Stopwatch]::StartNew()
    $t0 = PutKey 'par0' 'par0'
    $t1 = PutKey 'par1' 'par1'
    $t2 = PutKey 'par2' 'par2'
    $t3 = PutKey 'par3' 'par3'
    P '  4 PUTs launched, waiting...'
    [System.Threading.Tasks.Task]::WaitAll([System.Threading.Tasks.Task[]]@($t0, $t1, $t2, $t3))
    $sw2.Stop()
    $parSec = [math]::Max($sw2.Elapsed.TotalSeconds, 0.001)
    $codes2 = @()
    $bad = 0
    foreach ($t in @($t0, $t1, $t2, $t3)) {
        try {
            $c = [int]$t.Result.StatusCode
            $codes2 += $c
            if ($c -lt 200 -or $c -ge 300) { $bad++ }
        } catch { $codes2 += 'ERR'; $bad++ }
    }
    $parRate = $roundMB / $parSec
    P ('  statuses: ' + ($codes2 -join ', '))
    P ('  ' + [math]::Round($roundMB, 1) + ' MB / ' + [math]::Round($parSec, 2) + ' s = ' + [math]::Round($parRate, 2) + ' MB/s')

    # ---------------- verdict ----------------
    P '=== verdict ==='
    P ('  sequential : ' + [math]::Round($seqRate, 2) + ' MB/s  (' + [math]::Round($seqSec, 2) + ' s)')
    P ('  concurrent : ' + [math]::Round($parRate, 2) + ' MB/s  (' + [math]::Round($parSec, 2) + ' s)')
    $gain = $parRate / $seqRate
    P ('  speedup    : ' + [math]::Round($gain, 2) + 'x')
    if ($bad -gt 0) {
        P ('  [!] ' + $bad + ' request(s) failed in round 2 - treat the number as unreliable')
    } elseif ($gain -ge 1.5) {
        P '  >>> PARALLELISM HELPS - keep 4+ uploads in flight.'
        P ('  >>> 1 TB (1048576 MB) at ' + [math]::Round($parRate, 2) + ' MB/s = ' + [math]::Round(1048576 / $parRate / 3600, 1) + ' h')
    } else {
        P '  >>> NO MEANINGFUL GAIN - the cap is the line, not the connection.'
        P ('  >>> 1 TB at ' + [math]::Round($seqRate, 2) + ' MB/s = ' + [math]::Round(1048576 / $seqRate / 3600, 1) + ' h either way.')
    }

    # ---------------- cleanup ----------------
    P '--- stage 6: cleanup ---'
    foreach ($k in @('seq0', 'seq1', 'seq2', 'seq3', 'par0', 'par1', 'par2', 'par3')) {
        try {
            $dr = NewReq 'DELETE' ($base + '/_st/' + $k + '.bin')
            $null = $h.SendAsync($dr).GetAwaiter().GetResult()
        } catch {}
    }
    try {
        $dr = NewReq 'DELETE' ($base + '/_st/')
        $null = $h.SendAsync($dr).GetAwaiter().GetResult()
    } catch {}
    P '  done'
}
catch {
    P ''
    P ('FATAL: ' + $_.Exception.Message)
    P ('at: ' + $_.InvocationInfo.PositionMessage)
    P ('stack: ' + $_.ScriptStackTrace)
}
finally {
    P ''
    P ('result file: ' + $outFile)
}