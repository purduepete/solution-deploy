#requires -Version 7.5
[CmdletBinding(SupportsShouldProcess,ConfirmImpact='Medium')]
param(
    [Parameter(Mandatory)][string]$PlanPath,
    [string]$UserName='postgres',
    [switch]$Replace
)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
function ConvertTo-PostgresPasswordField {
    param([Parameter(Mandatory)][string]$Value)
    if($Value.Contains("`r") -or $Value.Contains("`n") -or $Value.Contains([char]0)){
        throw 'Password files cannot contain newline or NUL characters.'
    }
    $Value.Replace('\','\\').Replace(':','\:')
}
$framework=Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $framework 'src\Deployment.psm1') -DisableNameChecking
Import-Module (Join-Path $framework 'src\PostgreSQL.psm1') -DisableNameChecking
Import-Module (Join-Path $framework 'src\SshTransport.psm1') -DisableNameChecking
$plan=Read-DeploymentJson $PlanPath
if($plan.schemaVersion -ne 2 -or $plan.planHash -ne (Get-PlanDigest $plan)){throw 'Use the unchanged, host-aware deployment plan.'}
Assert-PostgresName $UserName
$policy=Get-PostgresConnectionPolicy -Plan $plan -ClientHost $plan.databaseTarget.host
if($policy.DatabaseHost -ine 'jimbrownhome1'){throw 'PostgreSQL credentials must stay on jimbrownhome1.'}
$target=@{}+$plan.target
foreach($field in @('host','address','root')){$target[$field]=$plan.databaseTarget[$field]}
$observed=Get-HostSnapshot $target
if($observed.identity -ne $policy.DatabaseHostIdentity){throw 'Database host identity changed. No password was requested or stored.'}
$directory=Get-DeploymentRemotePath $policy.DatabaseHost 'C:\ProgramData\JimlerTech\PostgreSQL'
$path=Join-Path $directory ($UserName+'.pgpass')
if((Test-Path -LiteralPath $path) -and -not $Replace){throw 'Password file already exists. Use -Replace only to intentionally replace it.'}
if(-not $PSCmdlet.ShouldProcess("$($policy.DatabaseHost) / $UserName",'Save a private PostgreSQL password file; no database changes')){return}
if(-not [Environment]::UserInteractive -or $Host.Name -ne 'ConsoleHost' -or $env:TERM_PROGRAM -eq 'vscode'){
    throw 'Run this script in a standalone PowerShell terminal outside VS Code, where the password can be entered securely.'
}
foreach($item in @($directory,$path)){
    if((Test-Path -LiteralPath $item) -and ((Get-Item -LiteralPath $item -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)){
        throw 'Credential storage cannot be a reparse point.'
    }
}
$parent=Split-Path -Parent $directory
if((Test-Path -LiteralPath $parent) -and ((Get-Item -LiteralPath $parent -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)){
    throw 'Credential parent cannot be a reparse point.'
}
Invoke-DeploymentFileOperation CreateDirectory @($directory)|Out-Null
$acl=[Security.AccessControl.DirectorySecurity]::new()
$acl.SetAccessRuleProtection($true,$false)
foreach($sid in @('S-1-5-18','S-1-5-32-544')){
    $principal=[Security.Principal.SecurityIdentifier]::new($sid)
    $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($principal,'FullControl','ContainerInherit,ObjectInherit','None','Allow'))
}
Set-Acl -LiteralPath $directory -AclObject $acl
$password=Read-Host "PostgreSQL password for $UserName on $($policy.DatabaseHost) (input hidden)" -AsSecureString
$pointer=[IntPtr]::Zero
$plain=$null;$line=$null;$bytes=$null
$temporary=Join-Path $directory ('.password-'+[guid]::NewGuid().ToString('N'))
try{
    if($password.Length -eq 0){throw 'The password is empty; nothing was saved.'}
    $pointer=[Runtime.InteropServices.Marshal]::SecureStringToBSTR($password)
    $plain=[Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer)
    $escaped=ConvertTo-PostgresPasswordField $plain
    $line="127.0.0.1:$($policy.Port):*:${UserName}:$escaped`n"
    $bytes=[Text.Encoding]::UTF8.GetBytes($line)
    $remote=Resolve-DeploymentSshPath $temporary
    if($remote){
        Invoke-DeploymentSsh $remote.hostName {param($path,$bytes)
            $stream=[IO.File]::Open($path,'CreateNew','Write','None')
            try{$stream.Write([byte[]]$bytes);$stream.Flush($true)}finally{$stream.Dispose()}
        } @($remote.path,$bytes)
    }else{
        $stream=[IO.File]::Open($temporary,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
        try{$stream.Write($bytes);$stream.Flush($true)}finally{$stream.Dispose()}
    }
    Assert-PostgresProtectedFile -Path $temporary -Purpose 'password file' -DenyBroadRead
    Invoke-DeploymentFileOperation Move @($temporary,$path,[bool]$Replace)
    Assert-PostgresProtectedFile -Path $path -Purpose 'password file' -DenyBroadRead
    [pscustomobject]@{
        Status='Saved';DatabaseHost=$policy.DatabaseHost;UserName=$UserName
        ServerPath="C:\ProgramData\JimlerTech\PostgreSQL\$UserName.pgpass"
        DatabaseChangesPerformed=$false
    }
}finally{
    if($pointer -ne [IntPtr]::Zero){[Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer)}
    if($bytes){[Array]::Clear($bytes,0,$bytes.Length)}
    $plain=$null;$escaped=$null;$line=$null
    if($password){$password.Dispose()}
    if(Test-Path -LiteralPath $temporary){Invoke-DeploymentFileOperation Delete @($temporary)}
}
