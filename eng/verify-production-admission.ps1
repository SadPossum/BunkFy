[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string] $AdmissionDirectory,
    [Parameter(Mandatory = $true)][Uri] $ExpectedPublicOrigin,
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

. (Join-Path $PSScriptRoot 'production-admission.common.ps1')

$admission = Get-BunkFyVerifiedProductionAdmission `
    -Directory $AdmissionDirectory `
    -ExpectedPublicOrigin $ExpectedPublicOrigin `
    -ExpectedReleaseId $ExpectedReleaseId `
    -ExpectedSourceCommit $ExpectedSourceCommit `
    -AllowFixtureEvidence:$AllowFixtureEvidence
if ($PassThru) {
    return $admission
}
Write-Host (
    "Verified production admission '$($admission.AdmissionEvidenceReference)' " +
    "for release '$($admission.ReleaseId)'.")
