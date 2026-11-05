[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [switch] $Force,
    [string] $OutputPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'common.ps1')
. (Join-Path $PSScriptRoot 'operations\local-sensitive-state.common.ps1')

$templatePath = Join-BunkFyPath 'deploy\preview\.env.example'
$environmentPath = if ([string]::IsNullOrWhiteSpace($OutputPath)) {
    Join-BunkFyPath 'deploy\preview\.env'
}
elseif ([IO.Path]::IsPathRooted($OutputPath)) {
    [IO.Path]::GetFullPath($OutputPath)
}
else {
    Join-BunkFyPath $OutputPath
}
if ((Test-Path -LiteralPath $environmentPath -PathType Leaf) -and -not $Force) {
    throw "Preview environment '$environmentPath' already exists. Use -Force to replace it."
}

function New-BunkFySecret {
    $bytes = New-Object byte[] 32
    $random = [Security.Cryptography.RandomNumberGenerator]::Create()
    try {
        $random.GetBytes($bytes)
    }
    finally {
        $random.Dispose()
    }

    return ([BitConverter]::ToString($bytes) -replace '-', '').ToLowerInvariant()
}

function New-BunkFyBase64Secret {
    $bytes = New-Object byte[] 32
    $random = [Security.Cryptography.RandomNumberGenerator]::Create()
    try {
        $random.GetBytes($bytes)
        return [Convert]::ToBase64String($bytes)
    }
    finally {
        $random.Dispose()
    }
}

if (-not $PSCmdlet.ShouldProcess($environmentPath, 'Generate local preview environment')) {
    return
}

$content = Get-Content -LiteralPath $templatePath -Raw
$replacements = @{
    'replace-with-random-postgres-password' = New-BunkFySecret
    'replace-with-random-redis-password' = New-BunkFySecret
    'replace-with-random-nats-password' = New-BunkFySecret
    'replace-with-random-minio-password' = New-BunkFySecret
    'replace-with-at-least-32-random-characters' = New-BunkFySecret
    'replace-with-a-separate-random-secret' = New-BunkFySecret
    'replace-with-base64-pseudonymisation-key' = New-BunkFyBase64Secret
    'replace-with-base64-replay-envelope-key' = New-BunkFyBase64Secret
    'replace-with-base64-ledger-integrity-key' = New-BunkFyBase64Secret
    'replace-with-base64-export-artifact-key' = New-BunkFyBase64Secret
}
foreach ($placeholder in $replacements.Keys) {
    $content = $content.Replace($placeholder, $replacements[$placeholder])
}

Write-BunkFyLocalSensitiveTextFile `
    -Path $environmentPath `
    -Content $content `
    -Overwrite:$Force `
    -Description 'Preview environment'
Write-Host "Generated '$environmentPath'. It is ignored by Git."
