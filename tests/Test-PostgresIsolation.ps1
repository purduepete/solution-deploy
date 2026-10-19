#requires -Version 7.4
[CmdletBinding()]
param([Parameter(Mandatory)][ValidatePattern('^solutiondeploy-pg-[a-f0-9]{8}$')][string]$ContainerName)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'src\PostgreSQL.psm1') -DisableNameChecking
$docker=(Get-Command docker.exe -CommandType Application|Select-Object -First 1).Source
$label=& $docker inspect --format '{{index .Config.Labels "solutiondeploy.fixture"}}' $ContainerName
if($LASTEXITCODE -ne 0 -or $label -ne 'true'){throw 'Isolation test requires the exact independently reviewed disposable fixture.'}
function Invoke-TestPsql([string]$Database,[string]$UserName,[string]$Sql,[switch]$ExpectFailure){
    if($Database -notin @('postgres','sd_test_roles_a','sd_test_roles_b','sd_validate_roles')){throw 'Synthetic role test cannot target any other database.'}
    $output=$Sql|& $docker exec --interactive $ContainerName psql --no-psqlrc --no-password --username $UserName --dbname $Database --set ON_ERROR_STOP=1 --tuples-only --no-align 2>&1
    $exit=$LASTEXITCODE
    if($ExpectFailure){if($exit -eq 0){throw 'A forbidden database action unexpectedly succeeded.'};return}
    if($exit -ne 0){throw 'Synthetic role/isolation SQL failed. Server output withheld.'}
    return ,@($output|ForEach-Object{[string]$_})
}
$snapshot=@{hostIdentity='synthetic-container';serverVersion='18';serverSystemIdentifier='synthetic';databases=@('postgres','sd_test_ferry','sd_test_home','sd_test_sitedock');roles=@('postgres')}
foreach($name in @('sd_test_roles_a','sd_test_roles_b')){
    $manifest=@{id='test-app';database=@{engine='postgresql';name=$name;schemaVersion=1}}
    $plan=Get-PostgresProvisioningPlan $manifest $snapshot
    Invoke-TestPsql postgres postgres $plan.provisioningSql|Out-Null
    $snapshot.databases+=$name;$snapshot.roles+=@($plan.roles.Values)
    $schema=@"
SET ROLE "$($plan.roles.owner)";
BEGIN;
CREATE TABLE public.solutiondeploy_schema(app_id text PRIMARY KEY, version integer NOT NULL);
INSERT INTO public.solutiondeploy_schema VALUES('test-app',1);
CREATE TABLE public.item(id bigserial PRIMARY KEY, payload jsonb NOT NULL);
COMMIT;
"@
    Invoke-TestPsql $name $plan.roles.migrator $schema|Out-Null
    Invoke-TestPsql $name $plan.roles.migrator ('BEGIN; SET ROLE "'+$plan.roles.owner+'";'+$plan.runtimeGrantsSql+'COMMIT;')|Out-Null
}
$role=(Get-PostgresRoleNames sd_test_roles_a).runtime
$result=Invoke-TestPsql sd_test_roles_a $role @"
INSERT INTO public.item(payload) VALUES('{"value":"synthetic"}');
SELECT count(*)::text||':'||(SELECT version::text FROM public.solutiondeploy_schema WHERE app_id='test-app') FROM public.item;
"@
if($result[-1] -ne '1:1'){throw 'Runtime data writes, sequence permissions, or schema ledger reads failed.'}
Invoke-TestPsql sd_test_roles_a $role 'UPDATE public.solutiondeploy_schema SET version=99;' -ExpectFailure
Invoke-TestPsql sd_test_roles_a $role 'CREATE TABLE public.forbidden(id int);' -ExpectFailure
Invoke-TestPsql sd_test_roles_b $role 'SELECT 1;' -ExpectFailure
$privileges=Invoke-TestPsql sd_test_roles_a $role @"
SELECT (rolsuper OR rolcreatedb OR rolcreaterole OR rolreplication OR rolbypassrls)::text
||':'||pg_has_role(current_user,'sd_sd_test_roles_a_owner','MEMBER')::text
||':'||pg_has_role(current_user,'sd_sd_test_roles_a_migrator','MEMBER')::text
FROM pg_roles WHERE rolname=current_user;
"@
if($privileges[-1] -ne 'false:false:false'){throw 'Runtime has excess PostgreSQL role privileges.'}
& $docker exec $ContainerName pg_dump --no-password --username $role --dbname sd_test_roles_a --format custom --no-owner --no-acl --file /tmp/solutiondeploy-proof.dump
if($LASTEXITCODE -ne 0){throw 'Synthetic role backup failed.'}
& $docker exec $ContainerName createdb --username postgres sd_validate_roles
if($LASTEXITCODE -ne 0){throw 'Synthetic validation database creation failed.'}
Invoke-TestPsql sd_validate_roles postgres 'REVOKE ALL ON DATABASE sd_validate_roles FROM PUBLIC;'|Out-Null
& $docker exec $ContainerName pg_restore --no-password --username postgres --dbname sd_validate_roles --no-owner --no-acl --exit-on-error --single-transaction /tmp/solutiondeploy-proof.dump
if($LASTEXITCODE -ne 0){throw 'Synthetic backup restore failed.'}
$restored=Invoke-TestPsql sd_validate_roles postgres "SELECT id::text||':'||(payload->>'value') FROM public.item;"
if($restored[-1] -ne '1:synthetic'){throw 'Restored data does not match the synthetic source.'}
@{status='Passed';runtimeDml=$true;sequenceUsage=$true;ledgerWriteDenied=$true;schemaCreateDenied=$true;crossDatabaseDenied=$true;privilegedMembershipDenied=$true;customBackupRestored=$true;productionAccess=$false}
