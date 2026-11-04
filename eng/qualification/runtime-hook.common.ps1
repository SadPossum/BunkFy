Set-StrictMode -Version Latest

function New-CodexCandidateRuntimeHook {
    param([Parameter(Mandatory)][string] $Source, [Parameter(Mandatory)][string] $OperationsDirectory)
    # The instrumentation is test-only. Preserve every original binding,
    # isolation, attestation and cleanup assertion around the one callback.
    $bytes = [Text.UTF8Encoding]::new($false).GetBytes($Source)
    $sha = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
    if ($sha -cne 'f150f591e82e4ad549378e29b107d8b9982c9b2ec4a2bbf2a1a8f808ac8d8233') {
        throw 'Candidate runtime operator changed; review the instrumentation before running it.'
    }
    $marker = '    & $previewIsolation -EnvironmentFile $environmentPath'
    if ([regex]::Matches($Source, [regex]::Escape($marker)).Count -ne 1) {
        throw 'Expected exactly one completed-isolation hook.'
    }
    $quotedDirectory = "'" + $OperationsDirectory.Replace("'", "''") + "'"
    $instrumented = $Source.Replace('$PSScriptRoot', $quotedDirectory)
    $callback = @'

    Invoke-CodexExactCandidateCanaries -EnvironmentPath $environmentPath `
        -PublicOrigin $publicOrigin -Project $projectName -Release $releaseId `
        -BackendReference $backendReference -WebReference $webReference
'@
    return $instrumented.Replace($marker, $marker + "`n" + $callback)
}
