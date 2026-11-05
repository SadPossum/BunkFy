function ConvertFrom-BunkFyPreviewBase32 {
    param([Parameter(Mandatory = $true)][string] $Value)

    $alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567'
    $normalized = $Value.Trim().TrimEnd('=').ToUpperInvariant()
    if ([string]::IsNullOrWhiteSpace($normalized)) {
        throw 'The TOTP enrollment secret is empty.'
    }

    $bytes = [Collections.Generic.List[byte]]::new()
    $buffer = 0
    $bitCount = 0
    foreach ($character in $normalized.ToCharArray()) {
        $digit = $alphabet.IndexOf($character)
        if ($digit -lt 0) {
            throw 'The TOTP enrollment secret is not valid Base32.'
        }

        $buffer = ($buffer -shl 5) -bor $digit
        $bitCount += 5
        while ($bitCount -ge 8) {
            $bitCount -= 8
            [void]$bytes.Add([byte](($buffer -shr $bitCount) -band 0xff))
            $buffer = if ($bitCount -eq 0) {
                0
            }
            else {
                $buffer -band ((1 -shl $bitCount) - 1)
            }
        }
    }

    if ($bytes.Count -lt 16) {
        throw 'The TOTP enrollment secret is shorter than the supported minimum.'
    }
    return ,$bytes.ToArray()
}

function Get-BunkFyPreviewTotpCode {
    param(
        [Parameter(Mandatory = $true)][string] $Secret,
        [DateTimeOffset] $AtUtc = [DateTimeOffset]::UtcNow,
        [ValidateSet(6, 8)][int] $Digits = 6
    )

    $key = ConvertFrom-BunkFyPreviewBase32 -Value $Secret
    $counterBytes = [BitConverter]::GetBytes(
        [long][Math]::Floor($AtUtc.ToUnixTimeSeconds() / 30.0))
    $hash = $null
    $hmac = $null
    try {
        if ([BitConverter]::IsLittleEndian) {
            [Array]::Reverse($counterBytes)
        }
        $hmac = [Security.Cryptography.HMACSHA1]::new($key)
        $hash = $hmac.ComputeHash($counterBytes)
        $offset = $hash[$hash.Length - 1] -band 0x0f
        $binary = (($hash[$offset] -band 0x7f) -shl 24) -bor
            (($hash[$offset + 1] -band 0xff) -shl 16) -bor
            (($hash[$offset + 2] -band 0xff) -shl 8) -bor
            ($hash[$offset + 3] -band 0xff)
        $modulus = if ($Digits -eq 8) { 100000000 } else { 1000000 }
        return ($binary % $modulus).ToString(
            "D$Digits",
            [Globalization.CultureInfo]::InvariantCulture)
    }
    finally {
        if ($null -ne $hash) {
            [Security.Cryptography.CryptographicOperations]::ZeroMemory($hash)
        }
        [Security.Cryptography.CryptographicOperations]::ZeroMemory($counterBytes)
        [Security.Cryptography.CryptographicOperations]::ZeroMemory($key)
        if ($null -ne $hmac) {
            $hmac.Dispose()
        }
    }
}
