#requires -Version 7.4
#requires -RunAsAdministrator
[CmdletBinding(SupportsShouldProcess,ConfirmImpact='High')]
param(
    [Parameter(Mandatory)][string]$Root,
    [Parameter(Mandatory)][ValidatePattern('^[a-z][a-z0-9-]{1,39}$')][string]$AppId,
    [Parameter(Mandatory)][string]$Account,
    [Parameter(Mandatory)][string]$ExpectedAccountSid,
    [switch]$ApproveProvisioning
)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
if(-not $ApproveProvisioning){throw 'Runtime toolkit ACL changes require explicit provisioning approval.'}
if($Root -ne 'C:\ProgramData\SolutionDeploy'){throw 'Unexpected deployment root.'}
$sid=([Security.Principal.NTAccount]::new($Account)).Translate([Security.Principal.SecurityIdentifier])
if($sid.Value -ne $ExpectedAccountSid){throw 'Runtime account SID differs from the approved identity.'}
if($sid.Value -in @('S-1-5-18','S-1-5-19','S-1-5-20')){throw 'A dedicated non-service runtime identity is required.'}
$administrators=Get-LocalGroupMember -SID 'S-1-5-32-544' -ErrorAction Stop
if($sid.Value -in @($administrators.SID.Value)){throw 'Runtime account must not be a local administrator.'}
$installPath=Join-Path $Root 'control\installation.json'
if(-not (Test-Path -LiteralPath $installPath)){throw 'Provision and verify the protected host executor first.'}
if(-not $PSCmdlet.ShouldProcess($Account,'Grant read-only toolkit access and traversal of the dedicated deployment root')){return}
foreach($relative in @('.','control','apps')){
    $path=Join-Path $Root $relative
    $acl=Get-Acl -LiteralPath $path
    $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($sid,'ReadAndExecute','None','None','Allow'))
    Set-Acl -LiteralPath $path -AclObject $acl
}
$toolkit=Join-Path $Root 'control\framework'
$acl=Get-Acl -LiteralPath $toolkit
$acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($sid,'ReadAndExecute','ContainerInherit,ObjectInherit','None','Allow'))
Set-Acl -LiteralPath $toolkit -AclObject $acl
# No control journals, submission folders, other apps, or secret directories inherit this grant.
@{app=$AppId;accountSid=$sid.Value;toolkit=$toolkit;access='ReadAndExecute';status='Granted'}
