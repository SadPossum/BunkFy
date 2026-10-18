[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string] $PromotionDirectory,
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[a-z0-9][a-z0-9._-]{2,127}$')]
    [string] $ExpectedReleaseId,
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[0-9a-f]{40}$')]
    [string] $ExpectedSourceCommit,
    [switch] $AllowFixtureEvidence,
    [switch] $PassThru
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'image-promotion.common.ps1')

$promotion = Get-BunkFyVerifiedImagePromotion `
    -PromotionDirectory $PromotionDirectory `
    -ExpectedReleaseId $ExpectedReleaseId `
    -ExpectedSourceCommit $ExpectedSourceCommit `
    -AllowFixtureEvidence:$AllowFixtureEvidence
if ($PassThru) {
    return $promotion
}

Write-Host (
    "Verified image promotion '$($promotion.PromotionEvidenceReference)' " +
    "for release '$($promotion.ReleaseId)'.")
