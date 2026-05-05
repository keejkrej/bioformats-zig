param(
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

function Write-Utf8Bytes {
    param(
        [System.Diagnostics.Process]$Process,
        [string]$Text
    )

    $utf8 = [System.Text.UTF8Encoding]::new($false)
    $bytes = $utf8.GetBytes($Text)
    $Process.StandardInput.BaseStream.Write($bytes, 0, $bytes.Length)
    $Process.StandardInput.BaseStream.Flush()
}

function Invoke-LineRequest {
    param(
        [System.Diagnostics.Process]$Process,
        [hashtable]$Request
    )

    Write-Utf8Bytes $Process ((ConvertTo-Json -InputObject $Request -Compress -Depth 8) + "`n")
    $line = $Process.StandardOutput.ReadLine()
    if ([string]::IsNullOrWhiteSpace($line)) {
        throw "No line-delimited JSON-RPC response for method '$($Request.method)'."
    }
    $response = $line | ConvertFrom-Json
    if ($response.error) {
        throw "$($Request.method) failed: $($response.error.message)"
    }
    return $response
}

function Read-AsciiLine {
    param([System.IO.Stream]$Stream)

    $bytes = [System.Collections.Generic.List[byte]]::new()
    while ($true) {
        $byte = $Stream.ReadByte()
        if ($byte -lt 0) {
            throw "Unexpected EOF while reading response header."
        }
        if ($byte -eq 10) {
            break
        }
        if ($byte -ne 13) {
            $bytes.Add([byte]$byte)
        }
    }
    return [System.Text.Encoding]::ASCII.GetString($bytes.ToArray())
}

function Read-ExactBytes {
    param(
        [System.IO.Stream]$Stream,
        [int]$Length
    )

    $buffer = [byte[]]::new($Length)
    $offset = 0
    while ($offset -lt $Length) {
        $read = $Stream.Read($buffer, $offset, $Length - $offset)
        if ($read -le 0) {
            throw "Unexpected EOF while reading response body."
        }
        $offset += $read
    }
    return $buffer
}

function Invoke-FramedRequest {
    param(
        [System.Diagnostics.Process]$Process,
        [hashtable]$Request
    )

    $utf8 = [System.Text.UTF8Encoding]::new($false)
    $body = ConvertTo-Json -InputObject $Request -Compress -Depth 8
    $bodyBytes = $utf8.GetBytes($body)
    Write-Utf8Bytes $Process ("Content-Length: $($bodyBytes.Length)`r`n`r`n")
    $Process.StandardInput.BaseStream.Write($bodyBytes, 0, $bodyBytes.Length)
    $Process.StandardInput.BaseStream.Flush()

    $contentLength = $null
    while ($true) {
        $line = Read-AsciiLine $Process.StandardOutput.BaseStream
        if ($line -eq "") {
            break
        }
        if ($line -match '^Content-Length:\s*(\d+)$') {
            $contentLength = [int]$Matches[1]
        }
    }
    if ($null -eq $contentLength) {
        throw "Missing Content-Length response header."
    }

    $responseBytes = Read-ExactBytes $Process.StandardOutput.BaseStream $contentLength
    $response = $utf8.GetString($responseBytes) | ConvertFrom-Json
    if ($response.error) {
        throw "$($Request.method) failed: $($response.error.message)"
    }
    return $response
}

function Stop-BioformatsProcess {
    param(
        [System.Diagnostics.Process]$Process,
        [switch]$Framed
    )

    if ($Process.HasExited) {
        return
    }

    try {
        if ($Framed) {
            Invoke-FramedRequest $Process @{ jsonrpc = "2.0"; id = 99; method = "shutdown" } | Out-Null
        } else {
            Invoke-LineRequest $Process @{ jsonrpc = "2.0"; id = 99; method = "shutdown" } | Out-Null
        }
        $Process.StandardInput.Close()
        if (-not $Process.WaitForExit(2000)) {
            $Process.Kill()
        }
    }
    catch {
        if (-not $Process.HasExited) {
            $Process.Kill()
        }
        throw
    }
}

function Assert-True {
    param(
        [bool]$Condition,
        [string]$Message
    )

    if (-not $Condition) {
        throw $Message
    }
}

$binaryPath = Resolve-RepoPath $Binary

$lineProcess = Start-BioformatsProcess $binaryPath
try {
    $initialize = Invoke-LineRequest $lineProcess @{ jsonrpc = "2.0"; id = 1; method = "initialize" }
    Assert-True ($initialize.result.protocol -eq "json-rpc-2.0-stdio") "Unexpected initialize protocol."
    Assert-True ([bool]$initialize.result.capabilities.contentLengthFraming) "Content-Length framing was not advertised."
    Assert-True ([bool]$initialize.result.capabilities.inlineData) "Inline data was not advertised."

    $formats = Invoke-LineRequest $lineProcess @{ jsonrpc = "2.0"; id = 2; method = "formats" }
    Assert-True ($formats.result.Count -gt 0) "formats returned no readers."
    Assert-True (@($formats.result | Where-Object { $_.id -eq "netpbm" }).Count -eq 1) "formats did not include netpbm."

    $ppmBytes = [byte[]](
        [System.Text.Encoding]::ASCII.GetBytes("P6`n1 1`n255`n") +
        [byte[]](10, 20, 30)
    )
    $plane = Invoke-LineRequest $lineProcess @{
        jsonrpc = "2.0"
        id = 3
        method = "readPlane"
        params = @{
            data = [Convert]::ToBase64String($ppmBytes)
        }
    }
    Assert-True ($plane.result.metadata.format -eq "netpbm") "Inline readPlane did not return netpbm metadata."
    Assert-True ($plane.result.metadata.width -eq 1 -and $plane.result.metadata.height -eq 1) "Inline readPlane returned unexpected dimensions."
    Assert-True ($plane.result.data -eq "ChQe") "Inline readPlane returned unexpected pixel payload."

    [PSCustomObject]@{
        Check = "line-delimited"
        Status = "ok"
        Formats = $formats.result.Count
        InlinePixels = $plane.result.data
    }
}
finally {
    Stop-BioformatsProcess $lineProcess
    $stderr = $lineProcess.StandardError.ReadToEnd()
    if (-not [string]::IsNullOrWhiteSpace($stderr)) {
        Write-Warning $stderr
    }
    $lineProcess.Dispose()
}

$framedProcess = Start-BioformatsProcess $binaryPath
try {
    $initialize = Invoke-FramedRequest $framedProcess @{ jsonrpc = "2.0"; id = 4; method = "initialize" }
    Assert-True ($initialize.result.server -eq "bioformats-zig") "Unexpected framed initialize server name."
    Assert-True ([bool]$initialize.result.capabilities.contentLengthFraming) "Framed initialize did not advertise Content-Length support."

    [PSCustomObject]@{
        Check = "content-length"
        Status = "ok"
        Server = $initialize.result.server
    }
}
finally {
    Stop-BioformatsProcess $framedProcess -Framed
    $stderr = $framedProcess.StandardError.ReadToEnd()
    if (-not [string]::IsNullOrWhiteSpace($stderr)) {
        Write-Warning $stderr
    }
    $framedProcess.Dispose()
}
