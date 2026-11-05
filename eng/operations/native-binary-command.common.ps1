Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'local-sensitive-state.common.ps1')

function Invoke-BunkFyNativeBinaryCommand {
    param(
        [Parameter(Mandatory = $true)][string] $FilePath,
        [Parameter(Mandatory = $true)][string[]] $Arguments,
        [Parameter(Mandatory = $true)][string] $WorkingDirectory,
        [string] $InputPath,
        [string] $OutputPath,
        [string] $DiagnosticsDirectory
    )

    $hasInput = -not [string]::IsNullOrWhiteSpace($InputPath)
    $hasOutput = -not [string]::IsNullOrWhiteSpace($OutputPath)
    if ($hasInput -eq $hasOutput) {
        throw 'A binary command requires exactly one input or output file.'
    }

    $options = [IO.FileStreamOptions]::new()
    $options.Share = [IO.FileShare]::None
    $options.Options = [IO.FileOptions]::Asynchronous -bor [IO.FileOptions]::SequentialScan
    if ($hasInput) {
        Assert-BunkFyLocalSensitivePath -Path $InputPath -PathType Leaf -Description 'Binary command input'
        $options.Mode = [IO.FileMode]::Open
        $options.Access = [IO.FileAccess]::Read
        $streamPath = [IO.Path]::GetFullPath($InputPath)
    }
    else {
        $streamPath = [IO.Path]::GetFullPath($OutputPath)
        Assert-BunkFyLocalSensitivePath -Path (Split-Path -Parent $streamPath) `
            -PathType Container -Description 'Binary command output directory'
        # CreateNew prevents overwriting an existing file or following a link.
        $options.Mode = [IO.FileMode]::CreateNew
        $options.Access = [IO.FileAccess]::Write
        if (-not (Test-BunkFyWindowsPlatform)) {
            $options.UnixCreateMode = [IO.UnixFileMode]384
        }
    }

    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $FilePath
    $startInfo.WorkingDirectory = $WorkingDirectory
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardInput = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    foreach ($argument in $Arguments) { $startInfo.ArgumentList.Add($argument) }
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    $stream = $null
    $started = $false
    $complete = $false
    $createdOutput = $false
    $diagnosticStream = $null
    $diagnosticPath = $null
    $ownsDiagnosticsDirectory = $false
    $errorTask = $null
    try {
        $stream = [IO.File]::Open($streamPath, $options)
        $createdOutput = $hasOutput
        if ([string]::IsNullOrWhiteSpace($DiagnosticsDirectory)) {
            $DiagnosticsDirectory = Join-Path ([IO.Path]::GetTempPath()) "bunkfy-database-diagnostics-$([Guid]::NewGuid().ToString('N'))"
            New-BunkFyLocalSensitiveDirectory -Path $DiagnosticsDirectory -Description 'Private database diagnostics'
            $ownsDiagnosticsDirectory = $true
        }
        else {
            Assert-BunkFyLocalSensitivePath -Path $DiagnosticsDirectory -PathType Container -Description 'Private database diagnostics'
        }
        $diagnosticPath = Join-Path $DiagnosticsDirectory "$([Guid]::NewGuid().ToString('N')).diagnostic.log"
        $diagnosticOptions = [IO.FileStreamOptions]::new()
        $diagnosticOptions.Mode = [IO.FileMode]::CreateNew
        $diagnosticOptions.Access = [IO.FileAccess]::Write
        $diagnosticOptions.Share = [IO.FileShare]::None
        $diagnosticOptions.Options = [IO.FileOptions]::Asynchronous
        if (-not (Test-BunkFyWindowsPlatform)) { $diagnosticOptions.UnixCreateMode = [IO.UnixFileMode]384 }
        $diagnosticStream = [IO.File]::Open($diagnosticPath, $diagnosticOptions)
        $started = $process.Start()
        if (-not $started) { throw 'The binary command could not be started.' }

        # Drain both pipes concurrently, with bounded buffers and no text decoding.
        # Preserve warnings and failures privately: database diagnostics can
        # contain backup data, and must not be copied into terminal/CI logs.
        $errorTask = $process.StandardError.BaseStream.CopyToAsync($diagnosticStream, 81920)
        if ($hasOutput) {
            $process.StandardInput.Close()
            $outputTask = $process.StandardOutput.BaseStream.CopyToAsync($stream, 81920)
            [void]$outputTask.GetAwaiter().GetResult()
            $stream.Flush($true)
        }
        else {
            $outputTask = $process.StandardOutput.BaseStream.CopyToAsync([IO.Stream]::Null, 81920)
            try {
                $inputTask = $stream.CopyToAsync($process.StandardInput.BaseStream, 81920)
                [void]$inputTask.GetAwaiter().GetResult()
            }
            finally { $process.StandardInput.Close() }
            [void]$outputTask.GetAwaiter().GetResult()
        }
        [void]$errorTask.GetAwaiter().GetResult()
        $process.WaitForExit()
        if ($process.ExitCode -ne 0) {
            throw "The binary command failed with exit code $($process.ExitCode)."
        }
        $stream.Dispose()
        $stream = $null
        if ($hasOutput) {
            Protect-BunkFyLocalSensitivePath -Path $streamPath -PathType Leaf -Description 'Binary command output'
        }
        $complete = $true
    }
    finally {
        try {
            if ($started -and -not $process.HasExited) {
                # Terminate only this CLI process, never the managed database service.
                try { $process.Kill() }
                catch [InvalidOperationException] {
                    if (-not $process.HasExited) { throw }
                }
                [void]$process.WaitForExit(5000)
            }
        }
        finally {
            $process.Dispose()
            try {
                if ($null -ne $errorTask) {
                    try { [void]$errorTask.GetAwaiter().GetResult() }
                    catch { } # Preserve the command/stream failure already being raised.
                }
                if ($null -ne $stream) { $stream.Dispose() }
                if ($null -ne $diagnosticStream) { $diagnosticStream.Dispose() }
            }
            finally {
                if ($createdOutput -and -not $complete) {
                    Remove-Item -LiteralPath $streamPath -Force
                }
                if ($null -ne $diagnosticPath -and (Test-Path -LiteralPath $diagnosticPath)) {
                    if ((Get-Item -LiteralPath $diagnosticPath).Length -gt 0) {
                        Protect-BunkFyLocalSensitivePath -Path $diagnosticPath -PathType Leaf -Description 'Private database diagnostics'
                        Write-Warning "Database command diagnostics require review in the private file: $diagnosticPath"
                    }
                    else {
                        Remove-Item -LiteralPath $diagnosticPath -Force
                        if ($ownsDiagnosticsDirectory) { Remove-Item -LiteralPath $DiagnosticsDirectory }
                    }
                }
            }
        }
    }
}
