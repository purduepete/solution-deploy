#requires -Version 7.5
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'Deployment.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'Release.psm1') -DisableNameChecking

function Get-CommonReleaseRoute {
    param([Parameter(Mandatory)][string]$App,[string[]]$Component,
        [string]$Environment='production',[Parameter(Mandatory)][string]$Target)
    $root=Split-Path -Parent $PSScriptRoot
    $inventory=Read-DeploymentJson (Join-Path $root 'environments\releases.json')
    $configuration=Get-DeploymentEnvironment $Environment
    # The placement registry remains authoritative for controller apps, including future registrations.
    if($configuration.Value.apps.ContainsKey($App)){
        if($Component){throw 'Controller releases retain their complete managed scope; omit -Component.'}
        return @{procedure='controller'}
    }
    if($Environment -ne 'production'){throw 'Non-controller release procedures are verified only for production.'}
    if(-not $inventory.apps.ContainsKey($App)){throw "No release inventory entry for '$App'."}
    $entry=$inventory.apps[$App]
    if($Target -ine 'jimbrownhome1'){throw 'Non-controller releases support only the existing jimbrownhome1 placement. Host moves require a separate reviewed procedure.'}
    foreach($name in $Component){
        if($name -notin $entry.components){throw "Unknown component '$name' for '$App'. Allowed: $($entry.components -join ', ')."}
    }
    if($entry.ContainsKey('explicitComponents') -and $entry.explicitComponents -and -not $Component){
        throw "Shared host jobs require explicit -Component selection: $($entry.components -join ', ')."
    }
    # Pinned jobs run from their own release folder, independent of the app's web procedure.
    $jobs=if($entry.ContainsKey('jobs')){$entry.jobs}else{@{}}
    $selected=if($Component){@($Component)}else{@($entry.components)}
    $jobNames=@($selected|Where-Object {$jobs.ContainsKey($_)})
    $webNames=@($selected|Where-Object {-not $jobs.ContainsKey($_)})
    $procedure=$entry.procedure
    if(-not $webNames.Count){$procedure='none'}
    elseif($entry.procedure -in @('blocked','manual')){
        if($Component -or -not $jobNames.Count){throw "$App release blocked: $($entry.blocker)"}
        Write-Warning "$App $($webNames -join ', ') not released: $($entry.blocker)"
        $procedure='none'
    }
    if($procedure -ne 'none' -and $entry.ContainsKey('releasable')){
        $held=@($Component|Where-Object {$_ -and $_ -in $webNames -and $_ -notin $entry.releasable})
        if($held.Count){throw "$App component $($held -join ', ') is not releasable yet: $($entry.componentNote)"}
    }
    @{procedure=$procedure;entry=$entry;repository=[IO.Path]::GetFullPath((Join-Path $root $entry.source))
        webComponents=$webNames;jobs=$jobNames}
}

function Resolve-CommonReleaseSource {
    param([Parameter(Mandatory)][string]$Repository,[Parameter(Mandatory)][string]$Commit)
    $git=(Get-Command git -CommandType Application).Source
    if($Commit.StartsWith('-')){throw 'Commit must be a Git revision, not an option.'}
    $dirty=Invoke-DeploymentCommand $git @('--no-optional-locks','-c','core.fsmonitor=false','status','--porcelain','--untracked-files=normal') $Repository -Capture
    if($dirty){throw 'Release requires a clean committed source checkout.'}
    Invoke-DeploymentCommand $git @('-c','credential.interactive=false','fetch','--quiet','--prune','origin') $Repository
    $resolved=Invoke-DeploymentCommand $git @('rev-parse','--verify',($Commit+'^{commit}')) $Repository -Capture
    if($resolved -cnotmatch '^[a-f0-9]{40}$'){throw 'Could not resolve one immutable source commit.'}
    $branches=Invoke-DeploymentCommand $git @('for-each-ref',('--contains='+$resolved),'--format=%(refname)','refs/remotes/origin/') $Repository -Capture
    if([string]::IsNullOrWhiteSpace($branches)){throw 'Release commit is not reachable from a fetched origin branch. Push it first.'}
    $resolved
}

function Get-CommonReleaseChanges {
    param([Parameter(Mandatory)][string]$Repository,[Parameter(Mandatory)][string]$Baseline,
        [Parameter(Mandatory)][string]$Commit,[Parameter(Mandatory)][string[]]$Paths)
    if($Baseline -cnotmatch '^[a-f0-9]{40}$' -or $Commit -cnotmatch '^[a-f0-9]{40}$'){
        throw 'Component selection requires verified full deployed and requested commits.'
    }
    $git=(Get-Command git -CommandType Application).Source
    $changed=Invoke-DeploymentCommand $git (@('diff','--name-only',$Baseline,$Commit,'--')+$Paths) $Repository -Capture
    return -not [string]::IsNullOrWhiteSpace($changed)
}

function Invoke-CommonRelease {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$App,[string[]]$Component,[string]$Environment='production',
        [Parameter(Mandatory)][string]$Target,[string]$Commit='HEAD',
        [switch]$ApproveRelease,[Parameter(Mandatory)][string]$ApprovalReason,[switch]$DatabaseChangesReviewed,
        [DateTimeOffset]$ExpiresLocal=([DateTimeOffset]::Now.AddMinutes(30)),[string]$TailscaleUrl,
        [string]$OutputDirectory=(Join-Path (Split-Path -Parent $PSScriptRoot) '.local'),
        [ValidateRange(60,1800)][int]$TimeoutSeconds=300)
    $route=Get-CommonReleaseRoute -App $App -Component $Component -Environment $Environment -Target $Target
    $arguments=@{}+$PSBoundParameters
    [void]$arguments.Remove('Component')
    if($route.procedure -eq 'controller'){
        return Invoke-RoutineRelease @arguments
    }
    if(-not $ApproveRelease -or -not $DatabaseChangesReviewed -or [string]::IsNullOrWhiteSpace($ApprovalReason)){
        throw 'Release requires -ApproveRelease, a non-empty -ApprovalReason and -DatabaseChangesReviewed.'
    }
    if($ExpiresLocal -le [DateTimeOffset]::Now -or $ExpiresLocal -gt [DateTimeOffset]::Now.AddHours(1)){
        throw 'Release consent must expire within 1 hour.'
    }
    $arguments.Repository=$route.repository
    $results=@()
    if($route.procedure -ne 'none'){
        $arguments.Component=if($Component){@($route.webComponents)}else{$null}
        $results+=@(Invoke-CommonWebRelease $route $arguments)
    }
    if($route.jobs.Count){
        Import-Module (Join-Path $PSScriptRoot 'PinnedJobRelease.psm1') -DisableNameChecking
        foreach($job in $route.jobs){
            $results+=@(Invoke-PinnedJobRelease -App $App -Entry $route.entry -Component $job -Commit $Commit -Repository $route.repository `
                -ApprovalReason $ApprovalReason -OutputDirectory $OutputDirectory -TimeoutSeconds $TimeoutSeconds)
        }
    }
    if($results.Count -eq 1){return $results[0]}
    $status=if(@($results|Where-Object {$_.status -ne 'NoChanges'}).Count){'Succeeded'}else{'NoChanges'}
    @{app=$App;status=$status;releases=$results}
}

function Invoke-CommonWebRelease {
    param([Parameter(Mandatory)][hashtable]$Route,[Parameter(Mandatory)][hashtable]$Arguments)
    if($Route.procedure -eq 'hand-placed'){
        Import-Module (Join-Path $PSScriptRoot 'HandPlacedRelease.psm1') -DisableNameChecking
        $Arguments.Entry=$Route.entry
        return Invoke-HandPlacedRelease @Arguments
    }
    if($Route.procedure -ne 'fit-track'){throw 'No implemented release procedure for this inventory entry.'}
    Import-Module (Join-Path $PSScriptRoot 'FitTrackRelease.psm1') -DisableNameChecking
    Invoke-FitTrackRelease @Arguments
}

Export-ModuleMember -Function Get-CommonReleaseRoute,Resolve-CommonReleaseSource,Get-CommonReleaseChanges,Invoke-CommonRelease
