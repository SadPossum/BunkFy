Set-StrictMode -Version Latest

if ($null -eq (Get-Variable BunkFyImageConfigurationCache -Scope Script -ErrorAction SilentlyContinue)) {
    $script:BunkFyImageConfigurationCache = @{}
}

function Read-BunkFyDockerExportConfigurationDigest {
    param(
        [Parameter(Mandatory)][IO.Stream] $Stream,
        [Threading.CancellationToken] $CancellationToken = [Threading.CancellationToken]::None
    )

    $reader = [Formats.Tar.TarReader]::new($Stream, $true)
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $configurations = @{}
    $manifestConfig = $null
    $entries = 0
    [long]$payloadBytes = 0
    try {
        while ($null -ne ($entry = $reader.GetNextEntryAsync($false, $CancellationToken).AsTask().GetAwaiter().GetResult())) {
            $entries++
            if ($entries -gt 100000 -or $entry.Length -lt 0) { throw 'Docker image export exceeds its metadata bounds.' }
            $payloadBytes += 512 + $entry.Length
            if ($payloadBytes -gt 2GB) { throw 'Docker image export exceeds its payload bound.' }
            $name = [string]$entry.Name
            if ($name.StartsWith('/') -or $name.Contains('\') -or
                @($name.Split('/') | Where-Object { $_ -ceq '..' -or $_ -ceq '.' }).Count -gt 0) {
                throw 'Docker image export contains an unsafe entry path.'
            }
            if ($entry.EntryType -eq [Formats.Tar.TarEntryType]::Directory) { continue }
            if ($entry.EntryType -notin @([Formats.Tar.TarEntryType]::RegularFile, [Formats.Tar.TarEntryType]::V7RegularFile) -or
                -not $seen.Add($name)) {
                throw 'Docker image export contains a link, special or duplicate entry.'
            }
            $isManifest = $name -ceq 'manifest.json'
            $isConfigCandidate = $name -cmatch '^(?:blobs/sha256/[a-f0-9]{64}|[a-f0-9]{64}[.]json)$'
            if (-not $isManifest -and -not $isConfigCandidate) { continue }
            if ($entry.Length -gt 1MB) {
                if ($isManifest) { throw 'Docker export manifest is too large.' }
                continue
            }
            $memory = [IO.MemoryStream]::new()
            try {
                [void]$entry.DataStream.CopyToAsync($memory, 81920, $CancellationToken).GetAwaiter().GetResult()
                $bytes = $memory.ToArray()
            }
            finally { $memory.Dispose() }
            $document = $null
            try {
                $json = [Text.UTF8Encoding]::new($false, $true).GetString($bytes)
                $document = [Text.Json.JsonDocument]::Parse($json)
                $root = $document.RootElement
                if ($isManifest) {
                    if ($root.ValueKind -ne [Text.Json.JsonValueKind]::Array -or $root.GetArrayLength() -ne 1) {
                        throw 'Docker export must contain one selected platform image.'
                    }
                    $manifestConfig = $root[0].GetProperty('Config').GetString()
                    if ($manifestConfig -cnotmatch '^(?:blobs/sha256/[a-f0-9]{64}|[a-f0-9]{64}[.]json)$') {
                        throw 'Docker export has an invalid configuration pointer.'
                    }
                }
                elseif ($root.ValueKind -eq [Text.Json.JsonValueKind]::Object) {
                    $architecture = [Text.Json.JsonElement]::new()
                    $os = [Text.Json.JsonElement]::new()
                    $rootfs = [Text.Json.JsonElement]::new()
                    $configuration = [Text.Json.JsonElement]::new()
                    if (-not $root.TryGetProperty('architecture', [ref]$architecture) -or
                        -not $root.TryGetProperty('os', [ref]$os) -or
                        -not $root.TryGetProperty('rootfs', [ref]$rootfs) -or
                        -not $root.TryGetProperty('config', [ref]$configuration)) { continue }
                    $hash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
                    $declared = if ($name.StartsWith('blobs/sha256/')) { $name.Substring(13) } else { $name.Substring(0, 64) }
                    if ($hash -cne $declared) { throw 'Docker image configuration hash does not match its content address.' }
                    if ($configurations.Count -ge 16) { throw 'Docker export contains too many configuration records.' }
                    $configurations[$name] = [pscustomobject]@{
                        Digest = "sha256:$hash"
                        Architecture = $architecture.GetString()
                        Os = $os.GetString()
                        RootfsType = $rootfs.GetProperty('type').GetString()
                        ConfigurationKind = $configuration.ValueKind
                    }
                }
            }
            catch [Text.DecoderFallbackException] {
                if ($isManifest) { throw 'Docker export manifest is not UTF-8.' }
            }
            catch [Text.Json.JsonException] {
                if ($isManifest) { throw 'Docker export manifest is not valid JSON.' }
            }
            finally { if ($null -ne $document) { $document.Dispose() } }
        }
        # Tar end padding is allowed; appended data is not part of this contract.
        $buffer = [byte[]]::new(81920)
        $padding = 0
        while (($count = $Stream.ReadAsync($buffer, 0, $buffer.Length, $CancellationToken).GetAwaiter().GetResult()) -gt 0) {
            $padding += $count
            if ($padding -gt 1MB) { throw 'Docker export has excessive trailing padding.' }
            for ($index = 0; $index -lt $count; $index++) {
                if ($buffer[$index] -ne 0) { throw 'Docker export contains data after its tar terminator.' }
            }
        }
        if ([string]::IsNullOrWhiteSpace($manifestConfig) -or -not $configurations.ContainsKey($manifestConfig)) {
            throw 'Docker export is missing its selected image configuration.'
        }
        $selected = $configurations[$manifestConfig]
        if ($selected.Architecture -cne 'amd64' -or $selected.Os -cne 'linux' -or
            $selected.RootfsType -cne 'layers' -or $selected.ConfigurationKind -ne [Text.Json.JsonValueKind]::Object) {
            throw 'Docker export configuration is not the qualified Linux amd64 platform.'
        }
        return $selected.Digest
    }
    finally { $reader.Dispose() }
}

function Get-BunkFyDockerImageConfigurationDigest {
    param(
        [Parameter(Mandatory)][ValidatePattern('^(?:[a-z0-9][A-Za-z0-9./:_-]*@sha256:[a-f0-9]{64}|bunkfy-preview-postgres:17[.]11-libxslt-r4)$')][string] $Reference,
        [Parameter(Mandatory)][ValidatePattern('^sha256:[a-f0-9]{64}$')][string] $RuntimeImageId,
        [switch] $LocalPreviewPostgres
    )

    if (($Reference -ceq 'bunkfy-preview-postgres:17.11-libxslt-r4') -ne [bool]$LocalPreviewPostgres) {
        throw 'Local image export requires the exact patched Preview PostgreSQL subject.'
    }
    $metadataJson = @(& docker image inspect $Reference)
    if ($LASTEXITCODE -ne 0) { throw 'Unable to inspect the selected local infrastructure image.' }
    $metadata = @(($metadataJson -join "`n") | ConvertFrom-Json)
    if ($metadata.Count -ne 1 -or $metadata[0].Id -cne $RuntimeImageId -or
        $metadata[0].Os -cne 'linux' -or $metadata[0].Architecture -cne 'amd64' -or
        (-not $LocalPreviewPostgres -and $RuntimeImageId -cne ('sha256:' + ($Reference -split '@sha256:', 2)[1]))) {
        throw 'Local runtime image identity does not bind the selected immutable Linux amd64 reference.'
    }
    $cacheKey = "$RuntimeImageId|linux/amd64"
    if ($script:BunkFyImageConfigurationCache.ContainsKey($cacheKey)) {
        return $script:BunkFyImageConfigurationCache[$cacheKey]
    }
    $info = [Diagnostics.ProcessStartInfo]::new()
    $info.FileName = (Get-Command docker -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
    $info.UseShellExecute = $false
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    foreach ($argument in @('image', 'save', '--platform', 'linux/amd64', $RuntimeImageId)) { $info.ArgumentList.Add($argument) }
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $info
    $cancellation = [Threading.CancellationTokenSource]::new([TimeSpan]::FromSeconds(180))
    $stage = 'start'
    $started = $false
    try {
        if (-not $process.Start()) { throw 'Unable to start the read-only Docker image export.' }
        $started = $true
        $diagnostic = $process.StandardError.ReadToEndAsync()
        $stage = 'read-selected-configuration'
        $digest = Read-BunkFyDockerExportConfigurationDigest -Stream $process.StandardOutput.BaseStream `
            -CancellationToken $cancellation.Token
        $stage = 'require-completed-export'
        [void]$process.WaitForExitAsync($cancellation.Token).GetAwaiter().GetResult()
        $errorText = $diagnostic.GetAwaiter().GetResult()
        if ($process.ExitCode -ne 0) { throw 'Docker image export did not complete successfully.' }
        if (-not [string]::IsNullOrWhiteSpace($errorText)) { throw 'Docker image export emitted diagnostics requiring review.' }
        $script:BunkFyImageConfigurationCache[$cacheKey] = $digest
        return $digest
    }
    catch { throw "Unable to measure local image configuration ($stage; $($_.Exception.GetType().Name))." }
    finally {
        if ($started -and -not $process.HasExited) { $process.Kill($true); $process.WaitForExit() }
        $cancellation.Dispose()
        $process.Dispose()
    }
}
