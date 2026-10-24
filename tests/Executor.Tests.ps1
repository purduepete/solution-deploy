$root=Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $root 'src\Deployment.psm1') -Force -DisableNameChecking

Describe 'Immutable executor results' {
    BeforeEach {
        $tokens=$null;$errors=$null
        $ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'scripts\Invoke-HostExecutor.ps1'),[ref]$tokens,[ref]$errors)
        $catches=@($ast.FindAll({param($node) $node -is [Management.Automation.Language.CatchClauseAst]},$true))
        $body=($catches | Where-Object {$_.Body.Extent.Text.Contains('if ($request -and $resultPath')})[0].Body.Extent.Text
        $script:failureHandler=[scriptblock]::Create($body.Substring(1,$body.Length-2))
        $script:resultPath=Join-Path $TestDrive ([guid]::NewGuid().ToString('N')+'.json')
        $script:request=@{operationId='synthetic';plan=@{planHash='synthetic-hash'}}
    }
    It 'preserves an existing success when the executor rejects a repeat trigger' {
        Write-DeploymentJson $script:resultPath @{status='Succeeded';operationId='synthetic'}
        $before=(Get-FileHash $script:resultPath).Hash
        $rejected=$false
        try{throw 'Operation already has a result'}catch{
            try{& $script:failureHandler}catch{$rejected=$true}
        }
        $rejected|Should Be $true
        (Get-FileHash $script:resultPath).Hash|Should Be $before
        (Read-DeploymentJson $script:resultPath).status|Should Be Succeeded
    }
    It 'records a first failure without suppressing the original error' {
        $rejected=$false
        try{throw 'Synthetic first failure'}catch{
            try{& $script:failureHandler}catch{$rejected=$true}
        }
        $rejected|Should Be $true
        (Read-DeploymentJson $script:resultPath).status|Should Be Failed
    }
    It 'refuses an attempted overwrite with atomic create-new semantics' {
        Write-DeploymentJson $script:resultPath @{status='Succeeded'} -CreateNew
        $rejected=$false
        try{Write-DeploymentJson $script:resultPath @{status='Failed'} -CreateNew}catch [IO.IOException]{$rejected=$true}
        $rejected|Should Be $true
        (Read-DeploymentJson $script:resultPath).status|Should Be Succeeded
    }
}

Describe 'Executor transfer archive gate' {
    BeforeEach {
        $tokens=$null;$errors=$null
        $ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'scripts\Invoke-HostExecutor.ps1'),[ref]$tokens,[ref]$errors)
        $assign=$ast.Find({param($n) $n -is [Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -eq '$consumesTransfer'},$true)
        $gate=$ast.Find({param($n) $n -is [Management.Automation.Language.IfStatementAst] -and $n.Clauses[0].Item1.Extent.Text.StartsWith('$consumesTransfer')},$true)
        $script:gate=[scriptblock]::Create($assign.Extent.Text+"`n"+$gate.Extent.Text)
        $global:SyntheticExpandCalls=[Collections.Generic.List[object]]::new()
        function global:Expand-TransferArchive {param($ArchivePath,$Destination,$Transfer,$Archive) $global:SyntheticExpandCalls.Add(@($ArchivePath,$Destination,$Transfer,$Archive))}
        $script:operation='C:\synthetic\operations\op'
    }
    AfterEach {
        Remove-Item Function:\Expand-TransferArchive -ErrorAction SilentlyContinue
        Remove-Variable SyntheticExpandCalls -Scope Global -ErrorAction SilentlyContinue
    }
    function Invoke-Gate($request,$approval){$operation=$script:operation;& $script:gate}
    It 'extracts the copied archive into a new transfer directory before consumption' {
        Invoke-Gate @{action='PrepareCutover';transferSHA256=('a'*64);transferArchiveSHA256=('b'*64)} @{transferSHA256=('a'*64);transferArchiveSHA256=('b'*64)}
        $global:SyntheticExpandCalls.Count|Should Be 1
        ($global:SyntheticExpandCalls[0] -join '|')|Should Be ("C:\synthetic\operations\op\transfer.zip|C:\synthetic\operations\op\transfer|"+('a'*64)+'|'+('b'*64))
    }
    It 'keeps directory transport unchanged when neither side names an archive' {
        Invoke-Gate @{action='Cutover';transferSHA256=('a'*64)} @{transferSHA256=('a'*64)}
        $global:SyntheticExpandCalls.Count|Should Be 0
    }
    It 'does not extract for a prepared final Cutover' {
        Invoke-Gate @{action='Cutover';transferSHA256=('a'*64)} @{transferSHA256=('a'*64);transferArchiveSHA256=('b'*64);preparedStateSHA256=('c'*64)}
        $global:SyntheticExpandCalls.Count|Should Be 0
    }
    It 'rejects archive bindings that differ between request and approval' {
        $cases=@(
            @(@{action='PrepareCutover';transferSHA256=('a'*64)},@{transferSHA256=('a'*64);transferArchiveSHA256=('b'*64)}),
            @(@{action='PrepareCutover';transferSHA256=('a'*64);transferArchiveSHA256=('b'*64)},@{transferSHA256=('a'*64)}),
            @(@{action='Cutover';transferSHA256=('a'*64);transferArchiveSHA256=('d'*64)},@{transferSHA256=('a'*64);transferArchiveSHA256=('b'*64)}),
            @(@{action='Cutover';transferSHA256=('e'*64);transferArchiveSHA256=('b'*64)},@{transferSHA256=('a'*64);transferArchiveSHA256=('b'*64)})
        )
        foreach($case in $cases){
            $thrown=$false
            try{Invoke-Gate $case[0] $case[1]}catch{$thrown=$true}
            $thrown|Should Be $true
        }
        $global:SyntheticExpandCalls.Count|Should Be 0
    }
}