#Requires -Version 5.1
<#
.SYNOPSIS
    Step 5 - Deploy the corporate OU hierarchy (idempotent). Run this FIRST in practice.
.DESCRIPTION
    <Domain>
      +-- <CompanyOuName>
            +-- Board / HR / IT / Finance / Operations   (see OrgStructure in config.psd1)
                  +-- Users / Groups / Computers
#>
[CmdletBinding()]
param([string]$ConfigPath = (Join-Path $PSScriptRoot 'config.psd1'))
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib\Common.ps1')

function Confirm-LabOU {
    param([string]$Name, [string]$ParentDN, [bool]$Protect)
    $dn = "OU=$Name,$ParentDN"
    $found = Get-ADOrganizationalUnit -Filter "Name -eq '$(Get-LabSqlSafe $Name)'" -SearchBase $ParentDN -SearchScope OneLevel -ErrorAction SilentlyContinue
    if ($found) { Write-Log INFO "OU exists:  $dn"; return $dn }
    New-ADOrganizationalUnit -Name $Name -Path $ParentDN -ProtectedFromAccidentalDeletion $Protect
    Write-Log SUCCESS "OU created: $dn"
    $script:created++
    return $dn
}

try {
    Start-LabLog -Name '05_Deploy-OrganizationalUnits'
    $cfg = Import-LabConfig -Path $ConfigPath
    Import-Module ActiveDirectory
    Set-LabAdServer -Server $cfg.Dc1Name
    $script:created = 0
    $protect = [bool]$cfg.ProtectOUs

    $root = Confirm-LabOU -Name $cfg.CompanyOuName -ParentDN $cfg.DomainDN -Protect $protect
    foreach ($dept in $cfg.OrgStructure) {
        $deptDn = Confirm-LabOU -Name $dept.Name -ParentDN $root -Protect $protect
        foreach ($sub in $dept.SubOUs) { [void](Confirm-LabOU -Name $sub -ParentDN $deptDn -Protect $protect) }
    }
    Write-Log SUCCESS "Step 5 finished. New OUs created this run: $script:created"
    exit 0
}
catch {
    Write-Log ERROR "$($_.Exception.Message) (line $($_.InvocationInfo.ScriptLineNumber))"
    exit 1
}
