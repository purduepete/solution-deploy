#requires -Version 7.5
#requires -RunAsAdministrator
[CmdletBinding(SupportsShouldProcess,ConfirmImpact='High')]
param(
    [Parameter(Mandatory)][string]$Root,
    [Parameter(Mandatory)][string]$ExpectedHostIdentity,
    [Parameter(Mandatory)][string]$ExpectedInstalledCodeSHA256,
    [Parameter(Mandatory)][string]$ExpectedCodeSHA256,
    [switch]$ApproveUpdate
)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$source=Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $source 'src\Deployment.psm1') -DisableNameChecking
if(-not $ApproveUpdate){throw 'Executor updates require explicit review and -ApproveUpdate.'}
if($Root -notmatch '^[A-Z]:\\ProgramData\\SolutionDeploy$'){throw 'Executor root must be the dedicated ProgramData directory.'}
if((Get-CimInstance Win32_ComputerSystemProduct -Property UUID).UUID -ne $ExpectedHostIdentity){throw 'Executor host identity differs.'}
$files=@(Get-ChildItem -LiteralPath (Join-Path $source 'src'),(Join-Path $source 'scripts'),(Join-Path $source 'schemas') -File -Recurse |
    Where-Object Extension -in @('.ps1','.psm1','.py','.json') | Sort-Object FullName)
$inventory=@($files | ForEach-Object {@{path=[IO.Path]::GetRelativePath($source,$_.FullName);sha256=(Get-FileHash -LiteralPath $_.FullName).Hash.ToLowerInvariant()}})
$digest=Get-Sha256Text (ConvertTo-CanonicalJson $inventory)
if($digest -ne $ExpectedCodeSHA256){throw 'Updated executor code differs from the reviewed digest.'}
if(-not $PSCmdlet.ShouldProcess("$env:COMPUTERNAME / $Root",'Update protected deployment executor without restarting applications')){return}
$locks=[Collections.Generic.List[IDisposable]]::new()
$changed=[Collections.Generic.List[object]]::new()
$taskLimitChanged=$false
$previousTaskLimit=$null
$installationPath=Join-Path $Root 'control\installation.json'
$backup=Join-Path $Root ('control\executor-updates\'+[guid]::NewGuid().ToString('N'))
try{
    foreach($name in @('submission.lock','execution.lock')){$locks.Add((Get-DeploymentLock (Join-Path $Root ('control\'+$name))))}
    $installation=Read-DeploymentJson $installationPath
    if($installation.identity -ne $ExpectedHostIdentity -or $installation.root -ne $Root -or
        $installation.codeSHA256 -ne $ExpectedInstalledCodeSHA256){throw 'Installed executor baseline changed.'}
    foreach($file in $installation.files){
        $path=Resolve-OwnedPath (Join-Path $Root 'control\framework') $file.path
        if((Get-FileHash -LiteralPath $path).Hash.ToLowerInvariant() -ne $file.sha256){throw 'Installed executor has unrecorded changes.'}
    }
    foreach($file in $installation.files){if($file.path -notin $inventory.path){throw 'Removing installed executor files requires separate review.'}}
    $task=Get-ScheduledTask -TaskPath '\JimlerTech\' -TaskName 'SolutionDeploy-Executor' -ErrorAction Stop
    if($task.State -eq 'Running'){throw 'Protected executor is running; wait for its operation to finish.'}
    $expectedExecutor=Join-Path $Root 'control\framework\scripts\Invoke-HostExecutor.ps1'
    if(@($task.Actions).Count -ne 1 -or $task.Actions[0].Execute -ine $installation.powerShellPath -or
        $task.Actions[0].Arguments -notmatch [regex]::Escape($expectedExecutor)){
        throw 'Protected executor task differs from the installed baseline.'
    }
    $previousTaskLimit=[string]$task.Settings.ExecutionTimeLimit
    [IO.Directory]::CreateDirectory($backup) | Out-Null
    [IO.File]::Copy($installationPath,(Join-Path $backup 'installation.json'),$false)
    foreach($file in $inventory){
        $target=Resolve-OwnedPath (Join-Path $Root 'control\framework') $file.path
        $exists=Test-Path -LiteralPath $target
        if($exists -and (Get-FileHash -LiteralPath $target).Hash.ToLowerInvariant() -eq $file.sha256){continue}
        if($exists){
            $saved=Resolve-OwnedPath $backup $file.path
            [IO.Directory]::CreateDirectory((Split-Path -Parent $saved)) | Out-Null
            [IO.File]::Copy($target,$saved,$false)
        }
        $changed.Add(@{path=$file.path;existed=$exists})
        [IO.Directory]::CreateDirectory((Split-Path -Parent $target)) | Out-Null
        [IO.File]::Copy((Join-Path $source $file.path),$target,$true)
        if((Get-FileHash -LiteralPath $target).Hash.ToLowerInvariant() -ne $file.sha256){throw 'Copied executor bytes differ.'}
    }
    $updated=@{}+$installation
    $updated.files=$inventory;$updated.codeSHA256=$digest;$updated.updatedLocal=(Get-Date).ToString('o')
    Write-DeploymentJson $installationPath $updated
    $settings=$task.Settings
    $settings.ExecutionTimeLimit='PT30M'
    $taskLimitChanged=$true
    Set-ScheduledTask -TaskPath '\JimlerTech\' -TaskName 'SolutionDeploy-Executor' -Settings $settings -ErrorAction Stop | Out-Null
    $updatedTask=Get-ScheduledTask -TaskPath '\JimlerTech\' -TaskName 'SolutionDeploy-Executor' -ErrorAction Stop
    if([string]$updatedTask.Settings.ExecutionTimeLimit -ne 'PT30M'){throw 'Protected executor task limit did not update to 30 minutes.'}
    Write-DeploymentJson (Join-Path $backup 'result.json') @{
        status='Succeeded';previousCodeSHA256=$ExpectedInstalledCodeSHA256;codeSHA256=$digest
        changed=@($changed);executionTimeLimit='PT30M';completedLocal=(Get-Date).ToString('o')
    }
    @{status='Succeeded';codeSHA256=$digest;backup=$backup}
}catch{
    $failure=$_.Exception.Message
    $rollbackFailure=$null
    if($taskLimitChanged){
        try{
            $restoreTask=Get-ScheduledTask -TaskPath '\JimlerTech\' -TaskName 'SolutionDeploy-Executor' -ErrorAction Stop
            $restoreSettings=$restoreTask.Settings
            $restoreSettings.ExecutionTimeLimit=$previousTaskLimit
            Set-ScheduledTask -TaskPath '\JimlerTech\' -TaskName 'SolutionDeploy-Executor' -Settings $restoreSettings -ErrorAction Stop | Out-Null
        }catch{$rollbackFailure=$_.Exception.Message}
    }
    for($i=$changed.Count-1;$i -ge 0;$i--){
        $file=$changed[$i]
        $target=Resolve-OwnedPath (Join-Path $Root 'control\framework') $file.path
        if($file.existed){[IO.File]::Copy((Resolve-OwnedPath $backup $file.path),$target,$true)}
        elseif(Test-Path -LiteralPath $target){[IO.File]::Delete($target)}
    }
    if(Test-Path -LiteralPath (Join-Path $backup 'installation.json')){
        [IO.File]::Copy((Join-Path $backup 'installation.json'),$installationPath,$true)
        Write-DeploymentJson (Join-Path $backup 'result.json') @{status='Failed';error=$failure;completedLocal=(Get-Date).ToString('o')}
    }
    if($rollbackFailure){throw "Executor update failed: $failure. Restoring the prior task limit also failed: $rollbackFailure"}
    throw
}finally{for($i=$locks.Count-1;$i -ge 0;$i--){$locks[$i].Dispose()}}
