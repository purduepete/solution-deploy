[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('web-portfolio','web-options')][string]$Application
)
$ErrorActionPreference='Stop'
$root="C:\ProgramData\SolutionDeploy\apps\$Application"
$release="$root\releases\20261018"
$log="$root\shared\logs\service.log"
$launcher=if($Application -eq 'web-portfolio'){"$release\deploy\Start-PortfolioService.ps1"}else{"$release\scripts\Start-Deployment.ps1"}
try{
    "[$(Get-Date -Format o)] Starting $Application"|Add-Content $log
    & $launcher -ReleasePath $release -SettingsPath "$root\shared\secrets\settings.json" -NodePath 'C:\Files\ScoopApps\apps\nodejs\current\node.exe' *>> $log
    if(-not $? -or $LASTEXITCODE){throw "Application exited unsuccessfully ($LASTEXITCODE)"}
}catch{
    "[$(Get-Date -Format o)] Startup/runtime failure: $($_.Exception.Message)"|Add-Content $log
    exit 1
}
