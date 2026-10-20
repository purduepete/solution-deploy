#requires -Version 7.5
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('Plan','Stage','PrepareCutover','Deploy','Cutover','Verify','Status','Rollback')][string]$Action,
    [string]$App,
    [string]$Environment='production',
    [string]$Target,
    [string]$Commit='HEAD',
    [string]$PlanPath,
    [string]$ApprovalPath,
    [string]$RuntimePath,
    [string]$NpmPath,
    [string]$TransferDirectory,
    [string]$TransferArchivePath,
    [string]$OutputDirectory=(Join-Path $PSScriptRoot '.local'),
    [ValidateRange(60,1800)][int]$TimeoutSeconds=300,
    [switch]$Offline,
    [switch]$OpenReport
)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'src\Deployment.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'src\Controller.psm1') -DisableNameChecking

if ($Action -eq 'Plan') {
    if (-not $App) { throw 'Plan requires -App.' }
    $plan = New-DeploymentPlan -App $App -Environment $Environment -Target $Target -Commit $Commit -Offline:$Offline
    $directory = Join-Path $OutputDirectory 'plans'
    $path = Join-Path $directory ($plan.id+'.json')
    Write-DeploymentJson $path $plan
    Export-DeploymentReport $plan (Join-Path $directory ($plan.id+'.html')) -Open:$OpenReport | Out-Host
    $plan | Select-Object id,app,operation,status,planHash,blockers
    return
}
if (-not $PlanPath) { throw "$Action requires -PlanPath." }
$plan = Read-DeploymentJson $PlanPath
Assert-PlanInputs $plan
if ($App -and $App -ne $plan.app) { throw 'App does not match the saved plan.' }
if ($Environment -ne $plan.environment) { throw 'Environment does not match the saved plan.' }
if ($Target -and $Target -ine $plan.target.host) { throw 'Target does not match the saved plan. Replan instead of redirecting an approved operation.' }
if ($Action -eq 'Status') {
    Get-RemoteDeploymentStatus -Plan $plan
    return
}
if (-not $ApprovalPath) { throw "$Action requires explicit approval of the exact saved plan." }
$approval = Assert-DeploymentApproval $plan $ApprovalPath $Action
Submit-DeploymentOperation -Plan $plan -ApprovalPath $ApprovalPath -Action $Action `
    -RuntimePath $RuntimePath -NpmPath $NpmPath -TransferDirectory $TransferDirectory     -TransferArchivePath $TransferArchivePath -TimeoutSeconds $TimeoutSeconds