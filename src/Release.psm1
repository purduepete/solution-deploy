#requires -Version 7.5
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'Deployment.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'Controller.psm1') -DisableNameChecking

function Get-ReleaseToolHash {
    param([hashtable]$Plan,[string]$Path)
    if($Path -notmatch '^[A-Za-z]:\\' -or $Path -match '(?i)\\current\\|\\shims\\'){throw 'Routine release tools require fixed absolute installation paths.'}
    $share='\\'+$Plan.target.host+'.local\'+$Path.Substring(0,1)+'$'+$Path.Substring(2)
    (Get-FileHash -LiteralPath $share -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Get-RoutineReleaseContext {
    param([hashtable]$Plan)
    if($Plan.transitionKind -ne 'ManagedDeploy' -or $Plan.operation -ne 'Deploy' -or
        -not $Plan.currentRelease -or $Plan.observedHost -ine $Plan.target.host){
        throw 'Release supports only an existing managed deployment on the same host.'
    }
    $remote=Get-AdminSharePath $Plan.target
    $installation=Read-DeploymentJson (Join-Path $remote 'control\installation.json')
    if($installation.identity -ne $Plan.hostSnapshot.identity -or $installation.root -ne $Plan.target.root){
        throw 'Installed executor identity/root differs from the plan.'
    }
    if('src\RoutineRelease.psm1' -notin @($installation.files.path)){
        throw 'Installed executor does not support routine releases. Apply the reviewed host update first.'
    }
    foreach($file in $installation.files){
        $path=Resolve-OwnedPath (Join-Path $remote 'control\framework') $file.path
        if((Get-FileHash -LiteralPath $path).Hash.ToLowerInvariant() -ne $file.sha256){throw 'Installed executor file differs from its protected inventory.'}
    }
    $appRoot=Join-Path $remote ('apps\'+$Plan.app)
    $active=Read-DeploymentJson (Join-Path $appRoot 'state\active.json')
    $verification=Read-DeploymentJson (Join-Path $appRoot 'state\verification.json')
    if($active.planHash -ne $Plan.currentRelease.planHash -or $active.releaseId -ne $Plan.currentRelease.releaseId -or
        $verification.planHash -ne $active.planHash -or $verification.releaseId -ne $active.releaseId -or
        $verification.status -ne 'RuntimeVerified' -or $verification.readiness.ready -ne $true){
        throw 'Prior active release has no matching successful runtime verification.'
    }
    $releasePath=Resolve-OwnedPath $appRoot ('releases\'+$active.releaseId)
    $release=Read-DeploymentJson (Join-Path $releasePath 'release.json')
    if($release.planHash -ne $active.planHash -or $release.releaseId -ne $active.releaseId -or
        $release.sourceCommit -ne $Plan.currentRelease.sourceCommit){
        throw 'Prior protected release metadata belongs to another plan or commit.'
    }
    $matches=@(foreach($directory in Get-ChildItem -LiteralPath (Join-Path $remote 'operations') -Directory){
        $requestPath=Join-Path $directory.FullName 'request.json'
        $resultPath=Join-Path $directory.FullName 'result.json'
        if(-not (Test-Path -LiteralPath $requestPath) -or -not (Test-Path -LiteralPath $resultPath)){continue}
        $request=Read-DeploymentJson $requestPath
        if($request.plan.planHash -ne $active.planHash -or $request.action -notin @('Deploy','Cutover')){continue}
        $result=Read-DeploymentJson $resultPath
        if($result.status -eq 'Succeeded' -and $result.planHash -eq $active.planHash -and $result.operationId -eq $request.operationId){$request}
    })
    if($matches.Count -ne 1){throw 'A unique successful prior activation approval is required.'}
    $prior=$matches[0]
    if((ConvertTo-CanonicalJson $prior.plan.manifest) -cne (ConvertTo-CanonicalJson $Plan.manifest)){
        throw 'Application manifest changes require a separately reviewed deployment.'
    }
    foreach($gate in @('gracefulStopVerified','dataInventory','rollbackReady')){
        if(-not $prior.approval.gates.ContainsKey($gate) -or $prior.approval.gates[$gate] -ne $true){
            throw "Prior activation did not approve $gate."
        }
    }
    $fields=@{}
    foreach($key in @('psqlPath','psqlSHA256','postgresPassFile','postgresRuntimeRole','postgresEndpointSHA256',
        'postgresSslRootCert','postgresSslRootCertSHA256','migrationSqlSHA256')){
        if($prior.approval.ContainsKey($key)){$fields[$key]=$prior.approval[$key]}
    }
    foreach($key in @('psqlPath','psqlSHA256','postgresPassFile','postgresRuntimeRole','postgresEndpointSHA256','migrationSqlSHA256')){
        if(-not $fields.ContainsKey($key)){throw "Prior activation approval is missing $key."}
    }
    $fields.expectedSchemaFingerprint=$verification.database.schemaFingerprint
    if($fields.expectedSchemaFingerprint -notmatch '^[a-f0-9]{64}$'){throw 'Prior verified database schema fingerprint is missing.'}
    $runtimeHash=Get-ReleaseToolHash $Plan $release.runtimePath
    if($runtimeHash -ne $release.runtimeSHA256){throw 'Installed runtime differs from prior sealed bytes.'}
    if((Get-ReleaseToolHash $Plan $fields.psqlPath) -ne $fields.psqlSHA256){throw 'PostgreSQL verifier changed since activation.'}
    if($fields.ContainsKey('postgresSslRootCert') -and
        (Get-ReleaseToolHash $Plan $fields.postgresSslRootCert) -ne $fields.postgresSslRootCertSHA256){throw 'PostgreSQL certificate changed since activation.'}
    $npmPath=$null;$npmSHA256=$null;$npmCliSHA256=$null
    if(@($Plan.manifest.build.commands|Where-Object tool -eq 'npm').Count){
        $npmPath=Join-Path (Split-Path -Parent $release.runtimePath) 'npm.cmd'
        $npmSHA256=Get-ReleaseToolHash $Plan $npmPath
        $npmCliSHA256=Get-ReleaseToolHash $Plan (Join-Path (Split-Path -Parent $release.runtimePath) 'node_modules\npm\bin\npm-cli.js')
    }
    @{
        runtimePath=$release.runtimePath;runtimeSHA256=$runtimeHash;npmPath=$npmPath;npmSHA256=$npmSHA256
        npmCliSHA256=$npmCliSHA256;approvalFields=$fields
        installationSHA256=(Get-FileHash -LiteralPath (Join-Path $remote 'control\installation.json')).Hash.ToLowerInvariant()
        priorApprovalSHA256=(Get-Sha256Text (ConvertTo-CanonicalJson $prior.approval))
    }
}

function Invoke-ReleaseAccessRequest {
    param([uri]$Uri)
    $handler=[Net.Http.HttpClientHandler]::new()
    $handler.AllowAutoRedirect=$false
    $client=[Net.Http.HttpClient]::new($handler)
    $client.Timeout=[TimeSpan]::FromSeconds(20)
    try{
        $response=$client.GetAsync($Uri).GetAwaiter().GetResult()
        try{
            @{statusCode=[int]$response.StatusCode;location=$response.Headers.Location
                body=$response.Content.ReadAsStringAsync().GetAwaiter().GetResult()}
        }finally{$response.Dispose()}
    }finally{$client.Dispose();$handler.Dispose()}
}

function Test-ReleaseAccess {
    param([hashtable]$Plan,[Parameter(Mandatory)][string]$TailscaleUrl)
    $private=[uri]$TailscaleUrl
    if($private.Scheme -ne 'https' -or $private.DnsSafeHost -notmatch ('^'+[regex]::Escape($Plan.target.host)+'\.[a-z0-9-]+\.ts\.net$') -or
        $private.Port -ne [int]$Plan.manifest.launch.port -or $private.UserInfo -or
        $private.AbsolutePath -ne '/' -or $private.Query -or $private.Fragment){
        throw 'Tailscale URL must be the selected host HTTPS origin with the explicit reserved application port.'
    }
    $hosts=@($Plan.manifest.routes.hostname)
    if($hosts.Count -ne 1 -or $hosts[0] -notmatch '^[a-z0-9-]+\.jimlertech\.com$'){throw 'Routine release requires exactly one public hostname.'}
    $public=[uri]('https://'+$hosts[0]+'/')
    $response=Invoke-ReleaseAccessRequest ([uri]::new($private,[string]$Plan.manifest.readiness.path))
    if($response.statusCode -lt 200 -or $response.statusCode -ge 300){throw 'Tailscale readiness request failed.'}
    $body=$response.body|ConvertFrom-Json -AsHashtable
    if($body -isnot [hashtable]){throw 'Tailscale readiness response must be a JSON object.'}
    foreach($key in $Plan.manifest.readiness.expected.Keys){
        if(-not $body.ContainsKey($key) -or (ConvertTo-CanonicalJson $body[$key]) -cne
            (ConvertTo-CanonicalJson $Plan.manifest.readiness.expected[$key])){throw 'Tailscale readiness response did not match the manifest.'}
    }
    $response=Invoke-ReleaseAccessRequest $public
    $location=$response.location
    if($response.statusCode -notin @(302,303,307) -or -not $location -or -not $location.IsAbsoluteUri -or
        $location.Scheme -ne 'https' -or $location.DnsSafeHost -notmatch '\.cloudflareaccess\.com$' -or
        $location.AbsolutePath -notmatch '^/cdn-cgi/access/login/'){throw 'Cloudflare did not return the required Access login redirect.'}
    @{tailscale=@{verified=$true;url=$private.AbsoluteUri};cloudflare=@{verified=$true;url=$public.AbsoluteUri};verifiedLocal=(Get-Date).ToString('o')}
}

function Assert-ReleaseTools {
    param([hashtable]$Plan,[hashtable]$Context)
    if((Get-ReleaseToolHash $Plan $Context.runtimePath) -ne $Context.runtimeSHA256){throw 'Runtime changed after release consent.'}
    foreach($key in @('psqlPath','postgresSslRootCert')){
        if($Context.approvalFields.ContainsKey($key)){
            $hashKey=if($key -eq 'psqlPath'){'psqlSHA256'}else{'postgresSslRootCertSHA256'}
            if((Get-ReleaseToolHash $Plan $Context.approvalFields[$key]) -ne $Context.approvalFields[$hashKey]){throw 'Database verification tool or certificate changed after consent.'}
        }
    }
    if($Context.npmPath){
        if((Get-ReleaseToolHash $Plan $Context.npmPath) -ne $Context.npmSHA256 -or
            (Get-ReleaseToolHash $Plan (Join-Path (Split-Path -Parent $Context.runtimePath) 'node_modules\npm\bin\npm-cli.js')) -ne $Context.npmCliSHA256){throw 'npm changed after release consent.'}
    }
    $installation=Join-Path (Get-AdminSharePath $Plan.target) 'control\installation.json'
    if((Get-FileHash -LiteralPath $installation).Hash.ToLowerInvariant() -ne $Context.installationSHA256){throw 'Executor installation changed after release consent.'}
}

function Assert-ReleaseConsent {
    param([hashtable]$Plan,[string]$ConsentSHA256)
    if($Plan.planHash -ne (Get-PlanDigest $Plan) -or
        (Get-Sha256Text (ConvertTo-CanonicalJson $Plan.routineConsent)) -ne $ConsentSHA256 -or
        [DateTimeOffset]::Parse($Plan.routineConsent.expiresLocal) -le [DateTimeOffset]::Now){
        throw 'Release consent expired or its pinned inputs changed. A new explicit release approval is required.'
    }
    Assert-PlanInputs $Plan
}

function Assert-ReleaseClocks {
    param([hashtable]$Plan)
    foreach($hostName in @($Plan.target.host,$Plan.databaseTarget.host)|Sort-Object -Unique){
        $session=$null
        try{
            $session=New-CimSession -ComputerName ($hostName+'.local') -SessionOption (New-CimSessionOption -Protocol Dcom) -OperationTimeoutSec 20
            $clock=Get-CimInstance -CimSession $session -ClassName Win32_UTCTime -OperationTimeoutSec 20
            $remote=[DateTimeOffset]::new([int]$clock.Year,[int]$clock.Month,[int]$clock.Day,[int]$clock.Hour,[int]$clock.Minute,[int]$clock.Second,[TimeSpan]::Zero)
            if([Math]::Abs(([DateTimeOffset]::UtcNow-$remote).TotalSeconds) -gt 30){throw 'Controller and protected host clocks differ by more than 30 seconds.'}
        }finally{if($session){Remove-CimSession $session}}
    }
}

function Get-ReleasePhaseMedians {
    param([Parameter(Mandatory)][string]$ReleaseRoot,[Parameter(Mandatory)][string]$App,[int]$Count=5)
    $samples=@{}
    if(-not (Test-Path -LiteralPath $ReleaseRoot)){return @{}}
    $directories=@(Get-ChildItem -LiteralPath $ReleaseRoot -Directory | Sort-Object LastWriteTime -Descending)
    foreach($directory in $directories){
        try{
            $receiptPath=Join-Path $directory.FullName 'release.json'
            $planPath=Join-Path $directory.FullName 'plan.json'
            if(-not (Test-Path -LiteralPath $receiptPath) -or -not (Test-Path -LiteralPath $planPath)){continue}
            $receipt=Read-DeploymentJson $receiptPath
            if($receipt.status -ne 'Succeeded' -or (Read-DeploymentJson $planPath).app -ne $App){continue}
            foreach($phase in $receipt.phases){
                if(-not $samples.ContainsKey($phase.action)){$samples[$phase.action]=[Collections.Generic.List[double]]::new()}
                if($samples[$phase.action].Count -lt $Count){$samples[$phase.action].Add([double]$phase.elapsedSeconds)}
            }
        }catch{continue}
    }
    $medians=@{}
    foreach($action in $samples.Keys){
        $sorted=@($samples[$action]|Sort-Object)
        if($sorted.Count -lt 3){continue}
        $middle=[int][Math]::Floor($sorted.Count/2)
        $medians[$action]=if($sorted.Count % 2){$sorted[$middle]}else{($sorted[$middle-1]+$sorted[$middle])/2}
    }
    $medians
}

function Invoke-RoutineRelease {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$App,[string]$Environment='production',
        [Parameter(Mandatory)][string]$Target,[string]$Commit='HEAD',
        [switch]$ApproveRelease,[Parameter(Mandatory)][string]$ApprovalReason,[switch]$DatabaseChangesReviewed,
        [DateTimeOffset]$ExpiresLocal=([DateTimeOffset]::Now.AddMinutes(60)),[string]$TailscaleUrl,
        [string]$OutputDirectory=(Join-Path (Split-Path -Parent $PSScriptRoot) '.local'),
        [ValidateRange(60,1800)][int]$TimeoutSeconds=1800)
    if(-not $ApproveRelease -or -not $DatabaseChangesReviewed -or [string]::IsNullOrWhiteSpace($ApprovalReason)){
        throw 'Release requires -ApproveRelease, a non-empty -ApprovalReason and -DatabaseChangesReviewed.'
    }
    $now=[DateTimeOffset]::Now
    $releaseClock=[Diagnostics.Stopwatch]::StartNew()
    if($ExpiresLocal -le $now -or $ExpiresLocal -gt $now.AddHours(1)){throw 'Release consent must expire within 1 hour.'}
    Write-Host 'Release: preparing the exact deployment plan.'
    $plan=New-DeploymentPlan -App $App -Environment $Environment -Target $Target -Commit $Commit
    Write-Host 'Release: checking active metadata and pinned tools. Full release hashes are checked on the protected host before downtime.'
    $context=Get-RoutineReleaseContext $plan
    Assert-ReleaseClocks $plan
    $configuration=Get-DeploymentEnvironment $Environment
    $framework=Split-Path -Parent $PSScriptRoot
    $manifestPath=[IO.Path]::GetFullPath((Join-Path $framework $configuration.Value.apps[$App].manifest))
    $repository=Split-Path -Parent (Split-Path -Parent $manifestPath)
    $git=(Get-Command git -CommandType Application).Source
    Write-Host 'Release: checking the pushed source commit.'
    Invoke-DeploymentCommand $git @('-c','credential.interactive=false','fetch','--quiet','--prune','origin') $repository
    $dirty=Invoke-DeploymentCommand $git @('--no-optional-locks','-c','core.fsmonitor=false','status','--porcelain','--untracked-files=normal') $repository -Capture
    if($dirty){throw 'Release requires a clean committed source checkout.'}
    $branches=Invoke-DeploymentCommand $git @('for-each-ref',('--contains='+$plan.sourceCommit),'--format=%(refname)','refs/remotes/origin/') $repository -Capture
    if([string]::IsNullOrWhiteSpace($branches)){throw 'Release commit is not reachable from a fetched origin branch. Push the commit first.'}
    if(-not $TailscaleUrl){
        $origins=@(foreach($value in $plan.manifest.launch.environment.Values){
            foreach($part in ([string]$value -split ',')){if($part.Trim() -match '^https://[^/]+\.ts\.net:\d+/?$'){$part.Trim()}}
        })
        $origins=@($origins|Sort-Object -Unique)
        if($origins.Count -ne 1){throw 'Manifest does not identify one private HTTPS origin. Supply -TailscaleUrl.'}
        $TailscaleUrl=$origins[0]
    }
    $initialAccess=Test-ReleaseAccess $plan $TailscaleUrl
    $directory=Join-Path ([IO.Path]::GetFullPath($OutputDirectory)) ('releases\'+$plan.id)
    $phaseMedians=Get-ReleasePhaseMedians (Join-Path ([IO.Path]::GetFullPath($OutputDirectory)) 'releases') $App
    [IO.Directory]::CreateDirectory($directory)|Out-Null
    $archive=Join-Path $directory 'source.zip'
    try{
        Invoke-DeploymentCommand $git @('archive','--format=zip',('-o'+$archive),$plan.sourceCommit) $repository
        $archiveHash=(Get-FileHash -LiteralPath $archive).Hash.ToLowerInvariant()
    }finally{if(Test-Path -LiteralPath $archive){[IO.File]::Delete($archive)}}
    $plan.routineRelease=$true
    $plan.routineConsent=@{
        app=$App;environment=$Environment;target=$plan.target.host;sourceCommit=$plan.sourceCommit
        approvedBy=[Security.Principal.WindowsIdentity]::GetCurrent().Name;reason=$ApprovalReason.Trim()
        expiresLocal=$ExpiresLocal.ToString('o');actions=@('Stage','Preflight','Deploy','Verify','Recover')
        dataActionsReviewed=$true;sourceArchiveSHA256=$archiveHash;runtimeSHA256=$context.runtimeSHA256
        npmSHA256=$context.npmSHA256;npmCliSHA256=$context.npmCliSHA256
        runtimePath=$context.runtimePath;npmPath=$context.npmPath
        approvalInputsSHA256=(Get-Sha256Text (ConvertTo-CanonicalJson $context.approvalFields))
        installationSHA256=$context.installationSHA256;priorApprovalSHA256=$context.priorApprovalSHA256
        tailscaleUrl=$TailscaleUrl;initialAccessSHA256=(Get-Sha256Text (ConvertTo-CanonicalJson $initialAccess))
    }
    $plan.planHash=Get-PlanDigest $plan
    $consentHash=Get-Sha256Text (ConvertTo-CanonicalJson $plan.routineConsent)
    Write-DeploymentJson (Join-Path $directory 'plan.json') $plan -CreateNew
    $approval=@{}+$context.approvalFields
    $approval.planHash=$plan.planHash;$approval.hostIdentity=$plan.hostSnapshot.identity
    $approval.databaseHostIdentity=$plan.databaseHostSnapshot.identity;$approval.routeProfile=$plan.target.routeProfile
    $approval.actions=$plan.routineConsent.actions;$approval.approvedBy=$plan.routineConsent.approvedBy
    $approval.expiresLocal=$plan.routineConsent.expiresLocal;$approval.approvalReason=$ApprovalReason.Trim()
    $approval.consentSHA256=$consentHash;$approval.sourceArchiveSHA256=$archiveHash
    $approval.runtimeSHA256=$context.runtimeSHA256
    $approval.npmSHA256=$context.npmSHA256;$approval.npmCliSHA256=$context.npmCliSHA256
    $approval.gates=@{
        sourceCommitted=$true;artifactTrust=$true;hostProvisioning=$true;runtimeIdentity=$true
        routePreconditions=$true;clocksSynchronized=$true
    }
    $receipt=@{status='Running';planHash=$plan.planHash;consentSHA256=$consentHash;phases=@();externalAcceptance='Pending'
        sourceCommit=$plan.sourceCommit
        startedLocal=$now.ToLocalTime().ToString('o');preparationSeconds=[Math]::Round($releaseClock.Elapsed.TotalSeconds,2)}
    $receiptPath=Join-Path $directory 'release.json'
    try{
        foreach($action in @('Stage','Preflight','Deploy','Verify')){
            Write-Host ("Release: {0} started, elapsed {1:n0}s." -f $action,$releaseClock.Elapsed.TotalSeconds)
            Assert-ReleaseConsent $plan $consentHash
            Assert-ReleaseTools $plan $context
            Assert-ReleaseClocks $plan
            $approvalPath=Join-Path $directory ($action.ToLowerInvariant()+'-approval.json')
            Write-DeploymentJson $approvalPath $approval -CreateNew
            $phaseStarted=(Get-Date).ToString('o')
            $phaseClock=[Diagnostics.Stopwatch]::StartNew()
            $result=Submit-DeploymentOperation -Plan $plan -ApprovalPath $approvalPath -Action $action `
                -RuntimePath $context.runtimePath -NpmPath $context.npmPath -TimeoutSeconds $TimeoutSeconds
            if($result.status -ne 'Succeeded' -or $result.planHash -ne $plan.planHash){throw "$action returned no matching successful protected result."}
            $receipt.phases+=@{action=$action;result=$result;approvalSHA256=(Get-FileHash -LiteralPath $approvalPath).Hash.ToLowerInvariant()
                startedLocal=$phaseStarted;completedLocal=(Get-Date).ToString('o');elapsedSeconds=[Math]::Round($phaseClock.Elapsed.TotalSeconds,2)}
            Write-DeploymentJson $receiptPath $receipt
            if($phaseMedians.ContainsKey($action) -and $phaseClock.Elapsed.TotalSeconds -gt 2*$phaseMedians[$action]){
                Write-Warning ("Release: {0} took {1:n0}s, more than twice its recent median of {2:n0}s for {3}." -f $action,$phaseClock.Elapsed.TotalSeconds,$phaseMedians[$action],$App)
            }
            if($action -eq 'Preflight'){
                $proof=$result.verification
                if($proof.databaseEvidenceSHA256 -notmatch '^[a-f0-9]{64}$' -or [string]::IsNullOrWhiteSpace($proof.databaseEvidencePath)){
                    throw 'Preflight did not supply protected routine database evidence bindings.'
                }
                $approval.databaseEvidencePath=$proof.databaseEvidencePath
                $approval.databaseEvidenceSHA256=$proof.databaseEvidenceSHA256
                foreach($gate in @('gracefulStopVerified','dataInventory','rollbackReady','schemaCompatible','postgresStateValidated')){
                    $approval.gates[$gate]=$true
                }
            }
        }
        Assert-ReleaseConsent $plan $consentHash
        $receipt.access=Test-ReleaseAccess $plan $TailscaleUrl
        Assert-ReleaseConsent $plan $consentHash
        $receipt.externalAcceptance='Verified';$receipt.status='Succeeded'
        $receipt.completedLocal=(Get-Date).ToString('o')
        $receipt.elapsedSeconds=[Math]::Round($releaseClock.Elapsed.TotalSeconds,2)
        Write-DeploymentJson $receiptPath $receipt
        $receipt
    }catch{
        $receipt.status='Failed';$receipt.failedLocal=(Get-Date).ToString('o')
        $receipt.elapsedSeconds=[Math]::Round($releaseClock.Elapsed.TotalSeconds,2)
        $receipt.failure='Release incomplete. Inspect the protected operation results and authority before recovery; no automatic rollback was attempted.'
        Write-DeploymentJson $receiptPath $receipt
        throw
    }
}

Export-ModuleMember -Function Invoke-RoutineRelease,Get-RoutineReleaseContext,Test-ReleaseAccess,Assert-ReleaseConsent,Invoke-ReleaseAccessRequest
