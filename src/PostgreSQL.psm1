#requires -Version 7.4
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'Deployment.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'SshTransport.psm1') -DisableNameChecking

function Assert-PostgresName {
    param([Parameter(Mandatory)][string]$Name)
    if($Name -cnotmatch '^[a-z][a-z0-9_]{1,62}$'){throw 'PostgreSQL identifiers must use lowercase letters, digits, and underscores.'}
}

function Get-PostgresRoleNames {
    param([Parameter(Mandatory)][string]$Database)
    Assert-PostgresName $Database
    if($Database.Length -gt 40){throw 'Database name is too long for the app-role convention.'}
    @{owner='sd_'+$Database+'_owner';migrator='sd_'+$Database+'_migrator';runtime='sd_'+$Database+'_runtime'}
}

function Test-PostgresPrivateIPv4 {
    param([AllowEmptyString()][string]$Address)
    $ip=$null
    if(-not [Net.IPAddress]::TryParse($Address,[ref]$ip) -or $ip.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork -or $ip.ToString() -ne $Address){return $false}
    $b=$ip.GetAddressBytes()
    ($b[0] -eq 10) -or ($b[0] -eq 172 -and $b[1] -ge 16 -and $b[1] -le 31) -or ($b[0] -eq 192 -and $b[1] -eq 168)
}

function Assert-PostgresDnsName {
    param([AllowEmptyString()][string]$Name)
    $ip=$null
    if([string]::IsNullOrWhiteSpace($Name) -or $Name.Length -gt 253 -or
        $Name -notmatch '^(?i)[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?(?:\.[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?)*$' -or
        [Net.IPAddress]::TryParse($Name,[ref]$ip) -or $Name -ieq 'localhost' -or $Name -ilike '*.localhost'){
        throw 'Remote PostgreSQL requires a DNS server name that verify-full can match against the server certificate.'
    }
}

function Get-PostgresEndpointDigest {
    param([Parameter(Mandatory)][string]$HostName,[AllowEmptyString()][string]$HostAddress,
        [Parameter(Mandatory)][int]$Port,[AllowEmptyString()][string]$SslMode)
    Get-Sha256Text (ConvertTo-CanonicalJson @{hostName=$HostName.ToLowerInvariant();hostAddress=[string]$HostAddress;port=$Port;sslMode=[string]$SslMode})
}

function Get-PostgresConnectionPolicy {
    param([Parameter(Mandatory)][hashtable]$Plan,[string]$ClientHost)
    if(-not $Plan.ContainsKey('target') -or $Plan.target -isnot [Collections.IDictionary] -or [string]::IsNullOrWhiteSpace([string]$Plan.target.host)){throw 'Plan has no application target host.'}
    if(-not $ClientHost){$ClientHost=[string]$Plan.target.host}
    if($ClientHost -notmatch '^[A-Za-z0-9][A-Za-z0-9-]{0,62}$'){throw 'Database client host must be a plain computer name.'}
    if(-not $Plan.ContainsKey('databaseTarget')){
        # Plans created before host separation keep the original colocated, loopback-only contract.
        if(-not $Plan.ContainsKey('hostSnapshot') -or [string]::IsNullOrWhiteSpace([string]$Plan.hostSnapshot.identity)){throw 'Plan has no verified host identity.'}
        if($ClientHost -ine $Plan.target.host){throw 'Plans without databaseTarget allow only loopback database access on the verified application host.'}
        $policy=@{Mode='Loopback';Legacy=$true;HostName='127.0.0.1';HostAddress=$null;Port=5432;SslMode=$null;ServerName=$null
            DatabaseHost=[string]$Plan.target.host;DatabaseAddress=$null;DatabaseHostIdentity=[string]$Plan.hostSnapshot.identity;ClientHost=$ClientHost}
    }else{
        $target=$Plan.databaseTarget
        if($target -isnot [Collections.IDictionary]){throw 'Plan databaseTarget must be an object.'}
        foreach($field in @('host','address','root','port','serverName','remoteSslMode')){if(-not $target.Contains($field)){throw "Plan databaseTarget missing $field."}}
        $dbHost=[string]$target.host
        if($dbHost -notmatch '^[A-Za-z0-9][A-Za-z0-9-]{0,14}$'){throw 'Database host must be a plain computer name.'}
        if(-not (Test-PostgresPrivateIPv4 ([string]$target.address))){throw 'Database host address must be a private IPv4 address.'}
        if(-not [IO.Path]::IsPathFullyQualified([string]$target.root)){throw 'Database host root must be an absolute path.'}
        if([string]$target.port -notmatch '^\d{1,5}$' -or [int]$target.port -lt 1024 -or [int]$target.port -gt 65535){throw 'Invalid PostgreSQL port.'}
        $serverName=[string]$target.serverName
        Assert-PostgresDnsName $serverName
        if($serverName -ine $dbHost -and -not $serverName.StartsWith($dbHost+'.',[StringComparison]::OrdinalIgnoreCase)){throw 'Database serverName must name the database host.'}
        if($target.remoteSslMode -cne 'verify-full'){throw 'Remote PostgreSQL transport must use verify-full.'}
        if(-not $Plan.ContainsKey('databaseHostSnapshot') -or $Plan.databaseHostSnapshot -isnot [Collections.IDictionary]){throw 'Plan has no verified database host snapshot.'}
        $snap=$Plan.databaseHostSnapshot
        if($snap.verified -ne $true -or [string]::IsNullOrWhiteSpace([string]$snap.identity) -or [string]$snap.host -ine $dbHost -or [string]$snap.address -cne [string]$target.address){
            throw 'Database host snapshot does not verify the configured database host and address.'
        }
        if($Plan.target.host -ieq $dbHost -and $Plan.ContainsKey('hostSnapshot') -and $Plan.hostSnapshot -is [Collections.IDictionary] -and
            [string]$Plan.hostSnapshot.identity -and [string]$Plan.hostSnapshot.identity -ne [string]$snap.identity){
            throw 'Application and database host snapshots disagree about the same computer.'
        }
        $policy=@{Legacy=$false;Port=[int]$target.port;ServerName=$serverName;DatabaseHost=$dbHost;DatabaseAddress=[string]$target.address
            DatabaseHostIdentity=[string]$snap.identity;ClientHost=$ClientHost}
        if($ClientHost -ieq $dbHost){$policy.Mode='Loopback';$policy.HostName='127.0.0.1';$policy.HostAddress=$null;$policy.SslMode=$null}
        else{$policy.Mode='Remote';$policy.HostName=$serverName;$policy.HostAddress=[string]$target.address;$policy.SslMode='verify-full'}
    }
    $policy.EndpointSHA256=Get-PostgresEndpointDigest -HostName $policy.HostName -HostAddress ([string]$policy.HostAddress) -Port $policy.Port -SslMode ([string]$policy.SslMode)
    $policy
}

function Get-PostgresConnectionParameters {
    param([Parameter(Mandatory)][hashtable]$Policy,[Parameter(Mandatory)][string]$ApprovedEndpointSHA256,
        [string]$SslRootCert,[string]$SslRootCertSHA256)
    $expected=Get-PostgresEndpointDigest -HostName $Policy.HostName -HostAddress ([string]$Policy.HostAddress) -Port $Policy.Port -SslMode ([string]$Policy.SslMode)
    if($Policy.EndpointSHA256 -ne $expected -or $ApprovedEndpointSHA256 -ne $expected){throw 'PostgreSQL endpoint differs from the approved endpoint.'}
    $parameters=@{HostName=$Policy.HostName;Port=$Policy.Port;EndpointSHA256=$expected}
    if($Policy.Mode -eq 'Remote'){
        if([string]::IsNullOrWhiteSpace($SslRootCert) -or $SslRootCertSHA256 -notmatch '^[a-f0-9]{64}$'){throw 'Remote PostgreSQL requires the approved root certificate file and its SHA-256.'}
        $parameters.HostAddress=$Policy.HostAddress;$parameters.SslRootCert=$SslRootCert;$parameters.SslRootCertSHA256=$SslRootCertSHA256
    }elseif($Policy.Mode -ne 'Loopback' -or $SslRootCert -or $SslRootCertSHA256){throw 'Loopback PostgreSQL does not accept remote transport settings.'}
    $parameters
}

function Assert-PostgresRuntimeConnectionString {
    param([Parameter(Mandatory)][string]$ConnectionString,[Parameter(Mandatory)][hashtable]$Policy,
        [Parameter(Mandatory)][string]$Database,[Parameter(Mandatory)][string]$RuntimeRole,[string]$SslRootCert)
    # Messages never echo the connection string because it can carry the runtime password.
    Assert-PostgresName $Database;Assert-PostgresName $RuntimeRole
    $m=[regex]::Match($ConnectionString,'^postgres(?:ql)?://(?<user>[^:@/?#]+)(?::[^@/?#]*)?@(?<host>[A-Za-z0-9.-]+)(?::(?<port>\d{1,5}))?/(?<db>[^/?#]+)(?:\?(?<query>[^#]*))?$')
    if(-not $m.Success){throw 'Runtime DATABASE_URL must be a single-host postgresql:// URL with user, host, and database.'}
    $user=[Uri]::UnescapeDataString($m.Groups['user'].Value);$db=[Uri]::UnescapeDataString($m.Groups['db'].Value)
    $hostName=$m.Groups['host'].Value;$port=if($m.Groups['port'].Success){[int]$m.Groups['port'].Value}else{5432}
    $options=@{}
    if($m.Groups['query'].Success -and $m.Groups['query'].Value){
        foreach($pair in $m.Groups['query'].Value.Split('&')){
            $parts=$pair.Split('=',2)
            if($parts.Count -ne 2){throw 'Runtime DATABASE_URL has a malformed query parameter.'}
            $key=[Uri]::UnescapeDataString($parts[0]);$value=[Uri]::UnescapeDataString($parts[1])
            if($key -cnotin @('sslmode','hostaddr','sslrootcert','gssencmode','connect_timeout','application_name')){throw "Runtime DATABASE_URL parameter '$key' is not allowed."}
            if($options.ContainsKey($key)){throw "Runtime DATABASE_URL repeats parameter '$key'."}
            $options[$key]=$value
        }
    }
    if($user -cne $RuntimeRole){throw 'Runtime DATABASE_URL must authenticate as the approved runtime role.'}
    if($db -cne $Database){throw 'Runtime DATABASE_URL must name the approved application database.'}
    if($port -ne $Policy.Port){throw 'Runtime DATABASE_URL port differs from the approved endpoint.'}
    if($Policy.Mode -eq 'Remote'){
        if($hostName -ine $Policy.HostName){throw 'Runtime DATABASE_URL host must be the verified database server name.'}
        if($options['hostaddr'] -cne $Policy.HostAddress){throw 'Runtime DATABASE_URL must pin hostaddr to the approved database address.'}
        if($options['sslmode'] -cne 'verify-full'){throw 'Runtime DATABASE_URL must use sslmode=verify-full.'}
        if($options['gssencmode'] -cne 'disable'){throw 'Runtime DATABASE_URL must set gssencmode=disable so TLS cannot be bypassed.'}
        if(-not $options['sslrootcert'] -or -not [IO.Path]::IsPathFullyQualified($options['sslrootcert'])){throw 'Runtime DATABASE_URL must name an absolute sslrootcert file.'}
        if($SslRootCert -and $options['sslrootcert'] -ine $SslRootCert){throw 'Runtime DATABASE_URL sslrootcert differs from the approved root certificate.'}
        $endpoint=Get-PostgresEndpointDigest -HostName $hostName -HostAddress $options['hostaddr'] -Port $port -SslMode 'verify-full'
    }elseif($Policy.Mode -eq 'Loopback'){
        if($hostName -notin @('127.0.0.1','localhost')){throw 'Runtime DATABASE_URL must use loopback on the database host.'}
        if($options.ContainsKey('hostaddr')){throw 'Loopback runtime DATABASE_URL cannot set hostaddr.'}
        $endpoint=Get-PostgresEndpointDigest -HostName $Policy.HostName -HostAddress '' -Port $port -SslMode ''
    }else{throw 'Unknown PostgreSQL connection policy mode.'}
    if($endpoint -ne $Policy.EndpointSHA256){throw 'Runtime DATABASE_URL endpoint differs from the approved endpoint.'}
    @{mode=$Policy.Mode;hostName=$hostName;hostAddress=$options['hostaddr'];port=$port;database=$db;userName=$user
        sslMode=$options['sslmode'];sslRootCert=$options['sslrootcert'];endpointSHA256=$endpoint}
}

function Assert-PostgresProtectedFile {
    param([Parameter(Mandatory)][string]$Path,[Parameter(Mandatory)][string]$Purpose,[switch]$DenyBroadRead)
    $remote=Resolve-DeploymentSshPath $Path
    if($remote){
        $definition=${function:Assert-PostgresProtectedFile}.ToString()
        Invoke-DeploymentSsh $remote.hostName {param($definition,$path,$purpose,$deny)
            Set-Item Function:Assert-PostgresProtectedFile ([scriptblock]::Create($definition))
            function Resolve-DeploymentSshPath {param($Path) $null}
            Assert-PostgresProtectedFile $path $purpose -DenyBroadRead:$deny
        } @($definition,$remote.path,$Purpose,[bool]$DenyBroadRead)
        return
    }
    if(-not [IO.Path]::IsPathFullyQualified($Path) -or -not (Test-Path -LiteralPath $Path -PathType Leaf)){throw "PostgreSQL $Purpose must be an existing absolute file path."}
    $item=Get-Item -LiteralPath $Path -Force
    if($item.Attributes -band [IO.FileAttributes]::ReparsePoint){throw "PostgreSQL $Purpose cannot be a reparse point."}
    $writeMask=[int64]([Security.AccessControl.FileSystemRights]'WriteData, AppendData, WriteExtendedAttributes, WriteAttributes, Delete, ChangePermissions, TakeOwnership') -bor 0x40000000 -bor 0x10000000
    foreach($rule in (Get-Acl -LiteralPath $Path).Access){
        if($rule.AccessControlType -ne 'Allow'){continue}
        $sid=$rule.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value
        if($sid -notin @('S-1-1-0','S-1-5-11','S-1-5-32-545')){continue}
        if($DenyBroadRead -or ([int64]$rule.FileSystemRights -band $writeMask)){throw "PostgreSQL $Purpose grants broad access. Restrict its ACL before using it."}
    }
}

function New-PostgresToolStartInfo {
    param([Parameter(Mandatory)][string]$ToolPath,[Parameter(Mandatory)][string[]]$Arguments,
        [Parameter(Mandatory)][string]$PassFile,[Parameter(Mandatory)][string]$HostName,[string]$HostAddress,
        [Parameter(Mandatory)][int]$Port,[string]$SslRootCert,[Parameter(Mandatory)][string]$UserName,
        [Parameter(Mandatory)][string]$Database)
    $start=[Diagnostics.ProcessStartInfo]::new()
    $start.FileName=$ToolPath;$start.UseShellExecute=$false;$start.CreateNoWindow=$true
    $start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true
    $remote=-not [string]::IsNullOrEmpty($HostAddress)
    $connection=if($remote){@('--username',$UserName,'--no-password')}else{@('--host',$HostName,'--port',[string]$Port,'--username',$UserName,'--no-password')}
    foreach($arg in $connection+$Arguments){$start.ArgumentList.Add($arg)}
    # Credentials stay in a private file and never enter process arguments or reports.
    foreach($key in @('PGPASSWORD','PGSERVICE','PGSERVICEFILE','PGOPTIONS','PGDATABASE','PGHOST','PGHOSTADDR','PGPORT','PGUSER','DATABASE_URL',
        'PGSSLMODE','PGREQUIRESSL','PGSSLROOTCERT','PGSSLCERT','PGSSLKEY','PGSSLCERTMODE','PGSSLCRL','PGSSLCRLDIR','PGSSLSNI','PGSSLNEGOTIATION',
        'PGSSLMINPROTOCOLVERSION','PGSSLMAXPROTOCOLVERSION','PGSSLCOMPRESSION','PGGSSENCMODE','PGGSSDELEGATION','PGREQUIREAUTH','PGCHANNELBINDING',
        'PGTARGETSESSIONATTRS','PGLOADBALANCEHOSTS','PGSYSCONFDIR')){$start.Environment.Remove($key)|Out-Null}
    $start.Environment['PGPASSFILE']=$PassFile
    $start.Environment['PGCONNECT_TIMEOUT']='10'
    $start.Environment['PGDATABASE']=$Database
    $start.Environment['PGAPPNAME']='SolutionDeploy'
    $start.Environment['PGOPTIONS']='-c statement_timeout=120000 -c lock_timeout=10000'
    if($remote){
        # libpq checks the certificate against PGHOST while PGHOSTADDR pins the approved private address without DNS.
        $start.Environment['PGHOST']=$HostName
        $start.Environment['PGHOSTADDR']=$HostAddress
        $start.Environment['PGPORT']=[string]$Port
        $start.Environment['PGSSLMODE']='verify-full'
        $start.Environment['PGSSLROOTCERT']=$SslRootCert
        $start.Environment['PGSSLCERTMODE']='disable'
        $start.Environment['PGGSSENCMODE']='disable'
        $start.Environment['PGOPTIONS']='-c statement_timeout=120000 -c lock_timeout=10000 -c default_transaction_read_only=on'
    }
    $start
}

function Start-PostgresToolProcess {
    param([Parameter(Mandatory)][Diagnostics.ProcessStartInfo]$StartInfo,[int]$TimeoutSeconds=120,[switch]$Capture)
    $process=[Diagnostics.Process]::new()
    $process.StartInfo=$StartInfo
    try{
        if(-not $process.Start()){throw 'PostgreSQL tool did not start.'}
        $stdout=$process.StandardOutput.ReadToEndAsync();$stderr=$process.StandardError.ReadToEndAsync()
        $clock=[Diagnostics.Stopwatch]::StartNew()
        while(-not $process.WaitForExit(1000)){
            if($clock.Elapsed.TotalSeconds -ge $TimeoutSeconds){$process.Kill($true);$process.WaitForExit();throw 'PostgreSQL tool deadline exceeded. Outcome is unknown; inspect the protected operation record before retrying.'}
            if([int]$clock.Elapsed.TotalSeconds % 10 -eq 0){Write-Host ("PostgreSQL tool running, elapsed {0:n0}s" -f $clock.Elapsed.TotalSeconds)}
        }
        if($process.ExitCode -ne 0){throw "PostgreSQL tool failed with exit code $($process.ExitCode). Server output withheld to protect connection and data values."}
        if($Capture){$stdout.GetAwaiter().GetResult().TrimEnd("`r","`n")}
    }finally{$process.Dispose()}
}

function Invoke-PostgresTool {
    param([Parameter(Mandatory)][string]$ToolPath,[Parameter(Mandatory)][string[]]$Arguments,
        [Parameter(Mandatory)][string]$PassFile,[string]$HostName='127.0.0.1',[int]$Port=5432,
        [Parameter(Mandatory)][string]$UserName,[Parameter(Mandatory)][string]$Database,
        [int]$TimeoutSeconds=120,[switch]$Capture,
        [string]$HostAddress,[string]$SslRootCert,[string]$SslRootCertSHA256,[string]$EndpointSHA256)
    Assert-PostgresName $Database; Assert-PostgresName $UserName
    if($Port -lt 1024 -or $Port -gt 65535){throw 'Invalid PostgreSQL port.'}
    $loopback=$HostName -in @('127.0.0.1','::1','localhost')
    if($loopback){
        if($HostAddress -or $SslRootCert -or $SslRootCertSHA256){throw 'Loopback database tools do not accept remote transport settings.'}
        $sslMode=''
    }else{
        if(-not $HostAddress -or -not $SslRootCert -or -not $SslRootCertSHA256 -or -not $EndpointSHA256){
            throw 'Database tools use loopback on the database host. Remote read-only evidence requires an approved endpoint hash, verified server name, pinned private address, and verify-full root certificate.'
        }
        Assert-PostgresDnsName $HostName
        if(-not (Test-PostgresPrivateIPv4 $HostAddress)){throw 'Remote PostgreSQL address must be a pinned private IPv4 address.'}
        if([IO.Path]::GetFileName($ToolPath) -notin @('psql.exe','psql')){throw 'Remote PostgreSQL is limited to read-only psql evidence. Administrative SQL, backup, and restore run on the database host over loopback.'}
        $sslMode='verify-full'
    }
    if($EndpointSHA256 -and $EndpointSHA256 -ne (Get-PostgresEndpointDigest -HostName $HostName -HostAddress $HostAddress -Port $Port -SslMode $sslMode)){
        throw 'PostgreSQL endpoint differs from the approved endpoint.'
    }
    if(-not [IO.Path]::IsPathFullyQualified($ToolPath) -or -not (Test-Path -LiteralPath $ToolPath -PathType Leaf)){throw 'PostgreSQL tools require an existing absolute executable path.'}
    if(-not [IO.Path]::IsPathFullyQualified($PassFile) -or -not (Test-Path -LiteralPath $PassFile -PathType Leaf)){throw 'Provision the protected PostgreSQL password file in a standalone secure terminal first.'}
    Assert-PostgresProtectedFile -Path $PassFile -Purpose 'password file' -DenyBroadRead
    if(-not $loopback){
        Assert-PostgresProtectedFile -Path $SslRootCert -Purpose 'root certificate'
        if((Get-FileHash -LiteralPath $SslRootCert).Hash.ToLowerInvariant() -ne $SslRootCertSHA256){throw 'PostgreSQL root certificate differs from the approved file.'}
    }
    $start=New-PostgresToolStartInfo -ToolPath $ToolPath -Arguments $Arguments -PassFile $PassFile -HostName $HostName -HostAddress $(if($loopback){''}else{$HostAddress}) `
        -Port $Port -SslRootCert $SslRootCert -UserName $UserName -Database $Database
    Start-PostgresToolProcess -StartInfo $start -TimeoutSeconds $TimeoutSeconds -Capture:$Capture
}

function Assert-PostgresToolVersion {
    param([Parameter(Mandatory)][string]$ToolPath,[Parameter(Mandatory)][int]$ServerVersionNum)
    $raw=Invoke-DeploymentCommand -Executable $ToolPath -Arguments @('--version') -WorkingDirectory (Split-Path -Parent $ToolPath) -Capture
    if($raw -notmatch '\(PostgreSQL\)\s+(\d+)(?:\.\d+)*'){throw 'Cannot determine PostgreSQL tool major version.'}
    if([int]$Matches[1] -ne [int][Math]::Floor($ServerVersionNum/10000)){throw 'PostgreSQL backup/restore tools must match the verified server major version.'}
}

function Get-PostgresProvisioningPlan {
    param([Parameter(Mandatory)][hashtable]$Manifest,[Parameter(Mandatory)][hashtable]$Snapshot)
    if($Manifest.database.engine -ne 'postgresql'){throw 'Production requires PostgreSQL.'}
    $database=$Manifest.database.name;Assert-PostgresName $database
    $roles=Get-PostgresRoleNames $database
    foreach($field in @('hostIdentity','serverVersion','serverSystemIdentifier','databases','roles')){
        if(-not $Snapshot.ContainsKey($field)){throw "PostgreSQL preflight snapshot missing $field."}
    }
    if($database -in $Snapshot.databases -or @($roles.Values|Where-Object{$_ -in $Snapshot.roles}).Count){
        throw 'Database or role already exists. Review ownership rather than silently adopting or dropping it.'
    }
    $sql=@"
CREATE ROLE "$($roles.owner)" NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS;
CREATE ROLE "$($roles.migrator)" LOGIN NOINHERIT NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS;
CREATE ROLE "$($roles.runtime)" LOGIN NOINHERIT NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS;
GRANT "$($roles.owner)" TO "$($roles.migrator)";
CREATE DATABASE "$database" OWNER "$($roles.owner)" TEMPLATE template0;
REVOKE ALL ON DATABASE "$database" FROM PUBLIC;
GRANT CONNECT ON DATABASE "$database" TO "$($roles.runtime)", "$($roles.migrator)";
"@
    $grantSql=@"
REVOKE CREATE ON SCHEMA public FROM PUBLIC;
REVOKE ALL ON SCHEMA public FROM "$($roles.runtime)";
GRANT USAGE ON SCHEMA public TO "$($roles.runtime)";
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO "$($roles.runtime)";
REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON TABLE public.solutiondeploy_schema FROM "$($roles.runtime)";
DO `$ledger`$
BEGIN
    IF to_regclass('public.solutiondeploy_import') IS NOT NULL THEN
        REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON TABLE public.solutiondeploy_import FROM "$($roles.runtime)";
    END IF;
END
`$ledger`$;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO "$($roles.runtime)";
"@
    $plan=@{
        app=$Manifest.id;database=$database;roles=$roles;snapshot=$Snapshot
        provisioningSql=$sql;runtimeGrantsSql=$grantSql
        passwordSetup='Set migrator/runtime passwords interactively with psql \password in a standalone secure terminal, then provision private password/connection files.'
        transactional=$false
        grantOrdering='Apply reviewed schema first; then apply runtime grants transactionally after each migration. New tables receive no automatic runtime privileges.'
    }
    $plan.planHash=Get-PlanDigest $plan
    $plan
}

function Get-PostgresSnapshot {
    param([Parameter(Mandatory)][string]$PsqlPath,[Parameter(Mandatory)][string]$PassFile,
        [Parameter(Mandatory)][string]$UserName,[Parameter(Mandatory)][string]$HostIdentity,[int]$Port=5432)
    $query=@"
SELECT json_build_object(
 'serverVersion', current_setting('server_version'),
 'serverVersionNum', current_setting('server_version_num')::int,
 'serverSystemIdentifier', (SELECT system_identifier::text FROM pg_control_system()),
 'databases', (SELECT coalesce(json_agg(datname ORDER BY datname),'[]'::json) FROM pg_database WHERE NOT datistemplate),
 'roles', (SELECT coalesce(json_agg(rolname ORDER BY rolname),'[]'::json) FROM pg_roles),
 'extensions', (SELECT coalesce(json_agg(extname ORDER BY extname),'[]'::json) FROM pg_extension)
);
"@
    $raw=Invoke-PostgresTool -ToolPath $PsqlPath -Arguments @('-X','-A','-t','-v','ON_ERROR_STOP=1','-c',$query) -PassFile $PassFile -Port $Port -UserName $UserName -Database postgres -Capture
    $snapshot=$raw|ConvertFrom-Json -AsHashtable
    Assert-PostgresToolVersion $PsqlPath $snapshot.serverVersionNum
    $snapshot.hostIdentity=$HostIdentity
    $snapshot.collectedLocal=(Get-Date).ToString('o')
    $snapshot.snapshotHash=Get-PlanDigest $snapshot
    $snapshot
}

function Invoke-PostgresReviewedSql {
    param([Parameter(Mandatory)][string]$PsqlPath,[Parameter(Mandatory)][string]$PassFile,
        [Parameter(Mandatory)][string]$UserName,[Parameter(Mandatory)][string]$Database,
        [Parameter(Mandatory)][string]$SqlPath,[Parameter(Mandatory)][string]$ApprovedSHA256,
        [Parameter(Mandatory)][string]$JournalPath,[Parameter(Mandatory)][string]$IndependentReviewReference,
        [string]$OwnerRole,[switch]$Transactional,[switch]$Execute,[int]$Port=5432)
    if((Get-FileHash -LiteralPath $SqlPath).Hash.ToLowerInvariant() -ne $ApprovedSHA256){throw 'SQL differs from the independently reviewed script.'}
    if([string]::IsNullOrWhiteSpace($IndependentReviewReference)){throw 'Exact database action requires an independent review reference.'}
    if(-not $Execute){return @{status='Preview';sqlSHA256=$ApprovedSHA256;database=$Database;transactional=[bool]$Transactional}}
    if(Test-Path -LiteralPath $JournalPath){throw 'A database-action journal already exists. Inspect its outcome before retrying non-repeatable SQL.'}
    $args=@('-X','-v','ON_ERROR_STOP=1','--file',$SqlPath)
    if($OwnerRole){Assert-PostgresName $OwnerRole;$args=@('-X','-v','ON_ERROR_STOP=1','-c',('SET ROLE "'+$OwnerRole+'";'),'--file',$SqlPath)}
    if($Transactional){$args+='--single-transaction'}
    Write-DeploymentJson $JournalPath @{status='Running';sqlSHA256=$ApprovedSHA256;database=$Database;review=$IndependentReviewReference;startedLocal=(Get-Date).ToString('o')}
    try{
        Invoke-PostgresTool -ToolPath $PsqlPath -Arguments $args -PassFile $PassFile -Port $Port -UserName $UserName -Database $Database
        Write-DeploymentJson $JournalPath @{status='Succeeded';sqlSHA256=$ApprovedSHA256;database=$Database;review=$IndependentReviewReference;completedLocal=(Get-Date).ToString('o')}
    }catch{
        Write-DeploymentJson $JournalPath @{status='FailedOrUnknown';sqlSHA256=$ApprovedSHA256;database=$Database;review=$IndependentReviewReference;failedLocal=(Get-Date).ToString('o')}
        throw
    }
}

function Get-PostgresDatabaseEvidence {
    param([Parameter(Mandatory)][hashtable]$Manifest,[Parameter(Mandatory)][string]$PsqlPath,
        [Parameter(Mandatory)][string]$PassFile,[Parameter(Mandatory)][string]$UserName,
        [string[]]$SolutionDatabases=@('ferry_tracker','home_automation','site_dock'),
        [string]$HostName='127.0.0.1',[int]$Port=5432,[string]$HostAddress,[string]$SslRootCert,
        [string]$SslRootCertSHA256,[string]$EndpointSHA256)
    Assert-Identifier $Manifest.id
    if(-not @($SolutionDatabases).Count){throw 'Cross-solution isolation needs the managed database list.'}
    foreach($name in $SolutionDatabases){Assert-PostgresName $name}
    $remote=$HostName -notin @('127.0.0.1','::1','localhost')
    $connection=@{HostName=$HostName;Port=$Port}
    foreach($key in @('HostAddress','SslRootCert','SslRootCertSHA256','EndpointSHA256')){if($PSBoundParameters.ContainsKey($key)){$connection[$key]=$PSBoundParameters[$key]}}
    $databaseList=($SolutionDatabases|ForEach-Object{"'$_'"}) -join ','
    $roles=Get-PostgresRoleNames $Manifest.database.name
    $query=@"
SELECT json_build_object(
 'database',current_database(), 'runtimeRole',current_user,
 'schemaVersion',(SELECT version FROM public.solutiondeploy_schema WHERE app_id='$($Manifest.id)'),
 'serverVersion',current_setting('server_version'),
 'transportSsl',(SELECT ssl FROM pg_stat_ssl WHERE pid=pg_backend_pid()),
 'serverAddress',host(inet_server_addr()),
 'privilegedRole',(SELECT rolsuper OR rolcreatedb OR rolcreaterole OR rolreplication OR rolbypassrls FROM pg_roles WHERE rolname=current_user),
 'ownerMember',pg_has_role(current_user,'$($roles.owner)','MEMBER'),
 'migratorMember',pg_has_role(current_user,'$($roles.migrator)','MEMBER'),
 'canAlterLedger',has_table_privilege(current_user,'public.solutiondeploy_schema','INSERT,UPDATE,DELETE,TRUNCATE'),
 'canAlterImportLedger',coalesce(has_table_privilege(current_user,to_regclass('public.solutiondeploy_import'),'INSERT,UPDATE,DELETE,TRUNCATE'),false),
 'canCreateSchema',has_database_privilege(current_user,current_database(),'CREATE'),
 'canCreatePublic',has_schema_privilege(current_user,'public','CREATE'),
 'schemaDefinition',json_build_object(
   'columns',(SELECT coalesce(json_agg(row_to_json(c) ORDER BY c.table_name,c.ordinal_position),'[]'::json) FROM
     (SELECT c.relname AS table_name,a.attname AS column_name,a.attnum AS ordinal_position,
       format_type(a.atttypid,a.atttypmod) AS data_type,a.attnotnull AS not_null,
       pg_get_expr(d.adbin,d.adrelid) AS column_default,a.attidentity AS identity_kind,a.attgenerated AS generated_kind
      FROM pg_attribute a JOIN pg_class c ON c.oid=a.attrelid JOIN pg_namespace n ON n.oid=c.relnamespace
      LEFT JOIN pg_attrdef d ON d.adrelid=a.attrelid AND d.adnum=a.attnum
      WHERE n.nspname='public' AND c.relkind IN ('r','p','v','m') AND a.attnum>0 AND NOT a.attisdropped) c),
   'constraints',(SELECT coalesce(json_agg(json_build_object('table',c.conrelid::regclass::text,'name',c.conname,'definition',pg_get_constraintdef(c.oid)) ORDER BY c.conrelid::regclass::text,c.conname),'[]'::json) FROM pg_constraint c JOIN pg_namespace n ON n.oid=c.connamespace WHERE n.nspname='public'),
   'views',(SELECT coalesce(json_agg(json_build_object('name',viewname,'definition',definition) ORDER BY viewname),'[]'::json) FROM pg_views WHERE schemaname='public'),
   'indexes',(SELECT coalesce(json_agg(json_build_object('table',tablename,'name',indexname,'definition',indexdef) ORDER BY tablename,indexname),'[]'::json) FROM pg_indexes WHERE schemaname='public')
 ),
 'crossSolutionConnect',(SELECT coalesce(json_agg(datname ORDER BY datname),'[]'::json) FROM pg_database
 WHERE datname IN ($databaseList) AND datname<>current_database() AND has_database_privilege(current_user,oid,'CONNECT'))
);
"@
    $raw=Invoke-PostgresTool -ToolPath $PsqlPath -Arguments @('-X','-A','-t','-v','ON_ERROR_STOP=1','-c',$query) -PassFile $PassFile -UserName $UserName -Database $Manifest.database.name -Capture @connection
    $evidence=$raw|ConvertFrom-Json -AsHashtable
    if($remote -and ($evidence.transportSsl -ne $true -or $evidence.serverAddress -cne $HostAddress)){
        throw 'Remote PostgreSQL evidence did not arrive over verified TLS at the approved database address.'
    }
    if($evidence.database -ne $Manifest.database.name -or $evidence.schemaVersion -ne $Manifest.database.schemaVersion -or
        $evidence.privilegedRole -or $evidence.ownerMember -or $evidence.migratorMember -or $evidence.canAlterLedger -or
        -not $evidence.ContainsKey('canAlterImportLedger') -or $evidence.canAlterImportLedger -or
        $evidence.canCreateSchema -or $evidence.canCreatePublic -or $evidence.crossSolutionConnect.Count){
        throw 'PostgreSQL database/schema/runtime-isolation verification failed.'
    }
    $evidence.schemaFingerprint=Get-Sha256Text (ConvertTo-CanonicalJson $evidence.schemaDefinition)
    $evidence.Remove('schemaDefinition')
    $evidence.endpoint=@{mode=$(if($remote){'Remote'}else{'Loopback'});hostName=$HostName;hostAddress=$(if($remote){$HostAddress}else{$null})
        port=$Port;sslMode=$(if($remote){'verify-full'}else{$null});endpointSHA256=$(if($EndpointSHA256){$EndpointSHA256}else{$null})}
    $evidence.verifiedLocal=(Get-Date).ToString('o')
    $evidence
}

function Backup-PostgresDatabase {
    param([Parameter(Mandatory)][hashtable]$Manifest,[Parameter(Mandatory)][string]$ToolDirectory,
        [Parameter(Mandatory)][string]$PassFile,[Parameter(Mandatory)][string]$UserName,
        [Parameter(Mandatory)][string]$OutputPath,[Parameter(Mandatory)][string]$ApprovedToolSHA256,
        [Parameter(Mandatory)][string]$ApprovedPsqlSHA256,
        [Parameter(Mandatory)][string]$ApprovedPlanHash,[Parameter(Mandatory)][string]$PlanHash,
        [switch]$Execute,[int]$Port=5432)
    if($ApprovedPlanHash -ne $PlanHash -or $PlanHash -notmatch '^[a-f0-9]{64}$'){throw 'Backup approval must match the exact deployment plan.'}
    $dump=Join-Path $ToolDirectory 'pg_dump.exe'
    if((Get-FileHash -LiteralPath $dump).Hash.ToLowerInvariant() -ne $ApprovedToolSHA256){throw 'Backup tool differs from the approved executable.'}
    if(Test-Path -LiteralPath $OutputPath){throw 'Backup output exists. Never overwrite a prior backup.'}
    if(-not $Execute){return @{status='Preview';database=$Manifest.database.name;format='custom';output=$OutputPath}}
    $psql=Join-Path $ToolDirectory 'psql.exe'
    if((Get-FileHash -LiteralPath $psql).Hash.ToLowerInvariant() -ne $ApprovedPsqlSHA256){throw 'Backup version verifier differs from approved bytes.'}
    $version=Invoke-PostgresTool -ToolPath $psql -Arguments @('-X','-A','-t','-v','ON_ERROR_STOP=1','-c',"SELECT current_setting('server_version_num');") -PassFile $PassFile -Port $Port -UserName $UserName -Database $Manifest.database.name -Capture
    Assert-PostgresToolVersion $dump ([int]$version)
    $temporary=$OutputPath+'.partial'
    if(Test-Path -LiteralPath $temporary){throw 'A partial backup exists; inspect it before retrying.'}
    Invoke-PostgresTool -ToolPath $dump -Arguments @('--format=custom','--file',$temporary,'--no-owner','--no-acl') -PassFile $PassFile -Port $Port -UserName $UserName -Database $Manifest.database.name
    [IO.File]::Move($temporary,$OutputPath,$false)
    $proof=@{database=$Manifest.database.name;planHash=$PlanHash;sha256=(Get-FileHash -LiteralPath $OutputPath).Hash.ToLowerInvariant();bytes=(Get-Item -LiteralPath $OutputPath).Length;format='custom';restoredAndVerified=$false;createdLocal=(Get-Date).ToString('o')}
    Write-DeploymentJson ($OutputPath+'.json') $proof
    $proof
}

function Restore-PostgresValidationDatabase {
    param([Parameter(Mandatory)][string]$PgRestorePath,[Parameter(Mandatory)][string]$PassFile,
        [Parameter(Mandatory)][string]$UserName,[Parameter(Mandatory)][string]$Database,
        [Parameter(Mandatory)][string]$BackupPath,[Parameter(Mandatory)][string]$ApprovedBackupSHA256,
        [Parameter(Mandatory)][string]$ApprovedPsqlSHA256,
        [Parameter(Mandatory)][string]$IndependentReviewReference,[Parameter(Mandatory)][string]$JournalPath,
        [switch]$Execute,[int]$Port=5432)
    Assert-PostgresName $Database
    if($Database -notmatch '^sd_validate_[a-z0-9_]+$'){throw 'Restore validation must target a separately approved sd_validate_* database, never a production app database.'}
    if((Get-FileHash -LiteralPath $BackupPath).Hash.ToLowerInvariant() -ne $ApprovedBackupSHA256){throw 'Backup hash differs from review.'}
    if([string]::IsNullOrWhiteSpace($IndependentReviewReference)){throw 'Restore is a database write and requires independent exact-action review.'}
    if(-not $Execute){return @{status='Preview';database=$Database;backupSHA256=$ApprovedBackupSHA256}}
    if(Test-Path -LiteralPath $JournalPath){throw 'Restore journal exists. Review the prior outcome before retrying.'}
    Write-DeploymentJson $JournalPath @{status='Running';database=$Database;backupSHA256=$ApprovedBackupSHA256;review=$IndependentReviewReference}
    try{
        $psql=Join-Path (Split-Path -Parent $PgRestorePath) 'psql.exe'
        if((Get-FileHash -LiteralPath $psql).Hash.ToLowerInvariant() -ne $ApprovedPsqlSHA256){throw 'Restore version verifier differs from approved bytes.'}
        $version=Invoke-PostgresTool -ToolPath $psql -Arguments @('-X','-A','-t','-v','ON_ERROR_STOP=1','-c',"SELECT current_setting('server_version_num');") -PassFile $PassFile -Port $Port -UserName $UserName -Database $Database -Capture
        Assert-PostgresToolVersion $PgRestorePath ([int]$version)
        $count=Invoke-PostgresTool -ToolPath $psql -Arguments @('-X','-A','-t','-v','ON_ERROR_STOP=1','-c',"SELECT count(*) FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname='public' AND c.relkind IN ('r','p','v','m','S');") -PassFile $PassFile -Port $Port -UserName $UserName -Database $Database -Capture
        if([int]$count -ne 0){throw 'Validation restore target is not empty. Refusing to overwrite existing objects.'}
        Invoke-PostgresTool -ToolPath $PgRestorePath -Arguments @('--dbname',$Database,'--no-owner','--no-acl','--exit-on-error','--single-transaction',$BackupPath) -PassFile $PassFile -Port $Port -UserName $UserName -Database $Database
        Write-DeploymentJson $JournalPath @{status='RestoredNeedsParityValidation';database=$Database;backupSHA256=$ApprovedBackupSHA256;review=$IndependentReviewReference;completedLocal=(Get-Date).ToString('o')}
    }catch{
        Write-DeploymentJson $JournalPath @{status='FailedOrUnknown';database=$Database;backupSHA256=$ApprovedBackupSHA256;review=$IndependentReviewReference}
        throw
    }
}

Export-ModuleMember -Function Assert-PostgresName,Assert-PostgresProtectedFile,Get-PostgresRoleNames,Get-PostgresEndpointDigest,Get-PostgresConnectionPolicy,Get-PostgresConnectionParameters,Assert-PostgresRuntimeConnectionString,Invoke-PostgresTool,Assert-PostgresToolVersion,Get-PostgresProvisioningPlan,Get-PostgresSnapshot,Invoke-PostgresReviewedSql,Get-PostgresDatabaseEvidence,Backup-PostgresDatabase,Restore-PostgresValidationDatabase
