# ============================================================================
# config.psd1 - single place to edit lab parameters. No script logic changes.
# ============================================================================
@{
    # ---- Domain ------------------------------------------------------------
    DomainFqdn    = 'lab.local'
    DomainNetBios = 'LAB'
    DomainDN      = ''            # leave empty -> derived from DomainFqdn (DC=lab,DC=local)

    # ---- Machines ----------------------------------------------------------
    Dc1Name       = 'DC1'
    Dc1Ip         = '192.168.10.10'
    Dc2Name       = 'DC2'
    Dc2Ip         = '192.168.10.11'
    MsHostname    = 'MS'

    # ---- DHCP --------------------------------------------------------------
    # Scopes to protect with failover. Empty array = every scope found on DC1.
    ScopeIds             = @('192.168.10.0')
    FailoverName         = 'DC1-DC2-Failover'
    FailoverMode         = 'LoadBalance'      # LoadBalance | HotStandby
    LoadBalancePercent   = 50                 # LoadBalance: % served by DC1
    ReservePercent       = 5                  # HotStandby: % of addresses reserved for standby
    MaxClientLeadTime    = '01:00:00'
    FailoverSharedSecret = 'ChangeMe-Lab-Secret!'
    # If DC2 already has a scope-level Option 006, also rewrite it to DC2-first order.
    # (Failover replication from DC1 can overwrite scope-level options - see README.)
    OverrideScopeLevelDnsOnDc2 = $true

    # ---- File shares / home folders ---------------------------------------
    HomeRootPath  = 'C:\Shares\Homes'         # local path ON the member server
    ShareName     = 'Homes'
    HomeDrive     = 'H:'

    # ---- Input data (relative to repo root; .csv preferred, .xlsx fallback) -
    DataFolder    = 'data'
    CreateMissingGroups = $true               # create AD group if CSV references a missing one
    ChangePasswordAtLogon = $false

    # ---- OU / UPN ----------------------------------------------------------
    CompanyOuName = 'Contoso'                 # root business OU
    CompanyOuDN   = 'OU=Contoso,{DomainDN}'   # {DomainDN} is expanded automatically
    UpnSuffix     = 'contoso.com'
    ProtectOUs    = $true                     # ProtectedFromAccidentalDeletion
    OrgStructure  = @(
        @{ Name = 'Board';      SubOUs = @('Users','Groups') }
        @{ Name = 'HR';         SubOUs = @('Users','Groups','Computers') }
        @{ Name = 'IT';         SubOUs = @('Users','Groups','Computers') }
        @{ Name = 'Finance';    SubOUs = @('Users','Groups','Computers') }
        @{ Name = 'Operations'; SubOUs = @('Users','Groups','Computers') }
    )
}
