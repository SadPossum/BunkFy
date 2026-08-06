param(
    [ValidateSet(
        'config',
        'build',
        'up',
        'down',
        'logs',
        'status',
        'migrate',
        'open-operations',
        'close-operations')]
    [string] $Action = 'up',
    [switch] $Operations,
    [switch] $Tools
)

. (Join-Path $PSScriptRoot 'common.ps1')

$root = Get-BunkFyRepositoryRoot
$composeFile = Join-BunkFyPath 'deploy\preview\compose.yaml'
$environmentFile = Join-BunkFyPath 'deploy\preview\.env'

if ($Action -in @('build', 'up')) {
    $backendBootstrap = Join-BunkFyPath 'apps\backend\eng\gma-bootstrap.ps1'
    if (-not (Test-Path -LiteralPath $backendBootstrap -PathType Leaf)) {
        throw "Backend source composition bootstrap is missing: '$backendBootstrap'. Initialize submodules before building the preview stack."
    }

    & $backendBootstrap -Force
}

if (-not (Test-Path -LiteralPath $environmentFile -PathType Leaf)) {
    throw "Run eng/new-preview-env.ps1 before starting the preview stack."
}

$settings = @{}
foreach ($line in Get-Content -LiteralPath $environmentFile) {
    if ([string]::IsNullOrWhiteSpace($line) -or $line.TrimStart().StartsWith('#')) {
        continue
    }

    $parts = $line.Split('=', 2)
    if ($parts.Count -eq 2) {
        $settings[$parts[0].Trim()] = $parts[1].Trim()
    }
}

$minimumSecretLengths = @{
    BUNKFY_POSTGRES_PASSWORD = 16
    BUNKFY_REDIS_PASSWORD = 16
    BUNKFY_NATS_PASSWORD = 16
    BUNKFY_MINIO_ROOT_PASSWORD = 16
    BUNKFY_JWT_SIGNING_KEY = 32
    BUNKFY_REFRESH_TOKEN_PEPPER = 32
}
foreach ($entry in $minimumSecretLengths.GetEnumerator()) {
    $value = [string]$settings[$entry.Key]
    if ([string]::IsNullOrWhiteSpace($value) -or
        $value.Contains('replace-with-') -or
        $value.Length -lt $entry.Value) {
        throw "$($entry.Key) must be a non-placeholder secret of at least $($entry.Value) characters."
    }
}

$releaseId = [string]$settings['BUNKFY_RELEASE_ID']
if ($releaseId -cnotmatch '^[a-z0-9][a-z0-9._-]{2,127}$') {
    throw 'BUNKFY_RELEASE_ID must be a 3-128 character non-secret release identifier.'
}

$dataRightsKeyNames = @(
    'BUNKFY_DATA_RIGHTS_PSEUDONYMISATION_KEY',
    'BUNKFY_DATA_RIGHTS_REPLAY_ENVELOPE_KEY',
    'BUNKFY_DATA_RIGHTS_LEDGER_INTEGRITY_KEY',
    'BUNKFY_DATA_RIGHTS_EXPORT_ARTIFACT_KEY'
)
$dataRightsKeyDigests = [Collections.Generic.HashSet[string]]::new(
    [StringComparer]::Ordinal)
foreach ($keyName in $dataRightsKeyNames) {
    $encodedKey = [string]$settings[$keyName]
    try {
        $key = [Convert]::FromBase64String($encodedKey)
    }
    catch {
        throw "$keyName must be a base64-encoded 32-byte key."
    }

    if ($key.Length -ne 32) {
        throw "$keyName must be a base64-encoded 32-byte key."
    }

    $sha256 = [Security.Cryptography.SHA256]::Create()
    try {
        $digest = (
            [BitConverter]::ToString($sha256.ComputeHash($key)) -replace '-', '')
    }
    finally {
        $sha256.Dispose()
    }
    if (-not $dataRightsKeyDigests.Add($digest)) {
        throw 'Data-rights preview keys must use distinct key material.'
    }
}

$publicUrl = [Uri]([string]$settings['BUNKFY_PUBLIC_URL'])
$isLoopbackHttp = $publicUrl.Scheme -eq 'http' -and $publicUrl.IsLoopback
if ($publicUrl.Scheme -ne 'https' -and -not $isLoopbackHttp) {
    throw 'BUNKFY_PUBLIC_URL must use HTTPS unless it targets loopback.'
}

foreach ($provider in @('GOOGLE', 'MICROSOFT')) {
    if ([string]$settings["BUNKFY_${provider}_OIDC_ENABLED"] -ieq 'true' -and
        ([string]::IsNullOrWhiteSpace([string]$settings["BUNKFY_${provider}_OIDC_CLIENT_ID"]) -or
         [string]::IsNullOrWhiteSpace([string]$settings["BUNKFY_${provider}_OIDC_CLIENT_SECRET"]))) {
        throw "$provider OIDC is enabled but its client id or secret is missing."
    }
}

$arguments = @('compose', '--env-file', $environmentFile, '-f', $composeFile)
if ($Action -in @('open-operations', 'close-operations')) {
    $Operations = $true
}
if ($Action -eq 'down') {
    $Operations = $true
    $Tools = $true
}
if ($Operations) {
    $arguments += @('--profile', 'operations')
}
if ($Tools) {
    $arguments += @('--profile', 'tools')
}

switch ($Action) {
    'config' { $arguments += @('config', '--quiet') }
    'build' { $arguments += @('build') }
    'up' { $arguments += @('up', '--detach', '--build', '--wait') }
    'down' { $arguments += @('down') }
    'logs' { $arguments += @('logs', '--follow', '--tail', '200') }
    'status' { $arguments += @('ps') }
    'migrate' { $arguments += @('run', '--rm', 'migrations') }
    'open-operations' {
        $arguments += @('up', '--detach', '--no-build', '--wait', 'admin-api')
    }
    'close-operations' {
        $arguments += @('rm', '--stop', '--force', 'admin-api')
    }
}

Invoke-BunkFyCommand -FilePath 'docker' -Arguments $arguments -WorkingDirectory $root

if ($Action -eq 'close-operations') {
    $configurationArguments = @(
        'compose',
        '--env-file', $environmentFile,
        '-f', $composeFile,
        '--profile', 'operations',
        'config',
        '--format', 'json')

    Push-Location -LiteralPath $root
    try {
        $configurationJson = & docker @configurationArguments
        if ($LASTEXITCODE -ne 0) {
            throw 'Unable to resolve the preview management network.'
        }
        $configuration = $configurationJson | ConvertFrom-Json
        $managementNetwork = [string]$configuration.networks.management.name
        $existingNetworks = @(& docker network ls --format '{{.Name}}')
        if ($LASTEXITCODE -ne 0) {
            throw 'Unable to inspect Docker networks.'
        }

        if ($existingNetworks -contains $managementNetwork) {
            & docker network rm $managementNetwork | Out-Null
            if ($LASTEXITCODE -ne 0) {
                throw "Unable to remove preview management network '$managementNetwork'."
            }
        }
    }
    finally {
        Pop-Location
    }
}
