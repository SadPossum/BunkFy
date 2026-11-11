Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'common.ps1')
. (Join-Path $PSScriptRoot 'operations/preview-storage.common.ps1')
. (Join-Path $PSScriptRoot 'operations/preview-state.common.ps1')

$root = Get-BunkFyRepositoryRoot
$template = Join-Path $root 'deploy/preview/.env.example'
$oldProfileExists = Test-Path Env:BUNKFY_INFRA_PROFILE
$oldProfile = [Environment]::GetEnvironmentVariable('BUNKFY_INFRA_PROFILE')
try {
    $env:BUNKFY_INFRA_PROFILE = 'maintained'
    $maintained = Get-BunkFyPreviewComposeDefinition -Root $root `
        -ComposePath (Join-Path $root 'deploy/preview/compose.yaml') -EnvironmentPath $template
}
finally {
    if ($oldProfileExists) { [Environment]::SetEnvironmentVariable('BUNKFY_INFRA_PROFILE', $oldProfile) }
    else { Remove-Item Env:BUNKFY_INFRA_PROFILE -ErrorAction SilentlyContinue }
}

$script:DaemonCalls = 0
function docker { $script:DaemonCalls++; throw 'Metadata integrity fixtures must not call the Docker daemon.' }
$cases = [Collections.Generic.List[object]]::new()
function Check-IdentityCase([string] $Name, [scriptblock] $Action, [bool] $Reject = $false) {
    $failure = $null
    try { & $Action | Out-Null } catch { $failure = $_ }
    $passed = if ($Reject) { $null -ne $failure } else { $null -eq $failure }
    $cases.Add([pscustomobject]@{ name = $Name; passed = $passed; rejectionExpected = $Reject
        error = if ($null -ne $failure) { $failure.Exception.Message } else { $null } })
}

function New-IdentityFixture {
    param([string] $Shape = 'oci', [string] $Fault = '')
    $architecture = if ($Fault -ceq 'wrong-platform') { 'arm64' } else { 'amd64' }
    [byte[]]$configuration = [Text.Encoding]::UTF8.GetBytes(
        ('{"architecture":"' + $architecture + '","os":"linux","rootfs":{"type":"layers","diff_ids":[]},"config":{"Env":["SYNTHETIC_PRIVATE_CONFIGURATION"]}}'))
    if ($Fault -ceq 'invalid-config-json') { $configuration = [Text.Encoding]::UTF8.GetBytes('{invalid JSON') }
    $hash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($configuration)).ToLowerInvariant()
    $path = if ($Shape -ceq 'legacy') { "$hash.json" } else { "blobs/sha256/$hash" }
    if ($Fault -ceq 'bad-config-hash') { $path = 'blobs/sha256/' + ('a' * 64) }
    $pointer = if ($Fault -ceq 'unsafe-pointer') { '../configuration.json' } else { $path }
    $records = @([ordered]@{ Config = $pointer; RepoTags = @(); Layers = @() })
    if ($Fault -ceq 'multiple-images') { $records += $records[0] }
    [byte[]]$manifest = [Text.Encoding]::UTF8.GetBytes((ConvertTo-Json -InputObject $records -Compress -Depth 5))
    $entries = @(
        @{ Name = $path; Bytes = $configuration },
        @{ Name = 'manifest.json'; Bytes = $manifest })
    if ($Shape -ceq 'manifest-first') { [Array]::Reverse($entries) }
    if ($Fault -ceq 'duplicate-config') { $entries += $entries[0] }
    if ($Fault -ceq 'missing-manifest') { $entries = @($entries[0]) }
    if ($Fault -ceq 'opaque-layer') {
        $entries = @(@{ Name = 'blobs/sha256/' + ('b' * 64); Bytes = [byte[]]@(255, 254, 0, 128) }) + $entries
    }
    if ($Fault -ceq 'unsafe-entry') { $entries += @{ Name = '../escape'; Bytes = [byte[]]@(1) } }
    $stream = [IO.MemoryStream]::new()
    $writer = [Formats.Tar.TarWriter]::new($stream, $true)
    try {
        foreach ($record in $entries) {
            $entry = [Formats.Tar.PaxTarEntry]::new([Formats.Tar.TarEntryType]::RegularFile, $record.Name)
            $data = [IO.MemoryStream]::new([byte[]]$record.Bytes, $false)
            try { $entry.DataStream = $data; $writer.WriteEntry($entry) } finally { $data.Dispose() }
        }
        if ($Fault -ceq 'link-entry') {
            $entry = [Formats.Tar.PaxTarEntry]::new([Formats.Tar.TarEntryType]::SymbolicLink, 'link')
            $entry.LinkName = $path
            $writer.WriteEntry($entry)
        }
    }
    finally { $writer.Dispose() }
    if ($Fault -ceq 'appended-data') { $stream.WriteByte(65) }
    $value = [pscustomobject]@{ Bytes = $stream.ToArray(); Expected = "sha256:$hash" }
    $stream.Dispose()
    return $value
}

function Read-IdentityFixture([object] $Fixture) {
    $stream = [IO.MemoryStream]::new([byte[]]$Fixture.Bytes, $false)
    try { return Read-BunkFyDockerExportConfigurationDigest -Stream $stream }
    finally { $stream.Dispose() }
}

foreach ($shape in @('oci', 'manifest-first', 'legacy')) {
    Check-IdentityCase "configuration-digest-$shape-layout" {
        $fixture = New-IdentityFixture -Shape $shape
        if ((Read-IdentityFixture $fixture) -cne $fixture.Expected) { throw 'Wrong configuration content address.' }
    }
}
Check-IdentityCase 'opaque-layer-bytes-never-treated-as-configuration' {
    $fixture = New-IdentityFixture -Fault opaque-layer
    if ((Read-IdentityFixture $fixture) -cne $fixture.Expected) { throw 'Opaque layer changed configuration identity.' }
}
foreach ($fault in @('bad-config-hash','unsafe-pointer','multiple-images','duplicate-config',
        'wrong-platform','missing-manifest','invalid-config-json','unsafe-entry','link-entry','appended-data')) {
    Check-IdentityCase "reject-$fault" { [void](Read-IdentityFixture (New-IdentityFixture -Fault $fault)) } $true
}

$classicIds = [ordered]@{}
foreach ($entry in (Get-BunkFyPreviewInfrastructurePolicy).profiles.maintained.configurationIds.PSObject.Properties) {
    $classicIds[$entry.Name] = [string]$entry.Value
}
$classicIds['minio'] = (Get-Content (Join-Path $root '.gma/preview-storage-review.json') -Raw | ConvertFrom-Json).imageConfigDigest
$classicRecord = New-BunkFyPreviewInfrastructureRecord -ComposeDefinition $maintained -ImageIds $classicIds
$references = Get-BunkFyPreviewInfrastructureReferences $maintained
$modernIds = [ordered]@{}
$script:MeasuredConfigurations = @{}
foreach ($entry in $references.GetEnumerator()) {
    $modernIds[$entry.Key] = if ($entry.Key -ceq 'postgres') {
        (Get-BunkFyPreviewInfrastructurePolicy).profiles.maintained.postgresBuild.runtimeManifest
    } else { 'sha256:' + ([string]$entry.Value -split '@sha256:', 2)[1] }
    $script:MeasuredConfigurations[[string]$entry.Value] = [string]$classicIds[$entry.Key]
}
$script:ConfigurationReads = 0
$script:WrongConfiguration = $false
function Get-BunkFyDockerImageConfigurationDigest {
    param([string] $Reference, [string] $RuntimeImageId, [switch] $LocalPreviewPostgres)
    $script:ConfigurationReads++
    if ($script:WrongConfiguration) { return 'sha256:' + ('0' * 64) }
    return $script:MeasuredConfigurations[$Reference]
}
Check-IdentityCase 'containerd-config-record-equals-classic-record-and-retains-runtime-bindings' {
    $before = $modernIds | ConvertTo-Json
    $record = New-BunkFyPreviewInfrastructureRecord -ComposeDefinition $maintained -ImageIds $modernIds
    if (($record | ConvertTo-Json -Depth 12) -cne ($classicRecord | ConvertTo-Json -Depth 12) -or
        ($modernIds | ConvertTo-Json) -cne $before -or $script:ConfigurationReads -ne 6) {
        throw 'Portable configuration identity or caller runtime binding was changed.'
    }
}
Check-IdentityCase 'same-manifest-with-wrong-actual-configuration-still-rejected' {
    $script:WrongConfiguration = $true
    try { New-BunkFyPreviewInfrastructureRecord -ComposeDefinition $maintained -ImageIds $modernIds }
    finally { $script:WrongConfiguration = $false }
} $true
Check-IdentityCase 'unrelated-runtime-id-rejected-before-export' {
    $bad = [ordered]@{}
    foreach ($entry in $classicIds.GetEnumerator()) { $bad[$entry.Key] = $entry.Value }
    $bad['postgres'] = 'sha256:' + ('1' * 64)
    $before = $script:ConfigurationReads
    $rejected = $false
    try { New-BunkFyPreviewInfrastructureRecord -ComposeDefinition $maintained -ImageIds $bad } catch { $rejected = $true }
    if (-not $rejected -or $script:ConfigurationReads -ne $before) { throw 'An unrelated ID reached image export.' }
}

$failures = @($cases | Where-Object { -not $_.passed })
if ($failures.Count -gt 0) { $failures | ConvertTo-Json -Depth 4 | Write-Host; throw 'Image configuration identity fixtures failed.' }
if ($script:DaemonCalls -ne 0) { throw 'Image identity fixture made an unexpected daemon call.' }
Write-Host "Docker image configuration: $($cases.Count) integrity/operator cases passed; no daemon mutations."
