$root=Split-Path -Parent $PSScriptRoot
$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'scripts\Install-PostgresBackup.ps1'),[ref]$tokens,[ref]$errors)
if($errors){throw 'Backup installer did not parse.'}
$definition=$ast.Find({param($node)
    $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'New-PostgresBackupTrigger'
},$true)
if(-not $definition){throw 'Backup trigger function is missing.'}
. ([scriptblock]::Create($definition.Extent.Text))

Describe 'PostgreSQL backup schedule' {
    It 'sets the next future 03:00 as a local daily boundary across daylight-saving changes' {
        $cases=@(
            @{now='2026-03-07T04:00:00';expected='2026-03-08T03:00:00'}
            @{now='2026-03-08T02:30:00';expected='2026-03-08T03:00:00'}
            @{now='2026-10-31T04:00:00';expected='2026-11-01T03:00:00'}
            @{now='2026-11-01T02:30:00';expected='2026-11-01T03:00:00'}
            @{now='2026-11-01T03:00:00';expected='2026-11-02T03:00:00'}
        )
        foreach($case in $cases){
            $now=[datetime]::ParseExact($case.now,"yyyy-MM-dd'T'HH:mm:ss",[Globalization.CultureInfo]::InvariantCulture)
            $trigger=New-PostgresBackupTrigger -Now $now
            $trigger.StartBoundary | Should Be $case.expected
            $trigger.DaysInterval | Should Be 1
        }
    }

    It 'uses a boundary without a fixed offset in both Pacific time seasons' {
        $zone=[TimeZoneInfo]::FindSystemTimeZoneById('Pacific Standard Time')
        foreach($case in @(
            @{now='2026-03-08T00:00:00';utc='2026-03-08T10:00:00Z'}
            @{now='2026-11-01T00:00:00';utc='2026-11-01T11:00:00Z'}
        )){
            $now=[datetime]::ParseExact($case.now,"yyyy-MM-dd'T'HH:mm:ss",[Globalization.CultureInfo]::InvariantCulture)
            $boundary=(New-PostgresBackupTrigger -Now $now).StartBoundary
            $boundary | Should Match '^\d{4}-\d{2}-\d{2}T03:00:00$'
            $wall=[datetime]::ParseExact($boundary,"yyyy-MM-dd'T'HH:mm:ss",[Globalization.CultureInfo]::InvariantCulture)
            [TimeZoneInfo]::ConvertTimeToUtc($wall,$zone).ToString("yyyy-MM-dd'T'HH:mm:ss'Z'") | Should Be $case.utc
        }
    }

    It 'uses the tested trigger when installing the backup task' {
        $calls=$ast.FindAll({param($node)
            $node -is [Management.Automation.Language.CommandAst] -and $node.GetCommandName() -eq 'New-PostgresBackupTrigger'
        },$true)
        @($calls).Count | Should Be 1
    }
}
