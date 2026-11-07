$root=Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $root 'src\Deployment.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $root 'src\PostgreSQL.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $root 'src\SshTransport.psm1') -DisableNameChecking
$script:credentialScript=Join-Path $root 'scripts\Set-PostgresPasswordFile.ps1'
$tokens=$null;$parseErrors=$null
$script:credentialAst=[Management.Automation.Language.Parser]::ParseFile($script:credentialScript,[ref]$tokens,[ref]$parseErrors)
if($parseErrors){throw 'Credential script did not parse.'}
$fieldFunction=$script:credentialAst.Find({param($node)
    $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'ConvertTo-PostgresPasswordField'
},$true)
. ([scriptblock]::Create($fieldFunction.Extent.Text))

Describe 'PostgreSQL secure password entry' {
    BeforeEach {
        Mock Import-Module {}
        Mock Read-DeploymentJson {
            @{schemaVersion=2;planHash='synthetic-hash';target=@{host='synthetic-app'}
              databaseTarget=@{host='jimbrownhome1';address='192.168.2.14';root='C:\ProgramData\SolutionDeploy'}}
        }
        Mock Get-PlanDigest {'synthetic-hash'}
        Mock Get-PostgresConnectionPolicy {@{DatabaseHost='jimbrownhome1';DatabaseHostIdentity='synthetic-db-host';Port=5432}}
        Mock Get-HostSnapshot {@{identity='synthetic-db-host'}}
        Mock Test-Path {$false}
        Mock Read-Host {throw 'Unexpected password prompt'}
    }
    It 'escapes both libpq special characters without changing other characters' {
        ConvertTo-PostgresPasswordField 'sample\:suffix'|Should Be 'sample\\\:suffix'
        ConvertTo-PostgresPasswordField ' sample $value '' " '|Should Be ' sample $value '' " '
    }
    It 'rejects record injection and NUL characters' {
        foreach($invalid in @("sample`rnext","sample`nnext",("sample"+[char]0+"next"))){
            $thrown=$false
            try {ConvertTo-PostgresPasswordField $invalid|Out-Null}catch{$thrown=$true}
            $thrown|Should Be $true
        }
    }
    It 'previews storage without prompting or creating files' {
        & $script:credentialScript -PlanPath 'C:\synthetic\plan.json' -WhatIf
        Assert-MockCalled Read-Host -Times 0 -Scope It
    }
    It 'rejects host identity drift before requesting a password' {
        Mock Get-HostSnapshot {@{identity='different-host'}}
        $thrown=$false
        try {& $script:credentialScript -PlanPath 'C:\synthetic\plan.json' -WhatIf}catch{$thrown=$true}
        $thrown|Should Be $true
        Assert-MockCalled Read-Host -Times 0 -Scope It
    }
    It 'refuses existing credentials without explicit replacement' {
        Mock Test-Path {$true}
        $thrown=$false
        try {& $script:credentialScript -PlanPath 'C:\synthetic\plan.json' -WhatIf}catch{$thrown=$true}
        $thrown|Should Be $true
        Assert-MockCalled Read-Host -Times 0 -Scope It
    }
    It 'rejects altered plans before requesting a password' {
        Mock Get-PlanDigest {'different-hash'}
        $thrown=$false
        try {& $script:credentialScript -PlanPath 'C:\synthetic\plan.json' -WhatIf}catch{$thrown=$true}
        $thrown|Should Be $true
        Assert-MockCalled Read-Host -Times 0 -Scope It
    }
    It 'has no password argument that could enter shell history' {
        @($script:credentialAst.ParamBlock.Parameters|Where-Object {$_.Name.VariablePath.UserPath -match 'password|secret'}).Count|Should Be 0
    }
}
