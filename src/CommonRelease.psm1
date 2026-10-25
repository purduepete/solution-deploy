#requires -Version 7.5
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'Deployment.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'Release.psm1') -DisableNameChecking

# The directory serves these as each solution's last release; its LOCAL SERVICE account can read data\.
$script:ReleaseRecords='\\jimbrownhome1.local\c$\ProgramData\SolutionDeploy\apps\solution-deploy\data\releases'

function Get-CommonReleaseRecords {
    param([Parameter(Mandatory)][string]$App,[AllowNull()][object[]]$Result)
    @(foreach($item in @($Result)){
        if($item -isnot [System.Collections.IDictionary]){continue}
        if($item.Contains('releases')){Get-CommonReleaseRecords $App @($item['releases']);continue}
        if($item['status'] -ne 'Succeeded' -or [string]$item['sourceCommit'] -cnotmatch '^[a-f0-9]{40}$'){continue}
        $names=if($item.Contains('component')){@($item['component'])}elseif($item.Contains('components')){@($item['components'].Keys|Where-Object {$item['components'][$_] -eq 'Verified'})}else{@('app')}
        $completed=if($item.Contains('completedLocal')){[DateTimeOffset]::Parse([string]$item['completedLocal'])}else{[DateTimeOffset]::Now}
        foreach($name in $names){
            if([string]$name -notmatch '^[a-z0-9-]+$'){continue}
            @{app=$App;component=[string]$name;sourceCommit=[string]$item['sourceCommit'];completedLocal=$completed.ToString('o')}
        }
    })
}

function Write-CommonReleaseRecords {
    param([Parameter(Mandatory)][string]$App,[AllowNull()][object[]]$Result,[string]$Directory=$script:ReleaseRecords)
    foreach($record in Get-CommonReleaseRecords $App $Result){
        try{
            [IO.Directory]::CreateDirectory($Directory)|Out-Null
            Write-DeploymentJson (Join-Path $Directory "$App--$($record.component).json") $record
        }catch{Write-Warning "The release succeeded, but its directory record was not written: $($_.Exception.Message)"}
    }
}

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
    $byComponent=if($entry.ContainsKey('componentProcedures')){$entry.componentProcedures}else{@{}}
    $routed=@($webNames|Where-Object {$byComponent.ContainsKey($_)})
    if($routed.Count){
        $held=@($webNames|Where-Object {-not $byComponent.ContainsKey($_)})
        if($held.Count){throw "$App $($held -join ', ') release blocked: $($entry.blocker)"}
        $distinct=@($routed|ForEach-Object {$byComponent[$_]}|Select-Object -Unique)
        if($distinct.Count -ne 1){throw "$App components $($routed -join ', ') use different procedures; release them separately."}
        $procedure=$distinct[0]
    }
    if(-not $webNames.Count){$procedure='none'}
    elseif($procedure -in @('blocked','manual')){
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
        [DateTimeOffset]$ExpiresLocal=([DateTimeOffset]::Now.AddMinutes(60)),[string]$TailscaleUrl,
        [string]$OutputDirectory=(Join-Path (Split-Path -Parent $PSScriptRoot) '.local'),
        [ValidateRange(60,1800)][int]$TimeoutSeconds=300,[string]$ApprovedManifestSHA256)
    $route=Get-CommonReleaseRoute -App $App -Component $Component -Environment $Environment -Target $Target
    if($ApprovedManifestSHA256 -and $route.procedure -ne 'controller'){throw '-ApprovedManifestSHA256 applies only to framework-managed apps.'}
    $arguments=@{}+$PSBoundParameters
    [void]$arguments.Remove('Component')
    if($route.procedure -eq 'controller'){
        $controller=Invoke-RoutineRelease @arguments
        Write-CommonReleaseRecords $App @($controller)
        return $controller
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
    Write-CommonReleaseRecords $App $results
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
    if($Route.procedure -eq 'directory'){
        Import-Module (Join-Path $PSScriptRoot 'DirectoryRelease.psm1') -DisableNameChecking
        $directoryArguments=@{Repository=$Arguments.Repository;ApprovalReason=$Arguments.ApprovalReason}
        foreach($key in 'Commit','OutputDirectory','TimeoutSeconds'){if($Arguments.ContainsKey($key)){$directoryArguments[$key]=$Arguments[$key]}}
        return Invoke-DirectoryRelease @directoryArguments
    }
    if($Route.procedure -eq 'file-set'){
        Import-Module (Join-Path $PSScriptRoot 'FileSetRelease.psm1') -DisableNameChecking
        $fileArguments=@{Repository=$Arguments.Repository;Entry=$Route.entry;Component=$Route.webComponents;ApprovalReason=$Arguments.ApprovalReason}
        foreach($key in 'Commit','OutputDirectory'){if($Arguments.ContainsKey($key)){$fileArguments[$key]=$Arguments[$key]}}
        return Invoke-FileSetRelease @fileArguments
    }
    if($Route.procedure -ne 'fit-track'){throw 'No implemented release procedure for this inventory entry.'}
    Import-Module (Join-Path $PSScriptRoot 'FitTrackRelease.psm1') -DisableNameChecking
    Invoke-FitTrackRelease @Arguments
}

Export-ModuleMember -Function Get-CommonReleaseRoute,Resolve-CommonReleaseSource,Get-CommonReleaseChanges,Invoke-CommonRelease,Get-CommonReleaseRecords,Write-CommonReleaseRecords
