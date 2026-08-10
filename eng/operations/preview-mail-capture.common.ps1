Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-BunkFyMailpitMessagesForRecipient {
    param(
        [Parameter(Mandatory = $true)][object] $MessageList,
        [Parameter(Mandatory = $true)][string] $Recipient
    )

    try {
        $address = [Net.Mail.MailAddress]::new($Recipient.Trim())
    }
    catch {
        throw 'Recipient must be one plain email address.'
    }
    if (-not $address.Address.Equals(
            $Recipient.Trim(),
            [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Recipient must be one plain email address.'
    }

    $messagesProperty = $MessageList.PSObject.Properties['messages']
    if ($null -eq $messagesProperty -or $null -eq $messagesProperty.Value) {
        throw 'Mailpit message-list response is missing messages.'
    }

    $matches = [Collections.Generic.List[object]]::new()
    foreach ($message in @($messagesProperty.Value)) {
        $idProperty = $message.PSObject.Properties['ID']
        $toProperty = $message.PSObject.Properties['To']
        if ($null -eq $idProperty -or
            [string]::IsNullOrWhiteSpace([string]$idProperty.Value) -or
            $null -eq $toProperty -or
            $null -eq $toProperty.Value) {
            throw 'Mailpit returned an invalid message summary.'
        }

        $recipientMatches = @($toProperty.Value | Where-Object {
                $candidate = $_.PSObject.Properties['Address']
                $null -ne $candidate -and
                [string]$candidate.Value -ceq $address.Address
            })
        if ($recipientMatches.Count -eq 0) {
            $recipientMatches = @($toProperty.Value | Where-Object {
                    $candidate = $_.PSObject.Properties['Address']
                    $null -ne $candidate -and
                    [string]$candidate.Value -ieq $address.Address
                })
        }
        if ($recipientMatches.Count -gt 0) {
            $matches.Add($message)
        }
    }

    return @($matches)
}

function Get-BunkFyMailpitVerificationCode {
    param([Parameter(Mandatory = $true)][object] $Message)

    $textProperty = $Message.PSObject.Properties['Text']
    if ($null -eq $textProperty -or
        [string]::IsNullOrWhiteSpace([string]$textProperty.Value)) {
        throw 'Mailpit verification message has no plain-text body.'
    }

    $matches = [Text.RegularExpressions.Regex]::Matches(
        [string]$textProperty.Value,
        '(?m)^\s*Use this one-time verification code:\s*([A-Za-z0-9+/=]{32,256})\s*$')
    if ($matches.Count -ne 1) {
        throw 'Mailpit verification message must contain exactly one bounded verification code.'
    }

    $code = $matches[0].Groups[1].Value
    $decoded = $null
    try {
        $decoded = [Convert]::FromBase64String($code)
        if ($decoded.Length -lt 32 -or $decoded.Length -gt 128) {
            throw 'Mailpit verification code has an invalid decoded length.'
        }
    }
    catch [FormatException] {
        throw 'Mailpit verification code is not valid Base64.'
    }
    finally {
        if ($null -ne $decoded) {
            [Array]::Clear($decoded, 0, $decoded.Length)
        }
    }

    return $code
}
