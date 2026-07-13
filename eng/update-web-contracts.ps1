param(
    [switch] $Check,
    [switch] $NoBuild
)

. (Join-Path $PSScriptRoot 'common.ps1')

$root = Get-BunkFyRepositoryRoot
$webRoot = Join-BunkFyPath 'apps\web'
$openApiPath = Join-Path $webRoot 'openapi\bunkfy-api.json'
$generatedPath = Join-Path $webRoot 'src\api\contracts.generated.ts'
$exporter = Join-BunkFyPath 'apps\backend\eng\export-openapi.ps1'

& $exporter -OutputPath $openApiPath -Check:$Check -NoBuild:$NoBuild
if ($LASTEXITCODE -ne 0) {
    throw "OpenAPI export failed with exit code $LASTEXITCODE."
}

$pnpm = Resolve-BunkFyPnpm
if (-not $Check) {
    Invoke-BunkFyCommand `
        -FilePath $pnpm `
        -Arguments @('exec', 'openapi-typescript', $openApiPath, '--properties-required-by-default', '--output', $generatedPath) `
        -WorkingDirectory $webRoot
    Write-Host "Web API contracts updated: $generatedPath"
    return
}

$temporaryDirectory = Join-BunkFyPath '.tmp\contracts'
[System.IO.Directory]::CreateDirectory($temporaryDirectory) | Out-Null
$temporaryGeneratedPath = Join-Path $temporaryDirectory 'contracts.generated.ts'

try {
    Invoke-BunkFyCommand `
        -FilePath $pnpm `
        -Arguments @('exec', 'openapi-typescript', $openApiPath, '--properties-required-by-default', '--output', $temporaryGeneratedPath) `
        -WorkingDirectory $webRoot

    if (-not (Test-Path -LiteralPath $generatedPath -PathType Leaf)) {
        throw "Generated API contracts '$generatedPath' are missing. Run update-web-contracts.ps1."
    }

    $expected = [System.IO.File]::ReadAllText($temporaryGeneratedPath).Replace("`r`n", "`n")
    $actual = [System.IO.File]::ReadAllText($generatedPath).Replace("`r`n", "`n")
    if ($actual -ne $expected) {
        throw "Generated API contracts are stale. Run update-web-contracts.ps1."
    }

    Write-Host 'Generated web API contracts are current.'
}
finally {
    if (Test-Path -LiteralPath $temporaryGeneratedPath -PathType Leaf) {
        Remove-Item -LiteralPath $temporaryGeneratedPath -Force
    }
}
