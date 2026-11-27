param([string]$Prefix = $env:WASDON_PREFIX, [string]$Version = $env:WASDON_VERSION)
$ErrorActionPreference = 'Stop'
$addPath = -not $Prefix
if ($addPath) { $Prefix = Join-Path $env:LOCALAPPDATA 'Wasdon\SDK' }
if (-not $Version) { $Version = 'latest' }
if ([System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture -ne 'X64') { throw 'Wasdon requires Windows x64.' }
$releases = 'https://github.com/anosatsuk124/wasdon-zig/releases'
if ($Version -eq 'latest') { $base = "$releases/latest/download" }
elseif ($Version -match '^v[0-9][0-9A-Za-z.-]*$') { $base = "$releases/download/$Version" }
else { throw 'Expected a version tag such as v0.1.0' }
if ($env:WASDON_RELEASE_BASE) { $base = $env:WASDON_RELEASE_BASE }
$asset = 'wasdon-windows-x64.zip'
$parent = Split-Path -Parent $Prefix
$work = Join-Path $parent ('.wasdon-install-' + [guid]::NewGuid())
New-Item -ItemType Directory -Force $work | Out-Null
$previous = Join-Path $work 'previous'
$lock = $null
try {
    $archive = Join-Path $work $asset
    Invoke-WebRequest -UseBasicParsing "$base/$asset" -OutFile $archive
    $digestPath = Join-Path $work 'digest'
    Invoke-WebRequest -UseBasicParsing "$base/$asset.sha256" -OutFile $digestPath
    $expected = ((Get-Content $digestPath -Raw).Trim() -split '\s+')[0]
    if ((Get-FileHash $archive -Algorithm SHA256).Hash -ne $expected) { throw "SHA-256 mismatch for $asset" }
    $stage = Join-Path $work 'sdk'
    Expand-Archive -LiteralPath $archive -DestinationPath $stage
    & (Join-Path $stage 'bin\wasdon.exe') language list --json | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'SDK verification failed' }
    New-Item -ItemType File (Join-Path $stage '.wasdon-install') | Out-Null
    $lock = [IO.File]::Open("$Prefix.install-lock", 'OpenOrCreate', 'ReadWrite', 'None')
    if (Test-Path $Prefix) {
        if (-not (Test-Path (Join-Path $Prefix '.wasdon-install'))) { throw "Destination already exists: $Prefix" }
        Move-Item -LiteralPath $Prefix -Destination $previous
    }
    try { Move-Item -LiteralPath $stage -Destination $Prefix }
    catch { if (Test-Path $previous) { Move-Item $previous $Prefix }; throw }
    $bin = Join-Path $Prefix 'bin'
    if ($addPath) {
        $path = [Environment]::GetEnvironmentVariable('Path', 'User')
        if ($bin -notin ($path -split ';')) { [Environment]::SetEnvironmentVariable('Path', "$bin;$path", 'User') }
        $env:Path = "$bin;$env:Path"
    }
    Write-Output "Installed $bin\wasdon.exe"
} finally {
    if ($lock) { $lock.Dispose() }
    if ((Test-Path $previous) -and -not (Test-Path $Prefix)) { Move-Item $previous $Prefix }
    Remove-Item -LiteralPath $work -Recurse -Force
}
