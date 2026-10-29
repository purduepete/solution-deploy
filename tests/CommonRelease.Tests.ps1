$root=Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $root 'src\CommonRelease.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $root 'src\FitTrackRelease.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $root 'src\HandPlacedRelease.psm1') -Force -DisableNameChecking
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
        $inventory.apps.Count|Should Be 15
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
    It 'keeps all five registered controller apps on the existing routine route' {
        foreach($app in @('ferry-tracker','home-automation','site-dock','team-scoreboard','idea-notes')){
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
    It 'requires explicit shared-host selection' {
        Assert-CommonThrows {Get-CommonReleaseRoute -App solution-deploy -Target jimbrownhome1} '*explicit -Component*'
    }
    It 'releases the directory and its status publisher together and routes the other shared components to file sets' {
        foreach($name in 'directory','collector-status'){
            (Get-CommonReleaseRoute -App solution-deploy -Target jimbrownhome1 -Component $name).procedure|Should Be directory
        }
        (Get-CommonReleaseRoute -App solution-deploy -Target jimbrownhome1 -Component directory,collector-status).procedure|Should Be directory
        foreach($name in 'collector-monitor','lan-proxy','postgres-backup','finance-launcher'){
            (Get-CommonReleaseRoute -App solution-deploy -Target jimbrownhome1 -Component $name).procedure|Should Be file-set
        }
        Assert-CommonThrows {Get-CommonReleaseRoute -App solution-deploy -Target jimbrownhome1 -Component directory,lan-proxy} '*different procedures*'
    }
    It 'plans each file set inside its component paths and allowed host folders' {
        Import-Module (Join-Path $root 'src\FileSetRelease.psm1') -Force -DisableNameChecking
        $entry=(Read-DeploymentJson (Join-Path $root 'environments\releases.json')).apps['solution-deploy']
        @((Get-FileSetPlan $entry finance-launcher).files).Count|Should Be 2
        (Get-FileSetPlan $entry finance-launcher).after.apps -join ','|Should Be 'web-portfolio,web-options'
        @((Get-FileSetPlan $entry postgres-backup).files|ForEach-Object {$_.target}) -join ','|Should Not Match 'pgpass|credential'
        (Get-FileSetPlan $entry lan-proxy).files[1].share|Should Be '\\jimbrownhome1.local\c$\ProgramData\SolutionDeploy\apps\lan-proxy\site\lan-proxy.mjs'
        $bad=@{componentPaths=@{x=@('a.ps1')};fileSets=@{x=@{files=@(@{source='a.ps1';targets=@('C:\ProgramData\SolutionDeploy\..\Windows\a.ps1')});after=@{type='none'}}}}
        Assert-CommonThrows {Get-FileSetPlan $bad x} '*not an allowed host path*'
        $bad.fileSets.x.files[0].targets=@('C:\Windows\a.ps1')
        Assert-CommonThrows {Get-FileSetPlan $bad x} '*not an allowed host path*'
        $bad.fileSets.x.files[0].source='b.ps1'
        Assert-CommonThrows {Get-FileSetPlan $bad x} '*outside its component paths*'
        $bad.fileSets.x.files[0]=@{source='a.ps1';targets=@('C:\ProgramData\SolutionDeploy\a.ps1')}
        $bad.fileSets.x.after.type='reboot'
        Assert-CommonThrows {Get-FileSetPlan $bad x} '*unknown after step*'
    }
    It 'compares file sets by normalized content' {
        Import-Module (Join-Path $root 'src\FileSetRelease.psm1') -Force -DisableNameChecking
        $source=Join-Path $TestDrive 'source';$installed=Join-Path $TestDrive 'installed'
        New-Item -ItemType Directory $source,$installed -Force|Out-Null
        [IO.File]::WriteAllText("$source\a.ps1","one`ntwo`n");[IO.File]::WriteAllText("$installed\a.ps1","one`r`ntwo`r`n")
        $files=@(@{source='a.ps1';target='C:\ProgramData\SolutionDeploy\a.ps1';share="$installed\a.ps1"},
            @{source='a.ps1';target='C:\ProgramData\SolutionDeploy\b.ps1';share="$installed\b.ps1"})
        @(Compare-FileSet $files $source|ForEach-Object {$_.target}) -join ','|Should Be 'C:\ProgramData\SolutionDeploy\b.ps1'
    }
    It 'routes hand-placed web apps and sends Web Options jobs to the pinned-job procedure' {
        foreach($app in @('web-bookmarks','work-log','web-inventory','plex','web-options','web-portfolio')){
            $route=Get-CommonReleaseRoute -App $app -Target jimbrownhome1
            $route.procedure|Should Be hand-placed
            $route.entry.task|Should Be "SolutionDeploy-$app"
            ($route.entry.stop -in @('managed','task'))|Should Be $true
            $route.entry.readiness.path|Should BeLike '/*'
        }
        (Get-CommonReleaseRoute -App web-options -Target jimbrownhome1 -Component web).procedure|Should Be hand-placed
        @((Get-CommonReleaseRoute -App web-options -Target jimbrownhome1 -Component web).jobs).Count|Should Be 0
        (@((Get-CommonReleaseRoute -App web-options -Target jimbrownhome1).jobs) -join ',')|Should Be collector
        $job=Get-CommonReleaseRoute -App web-options -Target jimbrownhome1 -Component collector
        $job.procedure|Should Be none
        (@($job.jobs) -join ',')|Should Be collector
    }
    It 'routes Web Portfolio web to the folder swap and its stock collector to the pinned-job procedure' {
        $route=Get-CommonReleaseRoute -App web-portfolio -Target jimbrownhome1 -Component stock-collector
        $route.procedure|Should Be none
        (@($route.jobs) -join ',')|Should Be stock-collector
        $web=Get-CommonReleaseRoute -App web-portfolio -Target jimbrownhome1 -Component web
        $web.procedure|Should Be hand-placed
        @($web.jobs).Count|Should Be 0
        $all=Get-CommonReleaseRoute -App web-portfolio -Target jimbrownhome1
        $all.procedure|Should Be hand-placed
        (@($all.jobs) -join ',')|Should Be stock-collector
        $all.entry.hostInstallPath|Should Be backend
        @($all.entry.carryForward) -contains 'telegram_ingest\vader.session'|Should Be $true
    }
    It 'records each job runtime, task list and full runtime commit' {
        $inventory=Read-DeploymentJson (Join-Path $root 'environments\releases.json')
        foreach($app in @('web-options','web-portfolio')){
            foreach($job in $inventory.apps[$app].jobs.Values){
                $job.runtimeCommit|Should Match '^[a-f0-9]{40}$'
                $job.runtime|Should BeLike ($job.prefix+'*')
                @($job.tasks).Count|Should BeGreaterThan 1
                @($job.tasks|Where-Object {$_ -like '*-daily-audit'}).Count|Should Be 0
                foreach($task in $job.tasks){$task|Should BeLike "SolutionDeploy-$app-*"}
            }
        }
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
    It 'records only succeeded releases, one file per component' {
        $commit='b'*40
        $results=@(
            @{status='Succeeded';sourceCommit=$commit;completedLocal='2026-07-12T14:05:00-07:00';components=@{web='Verified';'upload-watcher'='UnchangedSourceVerified'}}
            @{status='Succeeded';sourceCommit=$commit;completedLocal='2026-07-12T14:06:00-07:00';component=@('lan-proxy','collector-monitor')}
            @{status='NoChanges';sourceCommit=$commit;component='postgres-backup'}
            @{status='Failed';sourceCommit=$commit;component='finance-launcher'}
            @{status='Succeeded';sourceCommit='HEAD';component='bad'}
        )
        @(Get-CommonReleaseRecords demo $results|ForEach-Object {$_.component})|Should Be @('web','lan-proxy','collector-monitor')
        (Get-CommonReleaseRecords ferry-tracker @(@{status='Succeeded';sourceCommit=$commit;completedLocal='2026-07-12T14:05:00-07:00'})).component|Should Be app
        (Get-CommonReleaseRecords demo @(@{releases=@($results[0])})).component|Should Be web
        $folder=Join-Path $TestDrive releases
        Write-CommonReleaseRecords demo $results -Directory $folder
        @(Get-ChildItem $folder|ForEach-Object Name|Sort-Object)|Should Be @('demo--collector-monitor.json','demo--lan-proxy.json','demo--web.json')
        $saved=Read-DeploymentJson (Join-Path $folder 'demo--web.json')
        $saved.sourceCommit|Should Be $commit
        ([DateTimeOffset]::Parse($saved.completedLocal)).UtcDateTime.ToString('HH:mm')|Should Be '21:05'
        (Get-CommonReleaseRecords fit-track @(@{status='Succeeded';sourceCommit=$commit;components=@{web='SourceUnchanged';'upload-watcher'='Verified'}})).component|Should Be 'upload-watcher'
    }
    It 'warns without failing when the record cannot be written' {
        $blocked=Join-Path $TestDrive 'not-a-folder'
        Set-Content $blocked 'file'
        $warnings=$null
        Write-CommonReleaseRecords demo @(@{status='Succeeded';sourceCommit=('c'*40);component='web'}) -Directory $blocked -WarningVariable warnings -WarningAction SilentlyContinue
        @($warnings).Count|Should Be 1
        [string]$warnings[0]|Should BeLike '*release succeeded, but its directory record was not written*'
    }
    It 'passes every release result to the record writer' {
        Mock Write-CommonReleaseRecords -ModuleName CommonRelease {}
        Mock Invoke-RoutineRelease -ModuleName CommonRelease {@{status='Succeeded';sourceCommit=('a'*40)}}
        Invoke-CommonRelease -App team-scoreboard -Target jimbrownhome1 -Commit ('a'*40) -ApproveRelease -ApprovalReason reviewed -DatabaseChangesReviewed|Out-Null
        Assert-MockCalled Write-CommonReleaseRecords -ModuleName CommonRelease -Times 1 -Exactly -Scope It -ParameterFilter {$App -eq 'team-scoreboard' -and $Result[0].status -eq 'Succeeded'}
        Import-Module (Join-Path $PSScriptRoot '..\src\PinnedJobRelease.psm1') -DisableNameChecking
        Mock Invoke-CommonWebRelease -ModuleName CommonRelease {@{status='Succeeded';sourceCommit=('d'*40);component='web'}}
        Mock Import-Module -ModuleName CommonRelease {}
        Mock Invoke-PinnedJobRelease -ModuleName CommonRelease {@{status='NoChanges';component='collector'}}
        $result=Invoke-CommonRelease -App web-options -Target jimbrownhome1 -Commit ('d'*40) -ApproveRelease -ApprovalReason reviewed -DatabaseChangesReviewed
        $result.status|Should Be Succeeded
        Assert-MockCalled Write-CommonReleaseRecords -ModuleName CommonRelease -Times 1 -Exactly -Scope It -ParameterFilter {$App -eq 'web-options' -and @($Result).Count -eq 2}
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

Describe 'Fit Track upload watcher release' {
    BeforeEach {
        $source=Join-Path $TestDrive 'source';$installed=Join-Path $TestDrive 'installed';$backup=Join-Path $TestDrive 'backup'
        Remove-Item $source,$installed,$backup -Recurse -Force -ErrorAction SilentlyContinue
        $names=@('Watch-Upload.ps1','run-watcher-hidden.vbs','upload_folder.py','Register-UploadWatcherTask.ps1','Test-UploadWatcher.ps1')
        foreach($root in @($source,$installed)){New-Item -ItemType Directory (Join-Path $root 'backend\scripts') -Force|Out-Null}
        foreach($name in $names){
            [IO.File]::WriteAllText((Join-Path $source "backend\scripts\$name"),"line 1`nline 2`n")
            [IO.File]::WriteAllText((Join-Path $installed "backend\scripts\$name"),"line 1`r`nline 2`r`n")
        }
        [IO.File]::WriteAllText((Join-Path $installed 'backend\.env.local'),'FITTRACK_TOKEN=secret')
    }
    It 'treats line-ending differences as unchanged and covers every watcher script' {
        $files=@(Get-FitTrackWatcherFiles $source $installed)
        $files.Count|Should Be 5
        @($files|Where-Object {-not $_.matches}).Count|Should Be 0
        @(Update-FitTrackWatcherFiles $source $installed $files $backup).Count|Should Be 0
    }
    It 'backs up and replaces only changed files as CRLF without touching the token file' {
        [IO.File]::WriteAllText((Join-Path $source 'backend\scripts\upload_folder.py'),"line 1`nchanged`n")
        Remove-Item (Join-Path $installed 'backend\scripts\Test-UploadWatcher.ps1')
        $files=@(Get-FitTrackWatcherFiles $source $installed)
        $updated=@(Update-FitTrackWatcherFiles $source $installed $files $backup)
        ($updated -join ',')|Should Be 'backend\scripts\upload_folder.py,backend\scripts\Test-UploadWatcher.ps1'
        [IO.File]::ReadAllText((Join-Path $installed 'backend\scripts\upload_folder.py'))|Should BeExactly "line 1`r`nchanged`r`n"
        [IO.File]::ReadAllText((Join-Path $backup 'backend\scripts\upload_folder.py'))|Should BeExactly "line 1`r`nline 2`r`n"
        [IO.File]::ReadAllBytes((Join-Path $installed 'backend\scripts\upload_folder.py'))[0]|Should Be ([byte][char]'l')
        [IO.File]::ReadAllText((Join-Path $installed 'backend\.env.local'))|Should BeExactly 'FITTRACK_TOKEN=secret'
        @(Get-FitTrackWatcherFiles $source $installed|Where-Object {-not $_.matches}).Count|Should Be 0
    }
    It 'stops before copying anything when the task registration script changed' {
        [IO.File]::WriteAllText((Join-Path $source 'backend\scripts\upload_folder.py'),"changed`n")
        [IO.File]::WriteAllText((Join-Path $source 'backend\scripts\Register-UploadWatcherTask.ps1'),"changed`n")
        $files=@(Get-FitTrackWatcherFiles $source $installed)
        Assert-CommonThrows {Update-FitTrackWatcherFiles $source $installed $files $backup} '*Re-register the task*Nothing was copied*'
        [IO.File]::ReadAllText((Join-Path $installed 'backend\scripts\upload_folder.py'))|Should BeExactly "line 1`r`nline 2`r`n"
        Test-Path $backup|Should Be $false
    }
}

Describe 'Hand-placed release boundaries' {
    BeforeEach {
        $script:next=Join-Path $TestDrive 'built'
        $script:old=Join-Path $TestDrive 'live'
        foreach($directory in @($script:next,$script:old)){
            [IO.Directory]::CreateDirectory((Join-Path $directory 'db'))|Out-Null
            [IO.File]::WriteAllText((Join-Path $directory 'db\001.sql'),"select 1;`r`n")
        }
        [IO.Directory]::CreateDirectory((Join-Path $script:next 'node_modules\pkg'))|Out-Null
        [IO.File]::WriteAllText((Join-Path $script:next 'node_modules\pkg\vendor.sql'),'drop table x;')
    }
    It 'allows unchanged SQL and ignores dependency folders' {
        [IO.File]::WriteAllText((Join-Path $script:next 'db\001.sql'),"select 1;`n")
        Assert-HandPlacedDatabaseInputs $script:next $script:old
    }
    It 'blocks added changed and removed SQL' {
        [IO.File]::WriteAllText((Join-Path $script:next 'db\002.sql'),'select 2;')
        Assert-CommonThrows {Assert-HandPlacedDatabaseInputs $script:next $script:old} '*Database input changed: db\002.sql*'
        [IO.File]::Delete((Join-Path $script:next 'db\002.sql'))
        [IO.File]::WriteAllText((Join-Path $script:next 'db\001.sql'),'select 3;')
        Assert-CommonThrows {Assert-HandPlacedDatabaseInputs $script:next $script:old} '*Database input changed*'
        [IO.File]::Delete((Join-Path $script:next 'db\001.sql'))
        Assert-CommonThrows {Assert-HandPlacedDatabaseInputs $script:next $script:old} '*Database input changed*'
    }
    It 'accepts a new SQL file only at the digest recorded as applied' {
        [IO.File]::WriteAllText((Join-Path $script:next 'db\001.sql'),[IO.File]::ReadAllText((Join-Path $script:old 'db\001.sql')))
        [IO.File]::WriteAllText((Join-Path $script:next 'db\005.sql'),"grant select on t to r;`r`n")
        $digest=Get-NormalizedFileDigest (Join-Path $script:next 'db\005.sql')
        Assert-HandPlacedDatabaseInputs $script:next $script:old @{'db/005.sql'=$digest}
        [IO.File]::WriteAllText((Join-Path $script:next 'db\005.sql'),"grant all on t to r;`n")
        Assert-CommonThrows {Assert-HandPlacedDatabaseInputs $script:next $script:old @{'db/005.sql'=$digest}} '*Database input changed: db\005.sql*'
        [IO.File]::Delete((Join-Path $script:next 'db\005.sql'))
    }
    It 'reads both access paths from the site inventory' {
        $access=Get-SiteAccess work-log
        $access.tailscale.Port|Should Be 8794
        $access.tailscale.AbsolutePath|Should Be '/'
        $access.cloudflare.Host|Should Be 'work-log.jimlertech.com'
    }
    It 'needs matching readiness JSON and the Access login redirect' {
        $access=@{tailscale=[uri]'https://jimbrownhome1.example.ts.net:8794/';cloudflare=[uri]'https://work-log.jimlertech.com/'}
        Mock Invoke-ReleaseAccessRequest -ModuleName HandPlacedRelease {
            if($Uri.Host -like '*ts.net'){@{statusCode=200;body='{"ok":true}'}}
            else{@{statusCode=302;location=[uri]'https://team.cloudflareaccess.com/cdn-cgi/access/login/work-log'}}
        }
        (Test-HandPlacedReadiness $access @{path='/healthz';expected=@{ok=$true}} 5).cloudflare.verified|Should Be $true
        Mock Invoke-ReleaseAccessRequest -ModuleName HandPlacedRelease {@{statusCode=200;body='{"ok":true}'}}
        Assert-CommonThrows {Test-HandPlacedReadiness $access @{path='/healthz';expected=@{ok=$true}} 5} '*Access login redirect*'
        Mock Invoke-ReleaseAccessRequest -ModuleName HandPlacedRelease {@{statusCode=200;body='{"ok":false}'}}
        Assert-CommonThrows {Test-HandPlacedReadiness $access @{path='/healthz';expected=@{ok=$true}} 4} '*ok did not match*'
    }
    It 'stops only processes owned by the released app' {
        $ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'scripts\Invoke-HandPlacedRelease.ps1'),[ref]$null,[ref]$null)
        $definition=$ast.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Get-OwnedProcess'},$true)
        . ([scriptblock]::Create($definition.Extent.Text))
        function Get-CimInstance {
            $pwsh='"C:\ProgramData\SolutionDeploy\runtime\powershell\7\pwsh.exe" -NoProfile -File '
            @(
                [pscustomobject]@{ProcessId=1;ExecutablePath='';CommandLine=$pwsh+'"C:\ProgramData\SolutionDeploy\apps\web-options\shared\Start-Service.ps1" -Application web-options'}
                [pscustomobject]@{ProcessId=2;ExecutablePath='';CommandLine='"C:\Files\ScoopApps\apps\nodejs\current\node.exe" C:\ProgramData\SolutionDeploy\apps\web-options\current\backend\dist\server.js'}
                [pscustomobject]@{ProcessId=3;ExecutablePath='';CommandLine='python.exe C:\ProgramData\SolutionDeploy\apps\web-options\releases\collector-68f9512\collector\run.py'}
                [pscustomobject]@{ProcessId=4;ExecutablePath='';CommandLine=$pwsh+'"C:\ProgramData\SolutionDeploy\apps\web-options\shared\Start-Service.ps1" -Application web-options-collector'}
                [pscustomobject]@{ProcessId=5;ExecutablePath='';CommandLine=$pwsh+'"C:\ProgramData\SolutionDeploy\apps\work-log\current\deploy\Start-WorkLogService.ps1"'}
                [pscustomobject]@{ProcessId=6;ExecutablePath='C:\Windows\notepad.exe';CommandLine='notepad.exe'}
                [pscustomobject]@{ProcessId=7;ExecutablePath='';CommandLine='node.exe C:\ProgramData\SolutionDeploy\apps\web-options\releases\history-4052ebc\backend\dist\server.js'}
            )
        }
        $app='web-options'
        $previous='C:\ProgramData\SolutionDeploy\apps\web-options\releases\history-4052ebc'
        (@(Get-OwnedProcess).ProcessId -join ',')|Should Be '1,2,7'
        $app='work-log';$previous=$null
        (@(Get-OwnedProcess).ProcessId -join ',')|Should Be '5'
        $app='plex'
        @(Get-OwnedProcess).Count|Should Be 0
    }
    It 'limits the host runner to the six hand-placed apps' {
        $runner=[IO.File]::ReadAllText((Join-Path $root 'scripts\Invoke-HandPlacedRelease.ps1'))
        $runner|Should Match ([regex]::Escape('(web-bookmarks|work-log|web-inventory|plex|web-options|web-portfolio)'))
    }
    It 'accepts only relative carry-forward paths inside the release' {
        $relative='^[A-Za-z0-9_.-]+(\\[A-Za-z0-9_.-]+)*$'
        $bad={param($path) $path -notmatch $relative -or $path -match '(^|\\)\.\.?(\\|$)'}
        $runner=[IO.File]::ReadAllText((Join-Path $root 'scripts\Invoke-HandPlacedRelease.ps1'))
        $runner.Contains("`$relative='$relative'")|Should Be $true
        foreach($path in 'config\config.ini','telegram_ingest\vader.session','telegram_ingest\.venv'){(& $bad $path)|Should Be $false}
        foreach($path in '..\shared\secrets','config\..\..\x','C:\Windows','\\host\share','.','telegram_ingest\.'){(& $bad $path)|Should Be $true}
    }

    It 'ignores Tailscale and LAN proxy listeners that share the origin port' {
        $ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'scripts\Invoke-HandPlacedRelease.ps1'),[ref]$null,[ref]$null)
        $definition=$ast.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Wait-PortReleased'},$true)
        . ([scriptblock]::Create($definition.Extent.Text))
        $app='web-bookmarks'
        function Get-OwnedProcess {@()}
        $script:listeners=@(
            [pscustomobject]@{LocalAddress='100.89.203.69';OwningProcess=6572}
            [pscustomobject]@{LocalAddress='192.168.2.14';OwningProcess=9632}
            [pscustomobject]@{LocalAddress='127.0.0.1';OwningProcess=4}
        )
        function Get-NetTCPConnection {$script:listeners}
        $outcome={param($port) try{Wait-PortReleased $port 1;'released'}catch{'held'}}
        & $outcome 8792|Should Be 'released'
        $script:listeners=@([pscustomobject]@{LocalAddress='127.0.0.1';OwningProcess=1752})
        & $outcome 8792|Should Be 'held'
    }

    It 'gives the new current junction the old link ACL, since LOCAL SERVICE reads through it' {
        $runner=[IO.File]::ReadAllText((Join-Path $root 'scripts\Invoke-HandPlacedRelease.ps1'))
        $capture=$runner.IndexOf('$linkAcl=Get-Acl -LiteralPath $current')
        $create=$runner.IndexOf('New-Item -ItemType Junction -Path $current -Target $release')
        $capture|Should BeGreaterThan -1
        $create|Should BeGreaterThan $capture
        $runner.Substring($create,200)|Should Match ([regex]::Escape('Set-Acl -LiteralPath $current -AclObject $linkAcl'))
    }
}
Describe 'Pinned-job release boundaries' {
    BeforeAll {Import-Module (Join-Path $root 'src\PinnedJobRelease.psm1') -Force -DisableNameChecking}
    $job=@{prefix='collector-'}
    function New-JobTask([string]$Name,[string]$Release){
        [pscustomobject]@{TaskName=$Name;Actions=@([pscustomobject]@{Execute='pwsh.exe'
            Arguments="-File `"$Release\scripts\Start-Collector.ps1`" -ReleasePath `"$Release`" -Action tick";WorkingDirectory=$Release})}
    }
    $base='C:\ProgramData\SolutionDeploy\apps\web-options\releases'

    It 'reads one shared release folder and its commit from the task actions' {
        $tasks=@((New-JobTask tick "$base\collector-68f9512"),(New-JobTask audit "$base\collector-68f9512"))
        $current=Get-PinnedJobReleasePath web-options $job $tasks
        $current.short|Should Be '68f9512'
        $current.name|Should Be 'collector-68f9512'
    }
    It 'rejects tasks that disagree or point outside the releases folder' {
        Assert-CommonThrows {Get-PinnedJobReleasePath web-options $job @((New-JobTask tick "$base\collector-68f9512"),(New-JobTask audit "$base\collector-02db285"))} '*different releases*'
        Assert-CommonThrows {Get-PinnedJobReleasePath web-options $job @(New-JobTask tick 'C:\Temp\collector-68f9512')} '*outside*'
        Assert-CommonThrows {Get-PinnedJobReleasePath web-options $job @(New-JobTask tick "$base\collector-latest")} '*commit*'
    }
    It 'moves every reference to the release and nothing else in the action' {
        $task=New-JobTask tick "$base\collector-68f9512"
        $action=New-PinnedJobAction $task.Actions[0] "$base\collector-68f9512" "$base\collector-1234567"
        $action.Argument|Should Be "-File `"$base\collector-1234567\scripts\Start-Collector.ps1`" -ReleasePath `"$base\collector-1234567`" -Action tick"
        $action.WorkingDirectory|Should Be "$base\collector-1234567"
        $action.Execute|Should Be 'pwsh.exe'
        Assert-CommonThrows {New-PinnedJobAction $task.Actions[0] "$base\collector-02db285" "$base\collector-1234567"} '*current release*'
    }
    It 'maps a subfolder to the release root and compares trees without caches or line endings' {
        $source=Join-Path $TestDrive 'repo'
        New-Item -ItemType Directory -Path "$source\stock-collector\collector\__pycache__","$source\stock-collector\scripts" -Force|Out-Null
        Set-Content "$source\stock-collector\collector\run.py" "print(1)`n" -NoNewline
        Set-Content "$source\stock-collector\collector\__pycache__\run.pyc" 'x'
        Set-Content "$source\stock-collector\scripts\Start.ps1" 'exit 0'
        Set-Content "$source\stock-collector\collector\__init__.py" '' -NoNewline
        $built=Join-Path $TestDrive 'built'
        Copy-PinnedJobSource $source @{'stock-collector'='.'} $built
        (Test-Path "$built\collector\run.py")|Should Be $true
        (Test-Path "$built\collector\__pycache__")|Should Be $false
        $installed=Join-Path $TestDrive 'installed'
        Copy-Item $built $installed -Recurse
        Set-Content "$installed\collector\run.py" "print(1)`r`n" -NoNewline
        New-Item -ItemType Directory "$installed\collector\__pycache__" -Force|Out-Null
        Set-Content "$installed\collector\__pycache__\run.pyc" 'y'
        @(Compare-PinnedJobTree (Get-PinnedJobTree $built) (Get-PinnedJobTree $installed)).Count|Should Be 0
        Set-Content "$installed\scripts\Extra.ps1" 'exit 1'
        Set-Content "$installed\collector\run.py" 'print(2)'
        (@(Compare-PinnedJobTree (Get-PinnedJobTree $built) (Get-PinnedJobTree $installed)) -join ',')|Should Be 'collector\run.py,scripts\Extra.ps1'
    }
}
Describe 'Directory release boundaries' {
    Import-Module (Join-Path $root 'src\DirectoryRelease.psm1') -Force -DisableNameChecking
    It 'compares exactly the files Install-Directory.ps1 copies' {
        $installer=Get-Content (Join-Path $root 'scripts\Install-Directory.ps1') -Raw
        $copies=@([regex]::Matches($installer,'Copy-Item "\$SourcePath\\([^"]+)"')|ForEach-Object {$_.Groups[1].Value})
        ($copies -join ',')|Should Be 'site\*,environments\releases.json,scripts\Start-Directory.ps1,scripts\Update-CollectorStatus.ps1'
        $map=Get-DirectoryInstallMap $root
        @($map.Keys|Where-Object {$_ -like 'site\*'}).Count|Should Be @(Get-ChildItem (Join-Path $root 'site') -File).Count
        foreach($key in 'environments\releases.json','Start-Directory.ps1','Update-CollectorStatus.ps1'){$map.Contains($key)|Should Be $true}
    }
    It 'reports missing and changed installed files but ignores line endings' {
        $source=Join-Path $TestDrive 'source'
        New-Item -ItemType Directory "$source\site","$source\environments","$source\scripts" -Force|Out-Null
        Set-Content "$source\site\app.js" "a`n" -NoNewline
        Set-Content "$source\site\empty.txt" '' -NoNewline
        Set-Content "$source\environments\releases.json" '{}'
        Set-Content "$source\scripts\Start-Directory.ps1" 'exit 0'
        Set-Content "$source\scripts\Update-CollectorStatus.ps1" 'exit 0'
        $installed=Join-Path $TestDrive 'installed'
        New-Item -ItemType Directory "$installed\site","$installed\environments" -Force|Out-Null
        Set-Content "$installed\site\app.js" "a`r`n" -NoNewline
        Set-Content "$installed\site\empty.txt" '' -NoNewline
        Set-Content "$installed\environments\releases.json" '{"x":1}'
        Copy-Item "$source\scripts\Start-Directory.ps1" $installed
        (@(Compare-DirectoryInstall (Get-DirectoryInstallMap $source) $installed) -join ',')|Should Be 'environments\releases.json,Update-CollectorStatus.ps1'
    }
    It 'records both components installed by a successful directory release' {
        $components=& (Get-Module DirectoryRelease) {$script:DirectoryComponents}
        $receipt=@{status='Succeeded';sourceCommit=('e'*40);completedLocal='2026-10-25T08:14:59-07:00';component=$components}
        (@(Get-CommonReleaseRecords solution-deploy @($receipt)|ForEach-Object component) -join ',')|Should Be 'directory,collector-status'
    }
}