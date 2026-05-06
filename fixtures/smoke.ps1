param(
    [string]$CacheDir = "fixtures/cache",
    [string]$Binary = "zig-out/bin/bioformats-zig.exe",
    [switch]$SkipPixels
)

$ErrorActionPreference = "Stop"

function Resolve-RepoPath {
    param([string]$Path)

    if ([System.IO.Path]::IsPathRooted($Path)) {
        return $Path
    }
    return (Join-Path (Get-Location) $Path)
}

function Start-BioformatsProcess {
    param([string]$BinaryPath)

    if (-not (Test-Path -LiteralPath $BinaryPath)) {
        throw "Binary not found: $BinaryPath. Run 'zig build' first or pass -Binary."
    }

    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = (Resolve-Path -LiteralPath $BinaryPath).Path
    $psi.WorkingDirectory = (Get-Location).Path
    $psi.UseShellExecute = $false
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    return [System.Diagnostics.Process]::Start($psi)
}

function Invoke-BioformatsRpc {
    param(
        [System.Diagnostics.Process]$Process,
        [int]$Id,
        [string]$Method,
        [hashtable]$Params = $null
    )

    $request = [ordered]@{
        jsonrpc = "2.0"
        id = $Id
        method = $Method
    }
    if ($null -ne $Params) {
        $request.params = $Params
    }
    Write-ProcessLine $Process (ConvertTo-Json -InputObject $request -Compress -Depth 8)
    $line = $Process.StandardOutput.ReadLine()
    if ([string]::IsNullOrWhiteSpace($line)) {
        throw "No JSON-RPC response for method '$Method'."
    }
    $response = $line | ConvertFrom-Json
    if ($response.error) {
        throw "$Method failed: $($response.error.message)"
    }
    return $response.result
}

function Write-ProcessLine {
    param(
        [System.Diagnostics.Process]$Process,
        [string]$Line
    )

    $utf8 = [System.Text.UTF8Encoding]::new($false)
    $bytes = $utf8.GetBytes($Line + "`n")
    $Process.StandardInput.BaseStream.Write($bytes, 0, $bytes.Length)
    $Process.StandardInput.BaseStream.Flush()
}

$cachePath = Resolve-RepoPath $CacheDir
if (-not (Test-Path -LiteralPath $cachePath)) {
    throw "Fixture cache not found: $cachePath. Use fixtures/fetch.ps1 first."
}
$hasVsiInCache = @(Get-ChildItem -LiteralPath $cachePath -Recurse -Filter "*.vsi" -File -ErrorAction SilentlyContinue).Count -gt 0

$files = @(Get-ChildItem -LiteralPath $cachePath -Recurse -File | Where-Object {
    $hasVmsSibling = @(Get-ChildItem -LiteralPath $_.DirectoryName -Filter "*.vms" -File -ErrorAction SilentlyContinue).Count -gt 0
    $hasVsiSibling = @(Get-ChildItem -LiteralPath $_.DirectoryName -Filter "*.vsi" -File -ErrorAction SilentlyContinue).Count -gt 0
    $hasNrrdHeaderSibling = @(Get-ChildItem -LiteralPath $_.DirectoryName -Filter "*.nhdr" -File -ErrorAction SilentlyContinue).Count -gt 0
    $hasIcsHeaderSibling = @(Get-ChildItem -LiteralPath $_.DirectoryName -Filter "*.ics" -File -ErrorAction SilentlyContinue).Count -gt 0
    -not ($hasVmsSibling -and $_.Extension -match '^\.(jpg|jpeg|opt)$') -and
        -not (($hasVsiSibling -or $hasVsiInCache) -and $_.Extension -ieq ".ets") -and
        -not ($hasNrrdHeaderSibling -and $_.Extension -ieq ".raw") -and
        -not ($hasIcsHeaderSibling -and $_.Extension -ieq ".ids")
})
if ($files.Count -eq 0) {
    throw "No cached fixture files found under $cachePath."
}

$binaryPath = Resolve-RepoPath $Binary
$process = Start-BioformatsProcess $binaryPath
$nextId = 1
$failures = 0

try {
    $formats = Invoke-BioformatsRpc $process $nextId "formats"
    $nextId++
    $canReadPixels = @{}
    foreach ($format in $formats) {
        $canReadPixels[$format.id] = [bool]$format.canReadPixels
    }

    foreach ($file in $files) {
        $status = "ok"
        $format = $null
        $width = $null
        $height = $null
        $pixelRead = $false
        try {
            $probe = Invoke-BioformatsRpc $process $nextId "probe" @{ path = $file.FullName }
            $nextId++
            $format = $probe.format

            $metadata = Invoke-BioformatsRpc $process $nextId "metadata" @{ path = $file.FullName }
            $nextId++
            $width = [int]$metadata.width
            $height = [int]$metadata.height
            if ($width -le 0 -or $height -le 0 -or [int]$metadata.planeCount -le 0) {
                throw "Invalid metadata dimensions or plane count."
            }

            $canRead = $canReadPixels.ContainsKey($metadata.format) -and $canReadPixels[$metadata.format]
            if (-not $SkipPixels -and $canRead) {
                $regionWidth = [Math]::Min(16, $width)
                $regionHeight = [Math]::Min(16, $height)
                $plane = Invoke-BioformatsRpc $process $nextId "readPlane" @{
                    path = $file.FullName
                    planeIndex = 0
                    x = 0
                    y = 0
                    width = $regionWidth
                    height = $regionHeight
                }
                $nextId++
                if ($plane.encoding -ne "base64" -or [string]::IsNullOrWhiteSpace($plane.data)) {
                    throw "readPlane returned no base64 pixel payload."
                }
                $pixelRead = $true
            }
        }
        catch {
            $status = $_.Exception.Message
            $failures++
        }

        [PSCustomObject]@{
            Status = $status
            Format = $format
            Width = $width
            Height = $height
            PixelRead = $pixelRead
            Path = $file.FullName
        }
    }
}
finally {
    if (-not $process.HasExited) {
        Write-ProcessLine $process '{"jsonrpc":"2.0","method":"shutdown"}'
        $process.StandardInput.Close()
        if (-not $process.WaitForExit(2000)) {
            $process.Kill()
        }
    }
    $stderr = $process.StandardError.ReadToEnd()
    if (-not [string]::IsNullOrWhiteSpace($stderr)) {
        Write-Warning $stderr
    }
    $process.Dispose()
}

if ($failures -gt 0) {
    throw "$failures fixture smoke check(s) failed."
}
