#requires -Version 7.5
#requires -RunAsAdministrator
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$RequestPath,
    [Parameter(Mandatory)][ValidatePattern('^[a-f0-9]{64}$')][string]$RequestSHA256,
    [Parameter(Mandatory)][ValidateSet('Prepare')][string]$Phase
)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$framework='C:\ProgramData\SolutionDeploy\control\framework'
Import-Module (Join-Path $framework 'src\Deployment.psm1') -DisableNameChecking
function Write-PinnedJobProgress {
    param([string]$Directory,[int]$Sequence,[string]$Message)
    $name=$Sequence.ToString('D8')
    $pending=Join-Path $Directory ($name+'.pending')
    [IO.File]::WriteAllText($pending,$Message)
    [IO.File]::Move($pending,(Join-Path $Directory ($name+'.txt')))
}
$operation=Split-Path -Parent $RequestPath
if($operation -notmatch '^C:\\ProgramData\\SolutionDeploy\\control\\collector-access\\release-[a-f0-9]{32}$' -or
    $RequestPath -ine (Join-Path $operation 'request.json')){throw 'Unexpected collector preflight request location.'}
$result=@{phase=$Phase;requestSHA256=$RequestSHA256;status='Failed'}
try{
    if((Get-FileHash -LiteralPath $RequestPath).Hash.ToLowerInvariant() -ne $RequestSHA256){throw 'Collector preflight request changed.'}
    $request=Read-DeploymentJson $RequestPath
    if((Get-FileHash -LiteralPath $PSCommandPath).Hash.ToLowerInvariant() -ne $request.runnerSHA256){throw 'Collector preflight runner changed.'}
    if($env:COMPUTERNAME -ine 'jimbrownhome1' -or $request.app -notin @('web-options','web-portfolio')){throw 'Unexpected collector destination.'}
    $root="C:\ProgramData\SolutionDeploy\apps\$($request.app)"
    $release=[IO.Path]::GetFullPath($request.releasePath)
    $python=[IO.Path]::GetFullPath($request.pythonPath)
    $configPath=[IO.Path]::GetFullPath($request.configPath)
    if(-not $release.StartsWith("$root\releases\",[StringComparison]::OrdinalIgnoreCase) -or
        -not $python.StartsWith("$root\runtime\",[StringComparison]::OrdinalIgnoreCase) -or
        -not $configPath.StartsWith("$root\shared\",[StringComparison]::OrdinalIgnoreCase)){
        throw 'Collector preflight paths are outside the app.'
    }
    $helper=Join-Path $framework 'scripts\Test-CollectorAccess.ps1'
    $module=Join-Path $operation 'CollectorAccess.psm1'
    if((Get-FileHash -LiteralPath $helper).Hash.ToLowerInvariant() -ne $request.helperSHA256 -or
        (Get-FileHash -LiteralPath $module).Hash.ToLowerInvariant() -ne $request.moduleSHA256){
        throw 'Collector access helper differs from the release tooling.'
    }
    $config=Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
    $directories=@((Join-Path $root 'shared\logs'))
    $state=$config.PSObject.Properties['notification_state_file']
    if($state -and $state.Value){$directories+=Split-Path -Parent $state.Value}
    $progressDirectory=Join-Path $operation 'progress'
    [IO.Directory]::CreateDirectory($progressDirectory)|Out-Null
    $progressIndex=0
    $access=& $helper -ReleasePath $release -PythonPath $python -ConfigPath $configPath `
        -CollectorAccessModulePath $module -WritableDirectories @($directories|Sort-Object -Unique) `
        -TimeoutSeconds $request.timeoutSeconds 6>&1 | ForEach-Object {
            if($_ -is [System.Management.Automation.InformationRecord]){
                $progressIndex++
                Write-PinnedJobProgress $progressDirectory $progressIndex ([string]$_.MessageData)
            }else{$_}
        }
    if(-not $access.Success -or $access.Sid -ne 'S-1-5-19'){throw 'Collector access preflight did not verify LOCAL SERVICE.'}
    $result.status='Succeeded';$result.sid=$access.Sid;$result.aclSnapshot=$access.AclSnapshot
}catch{
    $result.error=$_.Exception.Message
}
Write-DeploymentJson (Join-Path $operation 'prepare-result.json') $result
if($result.status -ne 'Succeeded'){exit 1}
