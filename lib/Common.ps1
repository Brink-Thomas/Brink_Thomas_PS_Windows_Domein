# ============================================================================
# lib/Common.ps1 - shared helpers (dot-source from every numbered script)
# ============================================================================
$global:LabRoot    = Split-Path -Path $PSScriptRoot -Parent
$global:LabLogFile = $null

function Write-Log {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)][ValidateSet('INFO','SUCCESS','WARNING','ERROR')][string]$Level,
        [Parameter(Mandatory, Position = 1)][string]$Message
    )
    $colors = @{ INFO = 'Cyan'; SUCCESS = 'Green'; WARNING = 'Yellow'; ERROR = 'Red' }
    $line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    Write-Host $line -ForegroundColor $colors[$Level]
    if ($global:LabLogFile) { Add-Content -Path $global:LabLogFile -Value $line }
}

function Start-LabLog {
    param([Parameter(Mandatory)][string]$Name)
    $dir = Join-Path $global:LabRoot 'logs'
    if (-not (Test-Path $dir)) { New-Item -Path $dir -ItemType Directory -Force | Out-Null }
    $global:LabLogFile = Join-Path $dir ("{0}_{1:yyyyMMdd_HHmmss}.log" -f $Name, (Get-Date))
    Write-Log INFO "Log file: $global:LabLogFile"
}

function Import-LabConfig {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { throw "Config file not found: $Path" }
    $c = Import-PowerShellDataFile -Path $Path
    if (-not $c.DomainDN)      { $c.DomainDN = (($c.DomainFqdn.Split('.') | ForEach-Object { "DC=$_" }) -join ',') }
    if (-not $c.DomainNetBios) { $c.DomainNetBios = $c.DomainFqdn.Split('.')[0].ToUpper() }
    $c.CompanyOuDN = Expand-LabDN -Value $c.CompanyOuDN -DomainDN $c.DomainDN
    return $c
}

function Expand-LabDN {
    param([string]$Value, [string]$DomainDN)
    return ($Value -replace '\{DomainDN\}', $DomainDN).Trim()
}

function Test-IsLocalHost {
    param([Parameter(Mandatory)][string]$Name)
    $short = $Name.Split('.')[0]
    return ($short -ieq $env:COMPUTERNAME -or $Name -in @('localhost', '.', '127.0.0.1'))
}

function Invoke-OnHost {
    # Runs a scriptblock locally when ComputerName is this machine, otherwise via WinRM.
    param(
        [Parameter(Mandatory)][string]$ComputerName,
        [Parameter(Mandatory)][scriptblock]$ScriptBlock,
        [object[]]$ArgumentList = @()
    )
    if (Test-IsLocalHost $ComputerName) { & $ScriptBlock @ArgumentList }
    else { Invoke-Command -ComputerName $ComputerName -ScriptBlock $ScriptBlock -ArgumentList $ArgumentList }
}

function Resolve-LabInputFile {
    param([string]$Path, [Parameter(Mandatory)][string]$DataFolder, [Parameter(Mandatory)][string]$BaseName)
    if ($Path) {
        if (-not (Test-Path -LiteralPath $Path)) { throw "Input file not found: $Path" }
        return (Resolve-Path -LiteralPath $Path).Path
    }
    foreach ($ext in '.csv', '.xlsx') {
        $candidate = Join-Path $DataFolder "$BaseName$ext"
        if (Test-Path -LiteralPath $candidate) { return $candidate }
    }
    throw "No input file '$BaseName.csv' or '$BaseName.xlsx' found in $DataFolder"
}

function Import-LabData {
    # .csv -> Import-Csv (no dependencies). .xlsx -> ImportExcel module (optional).
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string[]]$RequiredColumns)
    switch ([IO.Path]::GetExtension($Path).ToLower()) {
        '.csv'  { $rows = @(Import-Csv -Path $Path) }
        '.xlsx' {
            if (-not (Get-Module -ListAvailable -Name ImportExcel)) {
                throw "'$Path' is an Excel file but the ImportExcel module is missing. Run: Install-Module ImportExcel -Scope CurrentUser  (or export the sheet to .csv)"
            }
            Import-Module ImportExcel
            $rows = @(Import-Excel -Path $Path)
        }
        default { throw "Unsupported input file type: $Path (use .csv or .xlsx)" }
    }
    if ($rows.Count -eq 0) { throw "Input file contains no data rows: $Path" }
    $present = $rows[0].PSObject.Properties.Name
    $missing = @($RequiredColumns | Where-Object { $_ -notin $present })
    if ($missing.Count -gt 0) { throw "Input file is missing required column(s): $($missing -join ', ')" }
    Write-Log INFO "Loaded $($rows.Count) row(s) from $Path"
    return $rows
}

function ConvertTo-UInt32IP {
    param([Parameter(Mandatory)][string]$IP)
    $b = ([System.Net.IPAddress]::Parse($IP)).GetAddressBytes()
    [Array]::Reverse($b)
    return [BitConverter]::ToUInt32($b, 0)
}

function Test-IpInSubnet {
    param([Parameter(Mandatory)][string]$IP, [Parameter(Mandatory)][string]$ScopeId, [Parameter(Mandatory)][string]$SubnetMask)
    $mask = ConvertTo-UInt32IP $SubnetMask
    return (((ConvertTo-UInt32IP $IP) -band $mask) -eq ((ConvertTo-UInt32IP $ScopeId) -band $mask))
}

function Set-LabAdServer {
    # Pin every AD cmdlet to DC1 so scripts behave the same wherever they run.
    param([Parameter(Mandatory)][string]$Server)
    $global:PSDefaultParameterValues['*-AD*:Server'] = $Server
}

function Get-LabSqlSafe { param([string]$Value) return ($Value -replace "'", "''") }
