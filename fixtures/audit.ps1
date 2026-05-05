param(
    [string]$Binary = "zig-out/bin/bioformats-zig.exe",
    [switch]$List,
    [switch]$NoRuntime
)

$ErrorActionPreference = "Stop"

function Resolve-RepoPath {
    param([string]$Path)

    if ([System.IO.Path]::IsPathRooted($Path)) {
        return $Path
    }
    return (Join-Path (Get-Location) $Path)
}

function Get-EntryList {
    param($Value)

    if ($null -eq $Value) {
        return @()
    }
    if ($Value -is [array]) {
        return @($Value | ForEach-Object { [string]$_ })
    }
    return @([string]$Value)
}

function Get-SourceStatus {
    param([string[]]$Entries)

    if ($Entries.Count -eq 0) {
        return "missing"
    }
    if ($Entries | Where-Object { $_ -match '^(ome_images/|https?://|zenodo/|figshare/|openslide|external/)' }) {
        return "public-lead"
    }
    if ($Entries | Where-Object { $_ -eq "generated-fixture" }) {
        return "generated"
    }
    if ($Entries | Where-Object { $_ -match '^alias-of-' }) {
        return "alias"
    }
    if ($Entries | Where-Object { $_ -eq "needs-public-download-url" }) {
        return "needs-public-download-url"
    }
    if ($Entries | Where-Object { $_ -eq "needs-public-sample" }) {
        return "needs-public-sample"
    }
    if ($Entries | Where-Object { $_ -match '^(vendor-|synthetic-or-vendor-needed)' }) {
        return "vendor-or-synthetic"
    }
    if ($Entries | Where-Object { $_ -match '^bioformats-docs/' }) {
        return "documentation-only"
    }
    return "other"
}

function Start-BioformatsProcess {
    param([string]$BinaryPath)

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

function Get-RuntimeFormats {
    param([string]$BinaryPath)

    if (-not (Test-Path -LiteralPath $BinaryPath)) {
        return @()
    }

    $process = Start-BioformatsProcess $BinaryPath
    try {
        Write-ProcessLine $process '{"jsonrpc":"2.0","id":1,"method":"formats"}'
        $line = $process.StandardOutput.ReadLine()
        if ([string]::IsNullOrWhiteSpace($line)) {
            throw "No JSON-RPC response from '$BinaryPath'."
        }
        $response = $line | ConvertFrom-Json
        if ($response.error) {
            throw "formats failed: $($response.error.message)"
        }
        return @($response.result | ForEach-Object { [string]$_.id })
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
}

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$sourcesPath = Join-Path $scriptDir "sources.json"
$sources = Get-Content $sourcesPath -Raw | ConvertFrom-Json

$rows = @($sources.implemented_format_sources.PSObject.Properties |
    Sort-Object Name |
    ForEach-Object {
        $entries = @(Get-EntryList $_.Value)
        [PSCustomObject]@{
            Format = $_.Name
            Status = Get-SourceStatus $entries
            Sources = ($entries -join ", ")
        }
    })

if (-not $NoRuntime) {
    $binaryPath = Resolve-RepoPath $Binary
    $runtimeFormats = @(Get-RuntimeFormats $binaryPath | Sort-Object -Unique)
    if ($runtimeFormats.Count -gt 0) {
        $catalogFormats = @($rows | ForEach-Object { $_.Format })
        $missing = @($runtimeFormats | Where-Object { $_ -notin $catalogFormats })
        foreach ($format in $missing) {
            $rows += [PSCustomObject]@{
                Format = $format
                Status = "missing"
                Sources = ""
            }
        }
    }
}

if ($List) {
    $rows | Sort-Object Status, Format | Format-Table -AutoSize
    exit 0
}

$rows |
    Group-Object Status |
    Sort-Object Name |
    ForEach-Object {
        [PSCustomObject]@{
            Status = $_.Name
            Count = $_.Count
        }
    } |
    Format-Table -AutoSize

$needs = @($rows | Where-Object { $_.Status -match '^needs-|^missing$|^vendor-or-synthetic$|^documentation-only$|^other$' })
if ($needs.Count -gt 0) {
    Write-Host ""
    Write-Host "Formats needing fixture follow-up: $($needs.Count)"
    $needs | Sort-Object Status, Format | Select-Object Status, Format | Format-Table -AutoSize
}
