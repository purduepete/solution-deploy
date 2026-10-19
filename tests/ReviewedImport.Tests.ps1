Import-Module (Join-Path $PSScriptRoot '..\src\Deployment.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot '..\src\PostgreSQL.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot '..\src\Transfer.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot '..\src\Operations.psm1') -DisableNameChecking

Describe 'Reviewed production importer guards without any database connection or executable child' {
    BeforeEach {
        $script:base=Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $script:PlanPath=Join-Path $script:base 'plan.json'
        $script:ApprovalPath=Join-Path $script:base 'approval.json'
        $script:SourceDirectory=Join-Path $script:base 'source'
        $script:PassFile=Join-Path $script:base 'synthetic-pgpass.txt'
        $script:SourceVerificationPath=Join-Path $script:base 'continuity.json'
        $script:OperationDirectory=Join-Path $script:base 'operation'
        $script:TimeoutSeconds=180
        $script:Execute=$false
        $script:AppRoot=Join-Path $script:base 'apps\ferry-tracker'
        $script:wrapper=Join-Path $PSScriptRoot '..\scripts\Invoke-ReviewedNodeImport.ps1'
        $release=Join-Path $script:AppRoot 'releases\synthetic-release'
        [IO.Directory]::CreateDirectory((Join-Path $release 'deploy\postgresql'))|Out-Null
        [IO.Directory]::CreateDirectory((Join-Path $script:AppRoot 'state'))|Out-Null
        [IO.Directory]::CreateDirectory($script:SourceDirectory)|Out-Null
        [IO.File]::WriteAllText((Join-Path $release 'deploy\postgresql\import.mjs'),'Synthetic non-executable fixture.')
        $node=Join-Path $script:base 'not-an-executable.exe'
        [IO.File]::WriteAllText($node,'Synthetic non-executable fixture.')
        [IO.File]::WriteAllText($script:PassFile,'Synthetic invalid credential, never usable.')
        $script:fixturePlan=@{
            app='ferry-tracker';id='synthetic';transitionKind='LegacyConversion';releaseId='synthetic-release'
            target=@{root=$script:base;host=$env:COMPUTERNAME}
            databaseTarget=@{host=$env:COMPUTERNAME;port=5432};databaseHostSnapshot=@{identity='synthetic-identity'}
            manifest=@{launch=@{port=65500};database=@{name='ferry_tracker'}}
        }
        $script:fixturePlan.planHash=Get-PlanDigest $script:fixturePlan
        Write-DeploymentJson $script:PlanPath $script:fixturePlan
        Write-DeploymentJson (Join-Path $script:SourceDirectory 'transfer.json') @{files=@(@{kind='sqlite';sha256=('1'*64)})}
        Write-DeploymentJson $script:SourceVerificationPath @{kind='Synthetic mocked continuity'}
        $script:fixtureApproval=@{
            action='Import';planHash=$script:fixturePlan.planHash;hostIdentity='synthetic-identity';independentReview='Synthetic'
            expiresLocal=[DateTimeOffset]::Now.AddMinutes(5).ToString('o');timeoutSeconds=180
            wrapperSHA256=(Get-FileHash $script:wrapper).Hash.ToLowerInvariant()
            nodePath=$node;nodeSHA256=(Get-FileHash $node).Hash.ToLowerInvariant()
            importerSHA256=(Get-FileHash (Join-Path $release 'deploy\postgresql\import.mjs')).Hash.ToLowerInvariant()
            sourceSHA256=('1'*64);preparedStateSHA256=('2'*64)
            transferSHA256=(Get-FileHash (Join-Path $script:SourceDirectory 'transfer.json')).Hash.ToLowerInvariant()
            sourceVerificationSHA256=(Get-FileHash $script:SourceVerificationPath).Hash.ToLowerInvariant()
        }
        Write-DeploymentJson $script:ApprovalPath $script:fixtureApproval
        $global:ReviewedImportFixtureReceipt=@{transferSHA256=$script:fixtureApproval.transferSHA256;sourceFenceSHA256=('3'*64)}
        $global:ReviewedImportFixtureRuntime=$node
        $global:ReviewedImportFixtureSecretChecks=0
        $tokens=$null;$errors=$null
        $ast=[Management.Automation.Language.Parser]::ParseFile($script:wrapper,[ref]$tokens,[ref]$errors)
        $text=($ast.EndBlock.Statements|ForEach-Object {$_.Extent.Text}) -join "`n"
        $text=$text.Replace('$PSCommandPath',("'"+$script:wrapper.Replace("'","''")+"'"))
        $text=$text.Replace('$PSScriptRoot',("'"+(Split-Path -Parent $script:wrapper).Replace("'","''")+"'"))
        $script:body=[scriptblock]::Create($text)
        Mock Get-CimInstance {@{UUID='synthetic-identity'}}
        Mock Assert-PreparedState {$global:ReviewedImportFixtureReceipt}
        Mock Assert-SourceContinuity {}
        Mock Get-NetTCPConnection {}
        Mock Test-ReleaseInventory {@{runtimePath=$global:ReviewedImportFixtureRuntime}}
        Mock Get-Acl {@{AreAccessRulesProtected=$true;Access=@([pscustomobject]@{AccessControlType='Allow';IdentityReference=[Security.Principal.SecurityIdentifier]::new('S-1-5-18')})}}
        Mock Assert-PostgresProtectedFile {$global:ReviewedImportFixtureSecretChecks++}
    }
    AfterEach {Get-Variable ReviewedImportFixture* -Scope Global|Remove-Variable -Scope Global}
    It 'defaults to validation only without a journal, app activation or process start' {
        $result=& $script:body
        $result.status|Should Be 'ValidatedOnly'
        $result.databaseOpened|Should Be $false
        $global:ReviewedImportFixtureSecretChecks|Should Be 1
        Test-Path $script:OperationDirectory|Should Be $false
        Test-Path (Join-Path $script:AppRoot 'state\database-import-attempt.json')|Should Be $false
    }
    It 'rejects expired approval and a changed deadline before protected-secret validation' {
        foreach($change in @('expiresLocal','timeoutSeconds')){
            $approval=@{}+$script:fixtureApproval
            if($change -eq 'expiresLocal'){$approval.expiresLocal=[DateTimeOffset]::Now.AddSeconds(-1).ToString('o')}else{$approval.timeoutSeconds=181}
            Write-DeploymentJson $script:ApprovalPath $approval
            {& $script:body}|Should Throw 'Import action, plan, host, review, expiry or deadline differs'
        }
        $global:ReviewedImportFixtureSecretChecks|Should Be 0
    }
    It 'rejects changed importer, source verification and transfer hashes' {
        foreach($field in @('importerSHA256','sourceVerificationSHA256','transferSHA256')){
            $approval=@{}+$script:fixtureApproval;$approval[$field]='0'*64
            Write-DeploymentJson $script:ApprovalPath $approval
            $caught=$null
            try{& $script:body|Out-Null}catch{$caught=$_}
            if(-not $caught){throw "Importer failed to reject changed $field."}
        }
        $global:ReviewedImportFixtureSecretChecks|Should Be 0
    }
    It 'rejects active state and an unexpected listener' {
        Write-DeploymentJson (Join-Path $script:AppRoot 'state\active.json') @{synthetic=$true}
        {& $script:body}|Should Throw 'Production importer refuses an activated app'
    }
    It 'rejects a listener even when active state is absent' {
        Mock Get-NetTCPConnection {@{LocalPort=65500}}
        {& $script:body}|Should Throw 'Import requires an absent application listener'
    }
    It 'rejects a broadly readable password file in validation-only mode' {
        Mock Assert-PostgresProtectedFile {throw 'Synthetic protected-secret rejection'}
        {& $script:body}|Should Throw 'Synthetic protected-secret rejection'
        Test-Path $script:OperationDirectory|Should Be $false
    }
    It 'never replays a durable database-import attempt' {
        $script:Execute=$true
        $attempt=Join-Path $script:AppRoot 'state\database-import-attempt.json'
        Write-DeploymentJson $attempt @{evidence='Preserve this prior attempt'}
        $caught=$null
        try{& $script:body|Out-Null}catch{$caught=$_}
        if(-not $caught){throw 'Importer failed to refuse the existing attempt.'}
        (Read-DeploymentJson $attempt).evidence|Should Be 'Preserve this prior attempt'
        (Read-DeploymentJson (Join-Path $script:OperationDirectory 'result.json')).status|Should Be 'FailedOrUnknown'
    }
    It 'records a failed attempt when the protected pgpass contents are invalid, before starting a child' {
        $script:Execute=$true
        {& $script:body}|Should Throw 'Expected one exact loopback migrator pgpass entry'
        (Read-DeploymentJson (Join-Path $script:OperationDirectory 'result.json')).status|Should Be 'FailedOrUnknown'
        Test-Path (Join-Path $script:AppRoot 'state\database-import-attempt.json')|Should Be $true
    }
}
