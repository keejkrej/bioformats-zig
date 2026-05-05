param(
    [string]$Format,
    [string]$OutDir = "fixtures/cache",
    [int]$MaxDepth = 2,
    [long]$MaxBytes = 209715200,
    [string]$NamePattern = '\.(tif|tiff|ome\.tiff|png|gif|bmp|jpg|jpeg|jp2|jpx|am|amiramesh|grey|hx|labels|dm2|dm3|dm4|obf|c01|dib|flex|mea|res|oif|oib|pty|lut|dng|lsm|oir|vsi|ets|nd2|czi|lif|ics|ids|dv|r3d|mrc|map|nii|nrrd|nhdr|v|dcm|dicom|ima|vms|ims|ch5|h5|xml)$',
    [switch]$List
)

$ErrorActionPreference = "Stop"

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$sourcesPath = Join-Path $scriptDir "sources.json"
$sources = Get-Content $sourcesPath -Raw | ConvertFrom-Json

if ($List) {
    $sources.implemented_format_sources.PSObject.Properties |
        Sort-Object Name |
        ForEach-Object {
            [PSCustomObject]@{
                Format = $_.Name
                Sources = ($_.Value -join ", ")
            }
        } |
        Format-Table -AutoSize
    exit 0
}

if ([string]::IsNullOrWhiteSpace($Format)) {
    throw "Pass -Format <id>, or use -List to inspect available fixture sources."
}

$formatEntry = $sources.implemented_format_sources.PSObject.Properties |
    Where-Object { $_.Name -eq $Format } |
    Select-Object -First 1

if ($null -eq $formatEntry) {
    throw "No fixture source entry exists for format '$Format'."
}

function Resolve-SourceUrl {
    param([string[]]$Entries)

    foreach ($entry in $Entries) {
        if ($entry -match '^ome_images/(.+)$') {
            return ($sources.public_roots.ome_images.TrimEnd('/') + '/' + $Matches[1].TrimStart('/'))
        }
        if ($entry -match '^https?://') {
            return $entry
        }
    }
    return $null
}

function Resolve-ZenodoRecordId {
    param([string[]]$Entries)

    foreach ($entry in $Entries) {
        if ($entry -match '^zenodo/10\.5281/zenodo\.(\d+)$') {
            return $Matches[1]
        }
    }
    return $null
}

function Get-DirectoryLinks {
    param([string]$Url)

    $response = Invoke-WebRequest -UseBasicParsing -Uri $Url
    $links = @()
    foreach ($link in $response.Links) {
        if ($link.href) {
            $links += $link.href
        }
    }
    if ($links.Count -eq 0) {
        foreach ($match in [regex]::Matches($response.Content, 'href="([^"]+)"')) {
            $links += $match.Groups[1].Value
        }
    }
    return $links
}

function Resolve-Link {
    param(
        [string]$BaseUrl,
        [string]$Href
    )

    if ([string]::IsNullOrWhiteSpace($Href)) {
        return $null
    }
    if ($Href.StartsWith("?") -or $Href.StartsWith("#") -or $Href -eq "../") {
        return $null
    }
    return ([Uri]::new([Uri]$BaseUrl, $Href)).AbsoluteUri
}

function Get-RemoteLength {
    param([string]$Url)

    try {
        $head = Invoke-WebRequest -UseBasicParsing -Method Head -Uri $Url
        $length = $head.Headers["Content-Length"]
        if ($length) {
            if ($length -is [array]) {
                $length = $length[0]
            }
            return [long]$length
        }
    }
    catch {
        return $null
    }
    return $null
}

function Preferred-NamePattern {
    param([string]$Format)

    switch ($Format) {
        "amira" { return '\.(am|amiramesh|grey|hx|labels)$' }
        "cellomics" { return '\.(c01|dib)$' }
        "ecat7" { return '\.v$' }
        "flex" { return '\.(flex|mea|res)$' }
        "fluoview" { return '\.(tif|tiff)$' }
        "fv1000" { return '\.(oif|oib)$' }
        "gatan" { return '\.dm[34]$' }
        "gatandm2" { return '\.dm2$' }
        "hamamatsuvms" { return '\.vms$' }
        "mrc" { return '\.(mrc|map)$' }
        "nifti" { return '\.nii$' }
        "nrrd" { return '\.(nrrd|nhdr)$' }
        "obf" { return 'uncompressed\.obf$' }
        default { return $null }
    }
}

function Find-Candidate {
    param(
        [string]$Url,
        [int]$Depth,
        [string]$PreferredPattern
    )

    $links = Get-DirectoryLinks $Url
    $fallback = $null
    foreach ($href in $links) {
        $resolved = Resolve-Link $Url $href
        if ($null -eq $resolved) {
            continue
        }
        $leaf = [Uri]::UnescapeDataString(([Uri]$resolved).Segments[-1])
        if ($leaf -match '/$' -or $resolved.EndsWith('/')) {
            if ($Depth -gt 0) {
                $nested = Find-Candidate $resolved ($Depth - 1) $PreferredPattern
                if ($nested) {
                    return $nested
                }
            }
            continue
        }
        if ($leaf -notmatch $NamePattern) {
            continue
        }
        $length = Get-RemoteLength $resolved
        if ($length -ne $null -and $length -gt $MaxBytes) {
            continue
        }
        if ($PreferredPattern -and $leaf -match $PreferredPattern) {
            return $resolved
        }
        if ($null -eq $PreferredPattern -and $null -eq $fallback) {
            $fallback = $resolved
        }
    }
    return $fallback
}

function Find-ZenodoCandidate {
    param([string]$RecordId)

    $record = Invoke-RestMethod -UseBasicParsing -Uri "https://zenodo.org/api/records/$RecordId"
    foreach ($file in @($record.files)) {
        $name = [string]$file.key
        if ($name -notmatch $NamePattern) {
            continue
        }
        $length = [long]$file.size
        if ($length -gt $MaxBytes) {
            continue
        }
        return [PSCustomObject]@{
            Url = [string]$file.links.self
            FileName = $name
        }
    }
    return $null
}

function Get-IniValue {
    param(
        [string]$Content,
        [string]$Key
    )

    $escaped = [regex]::Escape($Key)
    $match = [regex]::Match($Content, "(?im)^\s*$escaped\s*=\s*(.+?)\s*$")
    if (-not $match.Success) {
        return $null
    }
    return $match.Groups[1].Value.Trim()
}

function Download-Companion {
    param(
        [string]$BaseUrl,
        [string]$Name,
        [string]$TargetDir
    )

    if ([string]::IsNullOrWhiteSpace($Name)) {
        return $null
    }
    $uri = [Uri]::new([Uri]$BaseUrl, $Name)
    $length = Get-RemoteLength $uri.AbsoluteUri
    if ($length -ne $null -and $length -gt $MaxBytes) {
        throw "Companion '$Name' is $length bytes, above MaxBytes $MaxBytes."
    }
    $targetPath = Join-Path $TargetDir ([Uri]::UnescapeDataString($uri.Segments[-1]))
    if (-not (Test-Path -LiteralPath $targetPath)) {
        Invoke-WebRequest -UseBasicParsing -Uri $uri.AbsoluteUri -OutFile $targetPath
    }
    return [PSCustomObject]@{
        Format = $Format
        Source = $uri.AbsoluteUri
        Path = $targetPath
        Bytes = (Get-Item $targetPath).Length
    }
}

function Download-HamamatsuVmsCompanions {
    param(
        [string]$VmsSource,
        [string]$VmsPath,
        [string]$TargetDir
    )

    $content = Get-Content -LiteralPath $VmsPath -Raw
    $rows = [int](Get-IniValue $content "NoJpegRows")
    $cols = [int](Get-IniValue $content "NoJpegColumns")
    if ($rows -le 0 -or $cols -le 0) {
        return
    }
    $baseUrl = [Uri]::new([Uri]$VmsSource, ".").AbsoluteUri
    $names = New-Object System.Collections.Generic.List[string]
    $names.Add((Get-IniValue $content "ImageFile"))
    $names.Add((Get-IniValue $content "ImageFile($($cols - 1),$($rows - 1))"))
    foreach ($name in ($names | Select-Object -Unique)) {
        $companion = Download-Companion $baseUrl $name $TargetDir
        if ($companion) {
            $companion
        }
    }
}

function Download-NrrdCompanions {
    param(
        [string]$HeaderSource,
        [string]$HeaderPath,
        [string]$TargetDir
    )

    $content = Get-Content -LiteralPath $HeaderPath -Raw
    $match = [regex]::Match($content, "(?im)^\s*data\s*file\s*:\s*(.+?)\s*$|^\s*datafile\s*:\s*(.+?)\s*$")
    if (-not $match.Success) {
        return
    }
    $name = if ($match.Groups[1].Success) { $match.Groups[1].Value.Trim() } else { $match.Groups[2].Value.Trim() }
    if ([string]::IsNullOrWhiteSpace($name) -or $name -match '\s') {
        return
    }
    $baseUrl = [Uri]::new([Uri]$HeaderSource, ".").AbsoluteUri
    Download-Companion $baseUrl $name $TargetDir
}

function Download-IcsCompanions {
    param(
        [string]$IcsSource,
        [string]$IcsPath,
        [string]$TargetDir
    )

    $content = Get-Content -LiteralPath $IcsPath -Raw
    $name = $null
    $match = [regex]::Match($content, "(?im)^\s*filename\s+(.+?)\s*$")
    if ($match.Success) {
        $name = $match.Groups[1].Value.Trim()
        if (-not ($name -match '\.[A-Za-z0-9]+$')) {
            $name = "$name.ids"
        }
    }
    if ([string]::IsNullOrWhiteSpace($name)) {
        $leaf = [System.IO.Path]::GetFileName($IcsPath)
        $name = [System.IO.Path]::ChangeExtension($leaf, ".ids")
    }
    $baseUrl = [Uri]::new([Uri]$IcsSource, ".").AbsoluteUri
    Download-Companion $baseUrl $name $TargetDir
}

$sourceUrl = Resolve-SourceUrl ([string[]]$formatEntry.Value)
$zenodoRecordId = Resolve-ZenodoRecordId ([string[]]$formatEntry.Value)
if ($null -eq $sourceUrl -and $null -eq $zenodoRecordId) {
    throw "Format '$Format' has no direct public URL or Zenodo record in sources.json: $($formatEntry.Value -join ', ')"
}

$candidate = $null
if ($sourceUrl) {
    if (-not $sourceUrl.EndsWith('/')) {
        $sourceUrl += '/'
    }
    $preferredPattern = Preferred-NamePattern $Format
    $candidateUrl = Find-Candidate $sourceUrl $MaxDepth $preferredPattern
    if ($candidateUrl) {
        $candidate = [PSCustomObject]@{
            Url = $candidateUrl
            FileName = [Uri]::UnescapeDataString(([Uri]$candidateUrl).Segments[-1])
        }
    }
}
if ($null -eq $candidate -and $zenodoRecordId) {
    $candidate = Find-ZenodoCandidate $zenodoRecordId
}
if ($null -eq $candidate) {
    throw "No downloadable candidate for '$Format' matched pattern '$NamePattern' within depth $MaxDepth and size cap $MaxBytes bytes."
}

$targetRoot = if ([System.IO.Path]::IsPathRooted($OutDir)) {
    $OutDir
} else {
    Join-Path (Get-Location) $OutDir
}
$targetDir = Join-Path $targetRoot $Format
New-Item -ItemType Directory -Force -Path $targetDir | Out-Null

$targetPath = Join-Path $targetDir $candidate.FileName
Invoke-WebRequest -UseBasicParsing -Uri $candidate.Url -OutFile $targetPath

[PSCustomObject]@{
    Format = $Format
    Source = $candidate.Url
    Path = $targetPath
    Bytes = (Get-Item $targetPath).Length
}

if ($Format -eq "hamamatsuvms") {
    Download-HamamatsuVmsCompanions $candidate.Url $targetPath $targetDir
}
if ($Format -eq "nrrd") {
    Download-NrrdCompanions $candidate.Url $targetPath $targetDir
}
if ($Format -eq "ics") {
    Download-IcsCompanions $candidate.Url $targetPath $targetDir
}
