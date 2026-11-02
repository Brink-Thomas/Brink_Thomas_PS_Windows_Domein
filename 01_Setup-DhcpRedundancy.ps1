#Requires -Version 5.1
<#
.SYNOPSIS
    Step 1 - Install/authorize DHCP on DC2 and build DHCP failover with DC1.
.DESCRIPTION
    Run on DC2, or remotely from DC1 (needs WinRM + domain admin rights).
    1. Install DHCP role + RSAT management tools on DC2 (if missing)
    2. Authorize DC2 in Active Directory
    3. Clear the Server Manager post-install flag (Roles\12 -> ConfigurationState = 2)
    4. Create DHCP failover relationship DC1 <-> DC2 and replicate
    5. Give DC2 a swapped Option 006 (DC2 IP first, DC1 IP second)
#>
[CmdletBinding()]
param(
    [string]$ConfigPath = (Join-Path $PSScriptRoot 'config.psd1'),
    [switch]$SkipFailover
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib\Common.ps1')

try {
    Start-LabLog -Name '01_Setup-DhcpRedundancy'
    $cfg    = Import-LabConfig -Path $ConfigPath
    $dc1    = $cfg.Dc1Name;  $dc1Ip = $cfg.Dc1Ip
    $dc2    = $cfg.Dc2Name;  $dc2Ip = $cfg.Dc2Ip
    $dc2Fqdn = "$dc2.$($cfg.DomainFqdn)"
    $dc2Remote = -not (Test-IsLocalHost $dc2)
    $cn = @{}; if ($dc2Remote) { $cn.ComputerName = $dc2 }

    # ---- 1. Roles / tools ---------------------------------------------------
    Write-Log INFO "Checking DHCP role and RSAT tools on $dc2 ..."
    $features = Get-WindowsFeature -Name 'DHCP', 'RSAT-DHCP' @cn
    foreach ($f in $features) {
        if ($f.Installed) { Write-Log INFO "Feature '$($f.Name)' already installed on $dc2." }
        else {
            Write-Log INFO "Installing feature '$($f.Name)' on $dc2 ..."
            $r = Install-WindowsFeature -Name $f.Name -IncludeManagementTools @cn
            if (-not $r.Success) { throw "Installation of '$($f.Name)' failed on $dc2." }
            Write-Log SUCCESS "Feature '$($f.Name)' installed (restart needed: $($r.RestartNeeded))."
        }
    }
    # The machine running this script also needs the DhcpServer cmdlets.
    if (-not (Get-Module -ListAvailable -Name DhcpServer)) {
        Write-Log INFO 'DhcpServer PowerShell module missing locally - installing RSAT-DHCP ...'
        Install-WindowsFeature -Name RSAT-DHCP | Out-Null
    }
    Import-Module DhcpServer

    # ---- 2. Authorize DC2 in AD --------------------------------------------
    Write-Log INFO "Checking DHCP authorization of $dc2Fqdn ..."
    $auth = @(Get-DhcpServerInDC | Where-Object { $_.DnsName -ieq $dc2Fqdn -or $_.IPAddress.IPAddressToString -eq $dc2Ip })
    if ($auth.Count -gt 0) { Write-Log INFO "$dc2Fqdn is already authorized." }
    else {
        Add-DhcpServerInDC -DnsName $dc2Fqdn -IPAddress $dc2Ip
        Write-Log SUCCESS "$dc2Fqdn ($dc2Ip) authorized in Active Directory."
    }

    # ---- 3. Clear Server Manager post-install warning -----------------------
    Write-Log INFO 'Clearing Server Manager DHCP post-install flag ...'
    Invoke-OnHost -ComputerName $dc2 -ScriptBlock {
        $key = 'HKLM:\SOFTWARE\Microsoft\ServerManager\Roles\12'
        if (-not (Test-Path $key)) { New-Item -Path $key -Force | Out-Null }
        Set-ItemProperty -Path $key -Name 'ConfigurationState' -Value 2 -Type DWord
    }
    Write-Log SUCCESS 'ConfigurationState = 2 written to Roles\12.'

    # Optional: create the "DHCP Administrators"/"DHCP Users" local groups, then restart the service.
    try {
        Add-DhcpServerSecurityGroup -ComputerName $dc2
        Invoke-OnHost -ComputerName $dc2 -ScriptBlock { Restart-Service -Name DHCPServer -Force }
        Write-Log SUCCESS 'DHCP security groups created and DHCP service restarted.'
    } catch {
        Write-Log WARNING "Could not add DHCP security groups / restart service: $($_.Exception.Message)"
    }

    # ---- 4. Failover --------------------------------------------------------
    if (-not $SkipFailover) {
        $scopeIds = @($cfg.ScopeIds)
        if ($scopeIds.Count -eq 0) {
            $scopeIds = @(Get-DhcpServerv4Scope -ComputerName $dc1 | ForEach-Object { $_.ScopeId.IPAddressToString })
        }
        if ($scopeIds.Count -eq 0) { throw "No DHCP scopes found on $dc1 - create a scope first." }
        Write-Log INFO "Failover scopes: $($scopeIds -join ', ')"

        $existing = @(Get-DhcpServerv4Failover -ComputerName $dc1 -ErrorAction SilentlyContinue |
            Where-Object { $_.PartnerServer -ieq $dc2 -or $_.PartnerServer -ieq $dc2Fqdn })

        if ($existing.Count -eq 0) {
            Write-Log INFO "Creating failover relationship '$($cfg.FailoverName)' ($dc1 <-> $dc2, mode $($cfg.FailoverMode)) ..."
            $p = @{
                ComputerName        = $dc1
                PartnerServer       = $dc2
                Name                = $cfg.FailoverName
                ScopeId             = $scopeIds
                SharedSecret        = $cfg.FailoverSharedSecret
                MaxClientLeadTime   = [TimeSpan]$cfg.MaxClientLeadTime
                AutoStateTransition = $true
                Force               = $true
            }
            if ($cfg.FailoverMode -eq 'HotStandby') { $p.ServerRole = 'Active'; $p.ReservePercent = $cfg.ReservePercent }
            else                                    { $p.LoadBalancePercent = $cfg.LoadBalancePercent }
            Add-DhcpServerv4Failover @p
            Write-Log SUCCESS 'Failover relationship created.'
            $failoverName = $cfg.FailoverName
        }
        else {
            $failoverName = $existing[0].Name
            Write-Log INFO "Failover relationship '$failoverName' already exists."
            $inRel   = @($existing[0].ScopeId | ForEach-Object { $_.IPAddressToString })
            $missing = @($scopeIds | Where-Object { $_ -notin $inRel })
            if ($missing.Count -gt 0) {
                Add-DhcpServerv4FailoverScope -ComputerName $dc1 -Name $failoverName -ScopeId $missing
                Write-Log SUCCESS "Added scope(s) to failover: $($missing -join ', ')"
            }
        }
        Invoke-DhcpServerv4FailoverReplication -ComputerName $dc1 -Name $failoverName -Force
        Write-Log SUCCESS 'Initial failover replication completed.'
    }
    else { Write-Log WARNING 'Failover creation skipped (-SkipFailover).' }

    # ---- 5. Option 006 on DC2 (DC2 first, DC1 second) -----------------------
    Write-Log INFO "Setting DC2 server-level Option 006 -> $dc2Ip, $dc1Ip ..."
    Set-DhcpServerv4OptionValue -ComputerName $dc2 -DnsServer @($dc2Ip, $dc1Ip)

    if ($cfg.OverrideScopeLevelDnsOnDc2) {
        foreach ($s in @($cfg.ScopeIds)) {
            $opt = Get-DhcpServerv4OptionValue -ComputerName $dc2 -ScopeId $s -OptionId 6 -ErrorAction SilentlyContinue
            if ($opt) {
                Set-DhcpServerv4OptionValue -ComputerName $dc2 -ScopeId $s -DnsServer @($dc2Ip, $dc1Ip)
                Write-Log WARNING "Scope $s on ${dc2}: scope-level Option 006 overridden. Failover replication from $dc1 may overwrite it - prefer server-level options only (see README)."
            }
        }
    }
    $check = (Get-DhcpServerv4OptionValue -ComputerName $dc2 -OptionId 6).Value -join ', '
    Write-Log SUCCESS "Option 006 on $dc2 (server level) = $check"
    Write-Log SUCCESS 'Step 1 finished.'
    exit 0
}
catch {
    Write-Log ERROR "$($_.Exception.Message) (line $($_.InvocationInfo.ScriptLineNumber))"
    exit 1
}
