param(
    [string]$BioformatsPath = "../bioformats",
    [switch]$Strict
)

$ErrorActionPreference = "Stop"

$skipReaders = @(
    "BaseTiff",
    "BaseZeiss",
    "BIFormat",
    "BufferedImage",
    "Delegate",
    "Format",
    "ICompressedTile",
    "IFormat",
    "Image",
    "ImageIO",
    "ImagePlus",
    "ImageProcessor",
    "LMSFile",
    "MinimalTiff",
    "MultipleImages",
    "SubResolutionFormat",
    "TiffDelegate",
    "TiffJAI",
    "Virtual",
    "Wrapped"
)

$readerIdOverrides = @{
    "BioRad" = "biorad"
    "BioRadGel" = "bioradgel"
    "BioRadSCN" = "bioradscn"
    "CanonRaw" = "canonraw"
    "CellH5" = "cellh5"
    "CellSens" = "cellsens"
    "CellVoyager" = "cellvoyager"
    "CellWorx" = "cellworx"
    "CV7000" = "cv7000"
    "DCIMG" = "dcimg"
    "DNG" = "dng"
    "Ecat7" = "ecat7"
    "EPS" = "eps"
    "FEI" = "fei"
    "FEITiff" = "feitiff"
    "FV1000" = "fv1000"
    "GatanDM2" = "gatandm2"
    "GIF" = "gif"
    "HamamatsuVMS" = "hamamatsuvms"
    "HIS" = "his"
    "HRDGDF" = "hrdgdf"
    "I2I" = "i2i"
    "ICS" = "ics"
    "IM3" = "im3"
    "IMOD" = "imod"
    "INR" = "inr"
    "IPLab" = "iplab"
    "IPW" = "ipw"
    "JDCE" = "jdce"
    "JPEG" = "jpeg"
    "JPEG2000" = "jpeg2000"
    "JPX" = "jpx"
    "KLB" = "klb"
    "L2D" = "l2d"
    "LEO" = "leo"
    "LIF" = "lif"
    "LIM" = "lim"
    "LiFlim" = "liflim"
    "MIAS" = "mias"
    "MINC" = "minc"
    "MNG" = "mng"
    "MRC" = "mrc"
    "MRW" = "mrw"
    "NAF" = "naf"
    "ND2" = "nd2"
    "NDPI" = "ndpi"
    "NDPIS" = "ndpis"
    "NRRD" = "nrrd"
    "Nifti" = "nifti"
    "OBF" = "obf"
    "OIR" = "oir"
    "OMETiff" = "ometiff"
    "OMEXML" = "omexml"
    "OpenlabRaw" = "openlabraw"
    "PCORAW" = "pcoraw"
    "PCX" = "pcx"
    "PDS" = "pds"
    "PGM" = "pgm"
    "PSD" = "psd"
    "QT" = "qt"
    "RCPNL" = "rcpnl"
    "RHK" = "rhk"
    "SBIG" = "sbig"
    "SDT" = "sdt"
    "SEQ" = "seq"
    "SIF" = "sif"
    "SIS" = "sis"
    "SMCamera" = "smcamera"
    "SPC" = "spc"
    "SPE" = "spe"
    "SVS" = "svs"
    "TCS" = "tcs"
    "UBM" = "ubm"
    "VGSAM" = "vgsam"
    "WATOP" = "watop"
    "XLEF" = "xlef"
    "ZeissCZI" = "zeissczi"
    "ZeissLMS" = "zeisslms"
    "ZeissLSM" = "zeisslsm"
    "ZeissTIFF" = "zeisstiff"
    "ZeissXRM" = "zeissxrm"
    "ZeissZVI" = "zeisszvi"
}

function Convert-ReaderNameToId {
    param([string]$ReaderName)

    if ($readerIdOverrides.ContainsKey($ReaderName)) {
        return $readerIdOverrides[$ReaderName]
    }
    return $ReaderName.ToLowerInvariant()
}

if (-not (Test-Path -LiteralPath $BioformatsPath)) {
    throw "Bio-Formats checkout not found: $BioformatsPath"
}

$rootPath = Join-Path (Get-Location) "src/root.zig"
$root = Get-Content $rootPath -Raw
$formatMatches = [regex]::Matches($root, '(?s)\.\{\s*\.id = "([^"]+)".*?\.can_read_pixels = ([^,\r\n]+),\s*\}')
$zigFormats = @{}
foreach ($match in $formatMatches) {
    $canReadPixels = $match.Groups[2].Value.Trim()
    $zigFormats[$match.Groups[1].Value] = $canReadPixels -ne "false"
}

$readerFiles = @(Get-ChildItem -LiteralPath $BioformatsPath -Recurse -Filter "*Reader.java" -File)
$concreteReaders = foreach ($file in $readerFiles) {
    $readerName = [System.IO.Path]::GetFileNameWithoutExtension($file.Name) -replace 'Reader$', ''
    if ($skipReaders -contains $readerName) {
        continue
    }
    [PSCustomObject]@{
        Reader = $readerName
        ExpectedId = Convert-ReaderNameToId $readerName
        Path = $file.FullName
    }
}

$missing = @($concreteReaders | Where-Object { -not $zigFormats.ContainsKey($_.ExpectedId) } | Sort-Object Reader)
$pixelDisabled = @(
    $zigFormats.GetEnumerator() |
        Where-Object { -not $_.Value } |
        Sort-Object Name |
        ForEach-Object {
            [PSCustomObject]@{
                Format = $_.Name
                CanReadPixels = $_.Value
            }
        }
)

[PSCustomObject]@{
    JavaReaderFiles = $readerFiles.Count
    ConcreteJavaReaders = @($concreteReaders).Count
    ZigFormats = $zigFormats.Count
    MissingConcreteReaders = $missing.Count
    PixelDisabledFormats = $pixelDisabled.Count
}

if ($missing.Count -gt 0) {
    "`nMissing concrete Java readers:"
    $missing | Select-Object Reader, ExpectedId, Path | Format-Table -AutoSize
}

if ($pixelDisabled.Count -gt 0) {
    "`nZig formats still advertised as metadata-only:"
    $pixelDisabled | Format-Table -AutoSize
}

if ($Strict -and ($missing.Count -gt 0 -or $pixelDisabled.Count -gt 0)) {
    throw "Reader audit failed strict mode."
}
