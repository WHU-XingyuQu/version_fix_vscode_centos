[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[A-Za-z0-9._-]+$')]
    [string]$HostAlias,

    [string]$CodePath = 'code',
    [string]$ArchivePath,

    [ValidatePattern('^\.[A-Za-z0-9._-]+$')]
    [string]$ServerSubdirectory = '.vscode-server'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Assert-NativeExit([string]$Action) {
    if ($LASTEXITCODE -ne 0) { throw "$Action failed (exit $LASTEXITCODE)." }
}

function Get-Sha256([string]$Path) {
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$remoteInstaller = Join-Path $scriptDir 'install-centos7-server.sh'
if (-not (Test-Path -LiteralPath $remoteInstaller)) { throw "Missing $remoteInstaller" }

foreach ($name in @('ssh', 'scp', 'tar')) {
    if (-not (Get-Command $name -ErrorAction SilentlyContinue)) { throw "Required command missing: $name" }
}

$previousErrorAction = $ErrorActionPreference
$ErrorActionPreference = 'SilentlyContinue'
try { $codeLines = @(& $CodePath --version 2>$null) }
finally { $ErrorActionPreference = $previousErrorAction }
Assert-NativeExit 'Read local VS Code version'
if ($codeLines.Count -lt 3) { throw 'Unexpected code --version output.' }
$version = [string]$codeLines[0]
$commit = [string]$codeLines[1]
$architecture = [string]$codeLines[2]
if ($version -notmatch '^\d+\.\d+\.\d+$' -or $commit -notmatch '^[a-f0-9]{40}$') {
    throw 'Could not identify the local VS Code version and commit.'
}
if ($architecture -ne 'x64') { throw "Only Windows x64 VS Code is supported by this package ($architecture)." }
Write-Host "Local VS Code: $version / $commit / $architecture"

$factsCommand = 'source /etc/os-release; echo CODEX_HOME=$HOME; echo CODEX_ID=$ID; echo CODEX_VERSION=$VERSION_ID; echo CODEX_ARCH=$(uname -m); echo CODEX_GLIBC=$(getconf GNU_LIBC_VERSION)'
$factsOutput = @(& ssh -o ConnectTimeout=15 -T $HostAlias $factsCommand)
Assert-NativeExit 'SSH preflight'
$facts = @{}
foreach ($line in $factsOutput) {
    if ($line -match '^CODEX_([A-Z]+)=(.*)$') { $facts[$Matches[1]] = $Matches[2] }
}
foreach ($field in @('HOME', 'ID', 'VERSION', 'ARCH', 'GLIBC')) {
    if (-not $facts.ContainsKey($field)) { throw "Remote preflight missing $field. Output: $($factsOutput -join ' | ')" }
}
if ($facts.HOME -notmatch '^/[A-Za-z0-9._/-]+$') { throw 'Remote home path contains unsupported characters.' }
if ($facts.ID -notin @('centos', 'rhel') -or $facts.VERSION -notmatch '^7(\.|$)' -or $facts.ARCH -ne 'x86_64') {
    throw "Unsupported remote target: $($facts.ID) $($facts.VERSION) $($facts.ARCH). This patch is for CentOS/RHEL 7 x86_64."
}
Write-Host "Remote target: $($facts.ID) $($facts.VERSION), $($facts.ARCH), $($facts.GLIBC)"

$release = Invoke-RestMethod -Uri "https://api.github.com/repos/MikeWang000000/vscode-server-centos7/releases/tags/$version" -Headers @{ 'User-Agent' = 'Codex-VSCode-CentOS7-Repair' }
if ($release.tag_name -ne $version) { throw 'Release tag mismatch.' }
$assetName = "vscode-server_${version}_x64.tar.gz"
$asset = @($release.assets | Where-Object { $_.name -eq $assetName })
if ($asset.Count -ne 1) { throw "Exactly one $assetName asset is required." }
if ($asset[0].digest -notmatch '^sha256:([a-fA-F0-9]{64})$') { throw 'Release has no SHA256 digest; refusing unverified download.' }
$expectedHash = $Matches[1].ToLowerInvariant()
$expectedSize = [int64]$asset[0].size
if ($expectedSize -lt 1000000 -or $asset[0].browser_download_url -notlike "https://github.com/MikeWang000000/vscode-server-centos7/releases/download/$version/*") {
    throw 'Unexpected release asset metadata.'
}

if ($ArchivePath) {
    $archive = (Resolve-Path -LiteralPath $ArchivePath).Path
} else {
    $cacheDir = Join-Path $env:LOCALAPPDATA 'VSCode-CentOS7-Repair'
    New-Item -ItemType Directory -Force -Path $cacheDir | Out-Null
    $archive = Join-Path $cacheDir $assetName
    $validCache = (Test-Path -LiteralPath $archive) -and ((Get-Item -LiteralPath $archive).Length -eq $expectedSize) -and ((Get-Sha256 $archive) -eq $expectedHash)
    if (-not $validCache) {
        $partial = "$archive.partial"
        Write-Host "Downloading $assetName ($([Math]::Round($expectedSize / 1MB)) MiB)..."
        Invoke-WebRequest -Uri $asset[0].browser_download_url -OutFile $partial
        if ((Get-Item -LiteralPath $partial).Length -ne $expectedSize -or (Get-Sha256 $partial) -ne $expectedHash) {
            throw 'Downloaded archive failed the release size/SHA256 check.'
        }
        Move-Item -LiteralPath $partial -Destination $archive -Force
    }
}
if ((Get-Item -LiteralPath $archive).Length -ne $expectedSize -or (Get-Sha256 $archive) -ne $expectedHash) {
    throw 'Archive size/SHA256 does not match the GitHub release.'
}

$archiveEntries = @(& tar -tzf $archive)
Assert-NativeExit 'Inspect archive'
foreach ($required in @(
    'vscode-server/code-latest',
    "vscode-server/code-$commit",
    "vscode-server/code-$commit-cli",
    "vscode-server/cli/servers/Stable-$commit/server/node",
    'vscode-server/gnu/libc.so.6'
)) {
    if ($archiveEntries -cnotcontains $required) { throw "Archive does not match this VS Code commit: $required" }
}
if (@($archiveEntries | Where-Object { $_ -notlike 'vscode-server/*' -or $_ -match '(^|/)\.\.?(/|$)' }).Count -gt 0) {
    throw 'Archive contains an unexpected path.'
}
Write-Host "Archive verified: SHA256 $expectedHash"

$remoteHome = $facts.HOME.TrimEnd('/')
$stageDir = "$remoteHome/.vscode-centos7-installer-$commit"
$serverDir = "$remoteHome/$ServerSubdirectory"
& ssh -o ConnectTimeout=15 -T $HostAlias "mkdir -p $stageDir"
Assert-NativeExit 'Create remote staging directory'
$remoteArchive = "$stageDir/$assetName"
& scp -q -o ConnectTimeout=15 $archive "${HostAlias}:$remoteArchive"
Assert-NativeExit 'Upload archive'
& scp -q -o ConnectTimeout=15 $remoteInstaller "${HostAlias}:$stageDir/install-centos7-server.sh"
Assert-NativeExit 'Upload installer'
$remoteCommand = "bash $stageDir/install-centos7-server.sh $version $commit $expectedHash $serverDir $remoteArchive"
& ssh -o ConnectTimeout=15 -T $HostAlias $remoteCommand
Assert-NativeExit 'Remote patch and server smoke test'
Write-Host 'LOCAL_VERIFIED: SSH, patch, and localhost VS Code Server startup passed.'
Write-Host "Open VS Code and connect to SSH host '$HostAlias' to verify the editor window."
