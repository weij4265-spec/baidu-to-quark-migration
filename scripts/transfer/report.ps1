#Requires -Version 5.1
<#
    report.ps1
    Walk DEST_SUBDIR on the AList WebDAV endpoint and list everything that
    actually landed, with sizes. Prints to console and writes report-result.txt
    (UTF-8) so the result can be checked later without scrolling the console.

    WebDAV servers disagree on "Depth: infinity" (many reject it), so this
    walks the tree one level at a time with Depth: 1.

    ASCII-only source; config.txt is read as UTF-8.
#>
$ErrorActionPreference = 'Continue'

$here = $PSScriptRoot
$out = New-Object System.Collections.Generic.List[string]
$outFile = Join-Path $here 'report-result.txt'
function P($s) { $out.Add([string]$s); Write-Host ([string]$s) }
function Flush() { try { $out | Out-File -LiteralPath $outFile -Encoding UTF8 } catch {} }

$cfgFile = Join-Path (Split-Path -Parent $here) 'config.txt'
if (-not (Test-Path -LiteralPath $cfgFile)) { P '[!] config.txt not found'; Flush; exit 1 }

$cfg = @{}
Get-Content -LiteralPath $cfgFile -Encoding UTF8 | ForEach-Object {
    $line = $_.Trim()
    if ($line -and -not $line.StartsWith('#') -and $line.Contains('=')) {
        $i = $line.IndexOf('=')
        $cfg[$line.Substring(0, $i).Trim()] = $line.Substring($i + 1).Trim()
    }
}
# [string] cast first: a missing key leaves $null, and $null.TrimEnd() throws.
$base = ([string]$cfg['ALIST_URL']).TrimEnd('/')
$user = [string]$cfg['ALIST_USER']
$pass = [string]$cfg['ALIST_PASS']
$dest = ([string]$cfg['DEST_SUBDIR']).Trim('/')
if (-not $base -or -not $user) { P '[!] ALIST_URL / ALIST_USER missing'; Flush; exit 1 }
if (-not $dest) { P '[!] DEST_SUBDIR is empty - nothing to report on'; Flush; exit 1 }

$authB = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($user + ':' + $pass))
Add-Type -AssemblyName System.Net.Http -ErrorAction SilentlyContinue
$h = New-Object System.Net.Http.HttpClient
$h.Timeout = [TimeSpan]::FromMinutes(5)

function EscPath([string]$rel) {
    if (-not $rel) { return '' }
    $segs = $rel -split '[\\/]+' | Where-Object { $_ -ne '' }
    return (($segs | ForEach-Object { [Uri]::EscapeDataString($_) }) -join '/')
}
function Propfind([string]$url) {
    $m = [System.Net.Http.HttpMethod]::new('PROPFIND')
    $req = [System.Net.Http.HttpRequestMessage]::new($m, $url)
    $req.Headers.Add('Authorization', 'Basic ' + $authB)
    $req.Headers.Add('Depth', '1')
    try {
        $resp = $h.SendAsync($req).GetAwaiter().GetResult()
        $code = [int]$resp.StatusCode
        $body = ''
        if ($code -eq 207 -or $code -eq 200) { $body = $resp.Content.ReadAsStringAsync().GetAwaiter().GetResult() }
        try { $resp.Dispose() } catch {}
        return @{ Code = $code; Body = $body }
    } finally {
        try { $req.Dispose() } catch {}
    }
}

$rootUrl = $base + '/' + (EscPath $dest) + '/'
P ('== remote listing of ' + $dest + ' (recursive) ==')
P ('   ' + $rootUrl)

function Unesc([string]$s) { try { return [Uri]::UnescapeDataString($s) } catch { return $s } }

$queue = New-Object System.Collections.Queue
$queue.Enqueue(@{ Url = $rootUrl; Indent = '   ' })
$files = 0
$dirs = 0
$bytes = [long]0
$labels = New-Object System.Collections.Generic.List[string]
$walked = 0
$maxDirs = 2000
$rootFailed = $false

while ($queue.Count -gt 0 -and $walked -lt $maxDirs) {
    $node = $queue.Dequeue()
    $walked++
    $got = Propfind $node.Url
    if ($got.Code -ne 207 -and $got.Code -ne 200) {
        if ($walked -le 1) {
            P ('   HTTP ' + $got.Code + ' on the root folder')
            P '   >>> destination folder NOT readable - nothing was created?'
            $rootFailed = $true
        } else {
            P ($node.Indent + '[!] HTTP ' + $got.Code + ' ' + (Unesc $node.Url))
        }
        continue
    }
    # href is a path only (/dav/quark/...), so compare against the request's
    # AbsolutePath, not against the full URL.
    $selfPath = ((Unesc (([Uri]$node.Url).AbsolutePath))).TrimEnd('/')

    foreach ($m1 in [regex]::Matches($got.Body, '(?s)<D:response>(.*?)</D:response>')) {
        $blk = $m1.Groups[1].Value
        $href = [regex]::Match($blk, '<D:href>(.*?)</D:href>').Groups[1].Value
        if (-not $href) { continue }
        $hrefPath = (Unesc $href).TrimEnd('/')
        $name = ($hrefPath -split '/')[-1]
        if (-not $name) { continue }
        if ($hrefPath -eq $selfPath) { continue }
        if ($blk -match '<D:collection') {
            $dirs++
            P ($node.Indent + '[DIR] ' + $name)
            $childUrl = $node.Url.TrimEnd('/') + '/' + (EscPath $name) + '/'
            $queue.Enqueue(@{ Url = $childUrl; Indent = ($node.Indent + '  ') })
        } else {
            $files++
            $len = [regex]::Match($blk, '<D:getcontentlength>(.*?)</D:getcontentlength>').Groups[1].Value
            $n = [long]0
            if ($len) { $n = [long]$len; $bytes += $n }
            P ($node.Indent + '      ' + $name + '   ' + $n)
        }
    }
}

if ($walked -ge $maxDirs) { P ('   [!] stopped after ' + $maxDirs + ' folders - raise maxDirs in report.ps1') }

P ''
P ('   dirs=' + $dirs + '  files=' + $files + '  bytes=' + $bytes + '  (' + [math]::Round($bytes / 1MB, 2) + ' MB)')
if ($files -gt 0) { P '   >>> VERIFIED: files are actually present on the destination' }
elseif (-not $rootFailed) { P '   >>> nothing landed - check transfer.log' }
P ''
P ('   result file: ' + $outFile)
Flush
if ($rootFailed) { exit 1 } else { exit 0 }