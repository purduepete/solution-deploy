$root=Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $root 'src\OperationSafety.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $root 'src\Deployment.psm1') -DisableNameChecking
function Assert-SafetyThrows([scriptblock]$Action){
    $thrown=$false
    try{& $Action | Out-Null}catch{$thrown=$true}
    $thrown | Should Be $true
}

Describe 'Durable operation-scoped deployment phases' {
    BeforeEach {
        $script:operation=Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $script:request=@{operationId='plan-one-deploy';plan=@{id='plan-one';planHash='hash-one';currentRelease=@{planHash='old-hash';releaseId='old-release'}}}
        Write-DeploymentJson (Join-Path $script:operation 'request.json') $script:request
        $script:appRoot=Join-Path $script:operation 'app'
        Mock Assert-PreviousReleaseRunning -ModuleName OperationSafety {@{Verified=$true;ListenerOwned=$true}}
    }
    It 'records false before mutation and binds the exact request bytes' {
        Write-OperationPhase $script:operation $script:request Preflight
        $phase=Read-DeploymentJson (Join-Path $script:operation 'phase.json')
        $phase.targetMayHaveWritten | Should Be $false
        $phase.requestSHA256 | Should Be (Get-FileHash (Join-Path $script:operation 'request.json')).Hash.ToLowerInvariant()
        (Assert-CleanOperationAbort $script:request.plan $script:operation $script:appRoot).Verified | Should Be $true
    }
    It 'never clears a possible-write marker on a later phase' {
        Write-OperationPhase $script:operation $script:request MayWrite
        Write-OperationPhase $script:operation $script:request Preflight
        (Read-DeploymentJson (Join-Path $script:operation 'phase.json')).targetMayHaveWritten | Should Be $true
        Assert-SafetyThrows {Assert-CleanOperationAbort $script:request.plan $script:operation $script:appRoot}
    }
    It 'does not interpret a missing phase as proof no writes occurred' {
        Assert-SafetyThrows {Assert-CleanOperationAbort $script:request.plan $script:operation $script:appRoot}
    }
    It 'rejects altered request contents' {
        Write-OperationPhase $script:operation $script:request Preflight
        $script:request.action='changed'
        Write-DeploymentJson (Join-Path $script:operation 'request.json') $script:request
        Assert-SafetyThrows {Assert-CleanOperationAbort $script:request.plan $script:operation $script:appRoot}
    }
    It 'does not mistake the prior successful operation write marker for this failure' {
        Write-OperationPhase $script:operation $script:request Preflight
        Write-DeploymentJson (Join-Path $script:appRoot 'state\authority.json') @{operationId='prior-plan';targetMayHaveWritten=$true}
        (Assert-CleanOperationAbort $script:request.plan $script:operation $script:appRoot).Verified | Should Be $true
    }
    It 'rejects a write marker from the current failed operation' {
        Write-OperationPhase $script:operation $script:request Preflight
        Write-DeploymentJson (Join-Path $script:appRoot 'state\authority.json') @{operationId='plan-one';targetMayHaveWritten=$true}
        Assert-SafetyThrows {Assert-CleanOperationAbort $script:request.plan $script:operation $script:appRoot}
    }
    It 'rejects an operation which entered maintenance even without a possible write' {
        Write-OperationPhase $script:operation $script:request Maintenance
        Assert-SafetyThrows {Assert-CleanOperationAbort $script:request.plan $script:operation $script:appRoot}
    }
    It 'rejects a previous runtime that cannot be verified' {
        Write-OperationPhase $script:operation $script:request Preflight
        Mock Assert-PreviousReleaseRunning -ModuleName OperationSafety {throw 'Identity mismatch'}
        Assert-SafetyThrows {Assert-CleanOperationAbort $script:request.plan $script:operation $script:appRoot}
    }
}

Describe 'Protected executor preflight ordering' {
    It 'exposes protected recovery through the existing CLI' {
        $command=Get-Command (Join-Path $root 'Deploy.ps1')
        $validation=$command.Parameters.Action.Attributes | Where-Object {$_ -is [Management.Automation.ValidateSetAttribute]}
        ('Recover' -in $validation.ValidValues) | Should Be $true
    }
    It 'checks activation evidence and startup task before maintenance or stopping production' {
        $source=Get-Content (Join-Path $root 'scripts\Invoke-HostExecutor.ps1') -Raw
        $gate=$source.IndexOf("if(`$request.action -eq 'Deploy'){")
        $database=$source.IndexOf('Assert-DatabaseActivationEvidence $plan $approval $appRoot -ReleasePath $releasePath',$gate)
        $task=$source.IndexOf('Assert-AppBootTask',$gate)
        $maintenance=$source.IndexOf('Write-OperationPhase $operation $request Maintenance',$gate)
        $stop=$source.IndexOf('Stop-ManagedApp',$gate)
        ($database -gt $gate -and $database -lt $maintenance) | Should Be $true
        ($task -gt $gate -and $task -lt $maintenance -and $maintenance -lt $stop) | Should Be $true
    }
    It 'durably records potential writes before starting the new release' {
        $source=Get-Content (Join-Path $root 'scripts\Invoke-HostExecutor.ps1') -Raw
        ($source.IndexOf('Write-OperationPhase $operation $request MayWrite') -lt $source.IndexOf('$verification=Start-ReviewedAppTask')) | Should Be $true
    }
}
