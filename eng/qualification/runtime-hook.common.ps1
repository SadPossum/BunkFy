Set-StrictMode -Version Latest

function Get-CodexSafeRuntimeFailure {
    param([Parameter(Mandatory)][Management.Automation.ErrorRecord] $Failure)
    $message = [string]$Failure.Exception.Message
    $category = if ($message -match "^Candidate image '.+' does not match its attested manifest[.]$") {
        'imported-image-identity-mismatch'
    } elseif ($message -match '^GitHub attestation verification failed for ') {
        'github-attestation-verification'
    } elseif ($message -match '^Loading candidate image .+ failed with exit code ') {
        'docker-oci-image-import'
    } elseif ($message -match '^Candidate Preview did not resolve the expected ') {
        'resolved-compose-images'
    } else { 'unclassified' }
    $frames = @()
    foreach ($line in ([string]$Failure.ScriptStackTrace -split '\r?\n')) {
        if ($line -notmatch '^at (?<function>[A-Za-z0-9_<>.-]+), (?<file>.+): line (?<number>[0-9]{1,7})$') { continue }
        $function = $Matches['function']
        $number = [int]$Matches['number']
        $file = [IO.Path]::GetFileName($Matches['file'])
        $role = switch -Regex ($file) {
            '^\.qualified-runtime-[a-f0-9]{32}\.ps1$' { 'instrumented-runtime-operator'; break }
            '^verify-image-candidate\.ps1$' { 'candidate-verifier'; break }
            '^image-candidate\.common\.ps1$' { 'candidate-format-helper'; break }
            '^rehearse-full-candidate\.ps1$' { 'full-runtime-controller'; break }
            default { 'other-reviewed-script' }
        }
        $frames += [ordered]@{ function = $function; scriptRole = $role; line = $number }
        if ($frames.Count -ge 10) { break }
    }
    $result = [ordered]@{ category = $category; type = $Failure.Exception.GetType().FullName; locations = $frames }
    if ($category -ceq 'docker-oci-image-import') {
        # Only fixed public Docker import markers, never arbitrary stderr text.
        if ($message -match '^Loading candidate image .+ failed with exit code (?<code>[0-9]{1,3})[.]') {
            $result['dockerExitCode'] = [int]$Matches['code']
        }
        $result['dockerImportMarkers'] = @(
            foreach ($marker in @('manifest.json','oci-layout','image index','unsupported','not supported',
                    'unrecognized','not found','no such file','invalid tar','permission denied',
                    'no space left','cannot connect','digest mismatch','archive/tar','platform')) {
                if ($message.Contains($marker,[StringComparison]::OrdinalIgnoreCase)) { $marker }
            })
    }
    return $result
}

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
