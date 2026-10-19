#requires -Version 7.4
#requires -RunAsAdministrator
[CmdletBinding()]
param(
    [string]$Directory='C:\ProgramData\JimlerTech\PostgreSQL',
    [Parameter(Mandatory)][string]$PendingCredential
)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$result=Join-Path $Directory 'backup-installation.json'
try {
    if($env:COMPUTERNAME -ine 'jimbrownhome1'){throw 'Install only on jimbrownhome1.'}
    if([Security.Principal.WindowsIdentity]::GetCurrent().User.Value -ne 'S-1-5-18'){throw 'Run installation as SYSTEM so its encrypted credentials belong to the nightly task.'}
    $acl=Get-Acl -LiteralPath $Directory
    if(-not $acl.AreAccessRulesProtected){throw 'The PostgreSQL configuration directory must have protected permissions.'}
    foreach($file in 'Backup-Postgres.ps1','Send-BackupAlert.ps1','postgres.pgpass'){
        if(-not (Test-Path -LiteralPath (Join-Path $Directory $file))){throw "Missing installed file: $file"}
    }
    $pending=Get-Content -LiteralPath $PendingCredential -Raw|ConvertFrom-Json
    $credential=[pscredential]::new($pending.user, (ConvertTo-SecureString $pending.password -AsPlainText -Force))
    $credential|Export-Clixml -LiteralPath (Join-Path $Directory 'backup-share.credential.xml')
    if(-not $pending.pushoverUser -or -not $pending.pushoverToken){throw 'Pushover credentials are required for failure notifications.'}
    @{
        user=ConvertTo-SecureString $pending.pushoverUser -AsPlainText -Force
        token=ConvertTo-SecureString $pending.pushoverToken -AsPlainText -Force
    }|Export-Clixml -LiteralPath (Join-Path $Directory 'backup-alert.credential.xml')
    [IO.Directory]::CreateDirectory((Join-Path $Directory 'backups'))|Out-Null
    $share=New-PSDrive -Name PgBackupInstall -PSProvider FileSystem -Root '\\jimbrownhome\Shared' -Credential $credential
    try {
        $probe='\\jimbrownhome\Shared\PostgreSQL\jimbrownhome1\installation-access-test.txt'
        [IO.File]::WriteAllText($probe,'Unattended backup access verified')
        Remove-Item -LiteralPath $probe
    } finally {Remove-PSDrive -Name $share.Name -Force}
    $action=New-ScheduledTaskAction -Execute (Join-Path $PSHOME 'pwsh.exe') -Argument ('-NoProfile -NonInteractive -File "'+(Join-Path $Directory 'Backup-Postgres.ps1')+'"')
    $trigger=New-ScheduledTaskTrigger -Daily -At '03:00'
    $principal=New-ScheduledTaskPrincipal -UserId SYSTEM -LogonType ServiceAccount -RunLevel Highest
    $settings=New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 45)
    Register-ScheduledTask -TaskPath '\JimlerTech\' -TaskName 'PostgreSQL-Backup' -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Description 'Nightly PostgreSQL dumps, snapshot-matched restore tests, verified off-host copies and 14-day retention.' -Force|Out-Null
    @{
        status='Installed';installedLocal=(Get-Date).ToString('o');timeZone=(Get-TimeZone).Id
        task='\JimlerTech\PostgreSQL-Backup';scheduleLocal='03:00 daily';retentionDays=14
        shareWriteVerified=$true;failureNotificationsConfigured=$true
        scriptSHA256=(Get-FileHash -LiteralPath (Join-Path $Directory 'Backup-Postgres.ps1')).Hash
    }|ConvertTo-Json|Set-Content -LiteralPath $result
} catch {
    @{status='Failed';error=$_.Exception.Message}|ConvertTo-Json|Set-Content -LiteralPath $result
    throw
} finally {
    if(Test-Path -LiteralPath $PendingCredential){Remove-Item -LiteralPath $PendingCredential -Force}
}
