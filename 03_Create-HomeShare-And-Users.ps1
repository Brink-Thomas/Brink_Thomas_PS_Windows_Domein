#Requires -Version 5.1
<#
.SYNOPSIS
    Step 3 - Build the Homes share on MS, then create AD users with personal home folders.
.DESCRIPTION
    Run from DC1 (needs ActiveDirectory module + WinRM to MS).
    Share:  <HomeRootPath> on MS, SMB share <ShareName> (Everyone = Full),
            NTFS: inheritance disabled (ACEs copied), Administrators + Domain Admins = Full Control,
            Authenticated Users = Read & Execute on "This folder only".
    Users:  columns FirstName, LastName, SamAccountName, OUPath, Group, Password
            OUPath may contain the {DomainDN} placeholder.
.NOTES
    Passwords in CSV are plain text - lab use only.
#>
[CmdletBinding()]
param(
    [string]$ConfigPath = (Join-Path $PSScriptRoot 'config.psd1'),
    [string]$InputFile,
    [switch]$SkipShare,
    [switch]$SkipUsers
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib\Common.ps1')

# ---------------------------------------------------------------------------
# Remote block 1: share + root folder ACL (executes ON the member server)
# ---------------------------------------------------------------------------
$shareBlock = {
    param($Path, $ShareName, $NetBios)
    $ErrorActionPreference = 'Stop'
    function L($lvl, $msg) { [pscustomobject]@{ Level = $lvl; Message = $msg } }
    function SidName($sidString) { (New-Object System.Security.Principal.SecurityIdentifier $sidString).Translate([System.Security.Principal.NTAccount]) }

    $everyone = SidName 'S-1-1-0'
    $authUsers = SidName 'S-1-5-11'
    $admins   = SidName 'S-1-5-32-544'
    $users    = SidName 'S-1-5-32-545'
    $system   = SidName 'S-1-5-18'

    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -Path $Path -ItemType Directory -Force | Out-Null
        L SUCCESS "Created directory $Path"
    } else { L INFO "Directory $Path already exists." }

    if (-not (Get-SmbShare -Name $ShareName -ErrorAction SilentlyContinue)) {
        New-SmbShare -Name $ShareName -Path $Path -FullAccess $everyone.Value -Description 'User home folders' | Out-Null
        L SUCCESS "SMB share '$ShareName' created (Everyone: Full Control)."
    } else {
        Grant-SmbShareAccess -Name $ShareName -AccountName $everyone.Value -AccessRight Full -Force | Out-Null
        L INFO "SMB share '$ShareName' exists - Everyone: Full Control enforced."
    }
    Set-SmbShare -Name $ShareName -FolderEnumerationMode AccessBased -Force | Out-Null

    # --- NTFS: disable inheritance, keep copies of inherited ACEs ---
    $acl = Get-Acl -LiteralPath $Path
    $acl.SetAccessRuleProtection($true, $true)
    Set-Acl -LiteralPath $Path -AclObject $acl
    $acl = Get-Acl -LiteralPath $Path

    $domainAdmins = $null
    try { $domainAdmins = New-Object System.Security.Principal.NTAccount("$NetBios\Domain Admins"); [void]$domainAdmins.Translate([System.Security.Principal.SecurityIdentifier]) }
    catch { $domainAdmins = $null; L WARNING 'Could not resolve Domain Admins - only local Administrators granted.' }

    # remove the identities we manage + BUILTIN\Users (so ordinary users cannot create folders here)
    foreach ($id in @($admins, $system, $authUsers, $users, $domainAdmins)) { if ($id) { $acl.PurgeAccessRules($id) } }

    $InhF = [System.Security.AccessControl.InheritanceFlags]
    $PF = [System.Security.AccessControl.PropagationFlags]
    $FS = [System.Security.AccessControl.FileSystemRights]
    $AC = [System.Security.AccessControl.AccessControlType]
    $full = $FS::FullControl
    $subtree = [System.Security.AccessControl.InheritanceFlags]'ContainerInherit,ObjectInherit'
    $none = $PF::None

    foreach ($id in @($admins, $system, $domainAdmins)) {
        if ($id) { $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule($id, $full, $subtree, $none, $AC::Allow))) }
    }
    # Authenticated Users: Read & Execute, THIS FOLDER ONLY
    $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule($authUsers, $FS::ReadAndExecute, $InhF::None, $none, $AC::Allow)))
    Set-Acl -LiteralPath $Path -AclObject $acl
    L SUCCESS "NTFS ACL applied on ${Path}: Administrators/Domain Admins Full; Authenticated Users Read&Execute (this folder only)."
}

# ---------------------------------------------------------------------------
# Remote block 2: per-user folder + owner/permissions (executes ON the member server)
# ---------------------------------------------------------------------------
$folderBlock = {
    param($Root, $Sam, $NetBios)
    $ErrorActionPreference = 'Stop'
    function L($lvl, $msg) { [pscustomobject]@{ Level = $lvl; Message = $msg } }
    $folder = Join-Path $Root $Sam
    if (-not (Test-Path -LiteralPath $folder)) { New-Item -Path $folder -ItemType Directory -Force | Out-Null; L SUCCESS "Created $folder" }
    else { L INFO "Folder $folder already exists." }

    # wait for the new account to be visible to this server's DC
    $acct = New-Object System.Security.Principal.NTAccount("$NetBios\$Sam")
    $sid = $null
    for ($i = 1; $i -le 10 -and -not $sid; $i++) {
        try { $sid = $acct.Translate([System.Security.Principal.SecurityIdentifier]) } catch { Start-Sleep -Seconds 3 }
    }
    if (-not $sid) { throw "Account $NetBios\$Sam could not be resolved on this server (AD replication delay?)." }

    $admins = (New-Object System.Security.Principal.SecurityIdentifier 'S-1-5-32-544')
    $system = (New-Object System.Security.Principal.SecurityIdentifier 'S-1-5-18')
    $da = $null
    try { $da = (New-Object System.Security.Principal.NTAccount("$NetBios\Domain Admins")).Translate([System.Security.Principal.SecurityIdentifier]) } catch { }

    $acl = Get-Acl -LiteralPath $folder
    $acl.SetAccessRuleProtection($true, $false)                       # block inheritance, drop inherited ACEs
    foreach ($r in @($acl.Access)) { [void]$acl.RemoveAccessRule($r) }
    $inh = [System.Security.AccessControl.InheritanceFlags]'ContainerInherit,ObjectInherit'
    foreach ($id in @($admins, $system, $da, $sid)) {
        if ($id) {
            $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule($id, 'FullControl', $inh, 'None', 'Allow')))
        }
    }
    Set-Acl -LiteralPath $folder -AclObject $acl

    # icacls enables SeRestorePrivilege, which Set-Acl does not - needed to assign another user as owner
    $out = & icacls.exe $folder /setowner "$NetBios\$Sam" /C /Q 2>&1
    if ($LASTEXITCODE -ne 0) { throw "icacls /setowner failed: $out" }
    L SUCCESS "Folder $folder : owner and Full Control set for $NetBios\$Sam."
}

try {
    Start-LabLog -Name '03_Create-HomeShare-And-Users'
    $cfg = Import-LabConfig -Path $ConfigPath
    $ms  = $cfg.MsHostname
    $failed = 0

    # ---- Part A: share on MS -------------------------------------------------
    if (-not $SkipShare) {
        Write-Log INFO "Configuring home share on $ms ..."
        $res = Invoke-OnHost -ComputerName $ms -ScriptBlock $shareBlock -ArgumentList $cfg.HomeRootPath, $cfg.ShareName, $cfg.DomainNetBios
        foreach ($o in @($res | Where-Object { $_.PSObject.Properties.Name -contains 'Level' })) { Write-Log $o.Level $o.Message }
    } else { Write-Log WARNING 'Share setup skipped (-SkipShare).' }

    # ---- Part B: users on DC1 ----------------------------------------------
    if (-not $SkipUsers) {
        Import-Module ActiveDirectory
        Set-LabAdServer -Server $cfg.Dc1Name
        $file = Resolve-LabInputFile -Path $InputFile -DataFolder (Join-Path $global:LabRoot $cfg.DataFolder) -BaseName 'users'
        $rows = Import-LabData -Path $file -RequiredColumns 'FirstName','LastName','SamAccountName','OUPath','Group','Password'
        $n = 0
        foreach ($r in $rows) {
            $n++
            $sam = ([string]$r.SamAccountName).Trim()
            try {
                if (-not $sam) { throw 'SamAccountName is empty.' }
                $ou = Expand-LabDN -Value ([string]$r.OUPath) -DomainDN $cfg.DomainDN

                # -- target OU must exist --
                try { [void](Get-ADOrganizationalUnit -Identity $ou) } catch { throw "Target OU does not exist: $ou (run 05_Deploy-OrganizationalUnits.ps1 first)." }

                # -- user --
                $homeDir = "\\$ms\$($cfg.ShareName)\$sam"
                if (Get-ADUser -Filter "SamAccountName -eq '$(Get-LabSqlSafe $sam)'" -ErrorAction SilentlyContinue) {
                    Write-Log INFO "User $sam already exists - ensuring group and folder."
                } else {
                    $secure = ConvertTo-SecureString -String ([string]$r.Password) -AsPlainText -Force
                    New-ADUser -Name "$($r.FirstName) $($r.LastName)" -GivenName $r.FirstName -Surname $r.LastName `
                        -DisplayName "$($r.FirstName) $($r.LastName)" -SamAccountName $sam `
                        -UserPrincipalName "$sam@$($cfg.DomainFqdn)" -Path $ou `
                        -AccountPassword $secure -Enabled $true -ChangePasswordAtLogon $cfg.ChangePasswordAtLogon `
                        -HomeDrive $cfg.HomeDrive -HomeDirectory $homeDir
                    Write-Log SUCCESS "User $sam created in $ou (home: $homeDir)"
                }

                # -- group --
                $gName = ([string]$r.Group).Trim()
                if ($gName) {
                    $g = Get-ADGroup -Filter "Name -eq '$(Get-LabSqlSafe $gName)' -or SamAccountName -eq '$(Get-LabSqlSafe $gName)'" -ErrorAction SilentlyContinue
                    if (-not $g) {
                        if (-not $cfg.CreateMissingGroups) { throw "Group '$gName' does not exist." }
                        # place group in the sibling "Groups" OU when the user's OU is ...OU=Users,<dept>
                        $gPath = if ($ou -like 'OU=Users,*') { 'OU=Groups,' + $ou.Substring(9) } else { $ou }
                        try { [void](Get-ADOrganizationalUnit -Identity $gPath) } catch { $gPath = $ou }
                        $g = New-ADGroup -Name $gName -SamAccountName $gName -GroupScope Global -GroupCategory Security -Path $gPath -PassThru
                        Write-Log SUCCESS "Group $gName created in $gPath"
                    }
                    $member = (Get-ADUser -Identity $sam -Properties MemberOf).MemberOf
                    if ($g.DistinguishedName -in $member) { Write-Log INFO "$sam already member of $gName." }
                    else { Add-ADGroupMember -Identity $g -Members $sam; Write-Log SUCCESS "$sam added to $gName." }
                }

                # -- personal folder on MS --
                $res = Invoke-OnHost -ComputerName $ms -ScriptBlock $folderBlock -ArgumentList $cfg.HomeRootPath, $sam, $cfg.DomainNetBios
                foreach ($o in @($res | Where-Object { $_.PSObject.Properties.Name -contains 'Level' })) { Write-Log $o.Level $o.Message }
            }
            catch {
                Write-Log ERROR "Row ${n} ($sam): $($_.Exception.Message)"
                $failed++
            }
        }
    } else { Write-Log WARNING 'User creation skipped (-SkipUsers).' }

    if ($failed -gt 0) { throw "$failed user row(s) failed - see log." }
    Write-Log SUCCESS 'Step 3 finished.'
    exit 0
}
catch {
    Write-Log ERROR "$($_.Exception.Message) (line $($_.InvocationInfo.ScriptLineNumber))"
    exit 1
}
