param(
    [string]$SourceManifest = 'power.optimizer.plg',
    [string]$DistDir = 'dist'
)

$ErrorActionPreference = 'Stop'
$RepoRoot = Split-Path -Parent $PSScriptRoot

function Resolve-RepoPath {
    param([string]$Path)

    if ([System.IO.Path]::IsPathRooted($Path)) {
        return [System.IO.Path]::GetFullPath($Path)
    }

    return [System.IO.Path]::GetFullPath((Join-Path $RepoRoot $Path))
}

function Convert-ToRepoRelativePath {
    param([string]$Path)

    $fullPath = [System.IO.Path]::GetFullPath($Path)
    $repoRoot = [System.IO.Path]::GetFullPath($RepoRoot)
    $repoRootWithSep = $repoRoot.TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar) + [System.IO.Path]::DirectorySeparatorChar
    $repoRootUri = [System.Uri]::new($repoRootWithSep)
    $fullUri = [System.Uri]::new($fullPath)

    return [System.Uri]::UnescapeDataString($repoRootUri.MakeRelativeUri($fullUri).ToString()).Replace('\\', '/')
}

function Write-Utf8NoBom {
    param(
        [string]$Path,
        [string]$Content
    )

    $target = if ([System.IO.Path]::IsPathRooted($Path)) {
        [System.IO.Path]::GetFullPath($Path)
    } else {
        Resolve-RepoPath -Path $Path
    }

    [System.IO.File]::WriteAllText($target, $Content, [System.Text.UTF8Encoding]::new($false))
}

function Set-LfUtf8File {
    param([string]$Path)

    $raw = Get-Content -Raw -LiteralPath $Path
    if ($null -eq $raw) {
        return
    }

    $normalized = $raw.Replace("`r`n", "`n").Replace("`r", "`n")
    Write-Utf8NoBom -Path $Path -Content $normalized
}

$sourceManifestPath = Resolve-RepoPath -Path $SourceManifest
$manifest = Get-Content -Raw -LiteralPath $sourceManifestPath

$pluginOpen = [regex]::Match($manifest, '<PLUGIN[^>]*>').Value
if ([string]::IsNullOrWhiteSpace($pluginOpen)) {
    throw 'Could not find PLUGIN opening tag.'
}

$pluginNameMatch = [regex]::Match($pluginOpen, '\bname="([^"]+)"')
if (-not $pluginNameMatch.Success) {
    throw 'Could not find plugin name in PLUGIN opening tag.'
}
$pluginName = $pluginNameMatch.Groups[1].Value

$pluginVersionMatch = [regex]::Match($pluginOpen, '\bversion="([^"]+)"')
if (-not $pluginVersionMatch.Success) {
    throw 'Could not find plugin version in PLUGIN opening tag.'
}
$pluginVersion = $pluginVersionMatch.Groups[1].Value

$payloadDir = Resolve-RepoPath -Path "usr/local/emhttp/plugins/$pluginName"
if (-not (Test-Path -LiteralPath $payloadDir)) {
    throw "Missing plugin payload directory: $payloadDir"
}

Get-ChildItem -LiteralPath $payloadDir -File -Recurse |
    Where-Object { $_.Extension -in @('.page', '.php', '.sh', '.md') } |
    ForEach-Object {
    Set-LfUtf8File -Path $_.FullName
}

$eventDir = Join-Path $payloadDir 'event'
if (Test-Path -LiteralPath $eventDir) {
    Get-ChildItem -LiteralPath $eventDir -File -Recurse | ForEach-Object {
        Set-LfUtf8File -Path $_.FullName
    }
}

$archiveRelativePath = "$DistDir/$pluginName-$pluginVersion.tgz"
$archiveFullPath = Resolve-RepoPath -Path $archiveRelativePath
$archiveUrlPath = Convert-ToRepoRelativePath -Path $archiveFullPath
$archiveTempPath = $archiveFullPath + '.tmp'
$archiveDir = Split-Path -Parent $archiveFullPath

if (-not (Test-Path -LiteralPath $archiveDir)) {
    New-Item -ItemType Directory -Path $archiveDir -Force | Out-Null
}

$staleArchives = Get-ChildItem -LiteralPath $archiveDir -Filter "$pluginName-*.tgz" -File -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -ne "$pluginName-$pluginVersion.tgz" }

foreach ($staleArchive in $staleArchives) {
    Remove-Item -LiteralPath $staleArchive.FullName -Force
}

if (Test-Path -LiteralPath $archiveFullPath) {
    Remove-Item -LiteralPath $archiveFullPath -Force
}
if (Test-Path -LiteralPath $archiveTempPath) {
    Remove-Item -LiteralPath $archiveTempPath -Force
}

& tar -czf $archiveTempPath -C $payloadDir .
if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $archiveTempPath)) {
    throw 'Failed to create plugin release archive.'
}

Move-Item -LiteralPath $archiveTempPath -Destination $archiveFullPath -Force

$archiveSha256 = (Get-FileHash -LiteralPath $archiveFullPath -Algorithm SHA256).Hash.ToLowerInvariant()

$archiveNamePath = "/boot/config/plugins/$pluginName/$pluginName-$pluginVersion.tgz"
$remoteArchiveUrl = "https://raw.githubusercontent.com/Archmonger/Unraid-Power-Optimizer/main/$archiveUrlPath"
$archiveFileBlock = @"
<FILE Name="$archiveNamePath">
<URL>$remoteArchiveUrl</URL>
<SHA256>$archiveSha256</SHA256>
</FILE>
"@

$updatedManifest = [regex]::Replace(
    $manifest,
    '(?s)<FILE\s+Name="/boot/config/plugins/' + [regex]::Escape($pluginName) + '/[^"\n]+\.tgz">\s*<URL>.*?</URL>\s*<SHA256>.*?</SHA256>\s*</FILE>',
    $archiveFileBlock,
    1
)

if ($updatedManifest -eq $manifest) {
    $updatedManifest = [regex]::Replace(
        $manifest,
        '(?s)(</CHANGES>\s*)',
        ('$1' + "`n`n" + $archiveFileBlock + "`n"),
        1
    )
}

$updatedManifest = [regex]::Replace(
    $updatedManifest,
    'PLUGIN_VERSION="[^"]+"',
    ('PLUGIN_VERSION="' + $pluginVersion + '"'),
    1
)

$updatedContent = $updatedManifest.Replace("`r`n", "`n").Replace("`r", "`n")
Write-Utf8NoBom -Path $sourceManifestPath -Content $updatedContent

$sourceManifestDisplay = Convert-ToRepoRelativePath -Path $sourceManifestPath
Write-Host "Updated $sourceManifestDisplay"
Write-Host "Archive: $archiveUrlPath"
Write-Host "SHA256: $archiveSha256"
