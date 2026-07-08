Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:RepositoryRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path

function Get-BunkFyRepositoryRoot {
    return $script:RepositoryRoot
}

function Join-BunkFyPath {
    param([Parameter(Mandatory = $true)][string] $Path)
    return Join-Path $script:RepositoryRoot $Path
}

function Resolve-BunkFyDotNet {
    if (-not [string]::IsNullOrWhiteSpace($env:BUNKFY_DOTNET)) {
        return $env:BUNKFY_DOTNET
    }

    return 'dotnet'
}

function Resolve-BunkFyPnpm {
    if (-not [string]::IsNullOrWhiteSpace($env:BUNKFY_PNPM)) {
        return $env:BUNKFY_PNPM
    }

    return 'pnpm'
}

function Resolve-BunkFyGitHubCli {
    if (-not [string]::IsNullOrWhiteSpace($env:BUNKFY_GH)) {
        return $env:BUNKFY_GH
    }

    $pathGh = Get-Command gh -ErrorAction SilentlyContinue
    if ($pathGh) {
        return $pathGh.Source
    }

    $standardPath = 'C:\Program Files\GitHub CLI\gh.exe'
    if (Test-Path -LiteralPath $standardPath) {
        return $standardPath
    }

    return $null
}

function Invoke-BunkFyCommand {
    param(
        [Parameter(Mandatory = $true)][string] $FilePath,
        [string[]] $Arguments = @(),
        [string] $WorkingDirectory = $script:RepositoryRoot
    )

    Push-Location -LiteralPath $WorkingDirectory
    try {
        & $FilePath @Arguments
        if ($LASTEXITCODE -ne 0) {
            throw "$FilePath $($Arguments -join ' ') failed with exit code $LASTEXITCODE."
        }
    }
    finally {
        Pop-Location
    }
}

