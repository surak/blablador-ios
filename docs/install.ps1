# Installs bla — Blablador on the command line — on Windows. Downloads the build from the latest release, checks it
# against SHA256SUMS.txt and puts bla.exe in %LOCALAPPDATA%\Programs\bla, which it adds to your PATH.
#
#   powershell -ExecutionPolicy ByPass -c "irm https://surak.github.io/blablador-ios/install.ps1 | iex"
#
# With arguments, for a folder you choose:
#
#   powershell -ExecutionPolicy ByPass -File install.ps1 -Dir C:\Tools\bla
#
# Nothing needs to be installed first (no admin rights either). To remove bla again, delete the folder and its entry
# in the PATH, and if you like %USERPROFILE%\.bla.
param(
    [string]$Dir = "$env:LOCALAPPDATA\Programs\bla",
    [string]$Version = "",
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
$repo = 'surak/blablador-ios'

function Say($text) { Write-Host $text }

function Get-Hash($file) {
    # Get-FileHash only exists from PowerShell 4 on (Windows 8.1); older systems hash by hand.
    if (Get-Command Get-FileHash -ErrorAction SilentlyContinue) {
        return (Get-FileHash -Algorithm SHA256 -Path $file).Hash.ToLower()
    }
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { return [BitConverter]::ToString($sha.ComputeHash([IO.File]::ReadAllBytes($file))).Replace('-', '').ToLower() }
    finally { $sha.Dispose() }
}

# ---------- Which build this machine needs ----------

$arch = $env:PROCESSOR_ARCHITECTURE
if ($arch -ne 'AMD64') {
    throw "no build for $arch Windows; only 64-bit x86 is built. See https://github.com/$repo/releases/latest"
}
$platform = 'windows-x86_64'

# ---------- Downloading ----------

[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

if (-not $Version) {
    # The releases/latest redirect's final URL ends in /tag/v3.12.1; no API token needed and no rate limit.
    $response = [System.Net.HttpWebRequest]::Create("https://github.com/$repo/releases/latest")
    $response.AllowAutoRedirect = $false
    $response.Method = 'HEAD'
    try { $null = $response.GetResponse() } catch { $null = $_.Exception.Response }
    $location = $response.Address.AbsoluteUri
    if ($location -notmatch '/tag/(v[0-9][^/]*)$') {
        throw 'could not ask GitHub for the latest version; pass -Version v3.12.1'
    }
    $Version = $Matches[1]
}

$number = $Version -replace '^v', ''
$name = "Blablador-$number-bla-$platform.zip"
$base = "https://github.com/$repo/releases/download/$Version"

Say "bla $number for $platform -> $Dir\bla.exe"
if ($DryRun) {
    Say "would download $base/$name and $base/SHA256SUMS.txt"
    return
}

$tmp = Join-Path ([IO.Path]::GetTempPath()) ("bla-install-" + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tmp -Force | Out-Null
try {
    $file = Join-Path $tmp $name
    try {
        Invoke-RestMethod -Uri "$base/$name" -OutFile $file -UseBasicParsing
        Invoke-RestMethod -Uri "$base/SHA256SUMS.txt" -OutFile "$tmp\SHA256SUMS.txt" -UseBasicParsing
    } catch {
        throw "could not download $base/$name : $($_.Exception.Message)"
    }

    $line = Select-String -Path "$tmp\SHA256SUMS.txt" -Pattern ("^([0-9a-f]{64})  " + [regex]::Escape($name) + '$') |
        Select-Object -First 1
    if (-not $line) { throw "$name is not in SHA256SUMS.txt" }
    $want = $line.Matches[0].Groups[1].Value
    $got = Get-Hash $file
    if ($got -ne $want) { throw "the download does not match SHA256SUMS.txt ($got, expected $want)" }

    Expand-Archive -Path $file -DestinationPath $tmp -Force
    $exe = Get-ChildItem -Path $tmp -Recurse -Filter bla.exe -File | Select-Object -First 1
    if (-not $exe) { throw 'the archive has no bla.exe in it' }

    # ---------- Installing ----------

    New-Item -ItemType Directory -Path $Dir -Force | Out-Null
    # bla cannot be replaced while it runs, so the new one goes in beside it and takes its place by a rename.
    $new = Join-Path $Dir 'bla.new.exe'
    Copy-Item $exe.FullName $new -Force
    try {
        Move-Item -Path $new -Destination (Join-Path $Dir 'bla.exe') -Force
    } catch {
        Remove-Item $new -Force -ErrorAction SilentlyContinue
        throw "cannot write $Dir\bla.exe; is bla running? Close it and try again"
    }
    # The README of this version, next to the program.
    $readme = Get-ChildItem -Path $tmp -Recurse -Filter README.md -File | Select-Object -First 1
    if ($readme) { Copy-Item $readme.FullName (Join-Path $Dir 'README.md') -Force }

    $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    if (-not $userPath) { $userPath = '' }
    $onPath = ($userPath -split ';' | Where-Object { $_ -and $_.TrimEnd('\') -ieq $Dir.TrimEnd('\') }).Count -gt 0
    $inThisShell = ($env:Path -split ';' | Where-Object { $_ -and $_.TrimEnd('\') -ieq $Dir.TrimEnd('\') }).Count -gt 0
    if (-not $onPath) {
        $joined = if ($userPath.TrimEnd(';')) { $userPath.TrimEnd(';') + ';' + $Dir } else { $Dir }
        [Environment]::SetEnvironmentVariable('Path', $joined, 'User')
    }

    Say ''
    Say "Installed $(& (Join-Path $Dir 'bla.exe') --version) as $Dir\bla.exe"
    if (-not $inThisShell) {
        Say ''
        Say 'Open a new terminal so that bla is on your PATH (this one does not see the change).'
    }
    if (-not (Test-Path (Join-Path $env:USERPROFILE '.bla\.apikey')) -and -not $env:BLABLADOR_API_KEY) {
        Say ''
        Say 'Next: bla login   (paste your Blablador API key), then: bla "hello"'
    }
} finally {
    Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
}
