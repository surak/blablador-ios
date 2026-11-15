# Installs or updates the Blablador app on Windows: downloads the latest Blablador-<version>-windows-x86_64.zip,
# checks it against SHA256SUMS.txt, puts Blablador.exe in %LOCALAPPDATA%\Programs\Blablador, adds Start menu and
# Desktop shortcuts and starts it. The API key and chats are kept (they live in Credential Manager and AppData).
#
#   powershell -ExecutionPolicy ByPass -c "iex ((New-Object Net.WebClient).DownloadString('https://surak.github.io/blablador-ios/app.ps1'))"
#
# Run through iex, where param() does nothing, so the folder comes from BLABLADOR_DIR.
$Dir = if ($env:BLABLADOR_DIR) { $env:BLABLADOR_DIR } else { "$env:LOCALAPPDATA\Programs\Blablador" }

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
$repo = 'surak/blablador-ios'

$release = Invoke-RestMethod "https://api.github.com/repos/$repo/releases/latest" -UseBasicParsing
$asset = $release.assets | Where-Object { $_.name -like '*-windows-x86_64.zip' -and $_.name -notlike '*-bla-*' } | Select-Object -First 1
$sums = $release.assets | Where-Object { $_.name -eq 'SHA256SUMS.txt' } | Select-Object -First 1
if (-not $asset -or -not $sums) { throw "the latest release has no Windows app; see https://github.com/$repo/releases/latest" }
Write-Host "Blablador $($release.tag_name) -> $Dir"

$tmp = Join-Path ([IO.Path]::GetTempPath()) ("blablador-" + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tmp -Force | Out-Null
try {
    $zip = Join-Path $tmp $asset.name
    Invoke-WebRequest $asset.browser_download_url -OutFile $zip -UseBasicParsing
    $sumText = (Invoke-WebRequest $sums.browser_download_url -UseBasicParsing).Content
    if ($sumText -is [byte[]]) { $sumText = [Text.Encoding]::UTF8.GetString($sumText) }
    $line = ($sumText -split "`n") | Where-Object { $_ -match ("^([0-9a-f]{64})  " + [regex]::Escape($asset.name) + '\s*$') } | Select-Object -First 1
    if (-not $line) { throw "$($asset.name) is not in SHA256SUMS.txt" }
    $want = $Matches[1]
    $got = (Get-FileHash -Algorithm SHA256 $zip).Hash.ToLower()
    if ($got -ne $want) { throw "the download does not match SHA256SUMS.txt" }

    Expand-Archive $zip -DestinationPath $tmp -Force
    $exe = Get-ChildItem $tmp -Recurse -Filter Blablador.exe -File | Select-Object -First 1
    if (-not $exe) { throw 'the archive has no Blablador.exe in it' }

    # A running Blablador.exe cannot be replaced.
    Get-Process Blablador -ErrorAction SilentlyContinue | Stop-Process -Force
    Start-Sleep -Milliseconds 500
    New-Item -ItemType Directory -Path $Dir -Force | Out-Null
    Copy-Item $exe.FullName (Join-Path $Dir 'Blablador.exe') -Force
} finally {
    Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
}

$target = Join-Path $Dir 'Blablador.exe'
$shell = New-Object -ComObject WScript.Shell
foreach ($folder in @([Environment]::GetFolderPath('Programs'), [Environment]::GetFolderPath('Desktop'))) {
    $link = $shell.CreateShortcut((Join-Path $folder 'Blablador.lnk'))
    $link.TargetPath = $target
    $link.WorkingDirectory = $Dir
    $link.Save()
}
Write-Host "Installed. Starting Blablador (also in the Start menu and on the Desktop)."
Start-Process $target
