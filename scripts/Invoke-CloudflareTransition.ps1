#requires -Version 7.4
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$DeploymentPlanPath,
    [Parameter(Mandatory)][string]$ApprovalPath,
    [Parameter(Mandatory)][string]$RoutePlanPath,
    [Parameter(Mandatory)][string]$JournalDirectory,
    [string]$TokenEnvironmentVariable='CLOUDFLARE_API_TOKEN',
    [switch]$Execute
)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $root 'src\Deployment.psm1') -DisableNameChecking
Import-Module (Join-Path $root 'src\Cloudflare.psm1') -DisableNameChecking
Import-Module (Join-Path $root 'src\Lifecycle.psm1') -DisableNameChecking
Import-Module (Join-Path $root 'src\Operations.psm1') -DisableNameChecking
$deployment=Read-DeploymentJson $DeploymentPlanPath
$approval=Assert-DeploymentApproval $deployment $ApprovalPath $deployment.operation
foreach($key in @('routePlanSHA256','routePlanHash','routeTunnelId','verificationSHA256','externalReview')){
    if(-not $approval.ContainsKey($key)){throw "Route approval missing $key."}
}
if([string]::IsNullOrWhiteSpace($approval.externalReview)){throw 'Route transition requires review of its exact Access, DNS, tunnel, and policy changes.'}
if((Get-FileHash -LiteralPath $RoutePlanPath).Hash.ToLowerInvariant() -ne $approval.routePlanSHA256){throw 'Route plan differs from the reviewed artifact.'}
$route=Read-DeploymentJson $RoutePlanPath
Assert-CloudflareRoutePlan -Plan $route | Out-Null
if($route.PlanHash -cne $approval.routePlanHash){throw 'Route approval hash mismatch.'}
if($route.Status -notin @('Ready','NoChange')){throw 'Cloudflare route plan is blocked.'}
if($route.AppId -cne $deployment.app){throw 'Route plan belongs to a different app.'}
# routeTunnelId is the reviewer's explicit tunnel for this host profile; it is never inferred from a name.
$binding=Assert-CloudflareDeploymentBinding -Plan $route -DeploymentPlan $deployment -ApprovedTunnelId $approval.routeTunnelId
if($binding.Target.RouteProfile -cne $approval.routeProfile){throw 'Route plan host profile differs from the approved route profile.'}
if($env:COMPUTERNAME -ine $deployment.target.host -or (Get-CimInstance Win32_ComputerSystemProduct -Property UUID).UUID -ne $deployment.hostSnapshot.identity){throw 'Route transition must run on the approved destination, where the loopback upstream and catch token can be reverified.'}
$appRoot=Resolve-OwnedPath $deployment.target.root ('apps\'+$deployment.app)
$verificationPath=Join-Path $appRoot 'state\verification.json'
if((Get-FileHash -LiteralPath $verificationPath).Hash.ToLowerInvariant() -ne $approval.verificationSHA256){throw 'Runtime verification evidence differs from approval.'}
$verification=Read-DeploymentJson $verificationPath
if($verification.planHash -ne $deployment.planHash -or $verification.status -ne 'RuntimeVerified' -or $verification.releaseId -ne $deployment.releaseId){throw 'The approved release is not the runtime that passed local verification.'}
$active=Read-DeploymentJson (Join-Path $appRoot 'state\active.json')
if($active.releaseId -ne $verification.releaseId -or $active.planHash -ne $verification.planHash){throw 'Active runtime changed after the approved verification.'}
$current=Join-Path $appRoot 'current'
$manifest=Read-LifecycleManifest -Path (Join-Path $current 'deploy\application.json') -AppRoot $appRoot -ReleasePath $current
$runtime=Get-ReleaseRuntimePath -AppRoot $appRoot -ReleasePath $current -Manifest $manifest
$identity=Test-ManagedAppIdentity -AppRoot $appRoot -ReleasePath $current -Manifest $manifest -RuntimePath $runtime
if(-not $identity.Verified -or -not $identity.ListenerOwned){throw 'The approved upstream is not currently owned by its verified runtime.'}
$readiness=Test-AppReadiness -Port $manifest.launch.port -Path $manifest.readiness.path -Expected $manifest.readiness.expected -TimeoutSeconds 30
if(-not $readiness.Ready){throw 'The destination upstream failed live readiness before routing.'}
Assert-DatabaseActivationEvidence $deployment $approval $appRoot | Out-Null
# Cloudflare execution rechecks live Access/ownership and Ferry token refusals before writes.
Invoke-CloudflareRoutePlan -Plan $route -ApprovedPlanHash $approval.routePlanHash -JournalDirectory $JournalDirectory -TokenEnvironmentVariable $TokenEnvironmentVariable -Execute:$Execute
