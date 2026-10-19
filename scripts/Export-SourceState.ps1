#requires -Version 7.5
[CmdletBinding(SupportsShouldProcess,ConfirmImpact='High')]
param(
    [Parameter(Mandatory)][string]$PlanPath,
    [Parameter(Mandatory)][string]$ApprovedPlanHash,
    [Parameter(Mandatory)][string]$FencePath,
    [Parameter(Mandatory)][string]$ApprovedFenceSHA256,
    [Parameter(Mandatory)][string]$Destination,
    [string]$PythonPath,
    [string]$ReviewedSnapshotSHA256,
    [switch]$ApproveStateExport
)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$framework=Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $framework 'src\Deployment.psm1') -DisableNameChecking
Import-Module (Join-Path $framework 'src\Transfer.psm1') -DisableNameChecking
$plan=Read-DeploymentJson $PlanPath
if($plan.schemaVersion -ne 2 -or $plan.planHash -ne $ApprovedPlanHash -or (Get-PlanDigest $plan) -ne $ApprovedPlanHash){
    throw 'Export requires the exact reviewed host-aware plan.'
}
if($plan.operation -ne 'Cutover' -or $plan.observedHost -ine $env:COMPUTERNAME -or
    -not $plan.sourceHostSnapshot.verified -or
    (Get-CimInstance Win32_ComputerSystemProduct -Property UUID).UUID -ne $plan.sourceHostSnapshot.identity){
    throw 'Export must run on the verified source host for the reviewed Cutover.'
}
if((Get-FileHash -LiteralPath $FencePath).Hash.ToLowerInvariant() -ne $ApprovedFenceSHA256){throw 'Source fence differs from the reviewed evidence.'}
$fence=Read-DeploymentJson $FencePath
Assert-SourceFence $plan.transferManifest $fence $plan.id
$inventory=Get-StateInventory $plan.transferManifest
if(-not $inventory.complete){throw 'Required source state is missing.'}
if(-not $ApproveStateExport){throw 'Export needs explicit -ApproveStateExport after independent review of any SQLite snapshot action.'}
if($PSCmdlet.ShouldProcess("$($plan.observedHost) / $Destination","Export $($inventory.totalBytes) bytes of frozen $($plan.transitionKind) state")){
    Export-FrozenState -Plan $plan -Fence $fence -Destination $Destination -PythonPath $PythonPath -ReviewedSnapshotSHA256 $ReviewedSnapshotSHA256
}
