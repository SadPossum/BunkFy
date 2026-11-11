Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'docker-image-identity.common.ps1')

function Resolve-BunkFyQualifiedImageConfiguration {
    param([string] $Name, [string] $Reference, [string] $RuntimeImageId, [string] $ExpectedConfigurationId)

    # Classic Docker reports the configuration digest as Id. Containerd reports
    # the content-addressed manifest/index Id instead. Keep container bindings
    # on runtime IDs, while the backup/security contract retains config hashes.
    if ($RuntimeImageId -ceq $ExpectedConfigurationId) { return $RuntimeImageId }
    if ($Reference -ceq 'bunkfy-preview-postgres:17.11-libxslt-r4') {
        $configurationId = Get-BunkFyDockerImageConfigurationDigest -Reference $Reference -RuntimeImageId $RuntimeImageId -LocalPreviewPostgres
        if ($configurationId -cne $ExpectedConfigurationId) { throw 'Local patched PostgreSQL configuration changed.' }
        return $configurationId
    }
    if ($Reference -cnotmatch '@(?<digest>sha256:[a-f0-9]{64})$' -or $RuntimeImageId -cne $Matches['digest']) {
        throw "Local infrastructure image '$Name' differs from the qualified Linux amd64 configuration."
    }
    $configurationId = Get-BunkFyDockerImageConfigurationDigest -Reference $Reference -RuntimeImageId $RuntimeImageId
    if ($configurationId -cne $ExpectedConfigurationId) {
        throw "Local infrastructure image '$Name' differs from the qualified Linux amd64 configuration."
    }
    return $configurationId
}

function Get-BunkFyPreviewInfrastructurePolicy {
    $path = Join-Path $PSScriptRoot '..\..\.gma\preview-infrastructure-profiles.json'
    $policy = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
    if ([int]$policy.schemaVersion -ne 1 -or
        (@($policy.profiles.PSObject.Properties.Name | Sort-Object) -join ',') -cne 'legacy,maintained') {
        throw 'Preview infrastructure policy has an unsupported schema or profile set.'
    }
    return $policy
}

function Assert-BunkFyPreviewPostgresExecution {
    param(
        [Parameter(Mandatory = $true)][object] $Actual,
        [Parameter(Mandatory = $true)][object] $Expected
    )

    $fields = @($Actual.PSObject.Properties.Name | Sort-Object)
    if (($fields -join ',') -cne 'capDrop,readOnly,securityOptions,tmpfs,user' -or
        [string]$Actual.user -cne [string]$Expected.user -or
        $Actual.readOnly -isnot [bool] -or $Actual.readOnly -ne $Expected.readOnly) {
        throw 'PostgreSQL execution identity or read-only filesystem does not match the reviewed profile.'
    }
    foreach ($name in @('capDrop', 'securityOptions', 'tmpfs')) {
        $actualValues = @($Actual.PSObject.Properties[$name].Value)
        $expectedValues = @($Expected.PSObject.Properties[$name].Value)
        if ($actualValues.Count -ne $expectedValues.Count -or
            @($actualValues | Where-Object { $_ -isnot [string] }).Count -gt 0) {
            throw "PostgreSQL execution field '$name' does not match the reviewed profile."
        }
        if ($name -ceq 'tmpfs') {
            $normalize = {
                param([string] $Mount)
                $parts = $Mount.Split(':', 2)
                if ($parts.Count -ne 2) { throw 'PostgreSQL tmpfs options are missing.' }
                return $parts[0] + ':' + (@($parts[1].Split(',') | Sort-Object -CaseSensitive) -join ',')
            }
            $actualValues = @($actualValues | ForEach-Object { & $normalize $_ })
            $expectedValues = @($expectedValues | ForEach-Object { & $normalize $_ })
        }
        if ((@($actualValues | Sort-Object -CaseSensitive) -join "`n") -cne
            (@($expectedValues | Sort-Object -CaseSensitive) -join "`n")) {
            throw "PostgreSQL execution field '$name' does not match the reviewed profile."
        }
    }
}

function Get-BunkFyPreviewInfrastructureProfile {
    param([Parameter(Mandatory = $true)][object] $ComposeDefinition)

    $policy = Get-BunkFyPreviewInfrastructurePolicy
    $profileMatches = @()
    foreach ($entry in $policy.profiles.PSObject.Properties) {
        $matching = $true
        foreach ($name in @('postgres', 'redis', 'nats', 'mailpit')) {
            $service = $ComposeDefinition.services.PSObject.Properties[$name]
            if ($null -eq $service -or
                [string]$service.Value.image -cne [string]$entry.Value.images.PSObject.Properties[$name].Value) {
                $matching = $false
                break
            }
        }
        if ($matching) { $profileMatches += $entry }
    }
    if ($profileMatches.Count -ne 1) {
        throw 'Preview infrastructure must select one complete reviewed profile; mixed or overridden images are unsupported.'
    }
    $entry = $profileMatches[0]
    if ($entry.Name -ceq 'maintained') {
        $postgres = $ComposeDefinition.services.postgres
        $required = @('user', 'read_only', 'cap_drop', 'security_opt', 'tmpfs', 'platform', 'volumes')
        foreach ($name in $required) {
            if ($null -eq $postgres.PSObject.Properties[$name]) {
                throw "Maintained PostgreSQL is missing its reviewed '$name' setting."
            }
        }
        foreach ($name in @('postgres', 'redis', 'nats', 'mailpit')) {
            $service = $ComposeDefinition.services.PSObject.Properties[$name].Value
            if ($null -eq $service.PSObject.Properties['platform'] -or
                [string]$service.platform -cne 'linux/amd64') {
                throw 'The maintained infrastructure assessment covers Linux amd64 only.'
            }
        }
        $execution = [pscustomobject][ordered]@{
            user = [string]$postgres.user
            readOnly = $postgres.read_only
            capDrop = @($postgres.cap_drop)
            securityOptions = @($postgres.security_opt)
            tmpfs = @($postgres.tmpfs)
        }
        Assert-BunkFyPreviewPostgresExecution -Actual $execution -Expected $entry.Value.postgresExecution
        $mounts = @($postgres.volumes)
        if (($null -ne $postgres.PSObject.Properties['cap_add'] -and $null -ne $postgres.cap_add -and @($postgres.cap_add).Count -gt 0) -or
            ($null -ne $postgres.PSObject.Properties['entrypoint'] -and $null -ne $postgres.entrypoint) -or
            ($null -ne $postgres.PSObject.Properties['command'] -and $null -ne $postgres.command)) {
            throw 'Maintained PostgreSQL must retain the reviewed entrypoint and no added capabilities.'
        }
        if ($mounts.Count -ne 1 -or [string]$mounts[0].type -cne 'volume' -or
            [string]$mounts[0].source -cne 'postgres-data' -or
            [string]$mounts[0].target -cne '/var/lib/postgresql/data' -or
            ($null -ne $postgres.PSObject.Properties['privileged'] -and $postgres.privileged)) {
            throw 'Maintained PostgreSQL must use only its reviewed data volume and unprivileged container profile.'
        }
    }
    return [pscustomobject]@{
        Name = $entry.Name
        Images = $entry.Value.images
        ArchiveUtilityImage = [string]$entry.Value.archiveUtilityImage
        PostgresExecution = $entry.Value.postgresExecution
        ConfigurationIds = if ($null -ne $entry.Value.PSObject.Properties['configurationIds']) {
            $entry.Value.configurationIds
        } else { $null }
    }
}

function Get-BunkFyPreviewArchiveUtilityImage {
    param([Parameter(Mandatory = $true)][object] $ComposeDefinition)
    return (Get-BunkFyPreviewInfrastructureProfile -ComposeDefinition $ComposeDefinition).ArchiveUtilityImage
}

function Assert-BunkFyPreviewInfrastructureVolumes {
    param([Parameter(Mandatory = $true)][object] $ComposeDefinition)

    $profile = Get-BunkFyPreviewInfrastructureProfile -ComposeDefinition $ComposeDefinition
    $generation = if ($profile.Name -ceq 'maintained') { 'maintained:2' } else { 'legacy:1' }
    $volumeNames = [Collections.Generic.List[string]]::new()
    foreach ($logicalName in @('postgres-data', 'redis-data', 'nats-data')) {
        $volume = $ComposeDefinition.volumes.PSObject.Properties[$logicalName].Value
        if ([string]$volume.name -cnotmatch '^[A-Za-z0-9][A-Za-z0-9_.-]{0,255}$' -or
            $null -eq $volume.PSObject.Properties['labels'] -or
            [string]$volume.labels.'com.bunkfy.preview.infrastructure-generation' -cne $generation) {
            throw 'Preview state volumes must retain the reviewed infrastructure generation.'
        }
        $volumeNames.Add([string]$volume.name)
    }
    $existing = @(& docker volume ls --format '{{.Name}}')
    if ($LASTEXITCODE -ne 0) { throw 'Unable to inspect Preview infrastructure volumes.' }
    foreach ($name in $volumeNames) {
        if ($existing -notcontains $name) { continue }
        $json = & docker volume inspect --format '{{json .Labels}}' $name
        if ($LASTEXITCODE -ne 0) { throw 'Unable to inspect existing Preview infrastructure provenance.' }
        $labels = $json | ConvertFrom-Json -AsHashtable
        if ($null -eq $labels) { $labels = @{} }
        if ($labels -isnot [Collections.IDictionary]) { throw 'Preview infrastructure volume labels are invalid.' }
        $actual = [string]$labels['com.bunkfy.preview.infrastructure-generation']
        # Pre-existing unlabelled volumes keep their original infrastructure.
        if ($profile.Name -ceq 'legacy' -and [string]::IsNullOrEmpty($actual)) { continue }
        if ($actual -cne $generation) {
            throw "Existing Preview volume '$name' belongs to another or unknown infrastructure generation. It was left unchanged; use a new volume prefix or a separately qualified migration."
        }
    }
}

function Get-BunkFyPreviewInfrastructureImageIds {
    param([Parameter(Mandatory = $true)][object] $ComposeDefinition)

    $ids = [ordered]@{}
    $references = Get-BunkFyPreviewInfrastructureReferences -ComposeDefinition $ComposeDefinition
    foreach ($entry in $references.GetEnumerator()) {
        $ids[$entry.Key] = Get-BunkFyDockerImageId -Reference ([string]$entry.Value)
    }
    return $ids
}

function Assert-BunkFyPreviewInfrastructureContainers {
    param(
        [Parameter(Mandatory = $true)][object] $ComposeDefinition,
        [Parameter(Mandatory = $true)][string[]] $ComposeArguments,
        [Parameter(Mandatory = $true)][Collections.IDictionary] $ImageIds
    )

    $profile = Get-BunkFyPreviewInfrastructureProfile -ComposeDefinition $ComposeDefinition
    foreach ($service in @('postgres', 'redis', 'nats', 'mailpit', 'minio')) {
        $ids = @(& docker @ComposeArguments ps --all --quiet $service)
        if ($LASTEXITCODE -ne 0 -or $ids.Count -gt 1) {
            throw "Unable to inspect the Preview '$service' container identity."
        }
        if ($ids.Count -eq 0) {
            if ($service -ceq 'postgres') { throw 'The Preview PostgreSQL container is missing.' }
            continue
        }
        $json = & docker inspect --format '{{json .}}' $ids[0]
        if ($LASTEXITCODE -ne 0) { throw "Unable to inspect Preview '$service'." }
        $container = $json | ConvertFrom-Json
        if ([string]$container.Image -cne [string]$ImageIds[$service]) {
            throw "Preview '$service' uses a different image than the selected infrastructure profile."
        }
        if ($service -ceq 'postgres' -and $profile.Name -ceq 'maintained') {
            $tmpfs = @($container.HostConfig.Tmpfs.PSObject.Properties | ForEach-Object { "$($_.Name):$($_.Value)" })
            $execution = [pscustomobject][ordered]@{
                user = [string]$container.Config.User
                readOnly = $container.HostConfig.ReadonlyRootfs
                capDrop = @($container.HostConfig.CapDrop)
                securityOptions = @($container.HostConfig.SecurityOpt)
                tmpfs = $tmpfs
            }
            Assert-BunkFyPreviewPostgresExecution -Actual $execution -Expected $profile.PostgresExecution
            $mounts = @($container.Mounts | Where-Object { $_.Type -cne 'tmpfs' })
            if ($container.HostConfig.Privileged -or
                ($null -ne $container.HostConfig.PSObject.Properties['CapAdd'] -and
                    $null -ne $container.HostConfig.CapAdd -and @($container.HostConfig.CapAdd).Count -gt 0) -or
                $mounts.Count -ne 1 -or
                [string]$mounts[0].Type -cne 'volume' -or
                [string]$mounts[0].Name -cne [string]$ComposeDefinition.volumes.'postgres-data'.name -or
                [string]$mounts[0].Destination -cne '/var/lib/postgresql/data') {
                throw 'Running PostgreSQL does not use the reviewed unprivileged data-only volume profile.'
            }
        }
    }
}

function Get-BunkFyPreviewInfrastructureReferences {
    param([Parameter(Mandatory = $true)][object] $ComposeDefinition)

    $profile = Get-BunkFyPreviewInfrastructureProfile -ComposeDefinition $ComposeDefinition
    $storage = Get-BunkFyPreviewStorageProfile -ComposeDefinition $ComposeDefinition
    $references = [ordered]@{}
    foreach ($name in @('postgres', 'redis', 'nats', 'mailpit')) {
        $references[$name] = [string]$profile.Images.PSObject.Properties[$name].Value
    }
    $references['minio'] = $storage.Image
    $references['archiveUtility'] = $profile.ArchiveUtilityImage
    return $references
}

function New-BunkFyPreviewInfrastructureRecord {
    param(
        [Parameter(Mandatory = $true)][object] $ComposeDefinition,
        [Parameter(Mandatory = $true)][Collections.IDictionary] $ImageIds
    )

    $profile = Get-BunkFyPreviewInfrastructureProfile -ComposeDefinition $ComposeDefinition
    $references = Get-BunkFyPreviewInfrastructureReferences -ComposeDefinition $ComposeDefinition
    if ($ImageIds.Count -ne $references.Count) {
        throw 'A measured Docker image identity is required for every infrastructure component.'
    }
    $configurationIds = [ordered]@{}
    foreach ($entry in $references.GetEnumerator()) {
        if (-not $ImageIds.Contains($entry.Key) -or [string]$ImageIds[$entry.Key] -cnotmatch '^sha256:[a-f0-9]{64}$') {
            throw "Infrastructure image identity '$($entry.Key)' is invalid."
        }
        $configurationIds[$entry.Key] = [string]$ImageIds[$entry.Key]
    }
    if ($profile.Name -ceq 'maintained') {
        foreach ($name in @('postgres', 'redis', 'nats', 'mailpit', 'archiveUtility')) {
            if ($null -eq $profile.ConfigurationIds -or
                $null -eq $profile.ConfigurationIds.PSObject.Properties[$name]) {
                throw "Local infrastructure image '$name' differs from the qualified Linux amd64 configuration."
            }
            $configurationIds[$name] = Resolve-BunkFyQualifiedImageConfiguration -Name $name `
                -Reference ([string]$references[$name]) -RuntimeImageId ([string]$ImageIds[$name]) `
                -ExpectedConfigurationId ([string]$profile.ConfigurationIds.PSObject.Properties[$name].Value)
        }
    }
    $storage = Get-BunkFyPreviewStorageProfile -ComposeDefinition $ComposeDefinition
    if ($storage.Provider -ceq 'silo') {
        $storageReview = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\..\.gma\preview-storage-review.json') -Raw | ConvertFrom-Json
        if ([string]$storageReview.image -cne $storage.Image) {
            throw 'Local infrastructure storage image differs from the qualified Silo configuration.'
        }
        $configurationIds['minio'] = Resolve-BunkFyQualifiedImageConfiguration -Name minio `
            -Reference ([string]$references['minio']) -RuntimeImageId ([string]$ImageIds['minio']) `
            -ExpectedConfigurationId ([string]$storageReview.imageConfigDigest)
    }
    $images = @($references.GetEnumerator() | ForEach-Object {
        $id = [string]$configurationIds[$_.Key]
        if ($id -cnotmatch '^sha256:[a-f0-9]{64}$') {
            throw "Infrastructure image identity '$($_.Key)' is invalid."
        }
        [pscustomobject][ordered]@{ name = $_.Key; reference = $_.Value; imageId = $id }
    })
    return [pscustomobject][ordered]@{
        version = 1
        profile = $profile.Name
        postgresExecution = $profile.PostgresExecution
        images = $images
    }
}

function Assert-BunkFyPreviewBackupInfrastructure {
    param(
        [Parameter(Mandatory = $true)][object] $Manifest,
        [Parameter(Mandatory = $true)][object] $ComposeDefinition,
        [Collections.IDictionary] $TargetImageIds = @{}
    )

    $profile = Get-BunkFyPreviewInfrastructureProfile -ComposeDefinition $ComposeDefinition
    $schema = [int]$Manifest.schemaVersion
    $property = $Manifest.PSObject.Properties['infrastructure']
    if ($schema -in @(2, 3, 4, 5, 6)) {
        if ($profile.Name -cne 'legacy' -or $null -ne $property) {
            throw 'Older backups require the original legacy infrastructure profile. No target resources were changed.'
        }
        return
    }
    if ($schema -ne 7 -or $null -eq $property -or $null -eq $property.Value) {
        throw 'The infrastructure-bound backup contract is missing or unsupported.'
    }
    $record = $property.Value
    if ((@($record.PSObject.Properties.Name | Sort-Object) -join ',') -cne
            'images,postgresExecution,profile,version' -or
        [int]$record.version -ne 1 -or [string]$record.profile -cne $profile.Name) {
        throw 'Backup infrastructure metadata has an invalid schema or profile.'
    }
    if ($null -eq $profile.PostgresExecution) {
        if ($null -ne $record.postgresExecution) { throw 'Legacy PostgreSQL execution metadata is invalid.' }
    }
    else {
        Assert-BunkFyPreviewPostgresExecution -Actual $record.postgresExecution -Expected $profile.PostgresExecution
    }
    $expected = New-BunkFyPreviewInfrastructureRecord -ComposeDefinition $ComposeDefinition -ImageIds $TargetImageIds
    $images = @($record.images)
    if ($images.Count -ne @($expected.images).Count) {
        throw 'Backup infrastructure does not contain the exact image set.'
    }
    foreach ($image in $expected.images) {
        $matchingImages = @($images | Where-Object { [string]$_.name -ceq [string]$image.name })
        if ($matchingImages.Count -ne 1 -or
            (@($matchingImages[0].PSObject.Properties.Name | Sort-Object) -join ',') -cne 'imageId,name,reference' -or
            [string]$matchingImages[0].reference -cne [string]$image.reference -or
            [string]$matchingImages[0].imageId -cne [string]$image.imageId) {
            throw "Backup infrastructure image '$($image.name)' differs from the selected local target. No target resources were changed."
        }
    }
}
