#Requires -Version 5.1
<#
.SYNOPSIS
    Step 2 - Import DHCP reservations from CSV/XLSX on DC1 and sync to DC2.
.DESCRIPTION
    Columns: ScopeId, IPAddress, ClientId (MAC), Name, Description
    Per row: scope must exist, IP must be in the scope's subnet, skip if the reservation
    (same IP or same MAC) already exists. Afterwards failover replication is invoked.
#>
[CmdletBinding()]
param(
    [string]$ConfigPath = (Join-Path $PSScriptRoot 'config.psd1'),
    [string]$InputFile
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib\Common.ps1')

try {
    Start-LabLog -Name '02_Import-DhcpReservations'
    $cfg = Import-LabConfig -Path $ConfigPath
    $dc1 = $cfg.Dc1Name
    Import-Module DhcpServer

    $file = Resolve-LabInputFile -Path $InputFile -DataFolder (Join-Path $global:LabRoot $cfg.DataFolder) -BaseName 'dhcp_reservations'
    $rows = Import-LabData -Path $file -RequiredColumns 'ScopeId','IPAddress','ClientId','Name','Description'

    $scopeCache = @{}
    $validScopes = New-Object 'System.Collections.Generic.HashSet[string]'
    $added = 0; $skipped = 0; $failed = 0
    $n = 0

    foreach ($r in $rows) {
        $n++
        try {
            $scopeId = ([string]$r.ScopeId).Trim()
            $ip      = ([string]$r.IPAddress).Trim()
            $hex     = ([string]$r.ClientId) -replace '[^0-9A-Fa-f]', ''
            if ($hex.Length -ne 12) { throw "ClientId '$($r.ClientId)' is not a valid MAC address." }
            $mac  = (($hex.ToUpper() -split '(.{2})') | Where-Object { $_ }) -join '-'
            $name = ([string]$r.Name).Trim()
            if (-not $name) { throw 'Name is empty.' }

            # -- scope exists? --
            if (-not $scopeCache.ContainsKey($scopeId)) {
                $scopeCache[$scopeId] = Get-DhcpServerv4Scope -ComputerName $dc1 -ScopeId $scopeId -ErrorAction SilentlyContinue
            }
            $scope = $scopeCache[$scopeId]
            if (-not $scope) { throw "Scope $scopeId does not exist on $dc1." }
            [void]$validScopes.Add($scopeId)

            # -- IP inside scope subnet? --
            if (-not (Test-IpInSubnet -IP $ip -ScopeId $scopeId -SubnetMask $scope.SubnetMask.IPAddressToString)) {
                throw "IP $ip is outside scope $scopeId ($($scope.SubnetMask))."
            }

            # -- already reserved? --
            $byIp  = $null; $byMac = $null
            try { $byIp  = Get-DhcpServerv4Reservation -ComputerName $dc1 -ScopeId $scopeId -IPAddress $ip -ErrorAction SilentlyContinue } catch { }
            try { $byMac = Get-DhcpServerv4Reservation -ComputerName $dc1 -ScopeId $scopeId -ClientId $mac -ErrorAction SilentlyContinue } catch { }
            if ($byIp -or $byMac) {
                Write-Log INFO "Row ${n}: reservation for $ip / $mac already exists - skipped."
                $skipped++; continue
            }

            Add-DhcpServerv4Reservation -ComputerName $dc1 -ScopeId $scopeId -IPAddress $ip -ClientId $mac -Name $name -Description ([string]$r.Description)
            Write-Log SUCCESS "Row ${n}: reservation added  $ip -> $mac ($name)"
            $added++
        }
        catch {
            Write-Log ERROR "Row ${n}: $($_.Exception.Message)"
            $failed++
        }
    }

    # -- sync to partner immediately --
    foreach ($s in $validScopes) {
        try {
            Invoke-DhcpServerv4FailoverReplication -ComputerName $dc1 -ScopeId $s -Force
            Write-Log SUCCESS "Failover replication triggered for scope $s."
        } catch {
            Write-Log ERROR "Replication of scope $s failed: $($_.Exception.Message)"
            $failed++
        }
    }

    Write-Log INFO "Summary: added=$added skipped=$skipped failed=$failed"
    if ($failed -gt 0) { throw "$failed operation(s) failed - see log." }
    Write-Log SUCCESS 'Step 2 finished.'
    exit 0
}
catch {
    Write-Log ERROR "$($_.Exception.Message) (line $($_.InvocationInfo.ScriptLineNumber))"
    exit 1
}
