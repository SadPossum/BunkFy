param(
    [switch] $SkipBootstrap,
    [switch] $SkipFetch
)

& (Join-Path $PSScriptRoot 'sync-submodules.ps1') -SkipBootstrap:$SkipBootstrap -SkipFetch:$SkipFetch
