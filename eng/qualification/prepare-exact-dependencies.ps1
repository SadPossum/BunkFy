[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string] $CandidateDirectory,
    [Parameter(Mandatory = $true)][ValidatePattern('^[a-f0-9]{40}$')][string] $ExpectedSourceCommit,
    [Parameter(Mandatory = $true)][string] $OutputPath,
    [switch] $ConfigurationOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$candidate = [IO.Path]::GetFullPath($CandidateDirectory)
if ($ExpectedSourceCommit -ceq ('0' * 40)) { throw 'An actual candidate source commit is required.' }
$head = @(& git -C $candidate rev-parse HEAD)
if ($LASTEXITCODE -ne 0 -or $head.Count -ne 1 -or [string]$head[0] -cne $ExpectedSourceCommit) {
    throw 'Dependency preparation source differs from the qualified candidate.'
}
$status = @(& git -C $candidate status --porcelain --ignore-submodules=none)
if ($LASTEXITCODE -ne 0 -or $status.Count -ne 0) { throw 'Candidate source/components must remain clean.' }

. (Join-Path $candidate 'eng/common.ps1')
. (Join-Path $candidate 'eng/operations/local-sensitive-state.common.ps1')
. (Join-Path $candidate 'eng/operations/preview-state.common.ps1')
. (Join-Path $candidate 'eng/operations/preview-storage.common.ps1')

$private = Join-Path ([IO.Path]::GetTempPath()) "bunkfy-candidate-dependencies-$([Guid]::NewGuid().ToString('N'))"
$settingsPath = Join-Path $private 'preview.env'
$previous = @{}
foreach ($item in Get-ChildItem Env: | Where-Object { $_.Name -cmatch '^(BUNKFY_|COMPOSE_)' }) {
    $previous[$item.Name] = $item.Value
}
try {
    foreach ($name in $previous.Keys) { Remove-Item "Env:$name" }
    $env:BUNKFY_INFRA_PROFILE = 'maintained'
    New-BunkFyLocalSensitiveDirectory -Path $private -Description 'Candidate dependency private settings'
    & (Join-Path $candidate 'eng/new-preview-env.ps1') -OutputPath $settingsPath | Out-Null
    $definition = Get-BunkFyPreviewComposeDefinition -Root $candidate `
        -ComposePath (Join-Path $candidate 'deploy/preview/compose.yaml') -EnvironmentPath $settingsPath
    $profile = Get-BunkFyPreviewInfrastructureProfile $definition
    $storage = Get-BunkFyPreviewStorageProfile $definition
    if ($profile.Name -cne 'maintained' -or $storage.Provider -cne 'silo') {
        throw 'The current candidate must resolve the reviewed maintained infrastructure and Silo.'
    }
    $references = Get-BunkFyPreviewInfrastructureReferences $definition
    if ($references.Count -ne 6 -or @($references.Values | Sort-Object -Unique).Count -ne 6) {
        throw 'Exactly six distinct immutable infrastructure/helper images are required.'
    }
    $images = @()
    $ids = [ordered]@{}
    foreach ($entry in $references.GetEnumerator()) {
        if ([string]$entry.Value -cnotmatch '^.+@sha256:[a-f0-9]{64}$') { throw 'Mutable dependency reference rejected.' }
        if (-not $ConfigurationOnly) {
            & docker pull --platform linux/amd64 ([string]$entry.Value)
            if ($LASTEXITCODE -ne 0) { throw "Unable to obtain reviewed dependency '$($entry.Key)'." }
            $metadataJson = @(& docker image inspect ([string]$entry.Value))
            if ($LASTEXITCODE -ne 0) { throw "Unable to inspect dependency '$($entry.Key)'." }
            $metadata = @((($metadataJson -join "`n") | ConvertFrom-Json))
            if ($metadata.Count -ne 1 -or $metadata[0].Os -cne 'linux' -or $metadata[0].Architecture -cne 'amd64') {
                throw 'Dependency platform does not match the qualification.'
            }
            $ids[$entry.Key] = [string]$metadata[0].Id
        }
        $images += [ordered]@{ name = $entry.Key; reference = $entry.Value }
    }
    $record = if ($ConfigurationOnly) { $null } else {
        New-BunkFyPreviewInfrastructureRecord -ComposeDefinition $definition -ImageIds $ids
    }
    $report = [ordered]@{
        schemaVersion = 1
        applicationSourceCommit = $ExpectedSourceCommit
        result = if ($ConfigurationOnly) { 'configuration-only' } else { 'passed' }
        actualDockerImagesVerified = -not [bool]$ConfigurationOnly
        infrastructure = $record
        images = $images
        scope = 'Exact candidate dependency preparation only; no application rebuild, runtime or recovery acceptance.'
    }
    Write-BunkFyLocalSensitiveTextFile -Path ([IO.Path]::GetFullPath($OutputPath)) `
        -Content ($report | ConvertTo-Json -Depth 12) -Description 'Candidate dependency identity evidence'
    Write-Host "Candidate dependencies: $($references.Count) reviewed references; measured images: $(-not [bool]$ConfigurationOnly)."
}
finally {
    if (Test-Path -LiteralPath $private) { Remove-Item -LiteralPath $private -Recurse -Force }
    foreach ($item in Get-ChildItem Env: | Where-Object { $_.Name -cmatch '^(BUNKFY_|COMPOSE_)' }) {
        Remove-Item "Env:$($item.Name)"
    }
    foreach ($name in $previous.Keys) { [Environment]::SetEnvironmentVariable($name, [string]$previous[$name]) }
}
