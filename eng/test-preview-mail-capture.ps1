Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'operations\preview-mail-capture.common.ps1')

$codeBytes = [byte[]](1..64)
$code = [Convert]::ToBase64String($codeBytes)
[Array]::Clear($codeBytes, 0, $codeBytes.Length)

$list = [pscustomobject]@{
    messages = @(
        [pscustomobject]@{
            ID = 'target-message'
            To = @([pscustomobject]@{ Address = 'Smoke.User@Example.Test' })
        },
        [pscustomobject]@{
            ID = 'other-message'
            To = @([pscustomobject]@{ Address = 'other@example.test' })
        }
    )
}

$matches = @(Get-BunkFyMailpitMessagesForRecipient `
        -MessageList $list `
        -Recipient 'smoke.user@example.test')
if ($matches.Count -ne 1 -or [string]$matches[0].ID -cne 'target-message') {
    throw 'Mailpit recipient matching did not preserve exact case-insensitive address semantics.'
}

$message = [pscustomobject]@{
    Text = "Verify your address.`n`nUse this one-time verification code: $code`n"
}
$parsed = Get-BunkFyMailpitVerificationCode -Message $message
if ($parsed -cne $code) {
    throw 'Mailpit verification-code parsing changed the captured code.'
}
$parsed = $null
$code = $null

foreach ($invalid in @(
        [pscustomobject]@{ Text = 'No verification marker.' },
        [pscustomobject]@{
            Text = "Use this one-time verification code: YWJj`nUse this one-time verification code: YWJj"
        })) {
    $rejected = $false
    try {
        [void](Get-BunkFyMailpitVerificationCode -Message $invalid)
    }
    catch {
        $rejected = $true
    }
    if (-not $rejected) {
        throw 'Mailpit verification-code parsing accepted an ambiguous or invalid message.'
    }
}

Write-Host 'BunkFy Preview mail-capture fixture passed.'
