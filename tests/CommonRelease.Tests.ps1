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
    It 'routes hand-placed web apps and sends Web Options jobs to the pinned-job procedure' {
        foreach($app in @('web-bookmarks','work-log','web-inventory','plex','web-options')){
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
    It 'releases Web Portfolio jobs while its web procedure stays blocked' {
        $route=Get-CommonReleaseRoute -App web-portfolio -Target jimbrownhome1 -Component stock-collector
        $route.procedure|Should Be none
        (@($route.jobs) -join ',')|Should Be stock-collector
        $all=Get-CommonReleaseRoute -App web-portfolio -Target jimbrownhome1 -WarningAction SilentlyContinue
        $all.procedure|Should Be none
        (@($all.jobs) -join ',')|Should Be stock-collector
        Assert-CommonThrows {Get-CommonReleaseRoute -App web-portfolio -Target jimbrownhome1 -Component web,stock-collector} '*no-downtime*'
    }
    It 'records each job runtime, task list and full runtime commit' {
        $inventory=Read-DeploymentJson (Join-Path $root 'environments\releases.json')
        foreach($app in @('web-options','web-portfolio')){
            foreach($job in $inventory.apps[$app].jobs.Values){
                $job.runtimeCommit|Should Match '^[a-f0-9]{40}$'
                $job.runtime|Should BeLike ($job.prefix+'*')
                @($job.tasks).Count|Should BeGreaterThan 2
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
    It 'limits the host runner to the five hand-placed apps' {
        $runner=[IO.File]::ReadAllText((Join-Path $root 'scripts\Invoke-HandPlacedRelease.ps1'))
        $runner|Should Match ([regex]::Escape('(web-bookmarks|work-log|web-inventory|plex|web-options)'))
        $runner|Should Not Match 'web-portfolio'
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