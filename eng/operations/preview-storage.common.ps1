Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:BunkFyPreviewSiloImage = 'pgsty/silo:RELEASE.2026-10-26T00-00-00Z@sha256:7bb2aff6b89efe1cb1303c10fc21d579447434ed06649ac9ec05a5e2dbf30ad7'
$script:BunkFyPreviewLegacyStorageImage = 'minio/minio:RELEASE.2025-04-22T22-12-26Z@sha256:a1ea29fa28355559ef137d71fc570e508a214ec84ff8083e39bc5428980b015e'

function Get-BunkFyPreviewStorageProfile {
    param([Parameter(Mandatory = $true)][object] $ComposeDefinition)

    # Resolved Compose includes process-environment overrides; the env file
    # alone does not prove which image Docker will actually start.
    $service = $ComposeDefinition.services.minio
    $volume = $ComposeDefinition.volumes.'minio-data'
    $image = [string]$service.image
    $provider = [string]$volume.labels.'com.bunkfy.preview.storage-provider'
    $labelImage = [string]$volume.labels.'com.bunkfy.preview.storage-image'
    $platformProperty = $service.PSObject.Properties['platform']
    $platform = if ($null -eq $platformProperty) { '' } else { [string]$platformProperty.Value }
    if ($labelImage -cne $image -or
        [string]$volume.name -cnotmatch '^[A-Za-z0-9][A-Za-z0-9_.-]{0,255}$') {
        throw 'Preview storage image/volume provenance is invalid.'
    }
    if ($provider -ceq 'silo' -and $image -ceq $script:BunkFyPreviewSiloImage -and
        $platform -ceq 'linux/amd64') {
        return [pscustomobject]@{ Provider = 'silo'; Image = $image; VolumeName = [string]$volume.name }
    }
    if ($provider -ceq 'legacy-minio' -and $image -ceq $script:BunkFyPreviewLegacyStorageImage -and
        [string]::IsNullOrEmpty($platform)) {
        return [pscustomobject]@{ Provider = 'legacy-minio'; Image = $image; VolumeName = [string]$volume.name }
    }
    throw 'Preview storage must select the exact maintained fixture or the unchanged legacy MinIO profile.'
}

function Assert-BunkFyPreviewStorageVolume {
    param([Parameter(Mandatory = $true)][object] $ComposeDefinition)

    $profile = Get-BunkFyPreviewStorageProfile -ComposeDefinition $ComposeDefinition
    $existing = @(& docker volume ls --format '{{.Name}}')
    if ($LASTEXITCODE -ne 0) { throw 'Unable to inspect Preview storage volumes.' }
    if ($existing -notcontains $profile.VolumeName) { return }

    $json = & docker volume inspect --format '{{json .Labels}}' $profile.VolumeName
    if ($LASTEXITCODE -ne 0) { throw 'Unable to inspect the existing Preview storage provider.' }
    $labels = $json | ConvertFrom-Json -AsHashtable
    if ($null -eq $labels) { $labels = @{} }
    if ($labels -isnot [Collections.IDictionary]) { throw 'Preview storage volume labels are invalid.' }
    $provider = [string]$labels['com.bunkfy.preview.storage-provider']
    $image = [string]$labels['com.bunkfy.preview.storage-image']
    # Old unlabelled volumes retain their original MinIO mode. Neither
    # provider may automatically reinterpret the other's data volume.
    if ($profile.Provider -ceq 'legacy-minio' -and
        [string]::IsNullOrEmpty($provider) -and [string]::IsNullOrEmpty($image)) { return }
    if ($provider -cne $profile.Provider -or $image -cne $profile.Image) {
        throw "Existing Preview storage volume '$($profile.VolumeName)' belongs to a different or unknown provider/image. It was left unchanged. Cross-provider migration requires separate qualification."
    }
}

function Assert-BunkFyPreviewBackupStorageProvider {
    param(
        [Parameter(Mandatory = $true)][object] $Manifest,
        [Parameter(Mandatory = $true)][object] $ComposeDefinition
    )

    $profile = Get-BunkFyPreviewStorageProfile -ComposeDefinition $ComposeDefinition
    $schema = [int]$Manifest.schemaVersion
    if ($schema -in @(2, 3, 4, 5) -and $profile.Provider -ceq 'legacy-minio' -and
        $null -eq $Manifest.PSObject.Properties['objectStorage']) {
        # Preserve the established restore contract on its original provider.
        return
    }

    $property = $Manifest.PSObject.Properties['objectStorage']
    $info = if ($null -ne $property -and $null -ne $property.Value) { $property.Value } else { $null }
    $provider = if ($null -ne $info) { $info.PSObject.Properties['provider'] } else { $null }
    $image = if ($null -ne $info) { $info.PSObject.Properties['image'] } else { $null }
    if (($schema -ne 7 -and ($schema -ne 6 -or $profile.Provider -cne 'silo')) -or
        $null -eq $provider -or [string]$provider.Value -cne $profile.Provider -or
        $null -eq $image -or [string]$image.Value -cne $profile.Image) {
        throw 'Preview backup and target storage providers do not match. Use the original MinIO profile for legacy backups; cross-provider migration is not automatic. No target resources were changed.'
    }
}
