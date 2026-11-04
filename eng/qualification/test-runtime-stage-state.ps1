$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$controller = Join-Path $PSScriptRoot 'rehearse-full-candidate.ps1'
$tokens = $null
$errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($controller, [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw 'Controller has syntax errors.' }
$function = $ast.Find({ param($node)
    $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq 'Set-QualificationStage'
}, $true)
if ($null -eq $function) { throw 'Actual stage function is missing.' }
Invoke-Expression $function.Extent.Text
$completion = $ast.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq 'Complete-QualificationCallback' }, $true)
if ($null -eq $completion) { throw 'Actual completion function is missing.' }
Invoke-Expression $completion.Extent.Text
$qualificationState = [ordered]@{ Stage = 'preflight'; CallbackCompleted = $false }
$stage = 'preflight'
function Set-OriginalScopeStage { $script:stage = 'real-onboarding-and-worker-restart' }
$directory = Join-Path ([IO.Path]::GetTempPath()) ('bunkfy-stage-scope-test-' + [Guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($directory)
try {
    $child = Join-Path $directory 'actual-child-script.ps1'
    [IO.File]::WriteAllText($child, "Set-OriginalScopeStage`nSet-QualificationStage 'real-onboarding-and-worker-restart'`nComplete-QualificationCallback`n")
    & $child
    if ($stage -cne 'preflight') { throw 'Original cross-script scope failure did not reproduce.' }
    if ($qualificationState.Stage -cne 'real-onboarding-and-worker-restart') { throw 'Actual shared stage setter did not update the parent report.' }
    if (-not $qualificationState.CallbackCompleted) { throw 'Actual callback completion did not update the parent report.' }
    Write-Host 'Original stage-report scope failure reproduced; actual shared stage/completion setters pass across child script.'
}
finally {
    if (Test-Path -LiteralPath (Join-Path $directory 'actual-child-script.ps1')) {
        Remove-Item -LiteralPath (Join-Path $directory 'actual-child-script.ps1') -Force
    }
    [IO.Directory]::Delete($directory)
}
