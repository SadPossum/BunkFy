[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[a-z0-9][a-z0-9.-]{1,63}$')]
    [string] $ArtifactName,

    [Parameter(Mandatory = $true)]
    [string] $InputPath,

    [Parameter(Mandatory = $true)]
    [string] $OutputDirectory,

    [ValidatePattern('^[A-Z]+(?:,[A-Z]+)*$')]
    [string] $Severity = 'HIGH,CRITICAL',

    [ValidatePattern('^[1-9][0-9]*[smh]$')]
    [string] $Timeout = '20m'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if (Test-Path -LiteralPath variable:PSNativeCommandUseErrorActionPreference) {
    $PSNativeCommandUseErrorActionPreference = $false
}

function Write-JsonDocument {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Path,

        [Parameter(Mandatory = $true)]
        [object] $Value
    )

    $json = $Value |
        ConvertTo-Json -Depth 12
    $content = $json.Replace("`r`n", "`n").TrimEnd() + "`n"
    [System.IO.File]::WriteAllText(
        $Path,
        $content,
        [System.Text.UTF8Encoding]::new($false))
}

$resolvedInputPath = [System.IO.Path]::GetFullPath($InputPath)
if (-not [System.IO.File]::Exists($resolvedInputPath)) {
    throw "OCI image archive '$resolvedInputPath' does not exist."
}

$resolvedOutputDirectory = [System.IO.Path]::GetFullPath($OutputDirectory)
[System.IO.Directory]::CreateDirectory($resolvedOutputDirectory) | Out-Null

$trivy = Get-Command trivy -CommandType Application -ErrorAction Stop
$tar = Get-Command tar -CommandType Application -ErrorAction Stop
$expandedOciDirectory = Join-Path `
    ([System.IO.Path]::GetTempPath()) `
    "bunkfy-$ArtifactName-oci-$([Guid]::NewGuid().ToString('N'))"
$rawReportPath = Join-Path `
    ([System.IO.Path]::GetTempPath()) `
    "bunkfy-$ArtifactName-$([Guid]::NewGuid().ToString('N')).json"
$sarifPath = Join-Path $resolvedOutputDirectory "$ArtifactName-trivy.sarif"
$sbomPath = Join-Path $resolvedOutputDirectory "$ArtifactName-sbom.cdx.json"
$summaryPath = Join-Path $resolvedOutputDirectory "$ArtifactName-scan-summary.json"

$scanExitCode = 2
$convertExitCode = 2
$sbomExitCode = 2
$severityCounts = [ordered]@{
    critical = 0
    high = 0
    medium = 0
    low = 0
    unknown = 0
}
$findingTypeCounts = [ordered]@{
    vulnerabilities = 0
    misconfigurations = 0
    secrets = 0
    licenses = 0
}

try {
    [System.IO.Directory]::CreateDirectory($expandedOciDirectory) | Out-Null
    & $tar.Source `
        '-xf' `
        $resolvedInputPath `
        '-C' `
        $expandedOciDirectory
    if ($LASTEXITCODE -ne 0) {
        throw "Could not expand OCI image archive '$resolvedInputPath'."
    }

    foreach ($requiredPath in @(
            (Join-Path $expandedOciDirectory 'oci-layout'),
            (Join-Path $expandedOciDirectory 'index.json')
        )) {
        if (-not [System.IO.File]::Exists($requiredPath)) {
            throw "OCI image archive '$resolvedInputPath' is missing '$requiredPath'."
        }
    }
    if (-not [System.IO.Directory]::Exists(
            (Join-Path $expandedOciDirectory 'blobs'))) {
        throw "OCI image archive '$resolvedInputPath' is missing its blob store."
    }

    $scanArguments = @(
        'image',
        '--input', $expandedOciDirectory,
        '--scanners', 'vuln,secret,misconfig,license',
        '--severity', $Severity,
        '--ignore-unfixed=false',
        '--exit-code', '1',
        '--format', 'json',
        '--output', $rawReportPath,
        '--timeout', $Timeout,
        '--skip-version-check'
    )
    & $trivy.Source @scanArguments
    $scanExitCode = $LASTEXITCODE

    if ([System.IO.File]::Exists($rawReportPath)) {
        $rawReport = [System.IO.File]::ReadAllText($rawReportPath) |
            ConvertFrom-Json
        foreach ($result in @($rawReport.Results)) {
            foreach ($findingGroup in @(
                    @{ Property = 'Vulnerabilities'; Bucket = 'vulnerabilities' },
                    @{ Property = 'Misconfigurations'; Bucket = 'misconfigurations' },
                    @{ Property = 'Secrets'; Bucket = 'secrets' },
                    @{ Property = 'Licenses'; Bucket = 'licenses' }
                )) {
                $property = $result.PSObject.Properties[$findingGroup.Property]
                if ($null -eq $property) {
                    continue
                }

                foreach ($finding in @($property.Value)) {
                    if ($null -eq $finding) {
                        continue
                    }

                    $findingTypeCounts[$findingGroup.Bucket]++
                    $severityValue = [string] $finding.Severity
                    $severityKey = if (
                        [string]::IsNullOrWhiteSpace($severityValue)) {
                        'unknown'
                    }
                    else {
                        $severityValue.ToLowerInvariant()
                    }
                    if (-not $severityCounts.Contains($severityKey)) {
                        $severityKey = 'unknown'
                    }
                    $severityCounts[$severityKey]++
                }
            }
        }

        $convertArguments = @(
            'convert',
            '--format', 'sarif',
            '--output', $sarifPath,
            $rawReportPath
        )
        & $trivy.Source @convertArguments
        $convertExitCode = $LASTEXITCODE
    }

    $sbomArguments = @(
        'image',
        '--input', $expandedOciDirectory,
        '--scanners', 'vuln',
        '--list-all-pkgs',
        '--format', 'cyclonedx',
        '--output', $sbomPath,
        '--timeout', $Timeout,
        '--skip-version-check'
    )
    & $trivy.Source @sbomArguments
    $sbomExitCode = $LASTEXITCODE

    $gateStatus = if (
        $scanExitCode -notin @(0, 1) -or
        $convertExitCode -ne 0 -or
        $sbomExitCode -ne 0) {
        'error'
    }
    elseif ($scanExitCode -eq 1) {
        'blocked'
    }
    else {
        'passed'
    }

    Write-JsonDocument `
        -Path $summaryPath `
        -Value ([ordered]@{
            schemaVersion = 1
            artifactName = $ArtifactName
            generatedAtUtc = [DateTimeOffset]::UtcNow.ToString('O')
            gateStatus = $gateStatus
            blockingSeverities = @($Severity.Split(','))
            scannerExitCodes = [ordered]@{
                scan = $scanExitCode
                sarif = $convertExitCode
                sbom = $sbomExitCode
            }
            counts = [ordered]@{
                bySeverity = $severityCounts
                byFindingType = $findingTypeCounts
            }
        })
}
finally {
    if ([System.IO.File]::Exists($rawReportPath)) {
        [System.IO.File]::Delete($rawReportPath)
    }
    if ([System.IO.Directory]::Exists($expandedOciDirectory)) {
        [System.IO.Directory]::Delete($expandedOciDirectory, $true)
    }
}

if ($scanExitCode -notin @(0, 1) -or
    $convertExitCode -ne 0 -or
    $sbomExitCode -ne 0) {
    throw "Image evidence generation failed for '$ArtifactName'."
}

if ($scanExitCode -eq 1) {
    throw "Image security findings block '$ArtifactName'."
}

Write-Host "Image security evidence passed for '$ArtifactName'."
