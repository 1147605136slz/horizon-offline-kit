#requires -Version 5.1
<#
.SYNOPSIS
Cache the pinned Minecraft 26.3 inputs and prepare an existing Horizon installation.
.DESCRIPTION
Downloads only game metadata, jars, libraries and assets from the four pinned official
hosts. Requires an existing Horizon installation and a separately installed Java 25.
VerifyOnly reads the cache and validates prerequisites; it never downloads, creates
folders, or invokes Horizon prepare/check. Normal mode performs prepare followed by check.
The metadata has a pinned SHA1 but no independently published size in this script;
all child downloads require both their metadata size and SHA1. Every transfer must
produce a nonempty file, including the pinned metadata.
.EXAMPLE
./Prepare-Horizon.ps1 -HorizonRoot 'D:\Apps\Horizon' -JavaHome 'D:\Java\jdk-25'
Sample paths only; see VALIDATION.md for the tested installation and execution scope.
.EXAMPLE
./Prepare-Horizon.ps1 -HorizonRoot 'D:\Apps\Horizon' -JavaHome 'D:\Java\jdk-25' -VerifyOnly
Uses the same cache layout and checks all referenced resources without network access.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string] $HorizonRoot,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string] $JavaHome,
    [ValidateNotNullOrEmpty()][string] $CacheDir = (Join-Path $PSScriptRoot 'cache'),
    [ValidateRange(1, 128)][int] $Parallel = 12,
    [switch] $VerifyOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
$Version = '26.3'
$MetadataSha1 = '9f67e10ed013deeaad20ac3c800652765d493408'
$MetadataUrl = "https://piston-meta.mojang.com/v1/packages/$MetadataSha1/26.3.json"
$AllowedHosts = @('piston-meta.mojang.com', 'piston-data.mojang.com',
    'libraries.minecraft.net', 'resources.download.minecraft.net')
$HorizonRoot = [IO.Path]::GetFullPath($HorizonRoot)
$JavaHome = [IO.Path]::GetFullPath($JavaHome)
$CacheDir = [IO.Path]::GetFullPath($CacheDir)

function Get-Field($Object, [string] $Name) {
    if ($null -eq $Object) { return $null }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -ne $property) { return $property.Value }
    return $null
}

function Assert-OfficialUrl([string] $Url) {
    $uri = $null
    if (-not [Uri]::TryCreate($Url, [UriKind]::Absolute, [ref] $uri) -or
        $uri.Scheme -cne 'https' -or $uri.Host -notin $AllowedHosts -or
        -not $uri.IsDefaultPort -or $uri.UserInfo -or $uri.Fragment) {
        throw "Rejected metadata URL (HTTPS official host allowlist): $Url"
    }
}

function Assert-NoReparsePoint([string] $Path) {
    $cursor = $Path
    while ($cursor) {
        if (Test-Path -LiteralPath $cursor) {
            $item = Get-Item -LiteralPath $cursor -Force
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
                throw "Reparse point in cache path: $cursor"
            }
        }
        $parent = [IO.Path]::GetDirectoryName($cursor)
        if ($parent -eq $cursor) { break }
        $cursor = $parent
    }
}

function Get-CachePath([string] $RelativePath) {
    if ([string]::IsNullOrWhiteSpace($RelativePath) -or
        [IO.Path]::IsPathRooted($RelativePath) -or $RelativePath.Contains('\') -or
        $RelativePath -match '[\x00-\x1f:<>"|?*]') {
        throw "Invalid metadata relative path: $RelativePath"
    }
    foreach ($segment in $RelativePath.Split('/')) {
        if ($segment -in @('', '.', '..') -or $segment -match '[. ]$' -or
            $segment -match '^(?i:CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\.|$)') {
            throw "Unsafe metadata path segment: $RelativePath"
        }
    }
    $full = [IO.Path]::GetFullPath((Join-Path $CacheDir $RelativePath))
    $prefix = $CacheDir.TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
    if (-not $full.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Metadata path escapes cache: $RelativePath"
    }
    Assert-NoReparsePoint $full
    return $full
}

function New-Resource([string] $RelativePath, [string] $Url, [string] $Sha1, $Size) {
    Assert-OfficialUrl $Url
    if ($Sha1 -notmatch '^[a-fA-F0-9]{40}$') { throw "Missing or invalid SHA1: $RelativePath" }
    $length = $null
    if ($null -ne $Size) {
        $parsedSize = 0L
        if (-not [long]::TryParse([string] $Size, [ref] $parsedSize) -or $parsedSize -lt 0) {
            throw "Invalid metadata size: $RelativePath"
        }
        $length = $parsedSize
    }
    [pscustomobject]@{ Path = (Get-CachePath $RelativePath); Url = $Url;
        Sha1 = $Sha1.ToLowerInvariant(); Size = $length }
}

function New-MetadataResource([string] $RelativePath, $Descriptor) {
    if ($null -eq (Get-Field $Descriptor 'size')) { throw "Missing size: $RelativePath" }
    New-Resource $RelativePath (Get-Field $Descriptor 'url') (Get-Field $Descriptor 'sha1') (Get-Field $Descriptor 'size')
}

function Test-Resource($Resource, [string] $Path = $Resource.Path) {
    Assert-NoReparsePoint $Path
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }
    $length = (Get-Item -LiteralPath $Path).Length
    if ($null -ne $Resource.Size -and $length -ne $Resource.Size) { return $false }
    if ($null -eq $Resource.Size -and $length -eq 0) { return $false }
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA1).Hash -ieq $Resource.Sha1
}

function ConvertTo-CurlString([string] $Value) {
    if ($Value -match '[\r\n\x00]') { throw 'Invalid newline or NUL in curl config value.' }
    return '"' + $Value.Replace('\', '\\').Replace('"', '\"') + '"'
}

function Sync-Resources([object[]] $Resources) {
    $pending = @($Resources | Where-Object { -not (Test-Resource $_) })
    if ($pending.Count -eq 0) { return }
    if ($VerifyOnly) {
        throw ("Cache verification failed for {0} resource(s):`n{1}" -f $pending.Count,
            (($pending | ForEach-Object { $_.Path }) -join "`n"))
    }
    # One initial batch and at most two retry batches; only failed items enter retries.
    for ($attempt = 0; $attempt -le 2 -and $pending.Count -gt 0; $attempt++) {
        $transfers = [Collections.Generic.List[object]]::new()
        $config = Join-Path $CacheDir ('.curl-' + [guid]::NewGuid().ToString('N') + '.config')
        try {
            $lines = [Collections.Generic.List[string]]::new()
            foreach ($resource in $pending) {
                Assert-NoReparsePoint $resource.Path
                [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($resource.Path)) | Out-Null
                $part = $resource.Path + '.' + [guid]::NewGuid().ToString('N') + '.part'
                if ($transfers.Count -gt 0) { $lines.Add('next') }
                # --next resets local options: repeat every per-transfer option here.
                $lines.Add('fail')
                $lines.Add('silent')
                $lines.Add('show-error')
                $lines.Add('proto = "=https"')
                $lines.Add('tlsv1.2')
                $lines.Add('connect-timeout = 30')
                $lines.Add('max-time = 1800')
                # No location: redirects cannot escape the allowlist.
                $lines.Add('url = ' + (ConvertTo-CurlString $resource.Url))
                $lines.Add('output = ' + (ConvertTo-CurlString $part))
                $transfers.Add([pscustomobject]@{ Resource = $resource; Part = $part })
            }
            [IO.File]::WriteAllLines($config, $lines, [Text.UTF8Encoding]::new($false))
            # Global flags stay on the CLI and survive each config --next.
            & $script:CurlExe --disable --parallel --parallel-max $Parallel --config $config
            $curlExit = $LASTEXITCODE
            $failed = [Collections.Generic.List[object]]::new()
            foreach ($transfer in $transfers) {
                if (Test-Resource $transfer.Resource $transfer.Part) {
                    Assert-NoReparsePoint $transfer.Resource.Path
                    Move-Item -LiteralPath $transfer.Part -Destination $transfer.Resource.Path -Force
                } else {
                    $failed.Add($transfer.Resource)
                }
            }
            $pending = @($failed.ToArray())
            if ($curlExit -ne 0 -or $pending.Count -gt 0) {
                Write-Warning "curl batch $($attempt + 1): exit=$curlExit, failed=$($pending.Count)."
            }
        } finally {
            foreach ($transfer in $transfers) {
                if (Test-Path -LiteralPath $transfer.Part) { Remove-Item -LiteralPath $transfer.Part -Force }
            }
            if (Test-Path -LiteralPath $config) { Remove-Item -LiteralPath $config -Force }
        }
    }
    if ($pending.Count -gt 0) {
        throw ("Download verification failed after three batches:`n" +
            (($pending | ForEach-Object { $_.Path }) -join "`n"))
    }
}

$PrepareExe = Join-Path $HorizonRoot 'horizon-prepare.exe'
$LockPath = Join-Path $HorizonRoot 'research-lock.json'
$JavaExe = Join-Path $JavaHome 'bin/java.exe'
foreach ($path in @($PrepareExe, $LockPath, $JavaExe)) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Required file missing: $path" }
}
$lock = Get-Content -LiteralPath $LockPath -Raw -Encoding utf8 | ConvertFrom-Json
$mcLock = Get-Field $lock 'minecraft'
if ((Get-Field $mcLock 'version') -cne $Version -or (Get-Field $mcLock 'java_major') -ne 25) {
    throw 'Horizon research-lock must pin Minecraft 26.3 and Java 25.'
}
$acceptedMetadata = @((Get-Field $mcLock 'manifest_sha1')) + @((Get-Field $mcLock 'accepted_manifest_sha1'))
if ($MetadataSha1 -notin $acceptedMetadata) { throw 'Pinned version JSON SHA1 is not accepted by research-lock.' }
# Windows PowerShell 5.1 wraps native stderr as ErrorRecord even on exit 0.
# java -version writes its normal version banner there.
$oldErrorPreference = $ErrorActionPreference
try {
    $ErrorActionPreference = 'Continue'
    $javaText = (& $JavaExe -version 2>&1 | Out-String)
    $javaExit = $LASTEXITCODE
} finally {
    $ErrorActionPreference = $oldErrorPreference
}
if ($javaExit -ne 0 -or $javaText -notmatch '(?m)(?:openjdk|java) version "25(?:[.\-+\"]|$)') {
    throw "Expected Java 25 (exit=$javaExit): $javaText"
}
Assert-NoReparsePoint $CacheDir
if (-not $VerifyOnly) {
    $script:CurlExe = (Get-Command curl.exe -CommandType Application -ErrorAction Stop).Source
    [IO.Directory]::CreateDirectory($CacheDir) | Out-Null
}
$metadataResource = New-Resource 'versions/26.3/26.3.json' $MetadataUrl $MetadataSha1 $null
Sync-Resources @($metadataResource)
$metadata = Get-Content -LiteralPath $metadataResource.Path -Raw -Encoding utf8 | ConvertFrom-Json
if ((Get-Field $metadata 'id') -cne $Version -or
    (Get-Field (Get-Field $metadata 'javaVersion') 'majorVersion') -ne 25) {
    throw 'Version metadata must identify Minecraft 26.3 and Java 25, matching research-lock.'
}
$downloads = Get-Field $metadata 'downloads'
$client = New-MetadataResource 'versions/26.3/client.jar' (Get-Field $downloads 'client')
$server = New-MetadataResource 'versions/26.3/server.jar' (Get-Field $downloads 'server')
if ($client.Sha1 -ine (Get-Field $mcLock 'client_sha1') -or
    $server.Sha1 -ine (Get-Field $mcLock 'server_sha1')) {
    throw 'Client/server metadata hashes differ from research-lock.'
}
$indexDescriptor = Get-Field $metadata 'assetIndex'
$indexId = [string] (Get-Field $indexDescriptor 'id')
if ($indexId -notmatch '^[a-zA-Z0-9_-]+$') { throw "Invalid asset index id: $indexId" }
$assetIndex = New-MetadataResource "assets/indexes/$indexId.json" $indexDescriptor
$acceptedIndex = @((Get-Field $mcLock 'accepted_asset_index_sha1'))
if ($acceptedIndex.Count -gt 0 -and $null -ne $acceptedIndex[0] -and $assetIndex.Sha1 -notin $acceptedIndex) {
    throw 'Asset index SHA1 is not accepted by research-lock.'
}
# Validate all library URLs and paths before downloading the index or artifacts.
$resources = [Collections.Generic.Dictionary[string, object]]::new([StringComparer]::OrdinalIgnoreCase)
function Add-Resource($Resource) {
    if ($resources.ContainsKey($Resource.Path)) {
        $old = $resources[$Resource.Path]
        if ($old.Sha1 -ne $Resource.Sha1 -or $old.Size -ne $Resource.Size -or $old.Url -cne $Resource.Url) {
            throw "Conflicting resource descriptors: $($Resource.Path)"
        }
    } else { $resources.Add($Resource.Path, $Resource) }
}
Add-Resource $client
Add-Resource $server
foreach ($library in @(Get-Field $metadata 'libraries')) {
    $artifact = Get-Field (Get-Field $library 'downloads') 'artifact'
    if ($null -eq $artifact) { continue }
    $artifactPath = [string] (Get-Field $artifact 'path')
    if ([string]::IsNullOrWhiteSpace($artifactPath)) { throw 'Library artifact has no path.' }
    Add-Resource (New-MetadataResource "libraries/$artifactPath" $artifact)
}
Sync-Resources @($assetIndex)
$index = Get-Content -LiteralPath $assetIndex.Path -Raw -Encoding utf8 | ConvertFrom-Json
$objects = Get-Field $index 'objects'
if ($null -eq $objects) { throw 'Asset index has no objects.' }
foreach ($property in $objects.PSObject.Properties) {
    $hash = [string] (Get-Field $property.Value 'hash')
    if ($hash -notmatch '^[a-f0-9]{40}$') { throw "Invalid asset hash: $($property.Name)" }
    $size = Get-Field $property.Value 'size'
    if ($null -eq $size) { throw "Missing asset size: $($property.Name)" }
    $objectPath = $hash.Substring(0, 2) + '/' + $hash
    Add-Resource (New-Resource "assets/objects/$objectPath" "https://resources.download.minecraft.net/$objectPath" $hash $size)
}
Sync-Resources @($resources.Values)
$total = $resources.Count + 2
if ($VerifyOnly) {
    Write-Output "Verified $total cached resources for Minecraft $Version; no network or preparation performed."
    return
}
$output = Join-Path $HorizonRoot '.local/horizon-client/26.3'
$prepareArgs = @('--prepare', '--client-jar', $client.Path, '--server-jar', $server.Path,
    '--version-json', $metadataResource.Path, '--libraries-dir', (Join-Path $CacheDir 'libraries'),
    '--assets-dir', (Join-Path $CacheDir 'assets'), '--java-home', $JavaHome,
    '--root', $HorizonRoot, '--output', $output, '--complete', '--progress', 'json')
# The preparer may consult JAVA_HOME/PATH before --java-home. Select the validated JVM.
$oldJavaHome = $env:JAVA_HOME
$oldPath = $env:PATH
try {
    $env:JAVA_HOME = $JavaHome
    $env:PATH = (Join-Path $JavaHome 'bin') + [IO.Path]::PathSeparator + $oldPath
    & $PrepareExe @prepareArgs
    if ($LASTEXITCODE -ne 0) { throw "horizon-prepare --prepare failed: exit $LASTEXITCODE" }
    & $PrepareExe --check --root $HorizonRoot --output $output
    if ($LASTEXITCODE -ne 0) { throw "horizon-prepare --check failed: exit $LASTEXITCODE" }
} finally {
    $env:JAVA_HOME = $oldJavaHome
    $env:PATH = $oldPath
}
Write-Output "Prepared and checked Minecraft $Version resources: $output ($total cached inputs)."
