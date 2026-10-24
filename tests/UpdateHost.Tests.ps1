$root=Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $root 'src\Deployment.psm1') -DisableNameChecking

Describe 'Reviewed protected controller updates' {
    BeforeEach {
        $script:hostRoot=Join-Path $TestDrive 'host'
        $script:sourceRoot=Join-Path $TestDrive 'source'
        $body=(Get-Content (Join-Path $root 'scripts\Update-Host.ps1') -Raw) -replace '(?im)^#requires -RunAsAdministrator\r?\n',''
        $ast=[scriptblock]::Create($body).Ast
        $guard=$ast.Find({param($node) $node -is [Management.Automation.Language.IfStatementAst] -and $node.Extent.Text.Contains('Executor root must be')},$true)
        $body=$body.Replace($guard.Extent.Text,'')
        $body=$body.Replace('$source=Split-Path -Parent $PSScriptRoot',"`$source='$script:sourceRoot'")
        $body=$body.Replace("Join-Path `$source 'src\Deployment.psm1'","Join-Path '$root' 'src\Deployment.psm1'")
        $script:updateHost=[scriptblock]::Create($body)
        foreach($path in @('host\control\framework\src','source\src','source\scripts','source\schemas')){
            New-Item -ItemType Directory -Path (Join-Path $TestDrive $path) -Force | Out-Null
        }
        $addedTarget=Join-Path $script:hostRoot 'control\framework\src\b.psm1'
        if(Test-Path -LiteralPath $addedTarget){Remove-Item -LiteralPath $addedTarget}
        Set-Content (Join-Path $script:hostRoot 'control\framework\src\a.psm1') 'old'
        Set-Content (Join-Path $script:sourceRoot 'src\a.psm1') 'new'
        Set-Content (Join-Path $script:sourceRoot 'src\b.psm1') 'added'
        $script:oldInventory=@(@{path='src\a.psm1';sha256=(Get-FileHash (Join-Path $script:hostRoot 'control\framework\src\a.psm1')).Hash.ToLowerInvariant()})
        $script:oldDigest=Get-Sha256Text ($script:oldInventory | ConvertTo-Json -Depth 10 -Compress)
        $script:newInventory=@(
            @{path='src\a.psm1';sha256=(Get-FileHash (Join-Path $script:sourceRoot 'src\a.psm1')).Hash.ToLowerInvariant()}
            @{path='src\b.psm1';sha256=(Get-FileHash (Join-Path $script:sourceRoot 'src\b.psm1')).Hash.ToLowerInvariant()}
        )
        $script:newDigest=Get-Sha256Text (ConvertTo-CanonicalJson $script:newInventory)
        Write-DeploymentJson (Join-Path $script:hostRoot 'control\installation.json') @{
            identity='host-test';root=$script:hostRoot;codeSHA256=$script:oldDigest;files=$script:oldInventory
        }
        Mock Get-CimInstance {[pscustomobject]@{UUID='host-test'}}
    }
    It 'copies reviewed changes and additions with a verified new installation digest' {
        & $script:updateHost -Root $script:hostRoot -Confirm:$false -ApproveUpdate `
            -ExpectedHostIdentity host-test -ExpectedInstalledCodeSHA256 $script:oldDigest `
            -ExpectedCodeSHA256 $script:newDigest
        (Read-DeploymentJson (Join-Path $script:hostRoot 'control\installation.json')).codeSHA256 | Should Be $script:newDigest
        (Get-Content (Join-Path $script:hostRoot 'control\framework\src\a.psm1') -Raw).Trim() | Should Be new
        Test-Path (Join-Path $script:hostRoot 'control\framework\src\b.psm1') | Should Be $true
    }
    It 'rejects an unexpected old installation without copying code' {
        $rejected=$false
        try{
            & $script:updateHost -Root $script:hostRoot -Confirm:$false -ApproveUpdate `
                -ExpectedHostIdentity host-test -ExpectedInstalledCodeSHA256 ('0'*64) `
                -ExpectedCodeSHA256 $script:newDigest
        }catch{$rejected=$_.Exception.Message -eq 'Installed executor baseline changed.'}
        $rejected | Should Be $true
        (Get-Content (Join-Path $script:hostRoot 'control\framework\src\a.psm1') -Raw).Trim() | Should Be old
    }
    It 'restores changed files and preserves the installation on an interrupted copy' {
        $global:UpdateHostFailurePath=Join-Path $script:hostRoot 'control\framework\src\b.psm1'
        Mock Get-FileHash {throw 'Simulated copy verification failure'} -ParameterFilter {$LiteralPath -eq $global:UpdateHostFailurePath}
        $rejected=$false
        try{
            & $script:updateHost -Root $script:hostRoot -Confirm:$false -ApproveUpdate `
                -ExpectedHostIdentity host-test -ExpectedInstalledCodeSHA256 $script:oldDigest `
                -ExpectedCodeSHA256 $script:newDigest
        }catch{$rejected=$_.Exception.Message -eq 'Simulated copy verification failure'}
        $rejected | Should Be $true
        (Read-DeploymentJson (Join-Path $script:hostRoot 'control\installation.json')).codeSHA256 | Should Be $script:oldDigest
        (Get-Content (Join-Path $script:hostRoot 'control\framework\src\a.psm1') -Raw).Trim() | Should Be old
        Test-Path (Join-Path $script:hostRoot 'control\framework\src\b.psm1') | Should Be $false
    }
}
