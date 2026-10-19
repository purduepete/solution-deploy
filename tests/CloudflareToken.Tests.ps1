$script:tokenScript=Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts\Set-CloudflareToken.ps1'
Describe 'Masked Cloudflare credential setup' {
    It 'previews without requesting a token or changing ACLs' {
        Mock Test-Path {$false}
        Mock Read-Host {throw 'Unexpected secret prompt'}
        & $script:tokenScript -WhatIf
        Assert-MockCalled Read-Host -Times 0 -Scope It
    }

    It 'refuses replacement unless explicitly requested' {
        Mock Read-Host {throw 'Unexpected secret prompt'}
        Mock Test-Path {$true}
        $thrown=$false
        try{& $script:tokenScript -WhatIf}catch{$thrown=$true}
        $thrown|Should Be $true
        Assert-MockCalled Read-Host -Times 0 -Scope It
    }
    It 'accepts explicit replacement for preview without requesting the secret' {
        Mock Read-Host {throw 'Unexpected secret prompt'}
        Mock Test-Path {$true}
        & $script:tokenScript -Replace -WhatIf
        Assert-MockCalled Read-Host -Times 0 -Scope It
    }
    It 'has no argument that could put the token in shell history' {
        $tokens=$null;$errors=$null
        $ast=[Management.Automation.Language.Parser]::ParseFile($script:tokenScript,[ref]$tokens,[ref]$errors)
        $errors.Count|Should Be 0
        @($ast.ParamBlock.Parameters|Where-Object {$_.Name.VariablePath.UserPath -match 'token|secret|password'}).Count|Should Be 0
    }
}

Describe 'Cloudflare credential storage on Windows' {
    It 'stores encrypted data with restricted access and preserves the token across DPAPI round-trip' {
        Mock Read-Host {ConvertTo-SecureString 'synthetic-token-not-a-credential' -AsPlainText -Force}
        $originalLocal=$env:LOCALAPPDATA
        $originalTerminal=$env:TERM_PROGRAM
        $decoded=$null
        try{
            $env:LOCALAPPDATA=$TestDrive
            $env:TERM_PROGRAM='synthetic-standalone-test'
            $result=& $script:tokenScript -Confirm:$false
            $result.CloudflareChangesPerformed|Should Be $false
            $content=Get-Content -LiteralPath $result.Path -Raw
            $content.Contains('synthetic-token-not-a-credential')|Should Be $false
            $decoded=Import-Clixml -LiteralPath $result.Path
            $decoded.GetType().FullName|Should Be 'System.Security.SecureString'
            $credential=[pscredential]::new('synthetic',$decoded)
            $credential.GetNetworkCredential().Password|Should Be 'synthetic-token-not-a-credential'
            $directoryAcl=Get-Acl -LiteralPath (Split-Path -Parent $result.Path)
            $directoryAcl.AreAccessRulesProtected|Should Be $true
            $expected=@([Security.Principal.WindowsIdentity]::GetCurrent().User.Value,'S-1-5-18','S-1-5-32-544')
            foreach($rule in $directoryAcl.Access){
                ($rule.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value -in $expected)|Should Be $true
            }
            $replacement=& $script:tokenScript -Replace -Confirm:$false
            $replacement.Status|Should Be 'Saved'
        }finally{
            if($decoded){$decoded.Dispose()}
            $env:LOCALAPPDATA=$originalLocal
            $env:TERM_PROGRAM=$originalTerminal
        }
    }
}
