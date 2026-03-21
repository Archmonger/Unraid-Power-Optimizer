param(
    [string]$SourceManifest = 'power.optimizer.plg',
    [string]$LocalManifest = 'power.optimizer-local.plg',
    [string]$LocalBaseUrl
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

function Get-PluginBaseUrlFromManifest {
    param([string]$ManifestPath)

    if (-not (Test-Path -LiteralPath $ManifestPath)) {
        return ''
    }

    $raw = Get-Content -Raw -LiteralPath $ManifestPath
    $pluginOpen = [regex]::Match($raw, '<PLUGIN[^>]*>').Value
    if ([string]::IsNullOrWhiteSpace($pluginOpen)) {
        return ''
    }

    $urlMatch = [regex]::Match($pluginOpen, '\bpluginURL="([^"]+)"')
    if (-not $urlMatch.Success) {
        return ''
    }

    try {
        $uri = [System.Uri]::new($urlMatch.Groups[1].Value)
        return ($uri.GetLeftPart([System.UriPartial]::Authority) + $uri.AbsolutePath.Substring(0, $uri.AbsolutePath.LastIndexOf('/'))).TrimEnd('/')
    } catch {
        return ''
    }
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

function Get-RunFileBody {
    param(
        [string]$Manifest,
        [string]$Method
    )

    $methodAttr = if ([string]::IsNullOrWhiteSpace($Method)) {
        ''
    } else {
        ' Method="' + [regex]::Escape($Method) + '"'
    }

    $inlinePattern = '(?s)<FILE Run="/bin/bash"' + $methodAttr + '>\s*<INLINE(?:\s+Type="[^"]*")?>\s*<!\[CDATA\[\r?\n(.*?)\r?\n\]\]>\s*</INLINE>\s*</FILE>'
    $inlineMatch = [regex]::Match($Manifest, $inlinePattern)
    if ($inlineMatch.Success) {
        return $inlineMatch.Groups[1].Value
    }

    $fallbackPattern = '(?s)<FILE Run="/bin/bash"' + $methodAttr + '><!\[CDATA\[\r?\n(.*?)\r?\n\]\]></FILE>'
    $fallbackMatch = [regex]::Match($Manifest, $fallbackPattern)
    if ($fallbackMatch.Success) {
        return $fallbackMatch.Groups[1].Value
    }

    return $null
}

$sourceManifestPath = Resolve-RepoPath -Path $SourceManifest
$localManifestPath = Resolve-RepoPath -Path $LocalManifest

$baseUrlCandidate = ($LocalBaseUrl ?? '').Trim()
if ([string]::IsNullOrWhiteSpace($baseUrlCandidate)) {
    $baseUrlCandidate = ($env:LOCAL_BASE_URL ?? '').Trim()
}
if ([string]::IsNullOrWhiteSpace($baseUrlCandidate)) {
    $baseUrlCandidate = Get-PluginBaseUrlFromManifest -ManifestPath $localManifestPath
}
if ([string]::IsNullOrWhiteSpace($baseUrlCandidate)) {
    throw 'LocalBaseUrl is required. Provide -LocalBaseUrl, set LOCAL_BASE_URL, or ensure an existing local manifest has pluginURL set.'
}

$normalizedBaseUrl = $baseUrlCandidate
if ($normalizedBaseUrl -notmatch '^[a-zA-Z][a-zA-Z0-9+.-]*://') {
    # Unraid plugin manager expects URLs; default to HTTP for LAN hosts.
    $normalizedBaseUrl = "http://$normalizedBaseUrl"
}
$normalizedBaseUrl = $normalizedBaseUrl.TrimEnd('/')
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
$pluginVersion = [DateTime]::Now.ToString('yyyy.MM.dd.HHmm')
$localArchiveBaseName = "$pluginName-$pluginVersion.tgz"

$changesMatch = [regex]::Match($manifest, '(?s)<CHANGES>\r?\n(.*?)\r?\n</CHANGES>')
if (-not $changesMatch.Success) {
    throw 'Could not extract CHANGES block.'
}
$changesBody = $changesMatch.Groups[1].Value

$runInstallBody = Get-RunFileBody -Manifest $manifest -Method ''
if ($null -eq $runInstallBody) {
    throw 'Could not extract install Run block.'
}

$runRemoveBody = Get-RunFileBody -Manifest $manifest -Method 'remove'
if ($null -eq $runRemoveBody) {
    throw 'Could not extract remove Run block.'
}

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

$localArchiveRelativePath = "dist/local/$localArchiveBaseName"
$localArchiveFullPath = Resolve-RepoPath -Path $localArchiveRelativePath
$localArchiveUrlPath = Convert-ToRepoRelativePath -Path $localArchiveFullPath
$localArchiveTempPath = $localArchiveFullPath + '.tmp'
$localArchiveDir = Split-Path -Parent $localArchiveFullPath

if (-not (Test-Path -LiteralPath $localArchiveDir)) {
    New-Item -ItemType Directory -Path $localArchiveDir -Force | Out-Null
}

$staleLocalArchives = Get-ChildItem -LiteralPath $localArchiveDir -Filter "$pluginName-*.tgz" -File -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -ne $localArchiveBaseName }

foreach ($staleLocalArchive in $staleLocalArchives) {
    Remove-Item -LiteralPath $staleLocalArchive.FullName -Force
}

if (Test-Path -LiteralPath $localArchiveFullPath) {
    Remove-Item -LiteralPath $localArchiveFullPath -Force
}
if (Test-Path -LiteralPath $localArchiveTempPath) {
    Remove-Item -LiteralPath $localArchiveTempPath -Force
}

& tar -czf $localArchiveTempPath -C $payloadDir .
if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $localArchiveTempPath)) {
    throw 'Failed to create local plugin archive.'
}

Move-Item -LiteralPath $localArchiveTempPath -Destination $localArchiveFullPath -Force

$localArchiveSha256 = (Get-FileHash -LiteralPath $localArchiveFullPath -Algorithm SHA256).Hash.ToLowerInvariant()

$localRunInstallBody = $runInstallBody
$localRunInstallBody = [regex]::Replace(
    $localRunInstallBody,
    'PLUGIN_VERSION="[^"]+"',
    ('PLUGIN_VERSION="' + $pluginVersion + '"'),
    1
)
if ($localRunInstallBody -match 'PLUGIN_ARCHIVE_BASENAME="[^"]+"') {
    $localRunInstallBody = [regex]::Replace(
        $localRunInstallBody,
        'PLUGIN_ARCHIVE_BASENAME="[^"]+"',
        ('PLUGIN_ARCHIVE_BASENAME="' + $localArchiveBaseName + '"'),
        1
    )
}

$localPluginOpen = $pluginOpen
$localPluginOpen = [regex]::Replace(
    $localPluginOpen,
    '(\bversion=")[^"]+(")',
    {
        param($match)
        return $match.Groups[1].Value + $pluginVersion + $match.Groups[2].Value
    },
    1
)
$localManifestUrlPath = Convert-ToRepoRelativePath -Path $localManifestPath
$localPluginUrl = "$normalizedBaseUrl/$localManifestUrlPath"
if ($localPluginOpen -match '\bpluginURL="[^"]*"') {
    $localPluginOpen = [regex]::Replace($localPluginOpen, '\bpluginURL="[^"]*"', ('pluginURL="' + $localPluginUrl + '"'), 1)
} else {
    $localPluginOpen = $localPluginOpen.TrimEnd('>') + ' pluginURL="' + $localPluginUrl + '">'
}

$local = New-Object System.Text.StringBuilder
[void]$local.AppendLine('<?xml version="1.0" standalone=''yes''?>')
[void]$local.AppendLine($localPluginOpen)
[void]$local.AppendLine('<CHANGES>')
[void]$local.AppendLine($changesBody)
[void]$local.AppendLine('</CHANGES>')
[void]$local.AppendLine('')

[void]$local.AppendLine(('<FILE Name="/boot/config/plugins/{0}/{1}">' -f $pluginName, $localArchiveBaseName))
[void]$local.AppendLine(('<URL>{0}/{1}</URL>' -f $normalizedBaseUrl, $localArchiveUrlPath))
[void]$local.AppendLine(('<SHA256>{0}</SHA256>' -f $localArchiveSha256))
[void]$local.AppendLine('</FILE>')
[void]$local.AppendLine('')

[void]$local.AppendLine('<FILE Run="/bin/bash"><INLINE><![CDATA[')
[void]$local.Append($localRunInstallBody)
if (-not $localRunInstallBody.EndsWith("`n")) {
    [void]$local.AppendLine('')
}
[void]$local.AppendLine(']]></INLINE></FILE>')
[void]$local.AppendLine('')

[void]$local.AppendLine('<FILE Run="/bin/bash" Method="remove"><INLINE><![CDATA[')
[void]$local.Append($runRemoveBody)
if (-not $runRemoveBody.EndsWith("`n")) {
    [void]$local.AppendLine('')
}
[void]$local.AppendLine(']]></INLINE></FILE>')
[void]$local.AppendLine('</PLUGIN>')

$localContent = $local.ToString().Replace("`r`n", "`n").Replace("`r", "`n")
Write-Utf8NoBom -Path $localManifestPath -Content $localContent

$localManifestDisplay = Convert-ToRepoRelativePath -Path $localManifestPath
Write-Host "Generated $localManifestDisplay (base URL: $normalizedBaseUrl, archive: $localArchiveUrlPath)"
