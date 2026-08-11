[CmdletBinding()]
param(
    [string] $BackendImage = 'bunkfy/backend:preview',
    [string] $PostgreSqlImage = 'postgres:17.5-alpine@sha256:6567bca8d7bc8c82c5922425a0baee57be8402df92bae5eacad5f01ae9544daa',
    [string] $SourceCommitSha,
    [string] $OutputPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot '..\common.ps1')

$repositoryRoot = Get-BunkFyRepositoryRoot
if ([string]::IsNullOrWhiteSpace($SourceCommitSha)) {
    $SourceCommitSha = [string](& git -C $repositoryRoot rev-parse HEAD)
    if ($LASTEXITCODE -ne 0) {
        throw 'Unable to resolve the BunkFy source commit.'
    }
    $SourceCommitSha = $SourceCommitSha.Trim()
}
if ($SourceCommitSha -cnotmatch '^[0-9a-f]{40}$' -or
    $SourceCommitSha -ceq ('0' * 40)) {
    throw 'SourceCommitSha must be an exact lowercase, nonzero Git commit.'
}
& git -C $repositoryRoot cat-file -e "$SourceCommitSha`^{commit}"
if ($LASTEXITCODE -ne 0) {
    throw "SourceCommitSha '$SourceCommitSha' is not present in the BunkFy repository."
}

$runId = [Guid]::NewGuid().ToString('N').Substring(0, 12)
$resourcePrefix = "bunkfy-migration-rehearsal-$runId"
$networkName = "$resourcePrefix-network"
$postgresName = "$resourcePrefix-postgres"
$databaseName = 'bunkfy_migration_rehearsal'
$databaseUser = 'bunkfy_rehearsal'
$databasePassword = [Convert]::ToHexString(
    [Security.Cryptography.RandomNumberGenerator]::GetBytes(24)).ToLowerInvariant()
$pseudonymisationKey = [Convert]::ToBase64String(
    [Security.Cryptography.RandomNumberGenerator]::GetBytes(32))
$replayEnvelopeKey = [Convert]::ToBase64String(
    [Security.Cryptography.RandomNumberGenerator]::GetBytes(32))
$exportArtifactKey = [Convert]::ToBase64String(
    [Security.Cryptography.RandomNumberGenerator]::GetBytes(32))
$anonymisationFingerprintKey = [Convert]::ToBase64String(
    [Security.Cryptography.RandomNumberGenerator]::GetBytes(32))
$temporaryDirectory = Join-Path ([IO.Path]::GetTempPath()) $resourcePrefix
$createdContainers = [Collections.Generic.List[string]]::new()
$networkCreated = $false
$failure = $null
$evidence = $null

if ([string]::IsNullOrWhiteSpace($OutputPath)) {
    $stamp = [DateTimeOffset]::UtcNow.ToString('yyyyMMddTHHmmssZ')
    $OutputPath = Join-BunkFyPath ".tmp\migration-rehearsals\$stamp-$runId.json"
}
$OutputPath = [IO.Path]::GetFullPath($OutputPath, $repositoryRoot)
if (Test-Path -LiteralPath $OutputPath) {
    throw "Migration rehearsal evidence already exists: '$OutputPath'."
}

function Invoke-BunkFyDocker {
    param(
        [Parameter(Mandatory = $true)][string[]] $Arguments,
        [int] $TimeoutSeconds = 600
    )

    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = 'docker'
    $startInfo.WorkingDirectory = $repositoryRoot
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    foreach ($argument in $Arguments) {
        $startInfo.ArgumentList.Add($argument)
    }

    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    if (-not $process.Start()) {
        throw 'Unable to start Docker.'
    }

    $standardOutput = $process.StandardOutput.ReadToEndAsync()
    $standardError = $process.StandardError.ReadToEndAsync()
    if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
        $process.Kill($true)
        $process.WaitForExit()
        $process.Dispose()
        throw "Docker exceeded the $TimeoutSeconds second rehearsal budget."
    }

    $capturedStandardOutput = $standardOutput.GetAwaiter().GetResult().TrimEnd()
    $capturedStandardError = $standardError.GetAwaiter().GetResult().TrimEnd()
    $output = @($capturedStandardOutput, $capturedStandardError) |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) }

    $exitCode = $process.ExitCode
    $process.Dispose()
    return [pscustomobject]@{
        ExitCode = $exitCode
        StandardOutput = $capturedStandardOutput
        StandardError = $capturedStandardError
        Output = $output -join [Environment]::NewLine
    }
}

function Protect-BunkFyOutput {
    param([AllowEmptyString()][string] $Value)

    if ([string]::IsNullOrEmpty($Value)) {
        return ''
    }
    return $Value.Replace(
        $databasePassword,
        '[redacted]',
        [StringComparison]::Ordinal)
}

function Assert-BunkFyDockerSuccess {
    param(
        [Parameter(Mandatory = $true)][object] $Result,
        [Parameter(Mandatory = $true)][string] $Context
    )

    if ($Result.ExitCode -ne 0) {
        $safeOutput = Protect-BunkFyOutput -Value ([string]$Result.Output)
        throw "$Context failed with exit code $($Result.ExitCode).`n$safeOutput"
    }
}

function Resolve-BunkFyLocalImage {
    param(
        [Parameter(Mandatory = $true)][string] $Reference,
        [switch] $RequireRepositoryDigest
    )

    $inspect = Invoke-BunkFyDocker -Arguments @('image', 'inspect', $Reference)
    Assert-BunkFyDockerSuccess -Result $inspect -Context "Inspecting image '$Reference'"
    $records = @(ConvertFrom-Json -InputObject $inspect.Output)
    if ($records.Count -ne 1 -or
        [string]::IsNullOrWhiteSpace([string]$records[0].Id)) {
        throw "Image '$Reference' did not resolve to exactly one local image."
    }

    $imageId = ([string]$records[0].Id).Trim()
    if ($imageId -cnotmatch '^sha256:[0-9a-f]{64}$') {
        throw "Image '$Reference' has an invalid local image id."
    }

    $repositoryDigests = @(
        $records[0].RepoDigests |
            ForEach-Object { [string]$_ } |
            Where-Object { $_ -cmatch '@sha256:[0-9a-f]{64}$' })
    $digests = @(
        $repositoryDigests |
            ForEach-Object { ($_ -split '@')[-1] } |
            Sort-Object -Unique)
    if ($RequireRepositoryDigest -and $digests.Count -ne 1) {
        throw "Image '$Reference' must expose exactly one immutable repository digest."
    }

    return [pscustomobject]@{
        Reference = $Reference
        ImageId = $imageId
        RepositoryDigest = if ($digests.Count -eq 1) { $digests[0] } else { $null }
    }
}

function Write-BunkFyPrivateEnvironmentFile {
    param(
        [Parameter(Mandatory = $true)][string] $Name,
        [Parameter(Mandatory = $true)][Collections.IDictionary] $Values
    )

    $path = Join-Path $temporaryDirectory "$Name.env"
    $lines = foreach ($entry in $Values.GetEnumerator()) {
        if ([string]$entry.Key -cnotmatch '^[A-Za-z_][A-Za-z0-9_]*$') {
            throw "Environment key '$($entry.Key)' is invalid."
        }
        $value = [string]$entry.Value
        if ($value.Contains("`r", [StringComparison]::Ordinal) -or
            $value.Contains("`n", [StringComparison]::Ordinal)) {
            throw "Environment value '$($entry.Key)' contains a newline."
        }
        "$($entry.Key)=$value"
    }
    [IO.File]::WriteAllLines(
        $path,
        $lines,
        [Text.UTF8Encoding]::new($false))
    if (-not [Runtime.InteropServices.RuntimeInformation]::IsOSPlatform(
            [Runtime.InteropServices.OSPlatform]::Windows)) {
        [IO.File]::SetUnixFileMode(
            $path,
            [IO.UnixFileMode]::UserRead -bor [IO.UnixFileMode]::UserWrite)
    }
    return $path
}

function Get-BunkFyDatabaseSchemaFingerprint {
    $result = Invoke-BunkFyDocker -Arguments @(
        'exec',
        $postgresName,
        'pg_dump',
        '--schema-only',
        '--no-owner',
        '--no-privileges',
        "--username=$databaseUser",
        "--dbname=$databaseName",
        '--file=-')
    Assert-BunkFyDockerSuccess -Result $result -Context 'Reading the rehearsal database schema'
    $schemaLines = @(
        ([string]$result.StandardOutput -split "\r?\n") |
            ForEach-Object { $_.TrimEnd() } |
            Where-Object {
                -not $_.StartsWith('\restrict ', [StringComparison]::Ordinal) -and
                -not $_.StartsWith('\unrestrict ', [StringComparison]::Ordinal)
            })
    $schema = ($schemaLines -join "`n").Trim()
    $hash = [Convert]::ToHexString(
        [Security.Cryptography.SHA256]::HashData(
            [Text.Encoding]::UTF8.GetBytes($schema))).ToLowerInvariant()
    $lines = if ([string]::IsNullOrWhiteSpace($schema)) {
        0
    }
    else {
        @($schema -split "\n").Count
    }
    return [pscustomobject]@{
        Hash = $hash
        Lines = $lines
    }
}

function Invoke-BunkFyMigrationHost {
    param(
        [Parameter(Mandatory = $true)][string] $Phase,
        [Parameter(Mandatory = $true)][ValidateSet('Plan', 'Apply')][string] $Mode,
        [Parameter(Mandatory = $true)][string] $CommitSha,
        [string] $ApprovedDatabaseTargetSha256,
        [string] $ApprovedTargetCatalogSha256,
        [string] $BackupEvidenceReference,
        [switch] $Approved
    )

    $values = [ordered]@{
        DOTNET_ENVIRONMENT = 'Production'
        Persistence__Provider = 'PostgreSql'
        ConnectionStrings__PostgreSql = "Host=postgres;Port=5432;Database=$databaseName;Username=$databaseUser;Password=$databasePassword;Include Error Detail=false;Timeout=5"
        Migrations__Mode = $Mode
        Migrations__LockAcquireTimeoutSeconds = '10'
        Migrations__LockRetryDelayMilliseconds = '100'
        Migrations__OperationTimeoutSeconds = '300'
        Migrations__CommandTimeoutSeconds = '60'
        Migrations__ProductionAdmission__DeploymentProfile = 'Hosted'
        Migrations__ProductionAdmission__Runtime = 'Container'
        Migrations__ProductionAdmission__SourceCommitSha = $CommitSha
        Migrations__ProductionAdmission__ContainerImageDigest = $backend.RepositoryDigest
        Migrations__ProductionAdmission__DatabaseIdentity = "rehearsal-$runId"
        Migrations__ProductionAdmission__TargetCatalogVersion = '1'
        DataRights__Pseudonymisation__ActiveKeyVersion = '1'
        DataRights__Pseudonymisation__Keys__1 = $pseudonymisationKey
        DataRights__ReplayEnvelope__ActiveKeyVersion = '1'
        DataRights__ReplayEnvelope__Keys__1 = $replayEnvelopeKey
        DataRights__LedgerDelta__Provider = 'External'
        DataRights__TenantTerminationReplay__Provider = 'External'
        DataRights__ExportArtifacts__ActiveKeyVersion = '1'
        DataRights__ExportArtifacts__Keys__1 = $exportArtifactKey
        Ingestion__AnonymisationFingerprints__ActiveKeyVersion = '1'
        Ingestion__AnonymisationFingerprints__Keys__1 = $anonymisationFingerprintKey
    }
    if ($Approved) {
        $values.Migrations__ProductionAdmission__ApprovalState = 'Approved'
        $values.Migrations__ProductionAdmission__ApprovalReference =
            "rehearsal/$runId/approval"
        $values.Migrations__ProductionAdmission__ApprovedDatabaseTargetSha256 =
            $ApprovedDatabaseTargetSha256
        $values.Migrations__ProductionAdmission__ApprovedTargetCatalogSha256 =
            $ApprovedTargetCatalogSha256
        $values.Migrations__ProductionAdmission__BackupEvidenceReference = if (
            [string]::IsNullOrWhiteSpace($BackupEvidenceReference)) {
            "rehearsal/$runId/backup"
        }
        else {
            $BackupEvidenceReference
        }
        $values.Migrations__ProductionAdmission__RollbackEvidenceReference =
            "rehearsal/$runId/forward-repair"
        $values.Migrations__ProductionAdmission__ExistingHistoryDisposition =
            'ApplyCompatiblePrefix'
    }

    $environmentFile = Write-BunkFyPrivateEnvironmentFile `
        -Name $Phase `
        -Values $values
    $containerName = "$resourcePrefix-$Phase"
    $createdContainers.Add($containerName)
    try {
        return Invoke-BunkFyDocker -Arguments @(
            'run',
            '--rm',
            '--name', $containerName,
            '--label', 'com.bunkfy.operation=production-migration-rehearsal',
            '--label', "com.bunkfy.rehearsal=$runId",
            '--network', $networkName,
            '--env-file', $environmentFile,
            '--workdir', '/opt/bunkfy/migrations',
            $backend.ImageId,
            'BunkFy.Host.Migrations.dll')
    }
    finally {
        Remove-Item -LiteralPath $environmentFile -Force -ErrorAction SilentlyContinue
    }
}

function Get-BunkFyPlanEvidence {
    param([Parameter(Mandatory = $true)][string] $Output)

    $production = [regex]::Match(
        $Output,
        'database target (?<database>[a-f0-9]{64}); catalogue version (?<version>\d+); target (?<target>[a-f0-9]{64}); state (?<state>[a-f0-9]{64}); pending (?<pending>[a-f0-9]{64});')
    $summary = [regex]::Match(
        $Output,
        'Migration plan completed without mutation\. Modules (?<modules>\d+); target (?<target>\d+); applied (?<applied>\d+); pending (?<pending>\d+);')
    if (-not $production.Success -or -not $summary.Success) {
        throw 'The migration host did not emit the complete Production plan evidence contract.'
    }
    return [pscustomobject]@{
        DatabaseTargetSha256 = $production.Groups['database'].Value
        TargetCatalogVersion = [int]$production.Groups['version'].Value
        TargetCatalogSha256 = $production.Groups['target'].Value
        CurrentStateSha256 = $production.Groups['state'].Value
        PendingPlanSha256 = $production.Groups['pending'].Value
        ModuleCount = [int]$summary.Groups['modules'].Value
        TargetMigrationCount = [int]$summary.Groups['target'].Value
        AppliedMigrationCount = [int]$summary.Groups['applied'].Value
        PendingMigrationCount = [int]$summary.Groups['pending'].Value
    }
}

function Assert-BunkFyExpectedRejection {
    param(
        [Parameter(Mandatory = $true)][object] $Result,
        [Parameter(Mandatory = $true)][string] $ExpectedToken,
        [Parameter(Mandatory = $true)][string] $Context
    )

    if ($Result.ExitCode -eq 0) {
        throw "$Context unexpectedly succeeded."
    }
    $safeOutput = Protect-BunkFyOutput -Value ([string]$Result.Output)
    if (-not $safeOutput.Contains($ExpectedToken, [StringComparison]::Ordinal)) {
        throw "$Context failed for an unexpected reason.`n$safeOutput"
    }
}

function Assert-BunkFySchemaUnchanged {
    param(
        [Parameter(Mandatory = $true)][object] $Expected,
        [Parameter(Mandatory = $true)][string] $Context
    )

    $actual = Get-BunkFyDatabaseSchemaFingerprint
    if ($actual.Hash -cne $Expected.Hash -or $actual.Lines -ne $Expected.Lines) {
        throw "$Context mutated the rehearsal database schema."
    }
}

function Remove-BunkFyRehearsalResources {
    $cleanupFailures = [Collections.Generic.List[string]]::new()
    foreach ($containerName in @($createdContainers | Select-Object -Unique)) {
        $remove = Invoke-BunkFyDocker -Arguments @('rm', '--force', $containerName) -TimeoutSeconds 30
        if ($remove.ExitCode -ne 0 -and
            -not $remove.Output.Contains('No such container', [StringComparison]::OrdinalIgnoreCase)) {
            $cleanupFailures.Add("container '$containerName'")
        }
    }
    if ($networkCreated) {
        $removeNetwork = Invoke-BunkFyDocker -Arguments @('network', 'rm', $networkName) -TimeoutSeconds 30
        if ($removeNetwork.ExitCode -ne 0 -and
            -not $removeNetwork.Output.Contains('not found', [StringComparison]::OrdinalIgnoreCase)) {
            $cleanupFailures.Add("network '$networkName'")
        }
    }
    Remove-Item -LiteralPath $temporaryDirectory -Recurse -Force -ErrorAction SilentlyContinue
    if ($cleanupFailures.Count -gt 0) {
        throw "Could not remove rehearsal resources: $($cleanupFailures -join ', ')."
    }
}

try {
    New-Item -ItemType Directory -Path $temporaryDirectory -Force | Out-Null
    $backend = Resolve-BunkFyLocalImage -Reference $BackendImage -RequireRepositoryDigest
    $postgres = Resolve-BunkFyLocalImage `
        -Reference $PostgreSqlImage `
        -RequireRepositoryDigest

    Write-Host "Creating isolated migration target '$runId'."
    $network = Invoke-BunkFyDocker -Arguments @(
        'network',
        'create',
        '--internal',
        '--label', 'com.bunkfy.operation=production-migration-rehearsal',
        '--label', "com.bunkfy.rehearsal=$runId",
        $networkName)
    Assert-BunkFyDockerSuccess -Result $network -Context 'Creating the rehearsal network'
    $networkCreated = $true

    $postgresEnvironment = Write-BunkFyPrivateEnvironmentFile -Name 'postgres' -Values ([ordered]@{
        POSTGRES_DB = $databaseName
        POSTGRES_USER = $databaseUser
        POSTGRES_PASSWORD = $databasePassword
    })
    $createdContainers.Add($postgresName)
    $startPostgres = Invoke-BunkFyDocker -Arguments @(
        'run',
        '--detach',
        '--rm',
        '--name', $postgresName,
        '--label', 'com.bunkfy.operation=production-migration-rehearsal',
        '--label', "com.bunkfy.rehearsal=$runId",
        '--network', $networkName,
        '--network-alias', 'postgres',
        '--env-file', $postgresEnvironment,
        '--tmpfs', '/var/lib/postgresql/data:rw,nosuid,nodev,size=1g',
        $postgres.ImageId)
    Remove-Item -LiteralPath $postgresEnvironment -Force -ErrorAction SilentlyContinue
    Assert-BunkFyDockerSuccess -Result $startPostgres -Context 'Starting rehearsal PostgreSQL'

    $ready = $false
    $previousPostmasterStart = $null
    for ($attempt = 0; $attempt -lt 60; $attempt++) {
        $probe = Invoke-BunkFyDocker -Arguments @(
            'exec',
            $postgresName,
            'psql',
            '--no-psqlrc',
            '--tuples-only',
            '--no-align',
            '--set=ON_ERROR_STOP=1',
            "--username=$databaseUser",
            "--dbname=$databaseName",
            '--command', 'SELECT pg_postmaster_start_time();') -TimeoutSeconds 10
        $postmasterStart = ([string]$probe.Output).Trim()
        if ($probe.ExitCode -eq 0 -and
            -not [string]::IsNullOrWhiteSpace($postmasterStart)) {
            if ($postmasterStart -ceq $previousPostmasterStart) {
                $ready = $true
                break
            }
            $previousPostmasterStart = $postmasterStart
        }
        else {
            $previousPostmasterStart = $null
        }
        Start-Sleep -Seconds 1
    }
    if (-not $ready) {
        $logs = Invoke-BunkFyDocker -Arguments @('logs', $postgresName) -TimeoutSeconds 30
        throw "Rehearsal PostgreSQL did not become ready.`n$(Protect-BunkFyOutput $logs.Output)"
    }

    $containerInspect = Invoke-BunkFyDocker -Arguments @('container', 'inspect', $postgresName)
    Assert-BunkFyDockerSuccess -Result $containerInspect -Context 'Inspecting rehearsal PostgreSQL'
    $container = @(ConvertFrom-Json -InputObject $containerInspect.Output)[0]
    $attachedNetworks = @($container.NetworkSettings.Networks.PSObject.Properties.Name)
    $publishedPortCount = if ($null -eq $container.HostConfig.PortBindings) {
        0
    }
    else {
        @($container.HostConfig.PortBindings.PSObject.Properties).Count
    }
    if ($attachedNetworks.Count -ne 1 -or $attachedNetworks[0] -cne $networkName -or
        $publishedPortCount -ne 0) {
        throw 'Rehearsal PostgreSQL is not isolated on its private no-port network.'
    }
    $networkInspect = Invoke-BunkFyDocker -Arguments @('network', 'inspect', $networkName)
    Assert-BunkFyDockerSuccess -Result $networkInspect -Context 'Inspecting the rehearsal network'
    if (-not @(ConvertFrom-Json -InputObject $networkInspect.Output)[0].Internal) {
        throw 'The migration rehearsal network is not internal.'
    }

    $emptySchema = Get-BunkFyDatabaseSchemaFingerprint
    Write-Host 'Running Production migration plan.'
    $planResult = Invoke-BunkFyMigrationHost `
        -Phase 'plan' `
        -Mode Plan `
        -CommitSha $SourceCommitSha
    Assert-BunkFyDockerSuccess -Result $planResult -Context 'Production migration plan'
    $plan = Get-BunkFyPlanEvidence -Output $planResult.Output
    if ($plan.PendingMigrationCount -le 0 -or $plan.ModuleCount -le 0) {
        throw 'The empty rehearsal target did not produce a non-empty migration plan.'
    }
    Assert-BunkFySchemaUnchanged -Expected $emptySchema -Context 'Production Plan'

    Write-Host 'Checking Production admission failures.'
    $badSource = Invoke-BunkFyMigrationHost `
        -Phase 'reject-source' `
        -Mode Apply `
        -CommitSha 'not-a-source-commit' `
        -ApprovedDatabaseTargetSha256 $plan.DatabaseTargetSha256 `
        -ApprovedTargetCatalogSha256 $plan.TargetCatalogSha256 `
        -Approved
    Assert-BunkFyExpectedRejection `
        -Result $badSource `
        -ExpectedToken 'SourceCommitSha' `
        -Context 'Malformed source admission'
    Assert-BunkFySchemaUnchanged -Expected $emptySchema -Context 'Malformed source admission'

    $badBackup = Invoke-BunkFyMigrationHost `
        -Phase 'reject-backup' `
        -Mode Apply `
        -CommitSha $SourceCommitSha `
        -ApprovedDatabaseTargetSha256 $plan.DatabaseTargetSha256 `
        -ApprovedTargetCatalogSha256 $plan.TargetCatalogSha256 `
        -BackupEvidenceReference 'invalid backup reference' `
        -Approved
    Assert-BunkFyExpectedRejection `
        -Result $badBackup `
        -ExpectedToken 'BackupEvidenceReference' `
        -Context 'Malformed backup-evidence admission'
    Assert-BunkFySchemaUnchanged -Expected $emptySchema -Context 'Malformed backup-evidence admission'

    $wrongDatabaseHash = if ($plan.DatabaseTargetSha256[0] -ceq 'a') {
        'b' + $plan.DatabaseTargetSha256.Substring(1)
    }
    else {
        'a' + $plan.DatabaseTargetSha256.Substring(1)
    }
    $wrongTarget = Invoke-BunkFyMigrationHost `
        -Phase 'reject-target' `
        -Mode Apply `
        -CommitSha $SourceCommitSha `
        -ApprovedDatabaseTargetSha256 $wrongDatabaseHash `
        -ApprovedTargetCatalogSha256 $plan.TargetCatalogSha256 `
        -Approved
    Assert-BunkFyExpectedRejection `
        -Result $wrongTarget `
        -ExpectedToken 'ApprovedDatabaseTargetSha256' `
        -Context 'Wrong database-target admission'
    Assert-BunkFySchemaUnchanged -Expected $emptySchema -Context 'Wrong database-target admission'

    Write-Host 'Applying the approved migration plan.'
    $apply = Invoke-BunkFyMigrationHost `
        -Phase 'apply' `
        -Mode Apply `
        -CommitSha $SourceCommitSha `
        -ApprovedDatabaseTargetSha256 $plan.DatabaseTargetSha256 `
        -ApprovedTargetCatalogSha256 $plan.TargetCatalogSha256 `
        -Approved
    Assert-BunkFyDockerSuccess -Result $apply -Context 'Approved Production migration apply'
    if (-not $apply.Output.Contains(
            'All BunkFy PostgreSQL migrations are current.',
            [StringComparison]::Ordinal)) {
        throw 'The approved migration apply did not report a current catalogue.'
    }
    $appliedSchema = Get-BunkFyDatabaseSchemaFingerprint
    if ($appliedSchema.Hash -ceq $emptySchema.Hash) {
        throw 'The approved migration apply did not advance the empty target.'
    }

    $postApplyPlanResult = Invoke-BunkFyMigrationHost `
        -Phase 'post-apply-plan' `
        -Mode Plan `
        -CommitSha $SourceCommitSha
    Assert-BunkFyDockerSuccess -Result $postApplyPlanResult -Context 'Post-apply Production plan'
    $postApplyPlan = Get-BunkFyPlanEvidence -Output $postApplyPlanResult.Output
    if ($postApplyPlan.PendingMigrationCount -ne 0 -or
        $postApplyPlan.AppliedMigrationCount -ne $postApplyPlan.TargetMigrationCount -or
        $postApplyPlan.TargetCatalogSha256 -cne $plan.TargetCatalogSha256 -or
        $postApplyPlan.DatabaseTargetSha256 -cne $plan.DatabaseTargetSha256) {
        throw 'The approved apply did not reach the exact inspected migration target.'
    }

    Write-Host 'Re-running the approved apply to prove idempotence.'
    $rerun = Invoke-BunkFyMigrationHost `
        -Phase 'rerun' `
        -Mode Apply `
        -CommitSha $SourceCommitSha `
        -ApprovedDatabaseTargetSha256 $plan.DatabaseTargetSha256 `
        -ApprovedTargetCatalogSha256 $plan.TargetCatalogSha256 `
        -Approved
    Assert-BunkFyDockerSuccess -Result $rerun -Context 'Approved Production migration rerun'
    if (-not $rerun.Output.Contains(
            'All BunkFy PostgreSQL migrations are current.',
            [StringComparison]::Ordinal)) {
        throw 'The approved migration rerun did not report a current catalogue.'
    }
    Assert-BunkFySchemaUnchanged -Expected $appliedSchema -Context 'Approved apply rerun'

    $evidence = [ordered]@{
        schemaVersion = 1
        evidenceKind = 'bunkfy-production-migration-rehearsal'
        completedAtUtc = [DateTimeOffset]::UtcNow.ToString('O')
        runId = $runId
        sourceCommitSha = $SourceCommitSha
        images = [ordered]@{
            backend = [ordered]@{
                reference = $backend.Reference
                imageId = $backend.ImageId
                repositoryDigest = $backend.RepositoryDigest
            }
            postgresql = [ordered]@{
                reference = $postgres.Reference
                imageId = $postgres.ImageId
                repositoryDigest = $postgres.RepositoryDigest
            }
        }
        isolation = [ordered]@{
            internalNetwork = $true
            publishedPorts = 0
            persistentVolumes = 0
        }
        plan = [ordered]@{
            databaseTargetSha256 = $plan.DatabaseTargetSha256
            targetCatalogVersion = $plan.TargetCatalogVersion
            targetCatalogSha256 = $plan.TargetCatalogSha256
            currentStateSha256 = $plan.CurrentStateSha256
            pendingPlanSha256 = $plan.PendingPlanSha256
            moduleCount = $plan.ModuleCount
            targetMigrationCount = $plan.TargetMigrationCount
            appliedMigrationCount = $plan.AppliedMigrationCount
            pendingMigrationCount = $plan.PendingMigrationCount
            schemaFingerprintBefore = $emptySchema.Hash
            noMutation = $true
        }
        admission = [ordered]@{
            malformedSourceRejected = $true
            malformedBackupReferenceRejected = $true
            wrongDatabaseTargetRejected = $true
        }
        apply = [ordered]@{
            appliedMigrationCount = $postApplyPlan.AppliedMigrationCount
            pendingMigrationCount = $postApplyPlan.PendingMigrationCount
            resultingStateSha256 = $postApplyPlan.CurrentStateSha256
            schemaFingerprintAfter = $appliedSchema.Hash
            idempotentRerun = $true
        }
    }
}
catch {
    $failure = $_
}

try {
    Remove-BunkFyRehearsalResources
}
catch {
    if ($null -eq $failure) {
        $failure = $_
    }
    else {
        $failure = [InvalidOperationException]::new(
            "$($failure.Exception.Message) Cleanup also failed: $($_.Exception.Message)",
            $failure.Exception)
    }
}

if ($null -ne $failure) {
    throw $failure
}

$evidence.isolation.resourcesRemoved = $true
$outputDirectory = Split-Path -Parent $OutputPath
New-Item -ItemType Directory -Path $outputDirectory -Force | Out-Null
$evidence | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $OutputPath -Encoding utf8NoBOM
Write-Host "Production migration rehearsal passed: $OutputPath"
