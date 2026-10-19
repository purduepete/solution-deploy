#requires -Version 7.4
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Message,
    [string]$Title='PostgreSQL backup needs attention'
)
$ErrorActionPreference='Stop'
$keys=Import-Clixml -LiteralPath (Join-Path $PSScriptRoot 'backup-alert.credential.xml')
$response=Invoke-RestMethod -Method Post -Uri 'https://api.pushover.net/1/messages.json' -TimeoutSec 20 -Body @{
    token=ConvertFrom-SecureString $keys.token -AsPlainText
    user=ConvertFrom-SecureString $keys.user -AsPlainText
    title=$Title
    message=$Message.Substring(0,[Math]::Min(1024,$Message.Length))
    priority=1
}
if($response.status -ne 1){throw 'Pushover did not accept the backup alert.'}
