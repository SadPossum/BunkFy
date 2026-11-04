param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('emit', 'consume', 'partial-failure', 'early-rejection')]
    [string] $Mode,
    [string] $Path,
    [string] $ExpectedSha256,
    [long] $ExpectedLength,
    [string] $LiteralArgument
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ($LiteralArgument -cne 'space ; $(never-execute) ` quote" end') { exit 23 }
$stdout = [Console]::OpenStandardOutput()
$stderr = [Console]::OpenStandardError()
if ($Mode -ceq 'partial-failure') {
    $stdout.Write([byte[]](0, 255, 128, 0, 13, 10))
    [Console]::Error.WriteLine('PRIVATE_DATABASE_DIAGNOSTIC')
    exit 17
}
if ($Mode -ceq 'early-rejection') { exit 19 }
if ($Mode -ceq 'emit') {
    $source = [IO.File]::OpenRead($Path)
    try { $source.CopyTo($stdout, 81920) } finally { $source.Dispose() }
    exit 0
}

# Fill both native pipes before reading stdin. A sequential parent deadlocks.
$buffer = [byte[]]::new(81920)
for ($index = 0; $index -lt 16; $index++) {
    $stdout.Write($buffer)
    $stderr.Write($buffer)
}
$inputStream = [Console]::OpenStandardInput()
$hash = [Security.Cryptography.IncrementalHash]::CreateHash([Security.Cryptography.HashAlgorithmName]::SHA256)
$length = [long]0
try {
    while (($count = $inputStream.Read($buffer)) -gt 0) {
        $length += $count
        $hash.AppendData($buffer, 0, $count)
    }
    $digest = [Convert]::ToHexString($hash.GetHashAndReset()).ToLowerInvariant()
}
finally { $hash.Dispose() }
if ($length -ne $ExpectedLength -or $digest -cne $ExpectedSha256) { exit 29 }
