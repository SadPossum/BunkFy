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

function Get-BunkFySubmoduleConfig {
    $root = Get-BunkFyRepositoryRoot
    $gitModulesPath = Join-Path $root '.gitmodules'

    if (-not (Test-Path -LiteralPath $gitModulesPath -PathType Leaf)) {
        return @()
    }

    $lines = git -C $root config --file $gitModulesPath --get-regexp '^submodule\..*\.(path|url|branch)$'
    if ($LASTEXITCODE -ne 0) {
        throw "Unable to read submodule configuration from $gitModulesPath."
    }

    $entries = @{}
    foreach ($line in $lines) {
        if ($line -notmatch '^submodule\.(.+)\.(path|url|branch)\s+(.+)$') {
            continue
        }

        $name = $Matches[1]
        $key = $Matches[2]
        $value = $Matches[3]

        if (-not $entries.ContainsKey($name)) {
            $entries[$name] = [ordered]@{
                Name = $name
                Path = $null
                Url = $null
                Branch = $null
            }
        }

        switch ($key) {
            'path' { $entries[$name].Path = $value }
            'url' { $entries[$name].Url = $value }
            'branch' { $entries[$name].Branch = $value }
        }
    }

    $submodules = @()
    foreach ($name in ($entries.Keys | Sort-Object)) {
        $entry = $entries[$name]
        if ([string]::IsNullOrWhiteSpace($entry.Path)) {
            throw "Submodule '$name' does not declare a path."
        }

        if ([string]::IsNullOrWhiteSpace($entry.Branch)) {
            throw "Submodule '$name' does not declare a branch in .gitmodules."
        }

        $submodules += [pscustomobject]@{
            Name = $entry.Name
            Path = $entry.Path
            Url = $entry.Url
            Branch = $entry.Branch
        }
    }

    return $submodules
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

