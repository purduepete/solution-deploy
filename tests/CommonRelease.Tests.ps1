$root=Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $root 'src\CommonRelease.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $root 'src\FitTrackRelease.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $root 'src\Lifecycle.psm1') -DisableNameChecking
Import-Module (Join-Path $root 'src\Deployment.psm1') -DisableNameChecking
function Assert-CommonThrows([scriptblock]$Action,[string]$Message='*'){
    $caught=$null
    try{& $Action|Out-Null}catch{$caught=$_.Exception.Message}
    ($null -ne $caught)|Should Be $true
    $caught|Should BeLike $Message
}

Describe 'Common release inventory and routing' {
    It 'covers every site exactly once without changing placement authority' {
        $inventory=Read-DeploymentJson (Join-Path $root 'environments\releases.json')
        $sites=Read-DeploymentJson (Join-Path $root 'site\sites.json')
        $inventory.apps.Count|Should Be 14
        (@($inventory.apps.Keys|Sort-Object) -join ',')|Should Be (@($sites.sites.id|Sort-Object) -join ',')
        foreach($entry in $inventory.apps.Values){
            @($entry.components).Count|Should BeGreaterThan 0
            [string]::IsNullOrWhiteSpace($entry.source)|Should Be $false
            [string]::IsNullOrWhiteSpace($entry.versionEvidence)|Should Be $false
            if($entry.procedure -in @('blocked','manual')){
                [string]::IsNullOrWhiteSpace($entry.blocker)|Should Be $false
            }
        }
    }
    It 'keeps all four registered controller apps on the existing routine route' {
        foreach($app in @('ferry-tracker','home-automation','site-dock','team-scoreboard')){
            (Get-CommonReleaseRoute -App $app -Target jimbrownhome1).procedure|Should Be controller
            Assert-CommonThrows {Get-CommonReleaseRoute -App $app -Target jimbrownhome1 -Component web} '*omit -Component*'
        }
    }
    It 'resolves Fit Track from the command location rather than the working directory' {
        Push-Location $TestDrive
        try{
            $route=Get-CommonReleaseRoute -App fit-track -Target jimbrownhome1 -Component web
            $route.procedure|Should Be fit-track
            $route.repository|Should Be (Join-Path (Split-Path -Parent $root) 'fit-track')
        }finally{Pop-Location}
    }
    It 'rejects unknown components destinations and apps before any release' {
        Assert-CommonThrows {Get-CommonReleaseRoute -App fit-track -Target jimbrownhome -Component web} '*Host moves*'
        Assert-CommonThrows {Get-CommonReleaseRoute -App fit-track -Target jimbrownhome1 -Component collector} '*Unknown component*'
        Assert-CommonThrows {Get-CommonReleaseRoute -App unknown -Target jimbrownhome1} '*No release inventory*'
    }
    It 'requires explicit shared-host selection and still blocks unverified procedures' {
        Assert-CommonThrows {Get-CommonReleaseRoute -App solution-deploy -Target jimbrownhome1} '*explicit -Component*'
        Assert-CommonThrows {Get-CommonReleaseRoute -App solution-deploy -Target jimbrownhome1 -Component postgres-backup} '*baseline*'
        Assert-CommonThrows {Get-CommonReleaseRoute -App web-portfolio -Target jimbrownhome1 -Component web} '*no-downtime*'
    }
    It 'keeps both private-only distribution tools out of Git releases' {
        foreach($app in @('ride-and-lift','pgweb')){
            Assert-CommonThrows {Get-CommonReleaseRoute -App $app -Target jimbrownhome1} '*Git -Commit releases are unsupported*'
        }
    }
    It 'forwards controller arguments without invoking the non-controller deployer' {
        Mock Invoke-RoutineRelease -ModuleName CommonRelease {@{status='ExistingController';commit=$Commit;target=$Target}}
        $result=Invoke-CommonRelease -App team-scoreboard -Target jimbrownhome1 -Commit ('a'*40) -ApproveRelease -ApprovalReason reviewed -DatabaseChangesReviewed
        $result.status|Should Be ExistingController
        $result.commit|Should Be ('a'*40)
        Assert-MockCalled Invoke-RoutineRelease -ModuleName CommonRelease -Times 1 -Exactly -Scope It
    }
}

Describe 'Exact pushed source and component selection' {
    BeforeEach {
        Mock Invoke-DeploymentCommand -ModuleName CommonRelease {
            switch($Arguments[0]){
                'rev-parse' {return ('a'*40)}
                'for-each-ref' {return 'refs/remotes/origin/main'}
                'diff' {return 'backend/app/main.py'}
            }
        }
    }
    It 'resolves the revision once and checks fetched origin reachability' {
        (Resolve-CommonReleaseSource -Repository $TestDrive -Commit HEAD)|Should Be ('a'*40)
        Assert-MockCalled Invoke-DeploymentCommand -ModuleName CommonRelease -Times 1 -Exactly -Scope It -ParameterFilter {$Arguments[0] -eq 'rev-parse'}
        Assert-MockCalled Invoke-DeploymentCommand -ModuleName CommonRelease -Times 1 -Exactly -Scope It -ParameterFilter {$Arguments -contains 'fetch'}
        Assert-MockCalled Invoke-DeploymentCommand -ModuleName CommonRelease -Times 1 -Exactly -Scope It -ParameterFilter {$Arguments -contains '--contains=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'}
    }
    It 'rejects dirty and unpushed source as well as Git options' {
        Mock Invoke-DeploymentCommand -ModuleName CommonRelease {'dirty'} -ParameterFilter {$Arguments -contains 'status'}
        Assert-CommonThrows {Resolve-CommonReleaseSource $TestDrive HEAD} '*clean committed*'
        Mock Invoke-DeploymentCommand -ModuleName CommonRelease {''} -ParameterFilter {$Arguments -contains 'status'}
        Mock Invoke-DeploymentCommand -ModuleName CommonRelease {''} -ParameterFilter {$Arguments[0] -eq 'for-each-ref'}
        Assert-CommonThrows {Resolve-CommonReleaseSource $TestDrive HEAD} '*Push it first*'
        Assert-CommonThrows {Resolve-CommonReleaseSource $TestDrive '--output=somewhere'} '*not an option*'
    }
    It 'diffs exact endpoints and the declared component paths' {
        (Get-CommonReleaseChanges $TestDrive ('a'*40) ('b'*40) @('backend/app','deploy'))|Should Be $true
        Assert-MockCalled Invoke-DeploymentCommand -ModuleName CommonRelease -Times 1 -Exactly -Scope It -ParameterFilter {
            ($Arguments -join '|') -eq ('diff|--name-only|'+('a'*40)+'|'+('b'*40)+'|--|backend/app|deploy')
        }
        Mock Invoke-DeploymentCommand -ModuleName CommonRelease {''}
        (Get-CommonReleaseChanges $TestDrive ('a'*40) ('b'*40) @('frontend'))|Should Be $false
        Assert-CommonThrows {Get-CommonReleaseChanges $TestDrive unknown ('b'*40) @('frontend')} '*verified full*'
    }
}

Describe 'Fit Track routine database and source boundaries' {
    BeforeEach {
        $script:next=Join-Path $TestDrive 'source'
        $script:old=Join-Path $TestDrive 'installed'
        foreach($directory in @($script:next,$script:old)){
            [IO.Directory]::CreateDirectory((Join-Path $directory 'deploy\postgresql'))|Out-Null
            [IO.File]::WriteAllText((Join-Path $directory 'deploy\application.json'),'{"id":"fit-track"}')
            [IO.File]::WriteAllText((Join-Path $directory 'deploy\postgresql\001.sql'),'select 1;')
        }
    }
    It 'allows unchanged manifest and database inputs with different line endings' {
        [IO.File]::WriteAllText((Join-Path $script:old 'deploy\postgresql\001.sql'),"select 1;`r`n")
        [IO.File]::WriteAllText((Join-Path $script:next 'deploy\postgresql\001.sql'),"select 1;`n")
        Assert-FitTrackDatabaseInputs $script:next $script:old
    }
    It 'rejects added changed and removed migration inputs' {
        [IO.File]::WriteAllText((Join-Path $script:next 'deploy\postgresql\002.sql'),'select 2;')
        Assert-CommonThrows {Assert-FitTrackDatabaseInputs $script:next $script:old} '*database input changed*'
        [IO.File]::Delete((Join-Path $script:next 'deploy\postgresql\002.sql'))
        [IO.File]::WriteAllText((Join-Path $script:next 'deploy\postgresql\001.sql'),'select 3;')
        Assert-CommonThrows {Assert-FitTrackDatabaseInputs $script:next $script:old} '*database input changed*'
        [IO.File]::Delete((Join-Path $script:next 'deploy\postgresql\001.sql'))
        Assert-CommonThrows {Assert-FitTrackDatabaseInputs $script:next $script:old} '*database input changed*'
    }
    It 'rejects manifest and stray SQL changes without executing them' {
        [IO.File]::WriteAllText((Join-Path $script:next 'repair.sql'),'delete from work;')
        Assert-CommonThrows {Assert-FitTrackDatabaseInputs $script:next $script:old} '*SQL outside*'
        [IO.File]::Delete((Join-Path $script:next 'repair.sql'))
        [IO.File]::WriteAllText((Join-Path $script:next 'deploy\application.json'),'{"id":"different"}')
        Assert-CommonThrows {Assert-FitTrackDatabaseInputs $script:next $script:old} '*manifest/database input changed*'
    }
}

Describe 'Fit Track host result and runtime verification' {
    BeforeEach {
        Mock Invoke-CimMethod -ModuleName FitTrackRelease {@{ReturnValue=0;ProcessId=123}}
        $script:operation=Join-Path $TestDrive 'operation'
        [IO.Directory]::CreateDirectory($script:operation)|Out-Null
        Write-DeploymentJson (Join-Path $script:operation 'prepare-result.json') @{phase='Prepare';requestSHA256=('a'*64);status='Succeeded'}
    }
    It 'requires the exact submitted request and propagates host failure' {
        $invokeArguments=@{Session='fixture';Operation=$script:operation;RemoteOperation='C:\fixture';RequestSHA256=('a'*64);Phase='Prepare'}
        (Invoke-FitTrackHostPhase @invokeArguments).status|Should Be Succeeded
        Write-DeploymentJson (Join-Path $script:operation 'prepare-result.json') @{phase='Prepare';requestSHA256=('b'*64);status='Succeeded'}
        Assert-CommonThrows {Invoke-FitTrackHostPhase @invokeArguments} '*does not match*'
        Write-DeploymentJson (Join-Path $script:operation 'prepare-result.json') @{phase='Prepare';requestSHA256=('a'*64);status='Failed';error='fixture failure'}
        Assert-CommonThrows {Invoke-FitTrackHostPhase @invokeArguments} '*fixture failure*'
    }
    It 'does not accept a launch request as a completed host phase' {
        Mock Invoke-CimMethod -ModuleName FitTrackRelease {@{ReturnValue=5;ProcessId=0}}
        Assert-CommonThrows {Invoke-FitTrackHostPhase -Session fixture -Operation $script:operation -RemoteOperation 'C:\fixture' -RequestSHA256 ('a'*64) -Phase Prepare} '*Could not launch*'
    }
    It 'checks readiness separately from the actual lifecycle ownership object' {
        $tokens=$null;$errors=$null
        $ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'scripts\Invoke-FitTrackRelease.ps1'),[ref]$tokens,[ref]$errors)
        $definition=$ast.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Wait-FitTrackRuntime'},$true)
        Invoke-Expression $definition.Extent.Text
        Mock Start-Sleep {}
        Mock Get-ManagedAppStatus {[pscustomobject]@{Status='Running';Pid=123;MaintenanceActive=$false}}
        Mock Test-AppReadiness {[pscustomobject]@{Ready=$true}}
        $invokeArguments=@{AppRoot='C:\fixture';Release='C:\fixture\release';Manifest=@{readiness=@{path='/api/ready';expected=@{status='ok'}}};Runtime='C:\python.exe';TimeoutSeconds=0}
        Wait-FitTrackRuntime @invokeArguments
        Mock Test-AppReadiness {[pscustomobject]@{Ready=$false}}
        Assert-CommonThrows {Wait-FitTrackRuntime @invokeArguments} '*did not establish owned runtime readiness*'
        Mock Test-AppReadiness {[pscustomobject]@{Ready=$true}}
        Mock Get-ManagedAppStatus {[pscustomobject]@{Status='NotOwned';Pid=123;MaintenanceActive=$false}}
        Assert-CommonThrows {Wait-FitTrackRuntime @invokeArguments} '*did not establish owned runtime readiness*'
    }
}
