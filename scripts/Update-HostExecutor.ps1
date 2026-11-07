#requires -Version 7.4
<#
Upgrades the installed executor code on a provisioned host from this clean, committed repo.
Copies src, scripts and schemas through SSH/SFTP and rewrites the file inventory in
control\installation.json so the executor's code check matches the new bytes. The scheduled
task, ACLs and identity are left as Install-Host.ps1 created them.
#>
[CmdletBinding(SupportsShouldProcess,ConfirmImpact='High')]
param(
    [Parameter(Mandatory)][string]$HostName,
    [string]$Root='C:\ProgramData\SolutionDeploy'
)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'src\Deployment.psm1') -DisableNameChecking
Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'src\SshTransport.psm1') -DisableNameChecking
$source=Split-Path -Parent $PSScriptRoot
$git=(Get-Command git -CommandType Application).Source
if(& $git -C $source status --porcelain --untracked-files=normal -- src scripts schemas){throw 'Commit src, scripts and schemas before upgrading the executor.'}
$commit=(& $git -C $source rev-parse HEAD).Trim()
$remote=Get-DeploymentRemotePath $HostName $Root
$installPath=Join-Path $remote 'control\installation.json'
$install=Read-DeploymentJson $installPath
$files=@(Get-ChildItem -LiteralPath (Join-Path $source 'src'),(Join-Path $source 'scripts'),(Join-Path $source 'schemas') -File -Recurse |
    Where-Object Extension -in @('.ps1','.psm1','.py','.json') | Sort-Object FullName)
$inventory=@($files | ForEach-Object { @{path=[IO.Path]::GetRelativePath($source,$_.FullName);sha256=(Get-FileHash -LiteralPath $_.FullName).Hash.ToLowerInvariant()} })
$changed=@($inventory | Where-Object {
    $target=Join-Path $remote ('control\framework\'+$_.path)
    -not (Test-Path -LiteralPath $target) -or (Get-FileHash -LiteralPath $target).Hash.ToLowerInvariant() -ne $_.sha256
})
if(-not $changed.Count -and @($install.files).Count -eq $inventory.Count){Write-Host 'Executor code already matches this commit.';return}
$changed | ForEach-Object { Write-Host "update $($_.path)" }
if(-not $PSCmdlet.ShouldProcess("$HostName $Root","Upgrade executor code to $commit")){return}
if(Test-Path -LiteralPath (Join-Path $remote 'control\pending.json')){
    $pending=Read-DeploymentJson (Join-Path $remote 'control\pending.json')
    $result=Join-Path $remote ('operations\'+$pending.operationId+'\result.json')
    if(-not (Test-Path -LiteralPath $result)){throw "Operation $($pending.operationId) has no result yet. Upgrade after it finishes."}
}
$backup=Join-Path $remote ('archives\executor-upgrade-'+(Get-Date -Format 'yyyyMMdd-HHmmss'))
Invoke-DeploymentFileOperation CreateDirectory @($backup)|Out-Null
Copy-Item -LiteralPath $installPath -Destination $backup
foreach($file in $changed){
    $target=Join-Path $remote ('control\framework\'+$file.path)
    if(Test-Path -LiteralPath $target){
        $saved=Join-Path $backup $file.path
        Invoke-DeploymentFileOperation CreateDirectory @((Split-Path -Parent $saved))|Out-Null
        Copy-Item -LiteralPath $target -Destination $saved
    }
    Invoke-DeploymentFileOperation CreateDirectory @((Split-Path -Parent $target))|Out-Null
    Invoke-DeploymentFileOperation Copy @((Join-Path $source $file.path),$target,$true)
    if((Get-FileHash -LiteralPath $target).Hash.ToLowerInvariant() -ne $file.sha256){throw "Copied file differs: $($file.path)"}
}
$install.files=$inventory
$install.codeSHA256=Get-Sha256Text ($inventory | ConvertTo-Json -Depth 10 -Compress)
$install.commit=$commit
$install.upgradedLocal=(Get-Date).ToString('o')
Write-DeploymentJson $installPath $install
Write-Host "Executor upgraded to $commit ($($changed.Count) files). Backup: $backup"
