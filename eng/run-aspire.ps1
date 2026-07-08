param(
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]] $DotNetArguments
)

. (Join-Path $PSScriptRoot 'common.ps1')

$projectPath = Join-BunkFyPath 'src\BunkFy.AppHost\BunkFy.AppHost.csproj'
$arguments = @('run', '--project', $projectPath)
$arguments += $DotNetArguments | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }

Invoke-BunkFyCommand -FilePath (Resolve-BunkFyDotNet) -Arguments $arguments -WorkingDirectory (Split-Path -Parent $projectPath)

