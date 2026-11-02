#requires -Version 7.5
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'Deployment.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'Release.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'CommonRelease.psm1') -DisableNameChecking

$script:HostAppRoot='C:\ProgramData\SolutionDeploy\apps'
$script:HostShareRoot='\\jimbrownhome1.local\c$\ProgramData\SolutionDeploy\apps'

function Invoke-ReleaseTool {
    param([Parameter(Mandatory)][string]$Name,[Parameter(Mandatory)][string[]]$Arguments,
        [Parameter(Mandatory)][string]$WorkingDirectory,[int]$TimeoutSeconds=600)
    $tool=(Get-Command $Name -CommandType Application|Select-Object -First 1).Source
    Invoke-DeploymentCommand $tool $Arguments $WorkingDirectory -TimeoutSeconds $TimeoutSeconds
}

function Copy-TrackedTree {
    param([Parameter(Mandatory)][string]$Worktree,[Parameter(Mandatory)][string[]]$Paths,[Parameter(Mandatory)][string]$Output)
    foreach($path in $Paths){
        $source=Join-Path $Worktree $path
        if(-not (Test-Path -LiteralPath $source)){throw "Build input missing from the commit: $path"}
        Copy-Item -LiteralPath $source -Destination (Join-Path $Output $path) -Recurse -Force
    }
}

# Build recipes reproduce each app's documented build from a clean worktree at the release commit.
$script:Builds=@{
    'web-bookmarks'={
        param($Worktree,$Output,$Timeout)
        & (Join-Path $Worktree 'deploy\Build-WebBookmarksRelease.ps1') -RepositoryRoot $Worktree -OutputDirectory $Output|Out-Null
    }
    'work-log'={
        param($Worktree,$Output,$Timeout)
        [IO.Directory]::CreateDirectory($Output)|Out-Null
        Copy-TrackedTree $Worktree @('api','src','deploy','README.md') $Output
        Invoke-ReleaseTool dotnet @('publish',(Join-Path $Worktree 'deploy\dependencies\WorkLog.Dependencies.csproj'),'-c','Release',
            '-o',(Join-Path $Output 'deploy\dependencies\published'),'--nologo') $Worktree $Timeout
    }
    'web-inventory'={
        param($Worktree,$Output,$Timeout)
        $client=Join-Path $Worktree 'client'
        Invoke-ReleaseTool npm.cmd @('ci','--no-audit','--no-fund') $client $Timeout
        Invoke-ReleaseTool npm.cmd @('run','build') $client $Timeout
        Invoke-ReleaseTool dotnet @('publish',(Join-Path $Worktree 'api'),'-c','Release','-r','win-x64','--self-contained','true',
            '-o',$Output,'--nologo') $Worktree $Timeout
        Copy-Item -LiteralPath (Join-Path $client 'dist') -Destination (Join-Path $Output 'wwwroot') -Recurse -Force
        Copy-TrackedTree $Worktree @('deploy') $Output
    }
    'plex'={
        param($Worktree,$Output,$Timeout)
        [IO.Directory]::CreateDirectory($Output)|Out-Null
        $paths=@(Get-ChildItem -LiteralPath $Worktree -Force|Where-Object Name -ne '.git'|ForEach-Object Name)
        Copy-TrackedTree $Worktree $paths $Output
    }
    'web-options'={
        param($Worktree,$Output,$Timeout)
        Invoke-ReleaseTool npm.cmd @('ci','--ignore-scripts','--no-audit','--no-fund') $Worktree $Timeout
        foreach($script in 'build:shared','build:backend','build:frontend:access'){
            Invoke-ReleaseTool npm.cmd @('run',$script) $Worktree $Timeout
        }
        [IO.Directory]::CreateDirectory($Output)|Out-Null
        $paths=@(Get-ChildItem -LiteralPath $Worktree -Force|Where-Object Name -notin '.git','node_modules'|ForEach-Object Name)
        Copy-TrackedTree $Worktree $paths $Output
        # Workspace links and dev tools are rebuilt on the host by npm ci --omit=dev.
        Get-ChildItem -LiteralPath $Output -Directory -Recurse -Force -Filter node_modules|Remove-Item -Recurse -Force
    }
    'web-portfolio'={
        param($Worktree,$Output,$Timeout)
        Invoke-ReleaseTool npm.cmd @('ci','--ignore-scripts','--no-audit','--no-fund') $Worktree $Timeout
        Invoke-ReleaseTool npm.cmd @('run','build:shared') $Worktree $Timeout
        $backend=Join-Path $Worktree 'backend'
        Invoke-ReleaseTool npm.cmd @('ci','--ignore-scripts','--no-audit','--no-fund') $backend $Timeout
        Invoke-ReleaseTool npm.cmd @('run','build') $backend $Timeout
        $frontend=Join-Path $Worktree 'frontend'
        Invoke-ReleaseTool npm.cmd @('ci','--ignore-scripts','--no-audit','--no-fund') $frontend $Timeout
        $env:VITE_AUTH_MODE='access'
        try{Invoke-ReleaseTool npm.cmd @('run','build') $frontend $Timeout}finally{Remove-Item Env:VITE_AUTH_MODE -ErrorAction SilentlyContinue}
        # Without access mode the bundle calls the API on :3001 and CSP blocks it.
        if(-not (Select-String -Path (Join-Path $frontend 'dist\assets\*.js') -Pattern '"access"==="access"' -SimpleMatch -List)){
            throw 'The frontend bundle was not built with VITE_AUTH_MODE=access.'
        }
        foreach($folder in 'backend','frontend','scripts'){[IO.Directory]::CreateDirectory((Join-Path $Output $folder))|Out-Null}
        Copy-TrackedTree $Worktree @('backend\dist','backend\package.json','backend\package-lock.json','backend\tsconfig.json',
            'backend\tsconfig.prod.json','frontend\dist','config','deploy','scripts\Run-TelegramPull.ps1','telegram_ingest') $Output
    }
}

function Get-NormalizedFileDigest {
    param([Parameter(Mandatory)][string]$Path)
    Get-Sha256Text ([IO.File]::ReadAllText($Path).Replace("`r`n","`n"))
}

function Assert-HandPlacedDatabaseInputs {
    param([Parameter(Mandatory)][string]$Built,[Parameter(Mandatory)][string]$Installed,[hashtable]$Applied=@{})
    $find={param($root)
        if(-not (Test-Path -LiteralPath $root)){return @()}
        @(Get-ChildItem -LiteralPath $root -File -Recurse -Filter '*.sql' -Force|
            Where-Object {$_.FullName -notmatch '\\node_modules\\'}|
            ForEach-Object {[IO.Path]::GetRelativePath($root,$_.FullName)})}
    foreach($path in @(@(& $find $Built)+@(& $find $Installed)|Sort-Object -Unique)){
        $next=Join-Path $Built $path
        $old=Join-Path $Installed $path
        # A file verified as already applied to the live database passes at exactly its recorded digest.
        $key=$path.Replace('\','/')
        if($Applied.ContainsKey($key) -and (Test-Path -LiteralPath $next) -and (Get-NormalizedFileDigest $next) -eq $Applied[$key]){continue}
        if(-not (Test-Path -LiteralPath $next) -or -not (Test-Path -LiteralPath $old) -or
            (Get-NormalizedFileDigest $next) -ne (Get-NormalizedFileDigest $old)){
            throw "Database input changed: $path. Routine releases never run migrations; use a separately reviewed procedure."
        }
    }
}

function Invoke-ReleaseHostPhase {
    param([Parameter(Mandatory)]$Session,[Parameter(Mandatory)][string]$Label,[Parameter(Mandatory)][string]$Operation,
        [Parameter(Mandatory)][string]$RemoteOperation,[Parameter(Mandatory)][string]$RequestSHA256,
        [Parameter(Mandatory)][ValidateSet('Prepare','Activate')][string]$Phase,[int]$TimeoutSeconds=300,
        [string]$ProgressPath)
    $powerShell='C:\ProgramData\SolutionDeploy\runtime\powershell\7\pwsh.exe'
    $command='"'+$powerShell+'" -NoProfile -NonInteractive -WindowStyle Hidden -File "'+
        (Join-Path $RemoteOperation 'runner.ps1')+'" -RequestPath "'+
        (Join-Path $RemoteOperation 'request.json')+'" -RequestSHA256 '+$RequestSHA256+' -Phase '+$Phase
    $created=Invoke-CimMethod -CimSession $Session -ClassName Win32_Process -MethodName Create -Arguments @{CommandLine=$command}
    if($created.ReturnValue -ne 0){throw "Could not launch $Label $Phase (Windows result $($created.ReturnValue))."}
    $clock=[Diagnostics.Stopwatch]::StartNew()
    $path=Join-Path $Operation ($Phase.ToLowerInvariant()+'-result.json')
    while($clock.Elapsed.TotalSeconds -lt $TimeoutSeconds){
        if(Test-Path -LiteralPath $path){
            $result=Read-DeploymentJson $path
            if($result.requestSHA256 -ne $RequestSHA256 -or $result.phase -ne $Phase){throw "$Label host result does not match the request."}
            if($result.status -ne 'Succeeded'){throw "$Label $Phase failed: $($result.error) Inspect $path before recovery."}
            return $result
        }
        $progress=''
        if($ProgressPath -and (Test-Path -LiteralPath $ProgressPath)){
            try{$progress='; '+(Get-Content -LiteralPath $ProgressPath -Raw).Trim()}
            catch{$progress='; progress read failed: '+$_.Exception.Message}
        }
        Write-Host ("{0} {1}: elapsed {2:n0}s; host PID {3}{4}." -f $Label,$Phase,$clock.Elapsed.TotalSeconds,$created.ProcessId,$progress)
        Start-Sleep -Seconds 5
        $process=Get-CimInstance -CimSession $Session -ClassName Win32_Process -Filter "ProcessId=$($created.ProcessId)"
        if(-not $process -and -not (Test-Path -LiteralPath $path)){throw "$Label $Phase exited without a result. Outcome unknown; inspect $Operation."}
    }
    throw "$Label $Phase exceeded its deadline. Outcome unknown; inspect host PID $($created.ProcessId) and $Operation. Do not automatically retry or roll back."
}

function Get-SiteAccess {
    param([Parameter(Mandatory)][string]$App)
    $root=Split-Path -Parent $PSScriptRoot
    $site=@((Read-DeploymentJson (Join-Path $root 'site\sites.json')).sites|Where-Object {$_.id -eq $App})
    if($site.Count -ne 1){throw "No single access inventory entry for $App."}
    $private=[uri]$site[0].tailscaleUrl
    $public=[uri]$site[0].cloudflareUrl
    if($private.Scheme -ne 'https' -or $private.DnsSafeHost -notmatch '^jimbrownhome1\.[a-z0-9-]+\.ts\.net$' -or $private.IsDefaultPort){
        throw "Tailscale URL for $App must be the jimbrownhome1 HTTPS origin with its explicit port."
    }
    if($public.Scheme -ne 'https' -or $public.DnsSafeHost -notmatch '^[a-z0-9-]+\.jimlertech\.com$'){throw "Cloudflare URL for $App is not a single jimlertech.com hostname."}
    @{tailscale=[uri]('https://'+$private.Authority+'/');cloudflare=[uri]('https://'+$public.DnsSafeHost+'/')}
}

function Test-HandPlacedReadiness {
    param([Parameter(Mandatory)][hashtable]$Access,[Parameter(Mandatory)][hashtable]$Readiness,[int]$TimeoutSeconds=90)
    $uri=[uri]::new($Access.tailscale,[string]$Readiness.path)
    $clock=[Diagnostics.Stopwatch]::StartNew()
    $last='no response'
    $confirmed=$false
    do{
        try{
            $response=Invoke-ReleaseAccessRequest $uri
            $last="HTTP $($response.statusCode)"
            if($response.statusCode -eq 200){
                $ok=$true
                if($Readiness.ContainsKey('expected')){
                    $body=$null
                    try{$body=$response.body|ConvertFrom-Json -AsHashtable}catch{$body=$null}
                    if($body -isnot [hashtable]){$ok=$false;$last='HTTP 200 without the expected JSON object'}
                    else{
                        foreach($key in $Readiness.expected.Keys){
                            if(-not $body.ContainsKey($key) -or (ConvertTo-CanonicalJson $body[$key]) -cne (ConvertTo-CanonicalJson $Readiness.expected[$key])){
                                $ok=$false;$last="HTTP 200 but $key did not match"
                            }
                        }
                    }
                }
                if($ok){$confirmed=$true;break}
            }
        }catch{$last=$_.Exception.Message}
        Start-Sleep -Seconds 3
    }while($clock.Elapsed.TotalSeconds -lt $TimeoutSeconds)
    if(-not $confirmed){throw "Readiness at $uri was not confirmed within $TimeoutSeconds s (last result: $last)."}
    $response=Invoke-ReleaseAccessRequest $Access.cloudflare
    $location=$response['location']
    if($response.statusCode -notin @(302,303,307) -or -not $location -or -not $location.IsAbsoluteUri -or
        $location.Scheme -ne 'https' -or $location.DnsSafeHost -notmatch '\.cloudflareaccess\.com$' -or
        $location.AbsolutePath -notmatch '^/cdn-cgi/access/login/'){throw "Cloudflare did not return the Access login redirect for $($Access.cloudflare)."}
    @{tailscale=@{verified=$true;url=$uri.AbsoluteUri};cloudflare=@{verified=$true;url=$Access.cloudflare.AbsoluteUri};verifiedLocal=(Get-Date).ToString('o')}
}

function New-ReleaseWorktree {
    param([Parameter(Mandatory)][string]$Repository,[Parameter(Mandatory)][string]$Commit,[Parameter(Mandatory)][string]$Path)
    Invoke-ReleaseTool git @('worktree','add','--detach','--force',$Path,$Commit) $Repository
}

function Remove-ReleaseWorktree {
    param([Parameter(Mandatory)][string]$Repository,[Parameter(Mandatory)][string]$Path)
    if(Test-Path -LiteralPath $Path){
        try{Invoke-ReleaseTool git @('worktree','remove','--force',$Path) $Repository}catch{Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction SilentlyContinue}
    }
    Invoke-ReleaseTool git @('worktree','prune') $Repository
}

function Invoke-HandPlacedRelease {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$App,[Parameter(Mandatory)][hashtable]$Entry,[string[]]$Component,
        [string]$Environment='production',[string]$Target='jimbrownhome1',
        [string]$Commit='HEAD',[Parameter(Mandatory)][string]$Repository,[Parameter(Mandatory)][string]$ApprovalReason,
        [switch]$ApproveRelease,[switch]$DatabaseChangesReviewed,[string]$TailscaleUrl,
        [DateTimeOffset]$ExpiresLocal=([DateTimeOffset]::Now.AddMinutes(30)),
        [string]$OutputDirectory=(Join-Path (Split-Path -Parent $PSScriptRoot) '.local'),
        [int]$TimeoutSeconds=300)
    $startedLocal=(Get-Date).ToString('o')
    if(-not $script:Builds.ContainsKey($App)){throw "No build recipe for $App."}
    if($Component -and @($Component|Where-Object {$_ -ne 'web'}).Count){throw "$App supports only the web component in this procedure."}
    $commitId=Resolve-CommonReleaseSource $Repository $Commit
    $access=Get-SiteAccess $App
    $remote=Join-Path $script:HostShareRoot $App
    $appRoot=Join-Path $script:HostAppRoot $App
    [IO.Directory]::CreateDirectory((Join-Path $remote 'state'))|Out-Null
    $lock=Get-DeploymentLock (Join-Path $remote 'state\common-controller.lock')
    $session=$null
    $id=[guid]::NewGuid().ToString('N')
    $directory=Join-Path ([IO.Path]::GetFullPath($OutputDirectory)) ("releases\$App-$id")
    [IO.Directory]::CreateDirectory($directory)|Out-Null
    $receiptPath=Join-Path $directory 'release.json'
    $receipt=@{app=$App;sourceCommit=$commitId;status='Preparing';components=@{web='NotAttempted'};startedLocal=$startedLocal
        externalAcceptance='Pending';phases=@();reason=$ApprovalReason}
    $worktree=Join-Path ([IO.Path]::GetTempPath()) ("sd-$App-"+$id.Substring(0,8))
    try{
        $link=Get-Item -LiteralPath (Join-Path $remote 'current') -Force
        $legacyDirectory=$link.LinkType -ne 'Junction'
        if($legacyDirectory){
            if($Entry['legacyDirectory'] -ne $true){throw "$App current is not a release junction."}
            $previous=$null
            $installed=$link.FullName
        }else{
            $target=[string]$link.Target
            $prefix=Join-Path $appRoot 'releases\'
            if(-not $target.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)){throw "$App current points outside its releases folder: $target"}
            $previous=$target.Substring($prefix.Length)
            if($previous -notmatch '^[A-Za-z0-9._-]+$'){throw "Unexpected $App release id: $previous"}
            $installed=Join-Path $remote ('releases\'+$previous)
        }
        $baselinePath=Join-Path $remote 'state\common-release.json'
        if(Test-Path -LiteralPath $baselinePath){
            $baseline=Read-DeploymentJson $baselinePath
            if($baseline.releaseId -eq $previous -and $baseline.sourceCommit -eq $commitId){
                $receipt.initialAccess=Test-HandPlacedReadiness $access $Entry.readiness 10
                $receipt.status='NoChanges';$receipt.components.web='SourceUnchanged';$receipt.externalAcceptance='Verified'
                $receipt.completedLocal=(Get-Date).ToString('o')
                Write-DeploymentJson $receiptPath $receipt
                return $receipt
            }
        }
        $receipt.initialAccess=Test-HandPlacedReadiness $access $Entry.readiness 10
        Write-Host "${App}: building $($commitId.Substring(0,12)) in a clean worktree before downtime."
        New-ReleaseWorktree $Repository $commitId $worktree
        $built=Join-Path $directory 'build'
        & $script:Builds[$App] $worktree $built $TimeoutSeconds
        $applied=@{}
        if($Entry['appliedDatabaseInputs']){foreach($item in $Entry['appliedDatabaseInputs'].GetEnumerator()){$applied[$item.Key]=[string]$item.Value}}
        Assert-HandPlacedDatabaseInputs $built $installed $applied
        $payload=Join-Path $directory 'payload.zip'
        [IO.Compression.ZipFile]::CreateFromDirectory($built,$payload,[IO.Compression.CompressionLevel]::Optimal,$false)
        $receipt.components.web='Prepared'
        $releaseId=$commitId.Substring(0,12)+'-'+$id.Substring(0,8)
        $operation=Join-Path $remote ('state\routine\'+$id)
        $remoteOperation=Join-Path $appRoot ('state\routine\'+$id)
        [IO.Directory]::CreateDirectory($operation)|Out-Null
        Copy-Item -LiteralPath $payload -Destination (Join-Path $operation 'payload.zip')
        Copy-Item -LiteralPath (Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts\Invoke-HandPlacedRelease.ps1') -Destination (Join-Path $operation 'runner.ps1')
        $session=New-CimSession -ComputerName jimbrownhome1.local -SessionOption (New-CimSessionOption -Protocol Dcom) -OperationTimeoutSec 30
        $identity=(Get-CimInstance -CimSession $session -ClassName Win32_ComputerSystemProduct).UUID
        $request=@{id=$id;app=$App;sourceCommit=$commitId;releaseId=$releaseId;previousRelease=$previous;legacyDirectory=$legacyDirectory
            task=$Entry.task;originPort=[int]$Entry.originPort;stop=$Entry.stop;hostInstall=$Entry['hostInstall']
            hostInstallPath=$Entry['hostInstallPath'];carryForward=@($Entry['carryForward']|Where-Object {$_})
            hostIdentity=$identity;expiresLocal=$ExpiresLocal.ToString('o');reason=$ApprovalReason
            approvedBy=[Security.Principal.WindowsIdentity]::GetCurrent().Name
            payloadSHA256=(Get-FileHash -LiteralPath $payload).Hash.ToLowerInvariant()
            runnerSHA256=(Get-FileHash -LiteralPath (Join-Path $operation 'runner.ps1')).Hash.ToLowerInvariant()
            timeoutSeconds=$TimeoutSeconds}
        Write-DeploymentJson (Join-Path $operation 'request.json') $request -CreateNew
        $requestHash=(Get-FileHash -LiteralPath (Join-Path $operation 'request.json')).Hash.ToLowerInvariant()
        $receipt.operation=$remoteOperation;$receipt.requestSHA256=$requestHash;$receipt.releaseId=$releaseId;$receipt.previousRelease=$previous
        Write-DeploymentJson $receiptPath $receipt
        $receipt.phases+=@(Invoke-ReleaseHostPhase $session $App $operation $remoteOperation $requestHash Prepare $TimeoutSeconds)
        $receipt.phases+=@(Invoke-ReleaseHostPhase $session $App $operation $remoteOperation $requestHash Activate $TimeoutSeconds)
        $receipt.components.web='RuntimeStarted'
        Write-DeploymentJson $receiptPath $receipt
        $receipt.access=Test-HandPlacedReadiness $access $Entry.readiness 120
        Remove-Item -LiteralPath (Join-Path $operation 'payload.zip') -Force
        $receipt.components.web='Verified';$receipt.externalAcceptance='Verified';$receipt.status='Succeeded'
        $receipt.completedLocal=(Get-Date).ToString('o')
        Write-DeploymentJson $receiptPath $receipt
        $receipt
    }catch{
        $receipt.status='Failed';$receipt.error=$_.Exception.Message
        Write-DeploymentJson $receiptPath $receipt
        throw
    }finally{
        Remove-ReleaseWorktree $Repository $worktree
        $built=Join-Path $directory 'build'
        if(Test-Path -LiteralPath $built){Remove-Item -LiteralPath $built -Recurse -Force -ErrorAction SilentlyContinue}
        if($session){Remove-CimSession $session}
        $lock.Dispose()
    }
}

Export-ModuleMember -Function Assert-HandPlacedDatabaseInputs,Get-SiteAccess,Test-HandPlacedReadiness,Invoke-ReleaseHostPhase,Invoke-HandPlacedRelease,Get-NormalizedFileDigest,New-ReleaseWorktree,Remove-ReleaseWorktree
