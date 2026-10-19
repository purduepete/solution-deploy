#requires -Version 7.5
[CmdletBinding(SupportsShouldProcess)]
param([switch]$Replace)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
if(-not $IsWindows){throw 'This credential helper requires Windows DPAPI.'}
$directory=Join-Path $env:LOCALAPPDATA 'JimlerTech\SolutionDeploy'
$path=Join-Path $directory 'cloudflare-token.dpapi.xml'
if((Test-Path -LiteralPath $path) -and -not $Replace){throw 'A protected token already exists. Use -Replace only to replace it intentionally.'}
if(-not $PSCmdlet.ShouldProcess($path,'Save a user-bound encrypted Cloudflare API token; no Cloudflare changes')){return}
if(-not [Environment]::UserInteractive -or $Host.Name -ne 'ConsoleHost' -or $env:TERM_PROGRAM -eq 'vscode'){
    throw 'Run this helper in PowerShell 7 outside VS Code so the token is entered only at a masked prompt.'
}
$cursor=$directory
while($cursor){
    if((Test-Path -LiteralPath $cursor) -and ((Get-Item -LiteralPath $cursor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'Credential storage cannot use reparse-point directories.'}
    $cursor=Split-Path -Parent $cursor
}
if((Test-Path -LiteralPath $path) -and ((Get-Item -LiteralPath $path -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'Credential file cannot be a reparse point.'}
[IO.Directory]::CreateDirectory($directory)|Out-Null
$acl=[Security.AccessControl.DirectorySecurity]::new()
$acl.SetAccessRuleProtection($true,$false)
$user=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value
foreach($sid in @($user,'S-1-5-18','S-1-5-32-544')|Select-Object -Unique){
    $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new(
        [Security.Principal.SecurityIdentifier]::new($sid),'FullControl','ContainerInherit,ObjectInherit','None','Allow'))
}
[IO.FileSystemAclExtensions]::SetAccessControl([IO.DirectoryInfo]::new($directory),$acl)
$token=$null
$temporary=Join-Path $directory ('.token-'+[guid]::NewGuid().ToString('N'))
try{
    $token=Read-Host 'Cloudflare API token (input hidden; never paste it in chat)' -AsSecureString
    if($token.Length -eq 0){throw 'Token is empty; nothing was saved.'}
    $token|Export-Clixml -LiteralPath $temporary -NoClobber
    [IO.File]::Move($temporary,$path,[bool]$Replace)
    [pscustomobject]@{Status='Saved';Path=$path;Protection='Windows DPAPI, current Windows user and machine';CloudflareChangesPerformed=$false}
}finally{
    if($token){$token.Dispose()}
    if([IO.File]::Exists($temporary)){[IO.File]::Delete($temporary)}
}
