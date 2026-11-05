Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'operations\native-binary-command.common.ps1')
$nativeProcess = (Get-Process -Id $PID).Path
$probe = Join-Path $PSScriptRoot 'operations\fixtures\native-binary-command-probe.ps1'
$literal = 'space ; $(never-execute) ` quote" end'
$directory = Join-Path ([IO.Path]::GetTempPath()) "bunkfy-binary-probe-$([Guid]::NewGuid().ToString('N'))"
New-BunkFyLocalSensitiveDirectory -Path $directory -Description 'Binary command fixture directory'
$inputPath = Join-Path $directory 'all bytes with spaces.dump'
$outputPath = Join-Path $directory 'streamed.dump'
$checks = [Collections.Generic.List[string]]::new()

function Assert-BinaryProbeRejected {
    param([string] $Name, [scriptblock] $Action, [string] $RequiredError)
    $rejected = $false
    try { & $Action } catch {
        $rejected = $true
        if ($_.Exception.Message.Contains('PRIVATE_DATABASE_DIAGNOSTIC')) {
            throw 'Binary command echoed private database diagnostics.'
        }
        if ($RequiredError -and -not $_.Exception.Message.Contains($RequiredError)) { throw }
    }
    if (-not $rejected) { throw "Binary command fixture '$Name' was not rejected." }
    $checks.Add($Name)
}

try {
    # Every possible byte, including NUL and invalid UTF-8; larger than the
    # maintained PostgreSQL container's 32 MiB /tmp filesystem.
    $block = [byte[]]::new(65536)
    for ($index = 0; $index -lt $block.Length; $index++) { $block[$index] = [byte]($index % 256) }
    $source = [IO.File]::Create($inputPath)
    try {
        for ($index = 0; $index -lt 576; $index++) { $source.Write($block) }
        $source.Write($block, 0, 251)
    }
    finally { $source.Dispose() }
    Protect-BunkFyLocalSensitivePath -Path $inputPath -PathType Leaf -Description 'Binary command fixture'
    $digest = (Get-FileHash -LiteralPath $inputPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $length = (Get-Item -LiteralPath $inputPath).Length
    $base = @('-NoLogo', '-NoProfile', '-File', $probe, '-LiteralArgument', $literal)
    Invoke-BunkFyNativeBinaryCommand -DiagnosticsDirectory $directory -FilePath $nativeProcess `
        -Arguments ($base + @('-Mode', 'emit', '-Path', $inputPath)) `
        -WorkingDirectory $directory -OutputPath $outputPath
    if ((Get-Item -LiteralPath $outputPath).Length -ne $length -or
        (Get-FileHash -LiteralPath $outputPath -Algorithm SHA256).Hash.ToLowerInvariant() -cne $digest) {
        throw 'The binary output was truncated or changed.'
    }
    Assert-BunkFyLocalSensitivePath -Path $outputPath -PathType Leaf -Description 'Binary streamed fixture'
    $checks.Add('non-UTF8 and all-byte output above 32 MiB, private file, literal argv')

    Invoke-BunkFyNativeBinaryCommand -DiagnosticsDirectory $directory -FilePath $nativeProcess `
        -Arguments ($base + @('-Mode', 'consume', '-ExpectedSha256', $digest, '-ExpectedLength', [string]$length)) `
        -WorkingDirectory $directory -InputPath $outputPath
    $checks.Add('binary stdin above 32 MiB and concurrent large stdout/stderr drainage')
    Assert-BinaryProbeRejected 'consumer rejects corrupt binary payload' {
        Invoke-BunkFyNativeBinaryCommand -DiagnosticsDirectory $directory -FilePath $nativeProcess `
            -Arguments ($base + @('-Mode', 'consume', '-ExpectedSha256', ('0' * 64), '-ExpectedLength', [string]$length)) `
            -WorkingDirectory $directory -InputPath $outputPath
    } -RequiredError 'exit code 29'

    $partial = Join-Path $directory 'partial.dump'
    Assert-BinaryProbeRejected 'nonzero producer exit and private diagnostic suppression' {
        Invoke-BunkFyNativeBinaryCommand -DiagnosticsDirectory $directory -FilePath $nativeProcess `
            -Arguments ($base + @('-Mode', 'partial-failure')) `
            -WorkingDirectory $directory -OutputPath $partial
    } -RequiredError 'exit code 17'
    $diagnostics = @(Get-ChildItem -LiteralPath $directory -Filter '*.diagnostic.log')
    if ($diagnostics.Count -lt 1 -or @($diagnostics | Where-Object {
                [IO.File]::ReadAllText($_.FullName).Contains('PRIVATE_DATABASE_DIAGNOSTIC')
            }).Count -ne 1) { throw 'Native failure diagnostics were lost.' }
    foreach ($diagnostic in $diagnostics) {
        Assert-BunkFyLocalSensitivePath -Path $diagnostic.FullName -PathType Leaf -Description 'Preserved private diagnostics'
    }
    $checks.Add('native warnings and failures retained in private files without log disclosure')
    if (Test-Path -LiteralPath $partial) { throw 'A failed producer left a partial dump.' }
    $checks.Add('failed output removed')

    Assert-BinaryProbeRejected 'early closed stdin and broken pipe' {
        Invoke-BunkFyNativeBinaryCommand -DiagnosticsDirectory $directory -FilePath $nativeProcess `
            -Arguments ($base + @('-Mode', 'early-rejection')) `
            -WorkingDirectory $directory -InputPath $outputPath
    }
    Assert-BinaryProbeRejected 'existing output is never overwritten or deleted' {
        Invoke-BunkFyNativeBinaryCommand -DiagnosticsDirectory $directory -FilePath $nativeProcess `
            -Arguments ($base + @('-Mode', 'partial-failure')) `
            -WorkingDirectory $directory -OutputPath $outputPath
    }
    if ((Get-FileHash -LiteralPath $outputPath -Algorithm SHA256).Hash.ToLowerInvariant() -cne $digest) {
        throw 'Existing output changed after an overwrite attempt.'
    }
    $missingOutput = Join-Path $directory 'cannot-start.dump'
    Assert-BinaryProbeRejected 'failed executable start' {
        Invoke-BunkFyNativeBinaryCommand -DiagnosticsDirectory $directory -FilePath (Join-Path $directory 'missing-command') `
            -Arguments @('unused') -WorkingDirectory $directory -OutputPath $missingOutput
    }
    if (Test-Path -LiteralPath $missingOutput) { throw 'A failed process start left an empty dump.' }
    Assert-BinaryProbeRejected 'both input and output rejected' {
        Invoke-BunkFyNativeBinaryCommand -DiagnosticsDirectory $directory -FilePath $nativeProcess -Arguments $base `
            -WorkingDirectory $directory -InputPath $inputPath -OutputPath $partial
    }
    Assert-BinaryProbeRejected 'missing direction rejected' {
        Invoke-BunkFyNativeBinaryCommand -DiagnosticsDirectory $directory -FilePath $nativeProcess -Arguments $base -WorkingDirectory $directory
    }
    Write-Host "BunkFy native binary I/O: $($checks.Count) checks passed; $length bytes in each direction."
}
finally { Remove-Item -LiteralPath $directory -Recurse -Force }
