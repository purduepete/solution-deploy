#requires -Version 7.4
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidatePattern('^[a-f0-9]{8}$')][string]$SessionSuffix,
    [Parameter(Mandatory)][ValidatePattern('^[a-f0-9]{64}$')][string]$ReviewedScriptSHA256,
    [Parameter(Mandatory)][string]$IndependentReviewReference,
    [Parameter(Mandatory)][ValidatePattern('^postgres@sha256:[a-f0-9]{64}$')][string]$ImageDigest,
    [switch]$Execute
)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
if((Get-FileHash -LiteralPath $PSCommandPath).Hash.ToLowerInvariant() -ne $ReviewedScriptSHA256){throw 'Fixture launcher differs from independently reviewed code.'}
if([string]::IsNullOrWhiteSpace($IndependentReviewReference)){throw 'Disposable database initialization requires independent review before execution.'}
$config=Get-Content -LiteralPath (Join-Path $PSScriptRoot 'postgres-container.json') -Raw|ConvertFrom-Json
if($config.cpus -ne 2 -or $config.memory -ne '1g' -or ($config.databaseNames -join ',') -ne 'sd_test_ferry,sd_test_home,sd_test_sitedock'){throw 'Test fixture resource/database manifest changed.'}
$name='solutiondeploy-pg-'+$SessionSuffix
if(-not $Execute){return @{name=$name;image=$ImageDigest;databases=$config.databaseNames;status='Preview'}}
$docker=(Get-Command docker.exe -CommandType Application | Select-Object -First 1).Source
function Invoke-FixtureDocker([string[]]$DockerArguments){
    $start=[Diagnostics.ProcessStartInfo]::new()
    $start.FileName=$docker;$start.UseShellExecute=$false;$start.CreateNoWindow=$true
    $start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true
    foreach($arg in $DockerArguments){$start.ArgumentList.Add($arg)}
    $process=[Diagnostics.Process]::new();$process.StartInfo=$start
    try{
        if(-not $process.Start()){throw 'Docker did not start.'}
        $output=$process.StandardOutput.ReadToEndAsync();$errorOutput=$process.StandardError.ReadToEndAsync()
        if(-not $process.WaitForExit(60000)){$process.Kill($true);throw 'Docker fixture command exceeded 60 seconds.'}
        if($process.ExitCode -ne 0){throw 'Docker fixture command failed. Output withheld because container environment may contain a test credential.'}
        $output.GetAwaiter().GetResult().Trim()
    }finally{$process.Dispose()}
}
$existing=@(& $docker ps --all --filter "name=^/$name$" --format '{{.Names}}')
if($LASTEXITCODE -ne 0 -or $existing.Count){throw 'A fixture with this exact name already exists or Docker is unavailable. Inspect it rather than reusing or deleting it.'}
$password=[Convert]::ToHexString([Security.Cryptography.RandomNumberGenerator]::GetBytes(24)).ToLowerInvariant()
$previous=[Environment]::GetEnvironmentVariable('POSTGRES_PASSWORD','Process')
$started=$false
try{
    [Environment]::SetEnvironmentVariable('POSTGRES_PASSWORD',$password,'Process')
    Invoke-FixtureDocker @('run','--detach','--name',$name,'--label','solutiondeploy.fixture=true',
        '--cpus','2','--memory','1g','--shm-size','64m','--tmpfs','/var/lib/postgresql:rw,size=768m',
        '--publish','127.0.0.1::5432','--env','POSTGRES_PASSWORD',$ImageDigest)|Out-Null
    $started=$true
    $resources=Invoke-FixtureDocker @('inspect','--format','{{.HostConfig.NanoCpus}} {{.HostConfig.Memory}}',$name)
    if($resources -ne '2000000000 1073741824'){throw 'Docker did not grant the requested 2 CPUs / 1 GiB. Fixture is not usable.'}
    $ready=$false
    foreach($attempt in 1..30){
        & $docker exec $name pg_isready --username postgres --quiet 2>$null|Out-Null
        if($LASTEXITCODE -eq 0){$ready=$true;break}
        Start-Sleep -Seconds 1
    }
    if(-not $ready){throw 'Synthetic PostgreSQL fixture did not become ready within 30 seconds.'}
    foreach($database in $config.databaseNames){
        Invoke-FixtureDocker @('exec',$name,'createdb','--username','postgres',$database)|Out-Null
    }
    $binding=Invoke-FixtureDocker @('port',$name,'5432/tcp')
    if($binding -notmatch '^127\.0\.0\.1:(\d+)$'){throw 'Fixture listener is not bound exclusively to loopback.'}
    $port=[int]$Matches[1]
    # This is an in-memory return value. Callers must not serialize or display it.
    return @{name=$name;port=$port;password=$password;user='postgres';databases=$config.databaseNames;status='Ready';review=$IndependentReviewReference;image=$ImageDigest}
}catch{
    if($started){Invoke-FixtureDocker @('rm','--force',$name)|Out-Null}
    throw
}finally{
    [Environment]::SetEnvironmentVariable('POSTGRES_PASSWORD',$previous,'Process')
}
