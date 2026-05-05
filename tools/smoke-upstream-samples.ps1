param(
    [string]$BioformatsDir = "../bioformats",
    [string]$Binary = "zig-out/bin/bioformats-zig.exe"
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

function Invoke-BioformatsRpc {
    param(
        [System.Diagnostics.Process]$Process,
        [int]$Id,
        [string]$Method,
        [hashtable]$Params
    )

    $request = [ordered]@{
        jsonrpc = "2.0"
        id = $Id
        method = $Method
        params = $Params
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

$bioformatsPath = Resolve-RepoPath $BioformatsDir
if (-not (Test-Path -LiteralPath $bioformatsPath)) {
    throw "Bio-Formats checkout not found: $bioformatsPath"
}

$cases = @(
    @{
        Relative = "components/formats-bsd/test/spec/schema/samples/2011-06/6x4y1z1t1c8b-swatch.ome"
        Width = 6
        Height = 4
        PlaneCount = 1
        PlaneIndex = 0
        Pixel = "/w=="
    },
    @{
        Relative = "components/formats-bsd/test/spec/schema/samples/2011-06/6x4y1z1t3c8b-swatch-upgrade.ome"
        Width = 6
        Height = 4
        PlaneCount = 3
        PlaneIndex = 2
        Pixel = "AA=="
    },
    @{
        Relative = "components/formats-gpl/test/loci/formats/utests/xml/2010-04.ome"
        Width = 1024
        Height = 1024
        PlaneCount = 48
        PlaneIndex = 0
        Pixel = "AAA="
    }
)

$binaryPath = Resolve-RepoPath $Binary
$process = Start-BioformatsProcess $binaryPath
$nextId = 1
$failures = 0

try {
    foreach ($case in $cases) {
        $path = Join-Path $bioformatsPath $case.Relative
        if (-not (Test-Path -LiteralPath $path)) {
            throw "Upstream sample not found: $path"
        }

        $status = "ok"
        try {
            $metadata = Invoke-BioformatsRpc $process $nextId "metadata" @{ path = (Resolve-Path -LiteralPath $path).Path }
            $nextId++
            if ($metadata.format -ne "omexml" -or [int]$metadata.width -ne $case.Width -or [int]$metadata.height -ne $case.Height -or [int]$metadata.planeCount -ne $case.PlaneCount) {
                throw "Unexpected metadata for $($case.Relative)."
            }

            $plane = Invoke-BioformatsRpc $process $nextId "readPlane" @{
                path = (Resolve-Path -LiteralPath $path).Path
                planeIndex = $case.PlaneIndex
                x = 0
                y = 0
                width = 1
                height = 1
            }
            $nextId++
            if ($plane.encoding -ne "base64" -or $plane.data -ne $case.Pixel) {
                throw "Unexpected pixel payload '$($plane.data)' for $($case.Relative)."
            }
        }
        catch {
            $status = $_.Exception.Message
            $failures++
        }

        [PSCustomObject]@{
            Status = $status
            Format = "omexml"
            Width = $case.Width
            Height = $case.Height
            PlaneCount = $case.PlaneCount
            PlaneIndex = $case.PlaneIndex
            Path = $path
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
    throw "$failures upstream sample smoke check(s) failed."
}
