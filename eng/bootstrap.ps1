[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [switch] $SkipSubmodules,
    [switch] $SkipFrontendInstall,
    [switch] $SkipRestore,
    [switch] $Force
)

. (Join-Path $PSScriptRoot 'common.ps1')

function Write-BunkFySourceRootsFile {
    param(
        [Parameter(Mandatory = $true)][string] $Path,
        [Parameter(Mandatory = $true)][string[]] $Lines,
        [Parameter(Mandatory = $true)][string] $Description
    )

    if (Test-Path -LiteralPath $Path) {
        $existing = [System.IO.File]::ReadAllLines($Path)
        if (-not $Force -and [string]::Join("`n", $existing) -eq [string]::Join("`n", $Lines)) {
            Write-Host "$Description already configured: $Path"
            return
        }
    }

    $directory = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $directory -PathType Container)) {
        throw "Cannot write $Description because '$directory' does not exist. Initialize submodules first."
    }

    $action = if (Test-Path -LiteralPath $Path) { 'Refresh' } else { 'Create' }
    if ($PSCmdlet.ShouldProcess($Path, "$action $Description")) {
        [System.IO.File]::WriteAllLines($Path, $Lines, [System.Text.UTF8Encoding]::new($false))
        Write-Host "$action ${Description}: $Path"
    }
}

$root = Get-BunkFyRepositoryRoot

if (-not $SkipSubmodules) {
    Invoke-BunkFyCommand -FilePath git -Arguments @('submodule', 'sync', '--recursive')
    Invoke-BunkFyCommand -FilePath git -Arguments @('submodule', 'update', '--init', '--recursive')
}

$moduleAliases = @(
    'administration',
    'auth',
    'files',
    'notifications',
    'task-runtime',
    'tenancy'
)

$moduleRootProperties = @{
    'administration' = 'GmaModuleAdministrationRoot'
    'auth' = 'GmaModuleAuthRoot'
    'files' = 'GmaModuleFilesRoot'
    'notifications' = 'GmaModuleNotificationsRoot'
    'task-runtime' = 'GmaModuleTaskRuntimeRoot'
    'tenancy' = 'GmaModuleTenancyRoot'
}

$backendLines = New-Object 'System.Collections.Generic.List[string]'
$backendLines.Add('<Project>')
$backendLines.Add('  <PropertyGroup>')
$backendLines.Add('    <GmaFrameworkRoot>$(MSBuildThisFileDirectory)..\..\gma\framework\src\</GmaFrameworkRoot>')
$backendLines.Add('    <GmaModulesRoot>$(MSBuildThisFileDirectory)..\..\gma\modules\</GmaModulesRoot>')
foreach ($moduleAlias in $moduleAliases) {
    $propertyName = $moduleRootProperties[$moduleAlias]
    $backendLines.Add("    <$propertyName>`$(GmaModulesRoot)$moduleAlias\src\</$propertyName>")
}
$backendLines.Add('  </PropertyGroup>')
$backendLines.Add('</Project>')

Write-BunkFySourceRootsFile `
    -Path (Join-BunkFyPath 'apps\backend\Gma.SourceRoots.props') `
    -Lines $backendLines.ToArray() `
    -Description 'backend source-root configuration'

$frameworkLines = @(
    '<Project>',
    '  <PropertyGroup>',
    '    <GmaFrameworkRoot>$(MSBuildThisFileDirectory)src\</GmaFrameworkRoot>',
    '  </PropertyGroup>',
    '</Project>'
)

Write-BunkFySourceRootsFile `
    -Path (Join-BunkFyPath 'gma\framework\Gma.SourceRoots.props') `
    -Lines $frameworkLines `
    -Description 'framework source-root configuration'

$moduleLines = New-Object 'System.Collections.Generic.List[string]'
$moduleLines.Add('<Project>')
$moduleLines.Add('  <PropertyGroup>')
$moduleLines.Add('    <GmaFrameworkRoot>$(MSBuildThisFileDirectory)..\..\framework\src\</GmaFrameworkRoot>')
$moduleLines.Add('    <GmaModulesRoot>$(MSBuildThisFileDirectory)..\</GmaModulesRoot>')
foreach ($moduleAlias in $moduleAliases) {
    $propertyName = $moduleRootProperties[$moduleAlias]
    $moduleLines.Add("    <$propertyName>`$(GmaModulesRoot)$moduleAlias\src\</$propertyName>")
}
$moduleLines.Add('  </PropertyGroup>')
$moduleLines.Add('</Project>')

foreach ($moduleAlias in $moduleAliases) {
    Write-BunkFySourceRootsFile `
        -Path (Join-BunkFyPath "gma\modules\$moduleAlias\Gma.SourceRoots.props") `
        -Lines $moduleLines.ToArray() `
        -Description "$moduleAlias module source-root configuration"
}

if (-not $SkipFrontendInstall) {
    Invoke-BunkFyCommand `
        -FilePath (Resolve-BunkFyPnpm) `
        -Arguments @('--dir', (Join-BunkFyPath 'apps\web'), 'install', '--frozen-lockfile') `
        -WorkingDirectory $root
}

if (-not $SkipRestore) {
    Invoke-BunkFyCommand `
        -FilePath (Resolve-BunkFyDotNet) `
        -Arguments @('restore', (Join-BunkFyPath 'BunkFy.slnx')) `
        -WorkingDirectory $root
}

Write-Host 'BunkFy bootstrap complete.'

