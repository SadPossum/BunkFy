param(
    [string] $OutputPath = 'artifacts/gma-source-set.json',
    [switch] $RequireClean
)

. (Join-Path $PSScriptRoot 'common.ps1')

$repositoryRoot = Get-BunkFyRepositoryRoot
$implementation = Join-BunkFyPath `
    'apps/backend/gma/framework/eng/export-source-set.ps1'
if (-not (Test-Path -LiteralPath $implementation -PathType Leaf)) {
    throw 'GMA framework tooling is not mounted. Run eng/sync-submodules.ps1 first.'
}

& $implementation `
    @PSBoundParameters `
    -RepositoryRoot $repositoryRoot `
    -Recursive
