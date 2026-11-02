#Requires -Version 5.1
<#
.SYNOPSIS
    Step 4 - Add a forest UPN suffix and move users of the company OU onto it.
.DESCRIPTION
    Users are queried STRICTLY with -SearchBase <CompanyOuDN>, so built-in accounts in
    CN=Users (Administrator, krbtgt, Domain Admins members ...) are never touched.
#>
[CmdletBinding()]
param(
    [string]$ConfigPath = (Join-Path $PSScriptRoot 'config.psd1'),
    [switch]$WhatIfOnly
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib\Common.ps1')

try {
    Start-LabLog -Name '04_Configure-UpnSuffix'
    $cfg = Import-LabConfig -Path $ConfigPath
    Import-Module ActiveDirectory
    Set-LabAdServer -Server $cfg.Dc1Name

    $suffix     = $cfg.UpnSuffix
    $searchBase = $cfg.CompanyOuDN

    # ---- safety guards ----
    if ($searchBase -notmatch '^OU=') { throw "CompanyOuDN must point to an OU (got '$searchBase'). Refusing to run." }
    if ($searchBase -ieq $cfg.DomainDN -or $searchBase -imatch '^CN=Users') { throw 'SearchBase would include built-in accounts. Refusing to run.' }
    try { [void](Get-ADOrganizationalUnit -Identity $searchBase) } catch { throw "Company OU not found: $searchBase (run step 5 first)." }

    # ---- forest suffix ----
    $forest = Get-ADForest
    if ($suffix -in $forest.UPNSuffixes) { Write-Log INFO "UPN suffix '$suffix' already present in forest $($forest.Name)." }
    else {
        Set-ADForest -Identity $forest -UPNSuffixes @{ Add = $suffix }
        Write-Log SUCCESS "UPN suffix '$suffix' added to forest $($forest.Name)."
    }

    # ---- users ----
    $protectedSams = @('Administrator', 'Guest', 'krbtgt')
    $users = @(Get-ADUser -Filter * -SearchBase $searchBase -SearchScope Subtree -Properties UserPrincipalName)
    Write-Log INFO "Found $($users.Count) user(s) under $searchBase"
    $changed = 0; $skipped = 0; $failed = 0
    foreach ($u in $users) {
        try {
            if ($u.SamAccountName -in $protectedSams) { Write-Log WARNING "Skipping protected account $($u.SamAccountName)."; $skipped++; continue }
            $prefix = if ($u.UserPrincipalName) { ($u.UserPrincipalName -split '@')[0] } else { $u.SamAccountName }
            $newUpn = "$prefix@$suffix"
            if ($u.UserPrincipalName -ieq $newUpn) { Write-Log INFO "$($u.SamAccountName) already $newUpn"; $skipped++; continue }
            if ($WhatIfOnly) { Write-Log INFO "[WhatIf] $($u.SamAccountName): $($u.UserPrincipalName) -> $newUpn"; continue }
            Set-ADUser -Identity $u -UserPrincipalName $newUpn
            Write-Log SUCCESS "$($u.SamAccountName): $($u.UserPrincipalName) -> $newUpn"
            $changed++
        } catch {
            Write-Log ERROR "$($u.SamAccountName): $($_.Exception.Message)"
            $failed++
        }
    }
    Write-Log INFO "Summary: changed=$changed skipped=$skipped failed=$failed"
    if ($failed -gt 0) { throw "$failed user(s) failed - see log." }
    Write-Log SUCCESS 'Step 4 finished.'
    exit 0
}
catch {
    Write-Log ERROR "$($_.Exception.Message) (line $($_.InvocationInfo.ScriptLineNumber))"
    exit 1
}
