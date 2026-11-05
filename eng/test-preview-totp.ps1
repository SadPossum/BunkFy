Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'operations\preview-totp.common.ps1')

$secret = 'GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ'
$vectors = @(
    [pscustomobject]@{ Seconds = 59L; Code = '94287082' },
    [pscustomobject]@{ Seconds = 1111111109L; Code = '07081804' },
    [pscustomobject]@{ Seconds = 1111111111L; Code = '14050471' },
    [pscustomobject]@{ Seconds = 1234567890L; Code = '89005924' },
    [pscustomobject]@{ Seconds = 2000000000L; Code = '69279037' },
    [pscustomobject]@{ Seconds = 20000000000L; Code = '65353130' })
foreach ($vector in $vectors) {
    $actual = Get-BunkFyPreviewTotpCode `
        -Secret $secret `
        -AtUtc ([DateTimeOffset]::FromUnixTimeSeconds($vector.Seconds)) `
        -Digits 8
    if ($actual -cne $vector.Code) {
        throw "TOTP vector '$($vector.Seconds)' produced '$actual' instead of '$($vector.Code)'."
    }
}

$sixDigit = Get-BunkFyPreviewTotpCode `
    -Secret $secret `
    -AtUtc ([DateTimeOffset]::FromUnixTimeSeconds(59))
if ($sixDigit -cne '287082') {
    throw "Six-digit TOTP produced '$sixDigit' instead of '287082'."
}

foreach ($invalid in @('', 'ABC!', 'MZXW6===')) {
    $rejected = $false
    try {
        Get-BunkFyPreviewTotpCode -Secret $invalid | Out-Null
    }
    catch {
        $rejected = $true
    }
    if (-not $rejected) {
        throw "Invalid TOTP secret '$invalid' was accepted."
    }
}

Write-Host 'BunkFy Preview TOTP fixture passed.'
