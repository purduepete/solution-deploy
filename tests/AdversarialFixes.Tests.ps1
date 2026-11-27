$root=Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $root 'src\Deployment.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $root 'src\CommonRelease.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $root 'src\HandPlacedRelease.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $root 'src\DirectoryRelease.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $root 'src\FileSetRelease.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $root 'src\PinnedJobRelease.psm1') -Force -DisableNameChecking

function Assert-AdversarialThrows([scriptblock]$Action,[string]$Message='*'){
    $caught=$null
    try{& $Action|Out-Null}catch{$caught=$_.Exception.Message}
    ($null -ne $caught)|Should Be $true
    $caught|Should BeLike $Message
}

# Runs an internal (unexported) function of a module with the given arguments.
function Invoke-ModuleInternal([string]$Module,[string]$Name,[object[]]$Arguments=@()){
    & (Get-Module $Module) {param($functionName,$values) & $functionName @values} $Name $Arguments
}

# Stubs every host touch in DirectoryRelease so the release flow runs against local temp files only.
function Initialize-DirectoryReleaseFixture([string]$Marker){
    & (Get-Module DirectoryRelease) {param($path) $script:DirectoryUnknownMarker=$path} $Marker
    $global:SdHeadReads=0;$global:SdCompareCalls=0
    Mock Resolve-CommonReleaseSource -ModuleName DirectoryRelease {'b'*40}
    Mock Get-SiteAccess -ModuleName DirectoryRelease {@{}}
    Mock Get-DeploymentLock -ModuleName DirectoryRelease {[IO.MemoryStream]::new()}
    Mock Assert-DeploymentLease -ModuleName DirectoryRelease {}
    Mock New-DeploymentSession -ModuleName DirectoryRelease {'session'}
    Mock Close-DeploymentSession -ModuleName DirectoryRelease {}
    Mock Invoke-DeploymentFileOperation -ModuleName DirectoryRelease {param($Operation,$Arguments) if($Operation -eq 'Delete'){[IO.File]::Delete($Arguments[0])}}
    Mock Test-Path -ModuleName DirectoryRelease {param($LiteralPath,$PathType) [IO.File]::Exists($LiteralPath)}
    Mock Remove-Item -ModuleName DirectoryRelease {}
    Mock Set-Content -ModuleName DirectoryRelease {}
    Mock Get-DirectoryInstallMap -ModuleName DirectoryRelease {@{}}
    Mock Compare-DirectoryInstall -ModuleName DirectoryRelease {if($global:SdCompareCalls++ -eq 0){@()}else{@('site\server.mjs')}}
    Mock Invoke-HostGit -ModuleName DirectoryRelease {param($Arguments,$Repository,$Capture)
        if($Arguments[0] -eq 'rev-parse'){if(++$global:SdHeadReads -eq 1){'a'*40}else{'b'*40}}
    }
}

Describe 'Normalized digests hash binary files as raw bytes' {
    It 'keeps binary files with the same replacement characters distinct' {
        $first=Join-Path $TestDrive 'first.png';$second=Join-Path $TestDrive 'second.png'
        [IO.File]::WriteAllBytes($first,[byte[]](0x89,0x50,0x4E,0x47))
        [IO.File]::WriteAllBytes($second,[byte[]](0x8A,0x50,0x4E,0x47))
        (Get-NormalizedFileDigest $first)|Should Not Be (Get-NormalizedFileDigest $second)
    }
    It 'treats CRLF and LF text files with the same content as equal' {
        $crlf=Join-Path $TestDrive 'crlf.ps1';$lf=Join-Path $TestDrive 'lf.ps1'
        [IO.File]::WriteAllText($crlf,"one`r`ntwo`r`n");[IO.File]::WriteAllText($lf,"one`ntwo`n")
        (Get-NormalizedFileDigest $crlf)|Should Be (Get-NormalizedFileDigest $lf)
    }
    It 'keeps text files with different invalid UTF-8 bytes distinct' {
        $first=Join-Path $TestDrive 'invalid-first.ps1';$second=Join-Path $TestDrive 'invalid-second.ps1'
        [IO.File]::WriteAllBytes($first,[byte[]](0x61,0x20,0xFF,0x0A))
        [IO.File]::WriteAllBytes($second,[byte[]](0x61,0x20,0xFE,0x0A))
        (Get-NormalizedFileDigest $first)|Should Not Be (Get-NormalizedFileDigest $second)
    }
    It 'ignores a UTF-8 byte-order mark on valid text' {
        $bom=Join-Path $TestDrive 'bom.json';$plain=Join-Path $TestDrive 'plain.json'
        [IO.File]::WriteAllBytes($bom,[byte[]](@(0xEF,0xBB,0xBF)+[Text.Encoding]::UTF8.GetBytes('{"a":"caf'+[char]0x00E9+'"}')))
        [IO.File]::WriteAllBytes($plain,[Text.Encoding]::UTF8.GetBytes('{"a":"caf'+[char]0x00E9+'"}'))
        (Get-NormalizedFileDigest $bom)|Should Be (Get-NormalizedFileDigest $plain)
    }
}

Describe 'Directory release unknown outcome and consent' {
    It 'rejects a release whose consent has expired before anything runs' {
        Assert-AdversarialThrows {Invoke-DirectoryRelease -Repository $TestDrive -ApprovalReason 'test' `
            -ExpiresLocal ([DateTimeOffset]::Now.AddMinutes(-1))} '*Release consent expired.*'
    }
    It 'blocks a new release while an unknown-outcome marker exists, after taking the lock' {
        $marker=Join-Path $TestDrive 'state\directory-release-unknown.json'
        [IO.Directory]::CreateDirectory((Split-Path -Parent $marker))|Out-Null
        Write-DeploymentJson $marker @{operationId='abc';hostPid=42;startedLocal='2026-11-27T08:00:00-08:00';timedOutLocal='2026-11-27T08:05:00-08:00';sourceCommit=('a'*40)}
        Initialize-DirectoryReleaseFixture $marker
        Assert-AdversarialThrows {Invoke-DirectoryRelease -Repository $TestDrive -ApprovalReason 'test' -OutputDirectory $TestDrive} '*unknown outcome*host PID 42*remove*'
        Assert-MockCalled Get-DeploymentLock -ModuleName DirectoryRelease -Times 1 -Exactly -Scope It
        Assert-MockCalled Invoke-HostGit -ModuleName DirectoryRelease -Times 0 -Exactly -Scope It
    }
    It 'refuses a second caller that starts while the marker exists, even if the first one has not cleared it' {
        $marker=Join-Path $TestDrive 'race\state\directory-release-unknown.json'
        [IO.Directory]::CreateDirectory((Split-Path -Parent $marker))|Out-Null
        Initialize-DirectoryReleaseFixture $marker
        # The marker is written by the first caller while it holds the lock; the second must see it.
        Mock Get-DeploymentLock -ModuleName DirectoryRelease {
            Write-DeploymentJson $script:DirectoryUnknownMarker @{operationId='first';hostPid=7;startedLocal='2026-11-27T08:00:00-08:00';status='InFlight';sourceCommit=('b'*40)}
            [IO.MemoryStream]::new()
        }
        Assert-AdversarialThrows {Invoke-DirectoryRelease -Repository $TestDrive -ApprovalReason 'test' -OutputDirectory $TestDrive} '*unknown outcome*'
        Assert-MockCalled Invoke-HostGit -ModuleName DirectoryRelease -Times 0 -Exactly -Scope It
    }
    It 'exposes the unhealthy-current recovery switch on the release command' {
        (Get-Command Invoke-DirectoryRelease).Parameters['AllowUnhealthyCurrent'].SwitchParameter|Should Be $true
    }
    It 'writes an InFlight marker before the host installer is launched' {
        $marker=Join-Path $TestDrive 'launch\state\directory-release-unknown.json'
        [IO.Directory]::CreateDirectory((Split-Path -Parent $marker))|Out-Null
        Initialize-DirectoryReleaseFixture $marker
        $global:SdSeenAtLaunch=$null
        Mock Invoke-CimMethod -ModuleName DirectoryRelease {
            $global:SdSeenAtLaunch=Read-DeploymentJson $script:DirectoryUnknownMarker
            [pscustomobject]@{ReturnValue=0;ProcessId=4242}
        }
        Mock Get-CimInstance -ModuleName DirectoryRelease {$null}
        Mock Read-DeploymentJson -ModuleName DirectoryRelease {@{status='Failed';error='x';rollbackVerified=$true}} -ParameterFilter {$Path -like '*sd-directory-*'}
        Mock Test-Path -ModuleName DirectoryRelease {param($LiteralPath,$PathType) [IO.File]::Exists($LiteralPath) -or ($LiteralPath -like '*sd-directory-*.json')}
        try{
            Assert-AdversarialThrows {Invoke-DirectoryRelease -Repository $TestDrive -ApprovalReason 'test' -OutputDirectory $TestDrive} '*installer failed*'
            $global:SdSeenAtLaunch.status|Should Be 'InFlight'
            $global:SdSeenAtLaunch.Contains('hostPid')|Should Be $false
            # The host reported a verified rollback with no process left, so the marker is cleared.
            Test-Path -LiteralPath $marker|Should Be $false
        }finally{Remove-Variable SdSeenAtLaunch -Scope Global -ErrorAction SilentlyContinue}
    }
    It 'keeps the marker and Unknown status when rollback verification fails' {
        $marker=Join-Path $TestDrive 'rollback-fail\state\directory-release-unknown.json'
        [IO.Directory]::CreateDirectory((Split-Path -Parent $marker))|Out-Null
        Initialize-DirectoryReleaseFixture $marker
        Mock Invoke-CimMethod -ModuleName DirectoryRelease {[pscustomobject]@{ReturnValue=0;ProcessId=4242}}
        Mock Get-CimInstance -ModuleName DirectoryRelease {$null}
        Mock Read-DeploymentJson -ModuleName DirectoryRelease {@{status='Failed';error='boom Rollback verification failed: bad hash';rollbackVerified=$false}} -ParameterFilter {$Path -like '*sd-directory-*'}
        Mock Test-Path -ModuleName DirectoryRelease {param($LiteralPath,$PathType) [IO.File]::Exists($LiteralPath) -or ($LiteralPath -like '*sd-directory-*.json')}
        Assert-AdversarialThrows {Invoke-DirectoryRelease -Repository $TestDrive -ApprovalReason 'test' -OutputDirectory $TestDrive} '*without verified rollback*'
        Test-Path -LiteralPath $marker|Should Be $true
    }
    It 'keeps the Unknown status, the marker and the host files when the installer outlives the wait' {
        $marker=Join-Path $TestDrive 'timeout\state\directory-release-unknown.json'
        [IO.Directory]::CreateDirectory((Split-Path -Parent $marker))|Out-Null
        Initialize-DirectoryReleaseFixture $marker
        Mock Invoke-CimMethod -ModuleName DirectoryRelease {[pscustomobject]@{ReturnValue=0;ProcessId=4242}}
        Mock Get-CimInstance -ModuleName DirectoryRelease {[pscustomobject]@{ProcessId=4242}}
        Mock Test-Path -ModuleName DirectoryRelease {param($LiteralPath,$PathType) [IO.File]::Exists($LiteralPath)}
        Mock Remove-Item -ModuleName DirectoryRelease {}
        $out=Join-Path $TestDrive 'timeout-out'
        Assert-AdversarialThrows {Invoke-DirectoryRelease -Repository $TestDrive -ApprovalReason 'test' -OutputDirectory $out -TimeoutSeconds 0} '*outcome is unknown*'
        $saved=Read-DeploymentJson $marker
        $saved.status|Should Be 'Unknown'
        $saved.hostPid|Should Be 4242
        Assert-MockCalled Remove-Item -ModuleName DirectoryRelease -Times 0 -Exactly -Scope It
        $receipt=Get-ChildItem -LiteralPath $out -Recurse -Filter release.json|Select-Object -First 1|ForEach-Object {Read-DeploymentJson $_.FullName}
        $receipt.status|Should Be 'Unknown'
    }
    It 'passes the consent expiry into the host wrapper so the installer checks it before mutating' {
        $marker=Join-Path $TestDrive 'wrapper\state\directory-release-unknown.json'
        [IO.Directory]::CreateDirectory((Split-Path -Parent $marker))|Out-Null
        Initialize-DirectoryReleaseFixture $marker
        $expires=[DateTimeOffset]::Now.AddMinutes(45)
        $global:SdWrapper=$null
        Mock Set-Content -ModuleName DirectoryRelease {param($LiteralPath,$Value) if($LiteralPath -like '*.ps1'){$global:SdWrapper=$Value}}
        Mock Invoke-CimMethod -ModuleName DirectoryRelease {[pscustomobject]@{ReturnValue=1;ProcessId=0}}
        try{
            Assert-AdversarialThrows {Invoke-DirectoryRelease -Repository $TestDrive -ApprovalReason 'test' -OutputDirectory $TestDrive -ExpiresLocal $expires} '*Could not start*'
            (@($global:SdWrapper) -join "`n").Contains("-ExpiresLocal '$($expires.ToString('o'))'")|Should Be $true
        }finally{Remove-Variable SdWrapper -Scope Global -ErrorAction SilentlyContinue}
    }
    It 'clears the marker when the host reports that it never launched' {
        $marker=Join-Path $TestDrive 'nolaunch\state\directory-release-unknown.json'
        [IO.Directory]::CreateDirectory((Split-Path -Parent $marker))|Out-Null
        Initialize-DirectoryReleaseFixture $marker
        Mock Invoke-CimMethod -ModuleName DirectoryRelease {[pscustomobject]@{ReturnValue=9;ProcessId=0}}
        Mock Remove-Item -ModuleName DirectoryRelease {}
        Assert-AdversarialThrows {Invoke-DirectoryRelease -Repository $TestDrive -ApprovalReason 'test' -OutputDirectory $TestDrive} '*Could not start*'
        Test-Path -LiteralPath $marker|Should Be $false
    }
    It 'keeps the unknown-outcome marker, script and result when the installer exits without a result' {
        $marker=Join-Path $TestDrive 'noresult\state\directory-release-unknown.json'
        [IO.Directory]::CreateDirectory((Split-Path -Parent $marker))|Out-Null
        Initialize-DirectoryReleaseFixture $marker
        Mock Invoke-CimMethod -ModuleName DirectoryRelease {[pscustomobject]@{ReturnValue=0;ProcessId=4242}}
        Mock Get-CimInstance -ModuleName DirectoryRelease {$null}
        Mock Start-Sleep -ModuleName DirectoryRelease {}
        $out=Join-Path $TestDrive 'noresult-out'
        Assert-AdversarialThrows {Invoke-DirectoryRelease -Repository $TestDrive -ApprovalReason 'test' -OutputDirectory $out} '*exited without a result*'
        Test-Path -LiteralPath $marker|Should Be $true
        (Read-DeploymentJson $marker).hostPid|Should Be 4242
        Assert-MockCalled Remove-Item -ModuleName DirectoryRelease -Times 0 -Exactly -Scope It
        $receipt=Get-ChildItem -LiteralPath $out -Recurse -Filter release.json|Select-Object -First 1|ForEach-Object {Read-DeploymentJson $_.FullName}
        $receipt.status|Should Be 'Unknown'
    }
    It 'keeps the unknown-outcome marker when the installer result cannot be read' {
        $marker=Join-Path $TestDrive 'badresult\state\directory-release-unknown.json'
        [IO.Directory]::CreateDirectory((Split-Path -Parent $marker))|Out-Null
        Initialize-DirectoryReleaseFixture $marker
        Mock Invoke-CimMethod -ModuleName DirectoryRelease {[pscustomobject]@{ReturnValue=0;ProcessId=4242}}
        Mock Get-CimInstance -ModuleName DirectoryRelease {$null}
        Mock Read-DeploymentJson -ModuleName DirectoryRelease {throw 'result is truncated'} -ParameterFilter {$Path -like '*sd-directory-*'}
        Mock Test-Path -ModuleName DirectoryRelease {param($LiteralPath,$PathType) [IO.File]::Exists($LiteralPath) -or ($LiteralPath -like '*sd-directory-*.json')}
        Assert-AdversarialThrows {Invoke-DirectoryRelease -Repository $TestDrive -ApprovalReason 'test' -OutputDirectory $TestDrive} '*could not be read*'
        [IO.File]::Exists($marker)|Should Be $true
    }
    It 'repairs an unhealthy directory whose files already match when the recovery switch is set' {
        $marker=Join-Path $TestDrive 'repair\state\directory-release-unknown.json'
        [IO.Directory]::CreateDirectory((Split-Path -Parent $marker))|Out-Null
        Initialize-DirectoryReleaseFixture $marker
        Mock Compare-DirectoryInstall -ModuleName DirectoryRelease {@()}
        Mock Test-HandPlacedReadiness -ModuleName DirectoryRelease {throw 'readiness must not short-circuit the repair'}
        Mock Invoke-CimMethod -ModuleName DirectoryRelease {[pscustomobject]@{ReturnValue=1;ProcessId=0}}
        $global:SdWrapper=$null
        Mock Set-Content -ModuleName DirectoryRelease {param($LiteralPath,$Value) if($LiteralPath -like '*.ps1'){$global:SdWrapper=$Value}}
        try{
            Assert-AdversarialThrows {Invoke-DirectoryRelease -Repository $TestDrive -ApprovalReason 'test' -OutputDirectory $TestDrive -AllowUnhealthyCurrent} '*Could not start*'
            (@($global:SdWrapper) -join "`n").Contains('-AllowUnhealthyCurrent')|Should Be $true
            Assert-MockCalled Invoke-CimMethod -ModuleName DirectoryRelease -Times 1 -Exactly -Scope It
        }finally{Remove-Variable SdWrapper -Scope Global -ErrorAction SilentlyContinue}
    }
    It 'returns NoChanges without the recovery switch when the directory already matches' {
        $marker=Join-Path $TestDrive 'nochange\state\directory-release-unknown.json'
        [IO.Directory]::CreateDirectory((Split-Path -Parent $marker))|Out-Null
        Initialize-DirectoryReleaseFixture $marker
        Mock Compare-DirectoryInstall -ModuleName DirectoryRelease {@()}
        Mock Test-HandPlacedReadiness -ModuleName DirectoryRelease {'ready'}
        Mock Invoke-CimMethod -ModuleName DirectoryRelease {throw 'the installer must not run'}
        $receipt=Invoke-DirectoryRelease -Repository $TestDrive -ApprovalReason 'test' -OutputDirectory $TestDrive
        $receipt.status|Should Be 'NoChanges'
        Assert-MockCalled Invoke-CimMethod -ModuleName DirectoryRelease -Times 0 -Exactly -Scope It
    }
    It 'forwards the recovery switch to the host installer only when set' {
        $text=[IO.File]::ReadAllText((Join-Path $root 'src\DirectoryRelease.psm1'))
        $text.Contains("-AllowUnhealthyCurrent'}else{''}")|Should Be $true
        $text.Contains('-PreserveTailscaleRoute$installerSwitches')|Should Be $true
    }
}

Describe 'Directory installer lock, rollback and recovery switch' {
    BeforeAll {
        $tokens=$null;$errors=$null
        $script:installerAst=[Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'scripts\Install-Directory.ps1'),[ref]$tokens,[ref]$errors)
        $script:installerText=[IO.File]::ReadAllText((Join-Path $root 'scripts\Install-Directory.ps1'))
    }
    It 'declares the unhealthy-current switch alongside the route switch' {
        $names=@($script:installerAst.ParamBlock.Parameters|ForEach-Object {$_.Name.VariablePath.UserPath})
        ($names -contains 'AllowUnhealthyCurrent')|Should Be $true
        ($names -contains 'PreserveTailscaleRoute')|Should Be $true
    }
    It 'skips the pre-install route check only when recovery is requested' {
        $script:installerText.Contains('if($PreserveTailscaleRoute -and -not $AllowUnhealthyCurrent){')|Should Be $true
    }
    It 'holds an exclusive host lock from before any change and disposes it in finally' {
        $script:installerText.Contains('[IO.File]::Open("$root\state\directory-install.lock",[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)')|Should Be $true
        $lock=$script:installerText.IndexOf('directory-install.lock')
        $lock|Should BeGreaterThan $script:installerText.IndexOf('$pidFile=')
        $script:installerText.IndexOf('$lock.Dispose()')|Should BeGreaterThan $script:installerText.LastIndexOf('}finally{')
    }
    It 'snapshots the installed payload before stopping and restores it on failure' {
        $snapshot=$script:installerText.IndexOf('$rollback="$root\state\rollback-')
        $stop=$script:installerText.IndexOf('Stop-ScheduledTask -InputObject $task')
        $snapshot|Should BeGreaterThan -1
        $stop|Should BeGreaterThan $snapshot
        $script:installerText.Contains('Copy-Item -LiteralPath "$rollback\$relative" -Destination "$root\$relative" -Force')|Should Be $true
        $script:installerText.Contains("Start-ScheduledTask -TaskPath '\JimlerTech\' -TaskName `$taskName")|Should Be $true
        $script:installerText.Contains('throw $failure')|Should Be $true
    }
    It 'checks the consent expiry before stopping the server and again before copying files' {
        $calls=@($script:installerAst.FindAll({param($n) $n -is [Management.Automation.Language.CommandAst]},$true))
        $consent=@($calls|Where-Object {$_.GetCommandName() -eq 'Assert-ConsentCurrent'}|ForEach-Object {$_.Extent.StartOffset})
        $stop=@($calls|Where-Object {$_.GetCommandName() -eq 'Stop-RecordedDirectoryServer'}|ForEach-Object {$_.Extent.StartOffset})[0]
        $copy=@($calls|Where-Object {$_.GetCommandName() -eq 'Copy-Item' -and $_.Extent.Text -like '*SourcePath\site*'}|ForEach-Object {$_.Extent.StartOffset})[0]
        @($consent|Where-Object {$_ -lt $stop}).Count|Should BeGreaterThan 0
        @($consent|Where-Object {$_ -gt $stop -and $_ -lt $copy}).Count|Should BeGreaterThan 0
        $script:installerAst.ParamBlock.Parameters|Where-Object {$_.Name.VariablePath.UserPath -eq 'ExpiresLocal'}|Should Not BeNullOrEmpty
    }
    It 'stops the new server and waits for its port before restoring the snapshot, then verifies health' {
        $catch=@($script:installerAst.FindAll({param($n) $n -is [Management.Automation.Language.CatchClauseAst]},$true)|
            Where-Object {$_.Body.Extent.Text -match 'Wait-DirectoryPortReleased'})[0]
        ($null -ne $catch)|Should Be $true
        $calls=@($catch.Body.FindAll({param($n) $n -is [Management.Automation.Language.CommandAst]},$true))
        $at={param($name) @($calls|Where-Object {$_.GetCommandName() -eq $name}|ForEach-Object {$_.Extent.StartOffset})[0]}
        $taskStop=& $at 'Stop-ScheduledTask'
        $recordedStop=& $at 'Stop-RecordedDirectoryServer'
        $portWait=& $at 'Wait-DirectoryPortReleased'
        $restore=@($calls|Where-Object {$_.Extent.Text.StartsWith('Copy-Item -LiteralPath "$rollback')}|ForEach-Object {$_.Extent.StartOffset})[0]
        $restart=& $at 'Start-ScheduledTask'
        $health=& $at 'Wait-DirectoryHealthy'
        ($taskStop -lt $recordedStop)|Should Be $true
        ($recordedStop -lt $portWait)|Should Be $true
        ($portWait -lt $restore)|Should Be $true
        ($restore -lt $restart)|Should Be $true
        ($restart -lt $health)|Should Be $true
        $script:installerText.Contains('Rollback verification failed: $rollbackError')|Should Be $true
    }
    It 'disables the recovery and status tasks before the rollback stops the server, and re-enables them only after the restore' {
        $catch=@($script:installerAst.FindAll({param($n) $n -is [Management.Automation.Language.CatchClauseAst]},$true)|
            Where-Object {$_.Body.Extent.Text -match 'Wait-DirectoryPortReleased'})[0]
        $calls=@($catch.Body.FindAll({param($n) $n -is [Management.Automation.Language.CommandAst]},$true))
        $at={param($name) @($calls|Where-Object {$_.GetCommandName() -eq $name}|ForEach-Object {$_.Extent.StartOffset})}
        $disable=(& $at 'Disable-ScheduledTask')[0]
        $recordedStop=(& $at 'Stop-RecordedDirectoryServer')[0]
        $restore=@($calls|Where-Object {$_.Extent.Text.StartsWith('Copy-Item -LiteralPath "$rollback')}|ForEach-Object {$_.Extent.StartOffset})[0]
        $enable=@(& $at 'Enable-ScheduledTask')
        ($disable -lt $recordedStop)|Should Be $true
        $enable.Count|Should BeGreaterThan 0
        ($enable[0] -gt $restore)|Should Be $true
    }
    It 'repeats the consent check after snapshotting and before disabling the recovery task' {
        $calls=@($script:installerAst.FindAll({param($n) $n -is [Management.Automation.Language.CommandAst]},$true))
        $snapshot=$script:installerText.IndexOf('$rollback="$root\state\rollback-')
        $disable=@($calls|Where-Object {$_.GetCommandName() -eq 'Disable-ScheduledTask' -and $_.Extent.Text -like '*InputObject $task*'}|ForEach-Object {$_.Extent.StartOffset})[0]
        @($calls|Where-Object {$_.GetCommandName() -eq 'Assert-ConsentCurrent' -and $_.Extent.StartOffset -gt $snapshot -and $_.Extent.StartOffset -lt $disable}).Count|Should BeGreaterThan 0
    }
    It 'verifies the restored files against the snapshot before removing it' {
        $script:installerText.Contains('Restored files differ from the snapshot')|Should Be $true
        $script:installerText.IndexOf('Restored files differ from the snapshot')|Should BeLessThan $script:installerText.IndexOf('Remove-Item -LiteralPath $rollback -Recurse -Force')
    }
}

Describe 'File-set task fencing and process scoping' {
    It 'fences the tasks that consume each kind of change' {
        $inventory=@{'web-portfolio'=@{task='SolutionDeploy-web-portfolio'};'web-options'=@{task='SolutionDeploy-web-options'}}
        (@(Invoke-ModuleInternal 'FileSetRelease' 'Get-FileSetFenceTasks' @(@{component='finance-launcher';after=@{type='restart-apps';apps=@('web-portfolio','web-options')}},$inventory)) -join ',')|Should Be 'SolutionDeploy-web-portfolio,SolutionDeploy-web-options'
        (@(Invoke-ModuleInternal 'FileSetRelease' 'Get-FileSetFenceTasks' @(@{component='lan-proxy';after=@{type='lan-proxy'}},$inventory)) -join ',')|Should Be 'SolutionDeploy-lan-proxy'
        (@(Invoke-ModuleInternal 'FileSetRelease' 'Get-FileSetFenceTasks' @(@{component='collector-monitor';after=@{type='next-run';task='SolutionDeploy-collector-monitor'}},$inventory)) -join ',')|Should Be 'SolutionDeploy-collector-monitor'
        (@(Invoke-ModuleInternal 'FileSetRelease' 'Get-FileSetFenceTasks' @(@{component='postgres-backup';after=@{type='none'}},$inventory)) -join ',')|Should Be 'PostgreSQL-Backup'
    }
    It 'records the enabled state before disabling and re-enables only what was enabled' {
        Mock Get-ScheduledTask -ModuleName FileSetRelease {[pscustomobject]@{Settings=[pscustomobject]@{Enabled=$true};State='Ready'}}
        Mock Disable-ScheduledTask -ModuleName FileSetRelease {}
        Mock Enable-ScheduledTask -ModuleName FileSetRelease {}
        $fence=@{}
        Invoke-ModuleInternal 'FileSetRelease' 'Suspend-FileSetTask' @('session','SolutionDeploy-a',$fence)
        $fence['SolutionDeploy-a']|Should Be $true
        Assert-MockCalled Disable-ScheduledTask -ModuleName FileSetRelease -Times 1 -Exactly -Scope It
        Invoke-ModuleInternal 'FileSetRelease' 'Resume-FileSetTasks' @('session',$fence,[Collections.Generic.List[string]]::new())
        $fence.Count|Should Be 0
        Assert-MockCalled Enable-ScheduledTask -ModuleName FileSetRelease -Times 1 -Exactly -Scope It
    }
    It 'leaves a task that was already disabled alone' {
        Mock Get-ScheduledTask -ModuleName FileSetRelease {[pscustomobject]@{Settings=[pscustomobject]@{Enabled=$false};State='Disabled'}}
        Mock Disable-ScheduledTask -ModuleName FileSetRelease {}
        Mock Enable-ScheduledTask -ModuleName FileSetRelease {}
        $fence=@{}
        Invoke-ModuleInternal 'FileSetRelease' 'Suspend-FileSetTask' @('session','SolutionDeploy-b',$fence)
        Invoke-ModuleInternal 'FileSetRelease' 'Resume-FileSetTasks' @('session',$fence,[Collections.Generic.List[string]]::new())
        Assert-MockCalled Disable-ScheduledTask -ModuleName FileSetRelease -Times 0 -Exactly -Scope It
        Assert-MockCalled Enable-ScheduledTask -ModuleName FileSetRelease -Times 0 -Exactly -Scope It
    }
    It 'selects only the web launcher and the port owner, never the Telegram pull' {
        Mock Get-CimInstance -ModuleName FileSetRelease {
            @(
                [pscustomobject]@{ProcessId=1001;ParentProcessId=1;ExecutablePath='C:\Program Files\PowerShell\7\pwsh.exe';CommandLine='pwsh.exe -NoProfile -File "C:\ProgramData\SolutionDeploy\apps\web-portfolio\shared\Start-Service.ps1" -Application web-portfolio'}
                [pscustomobject]@{ProcessId=2002;ParentProcessId=1001;ExecutablePath='C:\Program Files\nodejs\node.exe';CommandLine='node.exe C:\ProgramData\SolutionDeploy\apps\web-portfolio\current\backend\dist\server.js'}
                [pscustomobject]@{ProcessId=3003;ParentProcessId=1;ExecutablePath='C:\Program Files\PowerShell\7\pwsh.exe';CommandLine='pwsh.exe -File "C:\ProgramData\SolutionDeploy\apps\web-portfolio\current\scripts\Run-TelegramPull.ps1"'}
                [pscustomobject]@{ProcessId=4004;ParentProcessId=3003;ExecutablePath='C:\Python\python.exe';CommandLine='python.exe C:\ProgramData\SolutionDeploy\apps\web-portfolio\current\telegram_ingest\ingest.py'}
                [pscustomobject]@{ProcessId=5005;ParentProcessId=1;ExecutablePath='C:\Program Files\nodejs\node.exe';CommandLine='node.exe C:\ProgramData\SolutionDeploy\apps\web-options\current\backend\dist\server.js'}
            )
        }
        Mock Get-NetTCPConnection -ModuleName FileSetRelease {@([pscustomobject]@{OwningProcess=2002;LocalAddress='127.0.0.1'})}
        $ids=@(Invoke-ModuleInternal 'FileSetRelease' 'Get-FileSetWebProcesses' @('session','web-portfolio',@{originPort=8793;task='SolutionDeploy-web-portfolio'}))
        (@($ids|ForEach-Object {$_.ProcessId}|Sort-Object) -join ',')|Should Be '1001,2002'
    }
    It 'terminates only the scoped processes during a restart' {
        Mock Get-CimInstance -ModuleName FileSetRelease {
            @(
                [pscustomobject]@{ProcessId=1001;ParentProcessId=1;CommandLine='pwsh.exe "C:\ProgramData\SolutionDeploy\apps\web-portfolio\shared\Start-Service.ps1" -Application web-portfolio'}
                [pscustomobject]@{ProcessId=3003;ParentProcessId=1;CommandLine='pwsh.exe "C:\ProgramData\SolutionDeploy\apps\web-portfolio\current\scripts\Run-TelegramPull.ps1"'}
            )
        }
        Mock Get-NetTCPConnection -ModuleName FileSetRelease {@()}
        Mock Stop-ScheduledTask -ModuleName FileSetRelease {}
        Mock Start-ScheduledTask -ModuleName FileSetRelease {}
        Mock Start-Sleep -ModuleName FileSetRelease {}
        Mock Invoke-CimMethod -ModuleName FileSetRelease {}
        Mock Get-SiteAccess -ModuleName FileSetRelease {@{}}
        Mock Test-HandPlacedReadiness -ModuleName FileSetRelease {'ready'}
        Invoke-ModuleInternal 'FileSetRelease' 'Restart-FileSetApp' @('session','web-portfolio',@{originPort=8793;task='SolutionDeploy-web-portfolio';readiness=@{}})|Out-Null
        Assert-MockCalled Invoke-CimMethod -ModuleName FileSetRelease -Times 1 -Exactly -Scope It -ParameterFilter {$InputObject.ProcessId -eq 1001}
        Assert-MockCalled Invoke-CimMethod -ModuleName FileSetRelease -Times 0 -Exactly -Scope It -ParameterFilter {$InputObject.ProcessId -eq 3003}
    }
    It 'restores replaced files from their backups and removes files it created' {
        $directory=Join-Path $TestDrive 'rollback'
        [IO.Directory]::CreateDirectory($directory)|Out-Null
        $share=Join-Path $directory 'a.mjs';$createdShare=Join-Path $directory 'new.mjs'
        [IO.File]::WriteAllText($share,'new a')
        [IO.File]::WriteAllText($createdShare,'created')
        $backup=Join-Path $TestDrive 'a-backup.mjs'
        [IO.File]::WriteAllText($backup,'old a')
        $acl=Get-Acl -LiteralPath $share
        $failed=@(Invoke-ModuleInternal 'FileSetRelease' 'Restore-FileSetFiles' @(@(@{share=$share;backup=$backup;acl=$acl}),@($createdShare)))
        $failed.Count|Should Be 0
        [IO.File]::ReadAllText($share)|Should Be 'old a'
        Test-Path -LiteralPath $createdShare|Should Be $false
        @(Get-ChildItem -LiteralPath $directory -Filter '*.tmp-*').Count|Should Be 0
    }
    It 'rejects an expired consent before resolving the source or touching any host' {
        Mock Resolve-CommonReleaseSource -ModuleName FileSetRelease {throw 'must not resolve'}
        Assert-AdversarialThrows {Invoke-FileSetRelease -Repository $TestDrive -Entry @{} -Component web -ApprovalReason 'test' `
            -ExpiresLocal ([DateTimeOffset]::Now.AddMinutes(-1))} '*Release consent expired.*'
        Assert-MockCalled Resolve-CommonReleaseSource -ModuleName FileSetRelease -Times 0 -Exactly -Scope It
    }
    It 'fences, rolls back and re-enables the task when the post-copy check fails' {
        $fixture=Join-Path $TestDrive 'fileset'
        $bundle=Join-Path $fixture 'bundle';$installed=Join-Path $fixture 'installed';$out=Join-Path $fixture 'out'
        foreach($folder in $bundle,$installed,$out){[IO.Directory]::CreateDirectory($folder)|Out-Null}
        [IO.File]::WriteAllText((Join-Path $bundle 'a.mjs'),'new a')
        [IO.File]::WriteAllText((Join-Path $installed 'a.mjs'),'old a')
        $global:SdFileSetFixture=@{bundle=$bundle;share=(Join-Path $installed 'a.mjs')}
        try{
            Mock Resolve-CommonReleaseSource -ModuleName FileSetRelease {'a'*40}
            Mock Get-FileSetPlan -ModuleName FileSetRelease {
                @{component='lan-proxy';after=@{type='lan-proxy'};files=@(@{source='a.mjs';target='C:\ProgramData\SolutionDeploy\apps\lan-proxy\site\a.mjs';share=$global:SdFileSetFixture.share})}
            }
            Mock Invoke-DeploymentCommand -ModuleName FileSetRelease {}
            Mock Expand-Archive -ModuleName FileSetRelease {
                param($LiteralPath,$DestinationPath)
                if(-not $DestinationPath){throw 'The fixture must extract into a release folder.'}
                Copy-Item -Path (Join-Path $global:SdFileSetFixture.bundle '*') -Destination $DestinationPath -Recurse -Force
            }
            Mock Get-DeploymentLock -ModuleName FileSetRelease {[IO.MemoryStream]::new()}
            Mock Assert-DeploymentLease -ModuleName FileSetRelease {}
            Mock New-DeploymentSession -ModuleName FileSetRelease {'session'}
            Mock Close-DeploymentSession -ModuleName FileSetRelease {}
            Mock Get-ScheduledTask -ModuleName FileSetRelease {[pscustomobject]@{Settings=[pscustomobject]@{Enabled=$true};State='Ready'}}
            Mock Disable-ScheduledTask -ModuleName FileSetRelease {}
            Mock Enable-ScheduledTask -ModuleName FileSetRelease {}
            # Both the pre-copy and the post-copy comparison report the file as different, so the release must roll back.
            Mock Compare-FileSet -ModuleName FileSetRelease {param($Files,$Source) @($Files)}
            Assert-AdversarialThrows {Invoke-FileSetRelease -Repository $TestDrive -Entry @{} -Component lan-proxy -ApprovalReason 'test' `
                -OutputDirectory $out} '*still differ*'
            [IO.File]::ReadAllText((Join-Path $installed 'a.mjs'))|Should Be 'old a'
            Assert-MockCalled Disable-ScheduledTask -ModuleName FileSetRelease -Times 1 -Exactly -Scope It -ParameterFilter {$TaskName -eq 'SolutionDeploy-lan-proxy'}
            Assert-MockCalled Enable-ScheduledTask -ModuleName FileSetRelease -Times 1 -Exactly -Scope It -ParameterFilter {$TaskName -eq 'SolutionDeploy-lan-proxy'}
            $receipt=Get-ChildItem -LiteralPath $out -Recurse -Filter release.json|Select-Object -First 1|ForEach-Object {Read-DeploymentJson $_.FullName}
            $receipt.status|Should Be 'Failed'
            $receipt.rolledBack|Should Be $true
        }finally{Remove-Variable SdFileSetFixture -Scope Global -ErrorAction SilentlyContinue}
    }
    It 're-fences, restores and restarts the lan proxy when a failure follows the resume' {
        $fixture=Join-Path $TestDrive 'refence'
        $bundle=Join-Path $fixture 'bundle';$installed=Join-Path $fixture 'installed';$out=Join-Path $fixture 'out'
        foreach($folder in $bundle,$installed,$out){[IO.Directory]::CreateDirectory($folder)|Out-Null}
        [IO.File]::WriteAllText((Join-Path $bundle 'a.mjs'),'new a')
        [IO.File]::WriteAllText((Join-Path $installed 'a.mjs'),'old a')
        $global:SdFileSetFixture=@{bundle=$bundle;share=(Join-Path $installed 'a.mjs')}
        $global:SdEvents=[Collections.Generic.List[string]]::new()
        $global:SdCompareCalls=0;$global:SdLanCalls=0
        try{
            Mock Resolve-CommonReleaseSource -ModuleName FileSetRelease {'a'*40}
            Mock Get-FileSetPlan -ModuleName FileSetRelease {
                @{component='lan-proxy';after=@{type='lan-proxy'};files=@(@{source='a.mjs';target='C:\ProgramData\SolutionDeploy\apps\lan-proxy\site\a.mjs';share=$global:SdFileSetFixture.share})}
            }
            Mock Invoke-DeploymentCommand -ModuleName FileSetRelease {}
            Mock Expand-Archive -ModuleName FileSetRelease {
                param($LiteralPath,$DestinationPath)
                Copy-Item -Path (Join-Path $global:SdFileSetFixture.bundle '*') -Destination $DestinationPath -Recurse -Force
            }
            Mock Get-DeploymentLock -ModuleName FileSetRelease {[IO.MemoryStream]::new()}
            Mock Assert-DeploymentLease -ModuleName FileSetRelease {}
            Mock New-DeploymentSession -ModuleName FileSetRelease {'session'}
            Mock Close-DeploymentSession -ModuleName FileSetRelease {}
            Mock Get-ScheduledTask -ModuleName FileSetRelease {[pscustomobject]@{Settings=[pscustomobject]@{Enabled=$true};State='Ready'}}
            Mock Disable-ScheduledTask -ModuleName FileSetRelease {param($CimSession,$TaskPath,$TaskName) $global:SdEvents.Add("disable $TaskName")}
            Mock Enable-ScheduledTask -ModuleName FileSetRelease {param($CimSession,$TaskPath,$TaskName) $global:SdEvents.Add("enable $TaskName")}
            # The pre-copy check finds the change; the post-copy check finds nothing left to fix.
            Mock Compare-FileSet -ModuleName FileSetRelease {param($Files,$Source) if($global:SdCompareCalls++ -eq 0){@($Files)}else{@()}}
            Mock Restart-FileSetLanProxy -ModuleName FileSetRelease {param($Session)
                $global:SdLanCalls++
                $global:SdEvents.Add("restart $($global:SdLanCalls) sees=$([IO.File]::ReadAllText($global:SdFileSetFixture.share))")
                if($global:SdLanCalls -eq 1){throw 'The LAN proxy did not come back on http://192.168.2.14:8798/ within 60 s.'}
                @{pid=1}
            }
            Assert-AdversarialThrows {Invoke-FileSetRelease -Repository $TestDrive -Entry @{} -Component lan-proxy -ApprovalReason 'test' `
                -OutputDirectory $out} '*did not come back*'
            ($global:SdEvents -join '|')|Should Be ('disable SolutionDeploy-lan-proxy|enable SolutionDeploy-lan-proxy|restart 1 sees=new a|' +
                'disable SolutionDeploy-lan-proxy|enable SolutionDeploy-lan-proxy|restart 2 sees=old a')
            [IO.File]::ReadAllText((Join-Path $installed 'a.mjs'))|Should Be 'old a'
            $receipt=Get-ChildItem -LiteralPath $out -Recurse -Filter release.json|Select-Object -First 1|ForEach-Object {Read-DeploymentJson $_.FullName}
            $receipt.rolledBack|Should Be $true
            $receipt.ContainsKey('rollbackFailures')|Should Be $false
        }finally{
            Remove-Variable SdFileSetFixture,SdEvents,SdCompareCalls,SdLanCalls -Scope Global -ErrorAction SilentlyContinue
        }
    }
    It 'fences every task that already resumed when the resume fails partway, before the old files go back' {
        $fixture=Join-Path $TestDrive 'partial-resume'
        $bundle=Join-Path $fixture 'bundle';$installed=Join-Path $fixture 'installed';$out=Join-Path $fixture 'out'
        foreach($folder in $bundle,$installed,$out){[IO.Directory]::CreateDirectory($folder)|Out-Null}
        [IO.File]::WriteAllText((Join-Path $bundle 'a.mjs'),'new a')
        [IO.File]::WriteAllText((Join-Path $installed 'a.mjs'),'old a')
        $global:SdFileSetFixture=@{bundle=$bundle;share=(Join-Path $installed 'a.mjs')}
        $global:SdEvents=[Collections.Generic.List[string]]::new()
        $global:SdCompareCalls=0;$global:SdEnables=0
        try{
            Mock Resolve-CommonReleaseSource -ModuleName FileSetRelease {'a'*40}
            Mock Get-FileSetPlan -ModuleName FileSetRelease {
                @{component='lan-proxy';after=@{type='none'};files=@(@{source='a.mjs';target='C:\ProgramData\SolutionDeploy\apps\lan-proxy\site\a.mjs';share=$global:SdFileSetFixture.share})}
            }
            Mock Get-FileSetFenceTasks -ModuleName FileSetRelease {'SolutionDeploy-one','SolutionDeploy-two'}
            Mock Invoke-DeploymentCommand -ModuleName FileSetRelease {}
            Mock Expand-Archive -ModuleName FileSetRelease {
                param($LiteralPath,$DestinationPath)
                Copy-Item -Path (Join-Path $global:SdFileSetFixture.bundle '*') -Destination $DestinationPath -Recurse -Force
            }
            Mock Get-DeploymentLock -ModuleName FileSetRelease {[IO.MemoryStream]::new()}
            Mock Assert-DeploymentLease -ModuleName FileSetRelease {}
            Mock New-DeploymentSession -ModuleName FileSetRelease {'session'}
            Mock Close-DeploymentSession -ModuleName FileSetRelease {}
            Mock Get-ScheduledTask -ModuleName FileSetRelease {[pscustomobject]@{Settings=[pscustomobject]@{Enabled=$true};State='Ready'}}
            Mock Disable-ScheduledTask -ModuleName FileSetRelease {param($CimSession,$TaskPath,$TaskName) $global:SdEvents.Add("disable $TaskName")}
            # The first task re-enables; the second is refused, so only the first must be fenced again.
            Mock Enable-ScheduledTask -ModuleName FileSetRelease {param($CimSession,$TaskPath,$TaskName)
                if($global:SdEnables++ -eq 1){throw 'enable refused for the second task'}
                $global:SdEvents.Add("enable $TaskName")
            }
            Mock Compare-FileSet -ModuleName FileSetRelease {param($Files,$Source) if($global:SdCompareCalls++ -eq 0){@($Files)}else{@()}}
            Assert-AdversarialThrows {Invoke-FileSetRelease -Repository $TestDrive -Entry @{} -Component lan-proxy -ApprovalReason 'test' `
                -OutputDirectory $out} '*enable refused for the second task*'
            $global:SdEvents.Count|Should BeGreaterThan 1
            # The task that resumed is fenced again right after it was enabled, before the old files are restored.
            $first=0
            while($global:SdEvents[$first] -notlike 'enable *'){$first++}
            $global:SdEvents[$first+1]|Should Be ($global:SdEvents[$first] -replace '^enable','disable')
            [IO.File]::ReadAllText((Join-Path $installed 'a.mjs'))|Should Be 'old a'
            $receipt=Get-ChildItem -LiteralPath $out -Recurse -Filter release.json|Select-Object -First 1|ForEach-Object {Read-DeploymentJson $_.FullName}
            $receipt.rolledBack|Should Be $true
        }finally{
            Remove-Variable SdFileSetFixture,SdEvents,SdCompareCalls,SdEnables -Scope Global -ErrorAction SilentlyContinue
        }
    }
    It 'refuses to terminate a port owner that does not belong to the app' {
        Mock Get-CimInstance -ModuleName FileSetRelease {
            @(
                [pscustomobject]@{ProcessId=1001;ParentProcessId=1;ExecutablePath='C:\Program Files\PowerShell\7\pwsh.exe';CommandLine='pwsh.exe "C:\ProgramData\SolutionDeploy\apps\web-portfolio\shared\Start-Service.ps1" -Application web-portfolio'}
                [pscustomobject]@{ProcessId=6006;ParentProcessId=1;ExecutablePath='C:\Program Files\nodejs\node.exe';CommandLine='node.exe C:\ProgramData\SolutionDeploy\apps\web-options\current\backend\dist\server.js'}
            )
        }
        Mock Get-NetTCPConnection -ModuleName FileSetRelease {@([pscustomobject]@{OwningProcess=6006;LocalAddress='127.0.0.1'})}
        Mock Stop-ScheduledTask -ModuleName FileSetRelease {}
        Mock Start-Sleep -ModuleName FileSetRelease {}
        Mock Invoke-CimMethod -ModuleName FileSetRelease {}
        Assert-AdversarialThrows {Invoke-ModuleInternal 'FileSetRelease' 'Restart-FileSetApp' @('session','web-portfolio',@{originPort=8793;task='SolutionDeploy-web-portfolio';readiness=@{}})} `
            '*Refusing to terminate unknown process PID 6006 owning port 8793*'
        Assert-MockCalled Invoke-CimMethod -ModuleName FileSetRelease -Times 0 -Exactly -Scope It
    }
    It 'refuses to terminate the Portfolio Telegram pull that owns the app port' {
        Mock Get-CimInstance -ModuleName FileSetRelease {
            @([pscustomobject]@{ProcessId=7007;ParentProcessId=1;ExecutablePath='C:\Program Files\PowerShell\7\pwsh.exe';CommandLine='pwsh.exe -File "C:\ProgramData\SolutionDeploy\apps\web-portfolio\current\scripts\Run-TelegramPull.ps1"'})
        }
        Mock Get-NetTCPConnection -ModuleName FileSetRelease {@([pscustomobject]@{OwningProcess=7007;LocalAddress='127.0.0.1'})}
        Mock Invoke-CimMethod -ModuleName FileSetRelease {}
        Assert-AdversarialThrows {Invoke-ModuleInternal 'FileSetRelease' 'Get-FileSetWebProcesses' @('session','web-portfolio',@{originPort=8793})} '*Refusing to terminate unknown process PID 7007*'
        Assert-MockCalled Invoke-CimMethod -ModuleName FileSetRelease -Times 0 -Exactly -Scope It
    }
}

Describe 'Hand-placed carry-forward timing' {
    BeforeAll {
        $tokens=$null;$errors=$null
        $script:runnerAst=[Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'scripts\Invoke-HandPlacedRelease.ps1'),[ref]$tokens,[ref]$errors)
        $script:runnerText=[IO.File]::ReadAllText((Join-Path $root 'scripts\Invoke-HandPlacedRelease.ps1'))
    }
    It 'copies carry-forward state only during Activate, after the app stops and before the junction switch' {
        $ifs=@($script:runnerAst.FindAll({param($n) $n -is [Management.Automation.Language.IfStatementAst]},$true))
        $phase=@($ifs|Where-Object {$_.Clauses[0].Item1.Extent.Text -eq "`$Phase -eq 'Prepare'"})[0]
        ($null -ne $phase)|Should Be $true
        $prepareEnd=$phase.Clauses[0].Item2.Extent.EndOffset
        $calls=@($script:runnerAst.FindAll({param($n) $n -is [Management.Automation.Language.CommandAst]},$true))
        $copies=@($calls|Where-Object {$_.GetCommandName() -eq 'Copy-Item' -and $_.Extent.Text -like '*$from*'})
        $copies.Count|Should Be 1
        $copy=$copies[0].Extent.StartOffset
        ($copy -gt $prepareEnd)|Should Be $true
        $stop=@($calls|Where-Object {$_.GetCommandName() -eq 'Stop-HandPlacedApp' -and $_.Extent.StartOffset -gt $prepareEnd})[0].Extent.StartOffset
        $junction=@($calls|Where-Object {$_.GetCommandName() -eq 'New-Item' -and $_.Extent.Text -match 'Junction'})[0].Extent.StartOffset
        ($copy -gt $stop)|Should Be $true
        ($copy -lt $junction)|Should Be $true
    }
    It 'fences the Portfolio Telegram task before the stop and lifts it only in the outer finally' {
        $calls=@($script:runnerAst.FindAll({param($n) $n -is [Management.Automation.Language.CommandAst]},$true))
        $disable=@($calls|Where-Object {$_.GetCommandName() -eq 'Disable-ScheduledTask'})[0].Extent.StartOffset
        $stop=@($calls|Where-Object {$_.GetCommandName() -eq 'Stop-HandPlacedApp'})[0].Extent.StartOffset
        ($disable -lt $stop)|Should Be $true
        $script:runnerText.Contains("`$app -eq 'web-portfolio' -and `$carry.Count")|Should Be $true
        $script:runnerText.Contains('Run-TelegramPull\.ps1|telegram_ingest')|Should Be $true
        $script:runnerText.Contains('SolutionDeploy-web-portfolio-telegram')|Should Be $true
        $tries=@($script:runnerAst.FindAll({param($n) $n -is [Management.Automation.Language.TryStatementAst]},$true))
        $enables=@($calls|Where-Object {$_.GetCommandName() -eq 'Enable-ScheduledTask'})
        $enables.Count|Should Be 1
        $outer=@($tries|Where-Object {$_.Finally -and $_.Finally.Extent.Text -match 'Enable-ScheduledTask'})
        $outer.Count|Should Be 1
        ($enables[0].Extent.StartOffset -ge $outer[0].Finally.Extent.StartOffset)|Should Be $true
        ($enables[0].Extent.EndOffset -le $outer[0].Finally.Extent.EndOffset)|Should Be $true
    }
    It 'rechecks the request and previous release after the carry-forward copy and before the junction switch' {
        $calls=@($script:runnerAst.FindAll({param($n) $n -is [Management.Automation.Language.CommandAst]},$true))
        $copy=@($calls|Where-Object {$_.GetCommandName() -eq 'Copy-Item' -and $_.Extent.Text -like '*$from*'})[0].Extent.StartOffset
        $delete=$script:runnerText.IndexOf('[IO.Directory]::Delete($current,$false)')
        $delete|Should BeGreaterThan $copy
        $between=@($calls|Where-Object {$_.Extent.StartOffset -gt $copy -and $_.Extent.StartOffset -lt $delete})
        @($between|Where-Object {$_.GetCommandName() -eq 'Assert-RequestCurrent'}).Count|Should BeGreaterThan 0
        @($between|Where-Object {$_.GetCommandName() -eq 'Assert-PreviousCurrent'}).Count|Should BeGreaterThan 0
    }
}

Describe 'Fit Track switch consent and recovery' {
    BeforeAll {
        $tokens=$null;$errors=$null
        $script:fitAst=[Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'scripts\Invoke-FitTrackRelease.ps1'),[ref]$tokens,[ref]$errors)
        $script:fitText=[IO.File]::ReadAllText((Join-Path $root 'scripts\Invoke-FitTrackRelease.ps1'))
    }
    It 'checks the request immediately before the active release is switched and never after' {
        $calls=@($script:fitAst.FindAll({param($n) $n -is [Management.Automation.Language.CommandAst]},$true))
        $set=@($calls|Where-Object {$_.GetCommandName() -eq 'Set-ActiveRelease'})[0].Extent.StartOffset
        $asserts=@($calls|Where-Object {$_.GetCommandName() -eq 'Assert-RequestCurrent'}|ForEach-Object {$_.Extent.StartOffset})
        @($asserts|Where-Object {$_ -gt $set}).Count|Should Be 0
        @($asserts|Where-Object {$_ -lt $set}).Count|Should BeGreaterThan 0
        $script:fitText.Contains("Assert-RequestCurrent`r`n        Set-ActiveRelease")|Should Be $false
        $script:fitText.Contains("Assert-RequestCurrent`n        Set-ActiveRelease")|Should Be $true
    }
    It 'tracks the stop and the switch so a failure before the switch restarts the previous release' {
        $script:fitText.Contains('$stopped=$true')|Should Be $true
        $script:fitText.Contains('$switched=$true')|Should Be $true
        $try=@($script:fitAst.FindAll({param($n) $n -is [Management.Automation.Language.TryStatementAst]},$true)|
            Where-Object {$_.Body.Extent.Text -match 'Set-ActiveRelease'})[0]
        $handler=$try.CatchClauses[0].Body.Extent.Text
        $handler.Contains('if($stopped -and -not $switched){')|Should Be $true
        $handler.Contains('Clear-AppMaintenance -AppRoot $appRoot -Confirm:$false')|Should Be $true
        $handler.Contains("Start-ScheduledTask -TaskPath '\JimlerTech\' -TaskName SolutionDeploy-fit-track")|Should Be $true
        $handler.Contains("`$result.recovery='Previous release restarted.'")|Should Be $true
    }
}

Describe 'Pinned-job verification bound to each repointed task' {
    BeforeAll {
        $script:base='C:\ProgramData\SolutionDeploy\apps\web-options\releases'
        $script:oldRelease="$script:base\collector-68f9512"
        $script:newRelease="$script:base\collector-1234567"
        function New-TimedTask([string]$Name,[string]$Release){
            [pscustomobject]@{TaskName=$Name;Actions=@([pscustomobject]@{Execute='pwsh.exe';Arguments="-File `"$Release\scripts\Start-Collector.ps1`" -ReleasePath `"$Release`"";WorkingDirectory=$Release})
                Triggers=@([pscustomobject]@{Repetition=[pscustomobject]@{Interval='PT5M'}});Settings=[pscustomobject]@{Enabled=$true}}
        }
        $script:tasks=@((New-TimedTask tick "$script:base\collector-68f9512"),(New-TimedTask watchdog "$script:base\collector-68f9512"))
    }
    It 'records a repoint time for each task after its own action change' {
        Mock Invoke-PinnedJobAccessPreflight -ModuleName PinnedJobRelease {@{status='Succeeded';sid='S-1-5-19'}}
        Mock Set-PinnedJobTaskAction -ModuleName PinnedJobRelease {}
        $receipt=@{repointed=@()}
        Set-VerifiedPinnedJobActions -Session fixture -App web-options -Tasks $script:tasks `
            -Current @{path=$script:oldRelease} -ReleasePath $script:newRelease -Receipt $receipt -Id ('c'*32)
        (@($receipt.repointedAt.Keys|Sort-Object) -join ',')|Should Be 'tick,watchdog'
        ($receipt.repointedAt['tick'] -is [datetime])|Should Be $true
        Assert-MockCalled Set-PinnedJobTaskAction -ModuleName PinnedJobRelease -Times 2 -Exactly -Scope It
    }
    It 'rejects a run that started before that task was repointed' {
        $global:SdLastRun=[datetime]'2026-11-27T11:59:00'
        Mock Get-ScheduledTaskInfo -ModuleName PinnedJobRelease {[pscustomobject]@{LastRunTime=$global:SdLastRun;LastTaskResult=0;NextRunTime=[datetime]'2026-11-27T12:05:00'}}
        Mock Get-ScheduledTask -ModuleName PinnedJobRelease {[pscustomobject]@{Actions=@([pscustomobject]@{Arguments='-File "x" -ReleasePath "C:\ProgramData\SolutionDeploy\apps\web-options\releases\collector-1234567"'})}}
        Mock Start-Sleep -ModuleName PinnedJobRelease {}
        Mock Write-Host -ModuleName PinnedJobRelease {}
        try{
            $since=@{tick=[datetime]'2026-11-27T12:00:00';watchdog=[datetime]'2026-11-27T11:00:00'}
            $release='C:\ProgramData\SolutionDeploy\apps\web-options\releases\collector-1234567'
            $results=Wait-PinnedJobRuns -Session fixture -Tasks $script:tasks -SinceByTask $since -ReleasePath $release -TimeoutSeconds 1
            $results['tick']|Should Be 'Repointed; no completed run within the wait'
            $global:SdLastRun=[datetime]'2026-11-27T12:01:00'
            $results=Wait-PinnedJobRuns -Session fixture -Tasks $script:tasks -SinceByTask $since -ReleasePath $release -TimeoutSeconds 1
            $results['tick']|Should Match '^Ran 12:01:00'
        }finally{Remove-Variable SdLastRun -Scope Global -ErrorAction SilentlyContinue}
    }
    It 'rejects an expired consent before the preflight or any repoint' {
        Mock Invoke-PinnedJobAccessPreflight -ModuleName PinnedJobRelease {throw 'must not run'}
        Mock Set-PinnedJobTaskAction -ModuleName PinnedJobRelease {}
        Assert-AdversarialThrows {Set-VerifiedPinnedJobActions -Session fixture -App web-options -Tasks $script:tasks `
            -Current @{path=$script:oldRelease} -ReleasePath $script:newRelease -Receipt @{repointed=@()} `
            -Id ('d'*32) -ExpiresLocal ([DateTimeOffset]::Now.AddMinutes(-1))} '*Release consent expired.*'
        Assert-MockCalled Invoke-PinnedJobAccessPreflight -ModuleName PinnedJobRelease -Times 0 -Exactly -Scope It
        Assert-MockCalled Set-PinnedJobTaskAction -ModuleName PinnedJobRelease -Times 0 -Exactly -Scope It
    }
    It 'rejects an expired consent before any pinned-job host action' {
        Assert-AdversarialThrows {Invoke-PinnedJobRelease -App web-options -Entry @{jobs=@{}} -Component collector -Repository $TestDrive `
            -ApprovalReason 'test' -ExpiresLocal ([DateTimeOffset]::Now.AddMinutes(-1))} '*Release consent expired.*'
    }
}

Describe 'Common release consent propagation' {
    It 'forwards the consent expiry to every directory, file-set and pinned-job procedure' {
        $text=[IO.File]::ReadAllText((Join-Path $root 'src\CommonRelease.psm1'))
        $text.Contains('-TimeoutSeconds $TimeoutSeconds -ExpiresLocal $ExpiresLocal)')|Should Be $true
        $text.Contains("'Commit','OutputDirectory','TimeoutSeconds','ExpiresLocal'")|Should Be $true
        $text.Contains("'Commit','OutputDirectory','ExpiresLocal'")|Should Be $true
        $text.Contains('$arguments.ExpiresLocal=$ExpiresLocal')|Should Be $true
    }
    It 'gives every consent-bearing procedure an expiry parameter' {
        foreach($name in 'Invoke-DirectoryRelease','Invoke-FileSetRelease','Invoke-PinnedJobRelease'){
            (Get-Command $name).Parameters.ContainsKey('ExpiresLocal')|Should Be $true
        }
    }
}
