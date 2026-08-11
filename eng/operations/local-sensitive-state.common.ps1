Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Test-BunkFyWindowsPlatform {
    return [Runtime.InteropServices.RuntimeInformation]::IsOSPlatform(
        [Runtime.InteropServices.OSPlatform]::Windows)
}

function Assert-BunkFyLocalPathAncestorsPhysical {
    param(
        [Parameter(Mandatory = $true)][string] $Path,
        [Parameter(Mandatory = $true)][string] $Description
    )

    $current = Split-Path -Parent ([IO.Path]::GetFullPath($Path))
    while (-not [string]::IsNullOrWhiteSpace($current)) {
        if (Test-Path -LiteralPath $current) {
            $item = Get-Item -LiteralPath $current -Force
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
                throw "$Description '$Path' has a reparse point or symbolic link ancestor."
            }
        }

        $parent = Split-Path -Parent $current
        if ([string]::IsNullOrWhiteSpace($parent) -or $parent -ceq $current) {
            break
        }
        $current = $parent
    }
}

function Get-BunkFyLocalSensitiveItem {
    param(
        [Parameter(Mandatory = $true)][string] $Path,
        [Parameter(Mandatory = $true)]
        [ValidateSet('Leaf', 'Container')]
        [string] $PathType,
        [Parameter(Mandatory = $true)][string] $Description
    )

    $fullPath = [IO.Path]::GetFullPath($Path)
    Assert-BunkFyLocalPathAncestorsPhysical `
        -Path $fullPath `
        -Description $Description
    if (-not (Test-Path -LiteralPath $fullPath -PathType $PathType)) {
        throw "$Description '$Path' does not exist as a $($PathType.ToLowerInvariant())."
    }

    $item = Get-Item -LiteralPath $fullPath -Force
    if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
        throw "$Description '$Path' must not be a reparse point or symbolic link."
    }

    return $item
}

function Get-BunkFyPrivateWindowsSecurityIdentifiers {
    $identifiers = [Collections.Generic.List[Security.Principal.SecurityIdentifier]]::new()
    $current = [Security.Principal.WindowsIdentity]::GetCurrent().User
    if ($null -eq $current) {
        throw 'Unable to resolve the current Windows security identity.'
    }

    $identifiers.Add($current)
    foreach ($value in @('S-1-5-18', 'S-1-5-32-544')) {
        $identifier = [Security.Principal.SecurityIdentifier]::new($value)
        if (-not ($identifiers | Where-Object { $_.Value -ceq $identifier.Value })) {
            $identifiers.Add($identifier)
        }
    }

    return $identifiers
}

function Set-BunkFyPrivateWindowsAcl {
    param(
        [Parameter(Mandatory = $true)][string] $Path,
        [Parameter(Mandatory = $true)]
        [ValidateSet('Leaf', 'Container')]
        [string] $PathType
    )

    $acl = Get-Acl -LiteralPath $Path
    $acl.SetAccessRuleProtection($true, $false)
    foreach ($rule in @($acl.Access)) {
        [void]$acl.RemoveAccessRuleSpecific($rule)
    }

    $identifiers = @(Get-BunkFyPrivateWindowsSecurityIdentifiers)
    $acl.SetOwner($identifiers[0])
    $inheritance = if ($PathType -eq 'Container') {
        [Security.AccessControl.InheritanceFlags]::ContainerInherit -bor
            [Security.AccessControl.InheritanceFlags]::ObjectInherit
    }
    else {
        [Security.AccessControl.InheritanceFlags]::None
    }
    foreach ($identifier in $identifiers) {
        $rule = [Security.AccessControl.FileSystemAccessRule]::new(
            $identifier,
            [Security.AccessControl.FileSystemRights]::FullControl,
            $inheritance,
            [Security.AccessControl.PropagationFlags]::None,
            [Security.AccessControl.AccessControlType]::Allow)
        [void]$acl.AddAccessRule($rule)
    }

    Set-Acl -LiteralPath $Path -AclObject $acl
}

function Assert-BunkFyPrivateWindowsAcl {
    param(
        [Parameter(Mandatory = $true)][string] $Path,
        [Parameter(Mandatory = $true)][string] $Description
    )

    $acl = Get-Acl -LiteralPath $Path
    if (-not $acl.AreAccessRulesProtected) {
        throw "$Description '$Path' inherits Windows access rules."
    }

    $allowed = [Collections.Generic.HashSet[string]]::new(
        [StringComparer]::Ordinal)
    $identifiers = @(Get-BunkFyPrivateWindowsSecurityIdentifiers)
    foreach ($identifier in $identifiers) {
        [void]$allowed.Add($identifier.Value)
    }

    $owner = $acl.GetOwner([Security.Principal.SecurityIdentifier])
    if (-not $allowed.Contains($owner.Value)) {
        throw "$Description '$Path' has an unexpected Windows owner."
    }

    $currentUserAllowed = $false
    $rules = $acl.GetAccessRules(
        $true,
        $true,
        [Security.Principal.SecurityIdentifier])
    foreach ($rule in $rules) {
        if ($rule.AccessControlType -ne
            [Security.AccessControl.AccessControlType]::Allow) {
            continue
        }

        $identity = $rule.IdentityReference.Value
        if (-not $allowed.Contains($identity)) {
            throw "$Description '$Path' grants Windows access outside the operator boundary."
        }
        if ($identity -ceq $identifiers[0].Value) {
            $currentUserAllowed = $true
        }
    }

    if (-not $currentUserAllowed) {
        throw "$Description '$Path' does not grant access to the current operator."
    }
}

function Protect-BunkFyLocalSensitivePath {
    param(
        [Parameter(Mandatory = $true)][string] $Path,
        [Parameter(Mandatory = $true)]
        [ValidateSet('Leaf', 'Container')]
        [string] $PathType,
        [string] $Description = 'Sensitive local path'
    )

    $item = Get-BunkFyLocalSensitiveItem `
        -Path $Path `
        -PathType $PathType `
        -Description $Description
    if (Test-BunkFyWindowsPlatform) {
        Set-BunkFyPrivateWindowsAcl -Path $item.FullName -PathType $PathType
    }
    else {
        $mode = if ($PathType -eq 'Container') {
            [IO.UnixFileMode]384 -bor [IO.UnixFileMode]64
        }
        else {
            [IO.UnixFileMode]384
        }
        [IO.File]::SetUnixFileMode($item.FullName, $mode)
    }

    Assert-BunkFyLocalSensitivePath `
        -Path $item.FullName `
        -PathType $PathType `
        -Description $Description
}

function Assert-BunkFyLocalSensitivePath {
    param(
        [Parameter(Mandatory = $true)][string] $Path,
        [Parameter(Mandatory = $true)]
        [ValidateSet('Leaf', 'Container')]
        [string] $PathType,
        [string] $Description = 'Sensitive local path'
    )

    $item = Get-BunkFyLocalSensitiveItem `
        -Path $Path `
        -PathType $PathType `
        -Description $Description
    if (Test-BunkFyWindowsPlatform) {
        Assert-BunkFyPrivateWindowsAcl `
            -Path $item.FullName `
            -Description $Description
        return
    }

    $mode = [int][IO.File]::GetUnixFileMode($item.FullName)
    $forbidden = if ($PathType -eq 'Container') {
        512 + 1024 + 2048 + 1 + 2 + 4 + 8 + 16 + 32
    }
    else {
        512 + 1024 + 2048 + 1 + 2 + 4 + 8 + 16 + 32 + 64
    }
    $required = if ($PathType -eq 'Container') { 256 + 64 } else { 256 }
    if (($mode -band $forbidden) -ne 0 -or
        ($mode -band $required) -ne $required) {
        $octal = [Convert]::ToString($mode, 8).PadLeft(4, '0')
        throw "$Description '$Path' has unsafe Unix mode $octal."
    }

    if ($PathType -eq 'Leaf') {
        $stream = $null
        try {
            $stream = [IO.File]::Open(
                $item.FullName,
                [IO.FileMode]::Open,
                [IO.FileAccess]::Read,
                [IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete)
        }
        catch {
            throw "$Description '$Path' is not readable by the current operator."
        }
        finally {
            if ($null -ne $stream) {
                $stream.Dispose()
            }
        }
    }
}

function New-BunkFyLocalSensitiveDirectory {
    param(
        [Parameter(Mandatory = $true)][string] $Path,
        [string] $Description = 'Sensitive local directory'
    )

    $fullPath = [IO.Path]::GetFullPath($Path)
    Assert-BunkFyLocalPathAncestorsPhysical `
        -Path $fullPath `
        -Description $Description
    if (Test-Path -LiteralPath $fullPath) {
        throw "$Description '$fullPath' already exists."
    }

    if (Test-BunkFyWindowsPlatform) {
        [void][IO.Directory]::CreateDirectory($fullPath)
    }
    else {
        [void][IO.Directory]::CreateDirectory(
            $fullPath,
            [IO.UnixFileMode]384 -bor [IO.UnixFileMode]64)
    }
    Protect-BunkFyLocalSensitivePath `
        -Path $fullPath `
        -PathType Container `
        -Description $Description
}

function Write-BunkFyLocalSensitiveTextFile {
    param(
        [Parameter(Mandatory = $true)][string] $Path,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string] $Content,
        [switch] $Overwrite,
        [string] $Description = 'Sensitive local file'
    )

    $fullPath = [IO.Path]::GetFullPath($Path)
    Assert-BunkFyLocalPathAncestorsPhysical `
        -Path $fullPath `
        -Description $Description
    $parent = Split-Path -Parent $fullPath
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
        throw "$Description parent directory '$parent' does not exist."
    }
    $parentItem = Get-Item -LiteralPath $parent -Force
    if ($parentItem.Attributes -band [IO.FileAttributes]::ReparsePoint) {
        throw "$Description parent directory '$parent' must not be a reparse point."
    }
    if (Test-Path -LiteralPath $fullPath) {
        [void](Get-BunkFyLocalSensitiveItem `
                -Path $fullPath `
                -PathType Leaf `
                -Description $Description)
        if (-not $Overwrite) {
            throw "$Description '$fullPath' already exists."
        }
    }

    $temporaryPath = Join-Path $parent (
        ".$([IO.Path]::GetFileName($fullPath)).$([Guid]::NewGuid().ToString('N')).tmp")
    try {
        $options = [IO.FileStreamOptions]::new()
        $options.Mode = [IO.FileMode]::CreateNew
        $options.Access = [IO.FileAccess]::Write
        $options.Share = [IO.FileShare]::None
        if (-not (Test-BunkFyWindowsPlatform)) {
            $options.UnixCreateMode = [IO.UnixFileMode]384
        }
        $stream = [IO.File]::Open($temporaryPath, $options)
        $stream.Dispose()
        Protect-BunkFyLocalSensitivePath `
            -Path $temporaryPath `
            -PathType Leaf `
            -Description 'Temporary sensitive local file'
        [IO.File]::WriteAllText(
            $temporaryPath,
            $Content,
            [Text.UTF8Encoding]::new($false))
        [IO.File]::Move($temporaryPath, $fullPath, [bool]$Overwrite)
        Protect-BunkFyLocalSensitivePath `
            -Path $fullPath `
            -PathType Leaf `
            -Description $Description
    }
    finally {
        if (Test-Path -LiteralPath $temporaryPath) {
            Remove-Item -LiteralPath $temporaryPath -Force
        }
    }
}

function Get-BunkFyLocalUnixIdentity {
    if (Test-BunkFyWindowsPlatform) {
        return $null
    }

    $userId = @(& id -u)
    if ($LASTEXITCODE -ne 0 -or $userId.Count -ne 1 -or
        [string]$userId[0] -cnotmatch '^\d+$') {
        throw 'Unable to resolve the current Unix user id.'
    }
    $groupId = @(& id -g)
    if ($LASTEXITCODE -ne 0 -or $groupId.Count -ne 1 -or
        [string]$groupId[0] -cnotmatch '^\d+$') {
        throw 'Unable to resolve the current Unix group id.'
    }

    return [pscustomobject]@{
        UserId = [string]$userId[0]
        GroupId = [string]$groupId[0]
    }
}

function Get-BunkFyLocalSensitiveTreeEntries {
    param(
        [Parameter(Mandatory = $true)][string] $Path,
        [string] $Description = 'Sensitive local tree'
    )

    $root = Get-BunkFyLocalSensitiveItem `
        -Path $Path `
        -PathType Container `
        -Description $Description
    $entries = @(Get-ChildItem -LiteralPath $root.FullName -Recurse -Force)
    foreach ($entry in $entries) {
        if ($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) {
            throw "$Description '$Path' contains a reparse point or symbolic link."
        }
    }

    return [pscustomobject]@{
        Root = $root
        Entries = $entries
    }
}

function Protect-BunkFyLocalSensitiveTree {
    param(
        [Parameter(Mandatory = $true)][string] $Path,
        [string] $Description = 'Sensitive local tree'
    )

    $tree = Get-BunkFyLocalSensitiveTreeEntries `
        -Path $Path `
        -Description $Description
    Protect-BunkFyLocalSensitivePath `
        -Path $tree.Root.FullName `
        -PathType Container `
        -Description $Description
    foreach ($entry in @($tree.Entries | Where-Object { $_.PSIsContainer })) {
        Protect-BunkFyLocalSensitivePath `
            -Path $entry.FullName `
            -PathType Container `
            -Description $Description
    }
    foreach ($entry in @($tree.Entries | Where-Object { -not $_.PSIsContainer })) {
        Protect-BunkFyLocalSensitivePath `
            -Path $entry.FullName `
            -PathType Leaf `
            -Description $Description
    }
}

function Assert-BunkFyLocalSensitiveTree {
    param(
        [Parameter(Mandatory = $true)][string] $Path,
        [string] $Description = 'Sensitive local tree'
    )

    $tree = Get-BunkFyLocalSensitiveTreeEntries `
        -Path $Path `
        -Description $Description
    Assert-BunkFyLocalSensitivePath `
        -Path $tree.Root.FullName `
        -PathType Container `
        -Description $Description
    foreach ($entry in $tree.Entries) {
        Assert-BunkFyLocalSensitivePath `
            -Path $entry.FullName `
            -PathType $(if ($entry.PSIsContainer) { 'Container' } else { 'Leaf' }) `
            -Description $Description
    }
}
