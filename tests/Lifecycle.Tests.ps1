#Requires -Version 7.5
# Pester 3.4 tests for src\Lifecycle.psm1. Run with:
#   pwsh -NoProfile -Command "Import-Module Pester -RequiredVersion 3.4.0; Invoke-Pester .\tests\Lifecycle.Tests.ps1"
# Uses only toy node processes on loopback ports under .local\. No admin operations, no production apps.
# Toy processes exit through files they poll (stop request or test exit file) or after 120 s on their own.

$repo = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $repo 'src\Lifecycle.psm1') -Force
$node = (Get-Command node.exe -ErrorAction SilentlyContinue).Source

$toyServer = @"
const http = require('http');
const fs = require('fs');
const port = Number(process.argv[2]);
const mode = process.argv[3] || 'ok';
const stopFile = process.env.SOLUTIONDEPLOY_STOP_FILE;
const exitFile = process.env.TOY_EXIT_FILE;
const server = http.createServer((req, res) => {
  if (req.url !== '/health') { res.writeHead(404); res.end(); return; }
  if (mode === 'html') { res.writeHead(200, { 'content-type': 'text/html' }); res.end('<html><form>Sign in</form></html>'); return; }
  if (mode === 'redirect') { res.writeHead(302, { location: '/login' }); res.end(); return; }
  if (mode === 'textjson') { res.writeHead(200, { 'content-type': 'text/plain' }); res.end('{"status":"ok"}'); return; }
  res.writeHead(200, { 'content-type': 'application/json; charset=utf-8' });
  res.end(JSON.stringify({ status: mode === 'degraded' ? 'degraded' : 'ok', app: 'toy', checks: { db: true, count: 2 },
    secretSeen: process.env.TOY_SECRET === 'p@ss=word `$(whoami)', dataDir: process.env.TOY_DATA || null }));
});
if (exitFile && fs.existsSync(exitFile)) { process.exit(4); }
server.listen(port, '127.0.0.1');
setInterval(() => {
  if (exitFile && fs.existsSync(exitFile)) { process.exit(0); }
  if (stopFile && mode !== 'ignore-stop' && fs.existsSync(stopFile)) { server.close(() => process.exit(0)); setTimeout(() => process.exit(0), 500); }
}, 150);
setTimeout(() => process.exit(3), 120000);
"@

function Get-FreePort {
    $l = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
    $l.Start(); $p = $l.LocalEndpoint.Port; $l.Stop(); return $p
}

function New-TestAppRoot {
    param([string]$Name)
    $root = Join-Path $repo ".local\lifecycle-tests\$Name-$([guid]::NewGuid().ToString('N').Substring(0, 8))"
    foreach ($d in 'releases\r1', 'shared\data', 'shared\secrets', 'shared\logs', 'shared\backups', 'shared\run', 'state') {
        New-Item -ItemType Directory -Path (Join-Path $root $d) -Force | Out-Null
    }
    Set-Content -LiteralPath (Join-Path $root 'releases\r1\server.js') -Value $toyServer -Encoding utf8NoBOM
    Set-Content -LiteralPath (Join-Path $root 'shared\secrets\app.env') -Encoding utf8NoBOM -Value @(
        '# toy secrets', 'TOY_SECRET="p@ss=word $(whoami)"', '', 'TOY_OTHER=plain')
    return $root
}

function New-ToyManifest {
    param([int]$Port, [string]$Mode = 'ok', [switch]$NoStopSupport, [int]$ReadyTimeout = 15)
    $launch = @{
        entrypoint  = 'server.js'
        arguments   = @([string]$Port, $Mode)
        port        = $Port
        environment = @{ TOY_DATA = '{data}'; TOY_EXIT_FILE = '{run}\test-exit' }
        secretFile  = '{secrets}\app.env'
    }
    if (-not $NoStopSupport) { $launch.stopFileEnvironment = 'SOLUTIONDEPLOY_STOP_FILE' }
    return @{
        schemaVersion = 1; id = 'toy-app'; repository = 'https://github.com/purduepete/toy'
        runtime = @{ kind = 'node'; minimumVersion = '20' }
        build = @{ commands = @() }
        launch = $launch
        readiness = @{ path = '/health'; expected = @{ status = 'ok'; secretSeen = $true; checks = @{ db = $true; count = 2 } }; timeoutSeconds = $ReadyTimeout }
        state = @(); routes = @(); source = @{ host = 'test'; root = 'x'; tasks = @() }
    }
}

function Request-ToyExit {
    # Test-only cleanup: the toy polls this file and exits on its own.
    param([string]$Root, [int]$ProcessId)
    Set-Content -LiteralPath (Join-Path $Root 'shared\run\test-exit') -Value 'exit'
    if ($ProcessId) {
        $deadline = [Diagnostics.Stopwatch]::StartNew()
        while ((Get-Process -Id $ProcessId -ErrorAction SilentlyContinue) -and $deadline.Elapsed.TotalSeconds -lt 10) { Start-Sleep -Milliseconds 200 }
    }
    Remove-Item -LiteralPath (Join-Path $Root 'shared\run\test-exit') -Force -ErrorAction SilentlyContinue
}

function Start-DirectToy {
    # Starts a toy server owned by the test (not by the module) for readiness and port-conflict tests.
    param([string]$Root, [int]$Port, [string]$Mode)
    $env:TOY_EXIT_FILE = Join-Path $Root 'shared\run\test-exit'
    try {
        $p = Start-Process -FilePath $node -ArgumentList "server.js $Port $Mode" -WorkingDirectory (Join-Path $Root 'releases\r1') `
            -WindowStyle Hidden -PassThru -RedirectStandardOutput (Join-Path $Root "shared\logs\direct-$Port.out.log") -RedirectStandardError (Join-Path $Root "shared\logs\direct-$Port.err.log")
    }
    finally { Remove-Item env:TOY_EXIT_FILE -ErrorAction SilentlyContinue }
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($sw.Elapsed.TotalSeconds -lt 10) {
        try { $c = [System.Net.Sockets.TcpClient]::new(); $c.Connect('127.0.0.1', $Port); $c.Dispose(); break } catch { Start-Sleep -Milliseconds 100 }
    }
    return $p
}

function Assert-ToyHeadless {
    # Independent of the module helper: each app PID has MainWindowHandle 0 and every console host it owns runs
    # with the headless flag 0x4 and draws no visible window. Returns the console host PIDs it inspected.
    param([int[]]$ProcessIds, [switch]$RequireConsoleHost)
    $hosts = @()
    foreach ($id in $ProcessIds) {
        $p = Get-Process -Id $id -ErrorAction Stop
        [long]$p.MainWindowHandle | Should Be 0
        $p.SessionId | Should Be ([Diagnostics.Process]::GetCurrentProcess().SessionId)
        foreach ($c in @(Get-CimInstance Win32_Process -Filter "ParentProcessId=$id AND Name='conhost.exe'")) {
            $c.CommandLine | Should Match '(^|\s)0x4(\s|$)'
            [long](Get-Process -Id $c.ProcessId).MainWindowHandle | Should Be 0
            $hosts += [int]$c.ProcessId
        }
    }
    if ($RequireConsoleHost) { $hosts.Count | Should BeGreaterThan 0 }
    return $hosts
}

function Write-FakeOwner {
    param([string]$Root, [int]$ProcessId, [datetime]$CreationUtc, [string]$Runtime, [string]$Entry)
    [ordered]@{
        schemaVersion = 1; appId = 'toy-app'; pid = $ProcessId; creationTimeUtc = $CreationUtc.ToUniversalTime().ToString('o')
        executablePath = $Runtime; releasePath = (Join-Path $Root 'releases\r1'); entrypointPath = $Entry
    } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $Root 'shared\run\process.json') -Encoding utf8NoBOM
}

Describe 'Lifecycle module surface' {
    It 'exports the contract functions' {
        $names = (Get-Module Lifecycle).ExportedFunctions.Keys
        foreach ($n in 'Test-AppReadiness', 'Start-ManagedApp', 'Stop-ManagedApp', 'Invoke-AppWatchdog', 'Install-AppBootTask', 'Test-ManagedAppIdentity', 'Get-ReleaseRuntimePath', 'Assert-AppBootTask', 'Test-ManagedAppHeadless', 'Get-ManagedAppEnvironment', 'Initialize-AppTaskFolder') {
            $names -contains $n | Should Be $true
        }
    }
    It 'Install-AppBootTask refuses without -ApproveProvisioning before touching anything' {
        $cred = [pscredential]::new('nobody', (ConvertTo-SecureString 'x' -AsPlainText -Force))
        { Install-AppBootTask -AppId 'toy-app' -AppRoot 'C:\does-not-exist' -ReleasePath 'C:\does-not-exist\current' -ManifestPath 'C:\x.json' `
                -RuntimePath 'C:\node.exe' -PowerShellPath 'C:\pwsh.exe' -Credential $cred } | Should Throw 'ApproveProvisioning'
    }
    It 'Install-AppTask.ps1 refuses without -ApproveProvisioning' {
        $script = Join-Path $repo 'scripts\Install-AppTask.ps1'
        { & $script -AppId 'toy-app' -AppRoot 'C:\x' -ReleasePath 'C:\x\current' -ManifestPath 'C:\x\m.json' } | Should Throw 'ApproveProvisioning'
    }
    It 'the ACL plan gives backups create-only like data, secrets read-only, and run create-only on the directory itself' {
        InModuleScope Lifecycle {
            $layout = Get-AppLayout -AppRoot 'C:\x\app'
            $plan = New-AppAclPlan -Layout $layout -Account 'host\sd-toy'
            @($plan | Where-Object Path -eq $layout.Backups).Count | Should Be 2
            ($plan | Where-Object Path -eq $layout.Secrets).Rights | Should Be 'ReadAndExecute, Synchronize'
            ($plan | Where-Object { $_.Path -eq $layout.Run -and $_.Propagation -eq 'None' }).Rights | Should Not Match 'Modify|Delete'
            ($plan | Where-Object { $_.Path -eq $layout.Run -and $_.Propagation -eq 'InheritOnly' }).Rights | Should Match 'Modify'
            ($plan | Where-Object Path -eq $layout.Root).Protect | Should Be $true
            ($plan | Where-Object Path -eq $layout.State).Rights | Should Be 'ReadAndExecute, Synchronize'
        }
    }
    It 'builds task arguments that quote paths with spaces' {
        InModuleScope Lifecycle {
            $a = New-AppTaskArgument -ScriptPath 'C:\a b\w.ps1' -AppRoot 'C:\r' -ReleasePath 'C:\r\current' -ManifestPath 'C:\r\current\m.json' -RuntimePath 'C:\Program Files\nodejs\node.exe'
            $a | Should Match '-File "C:\\a b\\w\.ps1"'
            $a | Should Match '-RuntimePath "C:\\Program Files\\nodejs\\node\.exe"'
            $a | Should Match '-WindowStyle Hidden'
        }
    }
}

if (-not $node) {
    Describe 'Process tests' { It 'needs node.exe on PATH' { $node | Should Not BeNullOrEmpty } }
    return
}

Describe 'Input validation' {
    $root = New-TestAppRoot 'validate'
    $release = Join-Path $root 'releases\r1'
    $port = Get-FreePort
    try {
        It 'rejects an entrypoint that escapes the release' {
            $m = New-ToyManifest -Port $port; $m.launch.entrypoint = '..\..\server.js'
            { Start-ManagedApp -AppRoot $root -ReleasePath $release -Manifest $m -RuntimePath $node } | Should Throw "must not contain '..'"
        }
        It 'rejects unknown environment tokens' {
            $m = New-ToyManifest -Port $port; $m.launch.environment.BAD = '{home}\x'
            { Start-ManagedApp -AppRoot $root -ReleasePath $release -Manifest $m -RuntimePath $node } | Should Throw 'Unknown token {home}'
        }
        It 'rejects a secret file outside shared\secrets' {
            $m = New-ToyManifest -Port $port; $m.launch.secretFile = '{data}\app.env'
            { Start-ManagedApp -AppRoot $root -ReleasePath $release -Manifest $m -RuntimePath $node } | Should Throw 'secretFile must resolve under'
        }
        It 'rejects a release outside AppRoot\releases' {
            $m = New-ToyManifest -Port $port
            { Start-ManagedApp -AppRoot $root -ReleasePath (Join-Path $root 'shared\data') -Manifest $m -RuntimePath $node } | Should Throw 'direct child'
        }
        It 'rejects a python runtime outside the release virtual environment' {
            $m = New-ToyManifest -Port $port; $m.runtime.kind = 'python'
            { Start-ManagedApp -AppRoot $root -ReleasePath $release -Manifest $m -RuntimePath $node } | Should Throw 'virtual environment'
        }
        It 'rejects a relative runtime path' {
            $m = New-ToyManifest -Port $port
            { Start-ManagedApp -AppRoot $root -ReleasePath $release -Manifest $m -RuntimePath 'node.exe' } | Should Throw 'absolute path'
        }
        It 'rejects an empty readiness expectation' {
            { Test-AppReadiness -Port $port -Path '/health' -Expected @{} -TimeoutSeconds 1 } | Should Throw 'at least one key'
        }
        It 'refuses to write or remove run files outside shared\run' {
            & (Get-Module Lifecycle) {
                param($Root)
                { Write-RunFile -Path (Join-Path $Root 'state\maintenance.json') -RunDirectory (Join-Path $Root 'shared\run') -Content 'x' } | Should Throw 'outside shared\run'
                { Remove-RunFile -Path (Join-Path $Root 'shared\data\x') -RunDirectory (Join-Path $Root 'shared\run') } | Should Throw 'outside shared\run'
            } $root
        }
        It 'parses secret files literally without executing values' {
            & (Get-Module Lifecycle) {
                param($Root)
                $s = Read-AppSecretFile -Path (Join-Path $Root 'shared\secrets\app.env') -SecretsRoot (Join-Path $Root 'shared\secrets')
                $s['TOY_SECRET'] | Should BeExactly 'p@ss=word $(whoami)'
                $s['TOY_OTHER'] | Should Be 'plain'
            } $root
        }
        It 'treats a manifest outside the release and state as untrusted' {
            $bad = Join-Path $root 'shared\run\application.json'
            (New-ToyManifest -Port $port) | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $bad
            { Read-LifecycleManifest -Path $bad -AppRoot $root -ReleasePath $release } | Should Throw 'inside the release'
        }
    }
    finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
}

Describe 'Test-AppReadiness' {
    $root = New-TestAppRoot 'ready'
    $expected = @{ status = 'ok'; checks = @{ db = $true; count = 2 } }
    $ok = Get-FreePort; $html = Get-FreePort; $redirect = Get-FreePort; $text = Get-FreePort; $degraded = Get-FreePort
    $procs = @(
        Start-DirectToy -Root $root -Port $ok -Mode 'ok'
        Start-DirectToy -Root $root -Port $html -Mode 'html'
        Start-DirectToy -Root $root -Port $redirect -Mode 'redirect'
        Start-DirectToy -Root $root -Port $text -Mode 'textjson'
        Start-DirectToy -Root $root -Port $degraded -Mode 'degraded'
    )
    try {
        It 'passes on HTTP 200 JSON containing the expected values' {
            (Test-AppReadiness -Port $ok -Path '/health' -Expected $expected -TimeoutSeconds 5).Ready | Should Be $true
        }
        It 'never passes an HTML sign-in page' {
            $r = Test-AppReadiness -Port $html -Path '/health' -Expected $expected -TimeoutSeconds 2
            $r.Ready | Should Be $false
            $r.Reason | Should Match 'not JSON'
        }
        It 'does not follow redirects' {
            $r = Test-AppReadiness -Port $redirect -Path '/health' -Expected $expected -TimeoutSeconds 2
            $r.Ready | Should Be $false
            $r.Reason | Should Be 'HTTP 302'
        }
        It 'rejects JSON served with a non-JSON content type' {
            (Test-AppReadiness -Port $text -Path '/health' -Expected @{ status = 'ok' } -TimeoutSeconds 2).Ready | Should Be $false
        }
        It 'rejects a value mismatch, a type mismatch, and a missing key' {
            (Test-AppReadiness -Port $degraded -Path '/health' -Expected $expected -TimeoutSeconds 2).Reason | Should Be '$.status does not match'
            (Test-AppReadiness -Port $ok -Path '/health' -Expected @{ checks = @{ count = '2' } } -TimeoutSeconds 1).Ready | Should Be $false
            (Test-AppReadiness -Port $ok -Path '/health' -Expected @{ missing = 1 } -TimeoutSeconds 1).Reason | Should Be '$.missing is missing'
        }
        It 'returns not ready within the timeout when nothing listens' {
            $closed = Get-FreePort
            $sw = [Diagnostics.Stopwatch]::StartNew()
            $r = Test-AppReadiness -Port $closed -Path '/health' -Expected $expected -TimeoutSeconds 2
            $sw.Elapsed.TotalSeconds | Should BeLessThan 6
            $r.Ready | Should Be $false
        }
    }
    finally {
        Set-Content -LiteralPath (Join-Path $root 'shared\run\test-exit') -Value 'exit'
        foreach ($p in $procs) { if ($p) { [void]$p.WaitForExit(10000) } }
        Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Describe 'Start, watchdog, and file-based stop' {
    $root = New-TestAppRoot 'cycle'
    $release = Join-Path $root 'releases\r1'
    $port = Get-FreePort
    $manifest = New-ToyManifest -Port $port
    $script:startedPid = $null
    try {
        It 'starts the app, records PID and creation time, and waits for readiness' {
            $r = Start-ManagedApp -AppRoot $root -ReleasePath $release -Manifest $manifest -RuntimePath $node -TimeoutSeconds 20
            $r.Status | Should Be 'Started'
            $r.Ready | Should Be $true
            $script:startedPid = $r.Pid
            $owner = Get-Content -LiteralPath (Join-Path $root 'shared\run\process.json') -Raw | ConvertFrom-Json -AsHashtable -DateKind String
            $owner.pid | Should Be $r.Pid
            $owner.creationTimeUtc | Should Not BeNullOrEmpty
            $owner.entrypointPath | Should Be (Join-Path $release 'server.js')
        }
        It 'launches the node app without a window: no main window, headless console host, both logs' {
            [void](Assert-ToyHeadless -ProcessIds $script:startedPid -RequireConsoleHost)
            $h = Test-ManagedAppHeadless -AppRoot $root -ReleasePath $release -Manifest $manifest -RuntimePath $node
            $h.Result | Should Be 'Headless'
            $h.Headless | Should Be $true
            @($h.Problems).Count | Should Be 0
            $h.Pid | Should Be $script:startedPid
            Test-Path -LiteralPath $h.StdoutLog | Should Be $true
            Test-Path -LiteralPath $h.StderrLog | Should Be $true
        }
        It 'does not leave launch or secret variables in the calling environment' {
            $env:TOY_SECRET | Should BeNullOrEmpty
            $env:TOY_DATA | Should BeNullOrEmpty
            $env:SOLUTIONDEPLOY_STOP_FILE | Should BeNullOrEmpty
        }
        It 'never writes secret values into the ownership record or logs' {
            $text = (Get-ChildItem -LiteralPath (Join-Path $root 'shared') -Recurse -File | Where-Object { $_.DirectoryName -notlike '*secrets' } |
                    ForEach-Object { Get-Content -LiteralPath $_.FullName -Raw }) -join "`n"
            $text | Should Not Match ([regex]::Escape('p@ss=word'))
        }
        It 'passes the expanded {data} token and the stop file path to the app' {
            $r = Test-AppReadiness -Port $port -Path '/health' -Expected @{ dataDir = (Join-Path $root 'shared\data') } -TimeoutSeconds 3
            $r.Ready | Should Be $true
        }
        It 'reports AlreadyRunning instead of launching a second copy' {
            (Start-ManagedApp -AppRoot $root -ReleasePath $release -Manifest $manifest -RuntimePath $node -TimeoutSeconds 10).Status | Should Be 'AlreadyRunning'
        }
        It 'watchdog reports Healthy for the verified process' {
            $w = Invoke-AppWatchdog -AppRoot $root -ReleasePath $release -Manifest $manifest -RuntimePath $node
            $w.Status | Should Be 'Healthy'
            $w.Pid | Should Be $script:startedPid
        }
        It 'watchdog skips while another lifecycle action holds the lock' {
            $lock = [System.IO.FileStream]::new((Join-Path $root 'shared\run\lifecycle.lock'), 'OpenOrCreate', 'ReadWrite', 'None')
            try { (Invoke-AppWatchdog -AppRoot $root -ReleasePath $release -Manifest $manifest -RuntimePath $node).Reason | Should Match 'lock' }
            finally { $lock.Dispose() }
        }
        It 'stops through the stop request file, sets maintenance, and clears the record' {
            $s = Stop-ManagedApp -AppRoot $root -ReleasePath $release -Manifest $manifest -RuntimePath $node -TimeoutSeconds 15
            $s.Status | Should Be 'Stopped'
            Get-Process -Id $script:startedPid -ErrorAction SilentlyContinue | Should BeNullOrEmpty
            Test-Path (Join-Path $root 'shared\run\process.json') | Should Be $false
            Test-Path (Join-Path $root 'shared\run\STOP') | Should Be $false
            (Get-AppMaintenance -AppRoot $root).Active | Should Be $true
        }
        It 'watchdog does not restart under the persisted maintenance flag' {
            $w = Invoke-AppWatchdog -AppRoot $root -ReleasePath $release -Manifest $manifest -RuntimePath $node
            $w.Status | Should Be 'Skipped'
            $w.Reason | Should Match 'maintenance'
            (Test-AppReadiness -Port $port -Path '/health' -Expected @{ status = 'ok' } -TimeoutSeconds 1).Ready | Should Be $false
        }
        It 'Start-ManagedApp refuses under maintenance' {
            { Start-ManagedApp -AppRoot $root -ReleasePath $release -Manifest $manifest -RuntimePath $node } | Should Throw 'maintenance'
        }
        It 'watchdog restarts the app once maintenance is cleared and removes a stale stop file first' {
            Clear-AppMaintenance -AppRoot $root
            Set-Content -LiteralPath (Join-Path $root 'shared\run\STOP') -Value 'stale'
            $w = Invoke-AppWatchdog -AppRoot $root -ReleasePath $release -Manifest $manifest -RuntimePath $node
            $w.Status | Should Be 'Started'
            $script:startedPid = $w.Pid
            Start-Sleep -Milliseconds 600
            (Invoke-AppWatchdog -AppRoot $root -ReleasePath $release -Manifest $manifest -RuntimePath $node).Status | Should Be 'Healthy'
        }
        It 'Stop-ManagedApp on a stopped app reports NotRunning' {
            (Stop-ManagedApp -AppRoot $root -ReleasePath $release -Manifest $manifest -RuntimePath $node -TimeoutSeconds 15).Status | Should Be 'Stopped'
            (Stop-ManagedApp -AppRoot $root -ReleasePath $release -Manifest $manifest -RuntimePath $node -TimeoutSeconds 5).Status | Should Be 'NotRunning'
        }
    }
    finally {
        Request-ToyExit -Root $root -ProcessId $script:startedPid
        Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Describe 'Ownership records are never trusted without process identity' {
    $root = New-TestAppRoot 'owner'
    $release = Join-Path $root 'releases\r1'
    $entry = Join-Path $release 'server.js'
    $port = Get-FreePort
    $manifest = New-ToyManifest -Port $port
    $self = Get-CimInstance Win32_Process -Filter "ProcessId=$PID"
    $script:startedPid = $null
    try {
        It 'treats a reused PID (creation time mismatch) as stale and starts a new process' {
            Write-FakeOwner -Root $root -ProcessId $PID -CreationUtc ([datetime]::UtcNow.AddDays(-3)) -Runtime $node -Entry $entry
            (Get-ManagedAppStatus -AppRoot $root -ReleasePath $release -Manifest $manifest -RuntimePath $node).Reason | Should Be 'pid-reused'
            $w = Invoke-AppWatchdog -AppRoot $root -ReleasePath $release -Manifest $manifest -RuntimePath $node
            $w.Status | Should Be 'Started'
            $w.Pid | Should Not Be $PID
            $script:startedPid = $w.Pid
            Get-Process -Id $PID | Should Not BeNullOrEmpty
            Stop-ManagedApp -AppRoot $root -ReleasePath $release -Manifest $manifest -RuntimePath $node -TimeoutSeconds 15 | Out-Null
            Clear-AppMaintenance -AppRoot $root
        }
        It 'treats a live process with the wrong executable as foreign and never stops it' {
            Write-FakeOwner -Root $root -ProcessId $PID -CreationUtc $self.CreationDate -Runtime $node -Entry $entry
            $st = Get-ManagedAppStatus -AppRoot $root -ReleasePath $release -Manifest $manifest -RuntimePath $node
            $st.Status | Should Be 'Foreign'
            $st.Reason | Should Be 'executable-mismatch'
            $s = Stop-ManagedApp -AppRoot $root -ReleasePath $release -Manifest $manifest -RuntimePath $node -TimeoutSeconds 3
            $s.Status | Should Be 'NotRunning'
            Test-Path (Join-Path $root 'shared\run\STOP') | Should Be $false
            Get-Process -Id $PID | Should Not BeNullOrEmpty
            Clear-AppMaintenance -AppRoot $root
        }
        It 'treats a record for another release as untrusted' {
            Write-FakeOwner -Root $root -ProcessId $PID -CreationUtc $self.CreationDate -Runtime $node -Entry (Join-Path $root 'releases\r0\server.js')
            (Get-ManagedAppStatus -AppRoot $root -ReleasePath $release -Manifest $manifest -RuntimePath $node).Status | Should Be 'Untrusted'
        }
        It 'treats a malformed record as untrusted' {
            Set-Content -LiteralPath (Join-Path $root 'shared\run\process.json') -Value '{"pid":"C:\\Windows"}'
            (Get-ManagedAppStatus -AppRoot $root -ReleasePath $release -Manifest $manifest -RuntimePath $node).Reason | Should Be 'record-bad-pid'
        }
        It 'refuses to start or stop when an unverified process holds the port' {
            $squatter = Start-DirectToy -Root $root -Port $port -Mode 'ok'
            try {
                { Start-ManagedApp -AppRoot $root -ReleasePath $release -Manifest $manifest -RuntimePath $node -TimeoutSeconds 5 } | Should Throw 'already in use'
                { Stop-ManagedApp -AppRoot $root -ReleasePath $release -Manifest $manifest -RuntimePath $node -TimeoutSeconds 3 } | Should Throw 'not verified'
                $squatter.HasExited | Should Be $false
                (Get-AppMaintenance -AppRoot $root).Active | Should Be $true
            }
            finally { Request-ToyExit -Root $root -ProcessId $squatter.Id; Clear-AppMaintenance -AppRoot $root }
        }
    }
    finally {
        Request-ToyExit -Root $root -ProcessId $script:startedPid
        Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Describe 'Fail-safe stop and start failures' {
    $root = New-TestAppRoot 'failsafe'
    $release = Join-Path $root 'releases\r1'
    try {
        It 'fails safe when the app has no stop support: nothing stopped, maintenance stays set' {
            $port = Get-FreePort
            $m = New-ToyManifest -Port $port -NoStopSupport
            $r = Start-ManagedApp -AppRoot $root -ReleasePath $release -Manifest $m -RuntimePath $node -TimeoutSeconds 20
            try {
                { Stop-ManagedApp -AppRoot $root -ReleasePath $release -Manifest $m -RuntimePath $node -TimeoutSeconds 3 } | Should Throw 'cannot be asked to stop'
                Get-Process -Id $r.Pid | Should Not BeNullOrEmpty
                (Get-AppMaintenance -AppRoot $root).Active | Should Be $true
                (Invoke-AppWatchdog -AppRoot $root -ReleasePath $release -Manifest $m -RuntimePath $node).Status | Should Be 'Skipped'
            }
            finally { Request-ToyExit -Root $root -ProcessId $r.Pid; Clear-AppMaintenance -AppRoot $root }
        }
        It 'times out without terminating an app that ignores the stop request' {
            $port = Get-FreePort
            $m = New-ToyManifest -Port $port -Mode 'ignore-stop'
            $r = Start-ManagedApp -AppRoot $root -ReleasePath $release -Manifest $m -RuntimePath $node -TimeoutSeconds 20
            try {
                $sw = [Diagnostics.Stopwatch]::StartNew()
                { Stop-ManagedApp -AppRoot $root -ReleasePath $release -Manifest $m -RuntimePath $node -TimeoutSeconds 2 } | Should Throw 'did not exit within 2 s'
                $sw.Elapsed.TotalSeconds | Should BeLessThan 10
                Get-Process -Id $r.Pid | Should Not BeNullOrEmpty
                Test-Path (Join-Path $root 'shared\run\STOP') | Should Be $true
                (Get-AppMaintenance -AppRoot $root).Active | Should Be $true
            }
            finally { Request-ToyExit -Root $root -ProcessId $r.Pid; Clear-AppMaintenance -AppRoot $root }
        }
        It 'fails within the bounded timeout when readiness serves a sign-in page, leaving the process for Stop-ManagedApp' {
            $port = Get-FreePort
            $m = New-ToyManifest -Port $port -Mode 'html'
            $sw = [Diagnostics.Stopwatch]::StartNew()
            { Start-ManagedApp -AppRoot $root -ReleasePath $release -Manifest $m -RuntimePath $node -TimeoutSeconds 4 } | Should Throw 'did not become ready within 4 s'
            $sw.Elapsed.TotalSeconds | Should BeLessThan 12
            $st = Get-ManagedAppStatus -AppRoot $root -ReleasePath $release -Manifest $m -RuntimePath $node
            $st.Status | Should Be 'Running'
            (Invoke-AppWatchdog -AppRoot $root -ReleasePath $release -Manifest $m -RuntimePath $node -HealthTimeoutSeconds 2).Status | Should Be 'Unhealthy'
            (Stop-ManagedApp -AppRoot $root -ReleasePath $release -Manifest $m -RuntimePath $node -TimeoutSeconds 10).Status | Should Be 'Stopped'
            Clear-AppMaintenance -AppRoot $root
        }
        It 'reports an app that exits before readiness' {
            $port = Get-FreePort
            $m = New-ToyManifest -Port $port
            Set-Content -LiteralPath (Join-Path $root 'shared\run\test-exit') -Value 'exit'
            try { { Start-ManagedApp -AppRoot $root -ReleasePath $release -Manifest $m -RuntimePath $node -TimeoutSeconds 10 } | Should Throw 'exited' }
            finally { Remove-Item -LiteralPath (Join-Path $root 'shared\run\test-exit') -Force -ErrorAction SilentlyContinue }
        }
    }
    finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
}

Describe 'Invoke-AppWatchdog.ps1 through AppRoot\current' {
    $root = New-TestAppRoot 'script'
    $release = Join-Path $root 'releases\r1'
    $current = Join-Path $root 'current'
    New-Item -ItemType Junction -Path $current -Target $release | Out-Null
    $port = Get-FreePort
    New-Item -ItemType Directory -Path (Join-Path $release 'deploy') | Out-Null
    $manifestPath = Join-Path $release 'deploy\application.json'
    @{ schemaVersion = 1; runtimePath = $node; runtimeSHA256 = (Get-FileHash -LiteralPath $node).Hash.ToLowerInvariant() } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $release 'release.json') -Encoding utf8NoBOM
    (New-ToyManifest -Port $port) | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $manifestPath -Encoding utf8NoBOM
    $script = Join-Path $repo 'scripts\Invoke-AppWatchdog.ps1'
    $pwsh = Join-Path $PSHOME 'pwsh.exe'
    $script:startedPid = $null
    function Invoke-WatchdogScript {
        # Start-Process with file redirection: a captured pipe would be inherited by the app and block until it exits.
        param([string]$Manifest = (Join-Path $current 'deploy\application.json'), [switch]$NoRuntime)
        $outFile = Join-Path $root 'wd.out'
        $a = @('-NoProfile', '-NonInteractive', '-File', "`"$script`"", '-AppRoot', "`"$root`"", '-ReleasePath', "`"$current`"", '-ManifestPath', "`"$Manifest`"")
        if (-not $NoRuntime) { $a += @('-RuntimePath', "`"$node`"") }
        $p = Start-Process -FilePath $pwsh -ArgumentList $a -NoNewWindow -PassThru -RedirectStandardOutput $outFile -RedirectStandardError (Join-Path $root 'wd.err')
        if (-not $p.WaitForExit(60000)) { throw 'watchdog script did not exit within 60 s' }
        return @($p.ExitCode, @(Get-Content -LiteralPath $outFile))
    }
    try {
        It 'starts the app from a separate process and exits 0' {
            $code, $out = Invoke-WatchdogScript
            $code | Should Be 0
            $result = ($out | Select-Object -Last 1) | ConvertFrom-Json
            $result.Status | Should Be 'Started'
            $script:startedPid = $result.Pid
            $owner = Get-Content -LiteralPath (Join-Path $root 'shared\run\process.json') -Raw | ConvertFrom-Json
            $owner.releasePath | Should Be $release
            Test-Path (Join-Path $root 'shared\logs\watchdog.log') | Should Be $true
        }
        It 'the app the watchdog script launched has no window' {
            [void](Assert-ToyHeadless -ProcessIds $script:startedPid -RequireConsoleHost)
            $m = Read-LifecycleManifest -Path $manifestPath -AppRoot $root -ReleasePath $current
            (Test-ManagedAppHeadless -AppRoot $root -ReleasePath $current -Manifest $m -RuntimePath $node).Result | Should Be 'Headless'
        }
        It 'the launched app outlives the watchdog process and the next pass is Healthy' {
            Get-Process -Id $script:startedPid | Should Not BeNullOrEmpty
            $code, $out = Invoke-WatchdogScript -NoRuntime
            $code | Should Be 0
            (($out | Select-Object -Last 1) | ConvertFrom-Json).Status | Should Be 'Healthy'
        }
        It 'exits 1 for an invalid manifest location' {
            $bad = Join-Path $root 'shared\run\application.json'
            Copy-Item -LiteralPath $manifestPath -Destination $bad
            $code, $out = Invoke-WatchdogScript -Manifest $bad
            $code | Should Be 1
        }
        It 'stops through the current link' {
            $m = Read-LifecycleManifest -Path $manifestPath -AppRoot $root -ReleasePath $current
            (Stop-ManagedApp -AppRoot $root -ReleasePath $current -Manifest $m -RuntimePath $node -TimeoutSeconds 15).Status | Should Be 'Stopped'
        }
    }
    finally {
        Request-ToyExit -Root $root -ProcessId $script:startedPid
        if (Test-Path -LiteralPath $current) { [System.IO.Directory]::Delete($current) }
        Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
}


Describe 'Boot task definition and install preflight' {
    It 'task settings have no execution time limit and ignore overlapping runs' {
        $d = & (Get-Module Lifecycle) { New-AppTaskDefinition -PowerShellPath "$PSHOME\pwsh.exe" -Argument 'x' -WorkingDirectory 'C:\' -IntervalMinutes 5 }
        $d.Settings.ExecutionTimeLimit | Should Be 'PT0S'
        [string]$d.Settings.MultipleInstances | Should Be 'IgnoreNew'
    }
    It 'user-right decision: deny wins, missing grant fails, grant passes' {
        & (Get-Module Lifecycle) {
            (Test-UserRightDecision -TokenSids 'S-1-5-21-1-2-3-1001', 'S-1-5-32-545' -Granted 'S-1-5-32-545' -Denied 'S-1-5-21-1-2-3-1001').Reason | Should Be 'denied'
            (Test-UserRightDecision -TokenSids 'S-1-5-21-1-2-3-1001' -Granted 'S-1-5-32-544' -Denied @()).Reason | Should Be 'not-granted'
            $ok = Test-UserRightDecision -TokenSids 'S-1-5-21-1-2-3-1001', 'S-1-5-32-551' -Granted 'S-1-5-32-551' -Denied @()
            $ok.Allowed | Should Be $true
        }
    }
    It 'read-access check passes for the current user and reports missing rights for an unlisted or denied SID' {
        $dir = Join-Path $repo ".local\lifecycle-tests\acl-$([guid]::NewGuid().ToString('N').Substring(0, 8))"
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        $file = Join-Path $dir 'f.txt'; Set-Content -LiteralPath $file -Value 'x'
        try {
            $wi = [Security.Principal.WindowsIdentity]::GetCurrent()
            $me = @($wi.User.Value) + @($wi.Groups | ForEach-Object Value)
            & (Get-Module Lifecycle) { param($f, $s) Get-MissingReadRight -Path $f -TokenSids $s } $file $me | Should BeNullOrEmpty
            $fake = 'S-1-5-21-1-2-3-1001'
            & (Get-Module Lifecycle) { param($f, $s) Get-MissingReadRight -Path $f -TokenSids $s } $file $fake | Should Not BeNullOrEmpty
            $acl = Get-Acl -LiteralPath $file
            $sid = [Security.Principal.SecurityIdentifier]$fake
            $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($sid, 'ReadAndExecute, Synchronize', 'Allow'))
            $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($sid, 'Read', 'Deny'))
            Set-Acl -LiteralPath $file -AclObject $acl
            & (Get-Module Lifecycle) { param($f, $s) Get-MissingReadRight -Path $f -TokenSids $s } $file $fake | Should Not BeNullOrEmpty
        }
        finally { Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue }
    }
    It 'reading the batch-logon holders either works (elevated) or fails loudly (not elevated)' {
        $r = $null; $err = $null
        try { $r = & (Get-Module Lifecycle) { Get-UserRightHolder -Right 'SeBatchLogonRight' } } catch { $err = $_ }
        ($null -ne $err -or $null -ne $r) | Should Be $true
    }
    It 'installer refuses a release path other than AppRoot\current and any pinned -RuntimePath' {
        $cred = [pscredential]::new('nobody', (ConvertTo-SecureString 'x' -AsPlainText -Force))
        { Install-AppBootTask -AppId 'toy-app' -AppRoot 'C:\x\app' -ReleasePath 'C:\x\app\releases\r1' -ManifestPath 'C:\x\app\releases\r1\deploy\application.json' `
                -PowerShellPath "$PSHOME\pwsh.exe" -Credential $cred -ApproveProvisioning } | Should Throw 'follows the active release'
        { Install-AppBootTask -AppId 'toy-app' -AppRoot 'C:\x\app' -ReleasePath 'C:\x\app\current' -ManifestPath 'C:\x\app\current\deploy\application.json' `
                -RuntimePath 'C:\node.exe' -PowerShellPath "$PSHOME\pwsh.exe" -Credential $cred -ApproveProvisioning } | Should Throw 'Do not pass -RuntimePath'
    }
}

Describe 'Assert-AppBootTask against a fake registered task' {
    $appRoot = 'C:\x\app'
    $pwshPath = Join-Path $PSHOME 'pwsh.exe'
    $watchdog = [IO.Path]::GetFullPath((Join-Path $repo 'scripts\Invoke-AppWatchdog.ps1'))
    $toolkit = [IO.Path]::GetFullPath($repo)
    $me = [Security.Principal.WindowsIdentity]::GetCurrent().Name
    $quotedScript = if ($watchdog -match ' ') { '"' + $watchdog + '"' } else { $watchdog }
    $expectedArgs = "-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File $quotedScript -AppRoot C:\x\app -ReleasePath C:\x\app\current -ManifestPath C:\x\app\current\deploy\application.json"
    function New-FakeTask {
        param([string]$User = $me, [string]$Logon = 'Password', [string]$RunLevel = 'Limited', [string]$Execute = $pwshPath,
            [string]$Arguments = $expectedArgs, [string]$WorkDir = $toolkit, [string]$Limit = 'PT0S', [switch]$Disabled, [switch]$NoBoot, [switch]$TwoActions)
        $settings = New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew
        $settings.ExecutionTimeLimit = $Limit
        if ($Disabled) { $settings.Enabled = $false }
        $actions = @(New-ScheduledTaskAction -Execute $Execute -Argument $Arguments -WorkingDirectory $WorkDir)
        if ($TwoActions) { $actions += New-ScheduledTaskAction -Execute 'cmd.exe' }
        $triggers = @(New-ScheduledTaskTrigger -Once -At (Get-Date))
        if (-not $NoBoot) { $triggers += New-ScheduledTaskTrigger -AtStartup }
        [pscustomobject]@{
            State = if ($Disabled) { 'Disabled' } else { 'Ready' }; Settings = $settings; Actions = $actions; Triggers = $triggers
            Principal = New-ScheduledTaskPrincipal -UserId $User -LogonType $Logon -RunLevel $RunLevel
        }
    }
    function Invoke-Assert { Assert-AppBootTask -AppId 'toy-app' -AppRoot $appRoot -PowerShellPath $pwshPath -ExpectedAccount $me }

    It 'validates the installer-generated task and reports the exact arguments' {
        $global:FakeBootTask = New-FakeTask
        Mock -ModuleName Lifecycle Get-AppBootTaskObject { $global:FakeBootTask }
        $r = Invoke-Assert
        $r.Validated | Should Be $true
        $r.Arguments | Should Be $expectedArgs
        $r.TaskName | Should Be 'SolutionDeploy-toy-app'
        $r.TaskPath | Should Be '\JimlerTech\'
        Assert-MockCalled -ModuleName Lifecycle Get-AppBootTaskObject -Times 1 -ParameterFilter { $TaskPath -eq '\JimlerTech\' -and $TaskName -eq 'SolutionDeploy-toy-app' }
        $r.AccountSid | Should Be ([Security.Principal.WindowsIdentity]::GetCurrent().User.Value)
    }
    $cases = @(
        @{ Name = 'a missing task'; Task = $null; Message = 'not registered' }
        @{ Name = 'another account'; Task = @{ User = 'NT AUTHORITY\SYSTEM'; Logon = 'ServiceAccount' }; Message = 'S-1-5-18' }
        @{ Name = 'S4U logon'; Task = @{ Logon = 'S4U' }; Message = 'expected Password' }
        @{ Name = 'Highest run level'; Task = @{ RunLevel = 'Highest' }; Message = 'expected Limited' }
        @{ Name = 'another executable'; Task = @{ Execute = 'C:\Windows\System32\cmd.exe' }; Message = 'action runs' }
        @{ Name = 'an extra -RuntimePath argument'; Task = @{ Arguments = "$expectedArgs -RuntimePath C:\evil\node.exe" }; Message = 'arguments differ' }
        @{ Name = 'a different script'; Task = @{ Arguments = $expectedArgs.Replace($watchdog, 'C:\evil\w.ps1') }; Message = 'arguments differ' }
        @{ Name = 'a pinned release'; Task = @{ Arguments = $expectedArgs.Replace('C:\x\app\current', 'C:\x\app\releases\r1') }; Message = 'arguments differ' }
        @{ Name = 'another working directory'; Task = @{ WorkDir = 'C:\x\app\shared\run' }; Message = 'working directory' }
        @{ Name = 'a 72-hour limit'; Task = @{ Limit = 'PT72H' }; Message = 'expected PT0S' }
        @{ Name = 'a disabled task'; Task = @{ Disabled = $true }; Message = 'disabled' }
        @{ Name = 'no boot trigger'; Task = @{ NoBoot = $true }; Message = 'at-startup' }
        @{ Name = 'two actions'; Task = @{ TwoActions = $true }; Message = 'expected 1' }
    )
    foreach ($c in $cases) {
        It "rejects $($c.Name)" {
            $global:FakeBootTask = if ($null -eq $c.Task) { $null } else { $p = $c.Task; New-FakeTask @p }
            Mock -ModuleName Lifecycle Get-AppBootTaskObject { $global:FakeBootTask }
            { Invoke-Assert } | Should Throw $c.Message
        }
    }
    It 'rejects a PowerShellPath that is not pwsh.exe before reading the task' {
        { Assert-AppBootTask -AppId 'toy-app' -AppRoot $appRoot -PowerShellPath 'C:\Windows\System32\cmd.exe' -ExpectedAccount $me } | Should Throw 'pwsh.exe'
    }
    Remove-Variable -Name FakeBootTask -Scope Global -ErrorAction SilentlyContinue
}


$python = (Get-Command python.exe -ErrorAction SilentlyContinue).Source
$toyPython = @(
    'import http.server, json, os, sys, threading, time'
    'port = int(sys.argv[1])'
    'stop_file = os.environ.get("SOLUTIONDEPLOY_STOP_FILE")'
    'exit_file = os.environ.get("TOY_EXIT_FILE")'
    'class H(http.server.BaseHTTPRequestHandler):'
    '    def do_GET(self):'
    '        if self.path != "/health":'
    '            self.send_response(404); self.end_headers(); return'
    '        body = json.dumps({"status": "ok", "app": "toy"}).encode()'
    '        self.send_response(200); self.send_header("content-type", "application/json"); self.end_headers(); self.wfile.write(body)'
    '    def log_message(self, *a): pass'
    'srv = http.server.HTTPServer(("127.0.0.1", port), H)'
    'def watch():'
    '    start = time.time()'
    '    while True:'
    '        if (stop_file and os.path.exists(stop_file)) or (exit_file and os.path.exists(exit_file)) or time.time() - start > 120:'
    '            os._exit(0)'
    '        time.sleep(0.15)'
    'threading.Thread(target=watch, daemon=True).start()'
    'srv.serve_forever()'
)

Describe 'Python venv: launcher and base-interpreter child identity' {
    if (-not $python) { It 'needs python.exe on PATH' { $python | Should Not BeNullOrEmpty }; return }
    $root = New-TestAppRoot 'py'
    $release = Join-Path $root 'releases\r1'
    Set-Content -LiteralPath (Join-Path $release 'server.py') -Value $toyPython -Encoding utf8NoBOM
    & $python -m venv (Join-Path $release '.venv') | Out-Null
    $venvPy = Join-Path $release '.venv\Scripts\python.exe'
    $port = Get-FreePort
    $m = New-ToyManifest -Port $port
    $m.runtime = @{ kind = 'python'; minimumVersion = '3.10' }
    $m.launch.entrypoint = 'server.py'
    $m.launch.arguments = @([string]$port)
    $m.readiness.expected = @{ status = 'ok'; app = 'toy' }
    $script:pyIds = @()
    try {
        It 'starts, records the venv child, and owns the listener' {
            $r = Start-ManagedApp -AppRoot $root -ReleasePath $release -Manifest $m -RuntimePath $venvPy -TimeoutSeconds 30
            $r.Status | Should Be 'Started'
            $id = Test-ManagedAppIdentity -AppRoot $root -ReleasePath $release -Manifest $m -RuntimePath $venvPy
            $id.Verified | Should Be $true
            $id.ChildPid | Should Not BeNullOrEmpty
            $id.ListenerOwned | Should Be $true
            @($id.ListenerPids) -contains $id.ChildPid | Should Be $true
            $script:pyIds = @($id.Pid, $id.ChildPid)
        }
        It 'launches the venv launcher and its interpreter child without a window' {
            [void](Assert-ToyHeadless -ProcessIds $script:pyIds -RequireConsoleHost)
            $h = Test-ManagedAppHeadless -AppRoot $root -ReleasePath $release -Manifest $m -RuntimePath $venvPy
            $h.Result | Should Be 'Headless'
            @($h.Processes).Count | Should Be 2
            ($h.Processes | Where-Object Role -eq 'child').Pid | Should Be $script:pyIds[1]
            foreach ($e in $h.Processes) { $e.MainWindowHandle | Should Be 0; $e.VisibleWindows | Should Be 0 }
        }
        It 'rejects a forged child PID that the launcher did not start' {
            $recPath = Join-Path $root 'shared\run\process.json'
            $saved = Get-Content -LiteralPath $recPath -Raw
            try {
                $rec = $saved | ConvertFrom-Json -AsHashtable -DateKind String
                $me = Get-CimInstance Win32_Process -Filter "ProcessId=$PID"
                $rec.childPid = $PID
                $rec.childCreationTimeUtc = $me.CreationDate.ToUniversalTime().ToString('o')
                $rec | ConvertTo-Json | Set-Content -LiteralPath $recPath -Encoding utf8NoBOM
                $id = Test-ManagedAppIdentity -AppRoot $root -ReleasePath $release -Manifest $m -RuntimePath $venvPy
                $id.Verified | Should Be $false
                $id.Status | Should Be 'Foreign'
            }
            finally { Set-Content -LiteralPath $recPath -Value $saved -NoNewline -Encoding utf8NoBOM }
        }
        It 'stops both the launcher and the child through the stop file' {
            (Stop-ManagedApp -AppRoot $root -ReleasePath $release -Manifest $m -RuntimePath $venvPy -TimeoutSeconds 20).Status | Should Be 'Stopped'
            foreach ($i in $script:pyIds) { Get-Process -Id $i -ErrorAction SilentlyContinue | Should BeNullOrEmpty }
        }
    }
    finally {
        Set-Content -LiteralPath (Join-Path $root 'shared\run\test-exit') -Value 'exit'
        foreach ($i in $script:pyIds) { $d = [Diagnostics.Stopwatch]::StartNew(); while ((Get-Process -Id $i -ErrorAction SilentlyContinue) -and $d.Elapsed.TotalSeconds -lt 10) { Start-Sleep -Milliseconds 200 } }
        Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Describe 'Switching current to a new release changes release and runtime on the next watchdog run' {
    $root = New-TestAppRoot 'switch'
    $r1 = Join-Path $root 'releases\r1'
    $r2 = Join-Path $root 'releases\r2'
    New-Item -ItemType Directory -Path $r2 | Out-Null
    Copy-Item -LiteralPath (Join-Path $r1 'server.js') -Destination $r2
    $rt2 = Join-Path $root 'rt2\node.exe'
    New-Item -ItemType Directory -Path (Split-Path $rt2) | Out-Null
    Copy-Item -LiteralPath $node -Destination $rt2
    $port = Get-FreePort
    foreach ($pair in @(@($r1, $node), @($r2, $rt2))) {
        New-Item -ItemType Directory -Path (Join-Path $pair[0] 'deploy') | Out-Null
        @{ schemaVersion = 1; runtimePath = $pair[1]; runtimeSHA256 = (Get-FileHash -LiteralPath $pair[1]).Hash.ToLowerInvariant() } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $pair[0] 'release.json') -Encoding utf8NoBOM
        (New-ToyManifest -Port $port) | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $pair[0] 'deploy\application.json') -Encoding utf8NoBOM
    }
    $current = Join-Path $root 'current'
    New-Item -ItemType Junction -Path $current -Target $r1 | Out-Null
    $script = Join-Path $repo 'scripts\Invoke-AppWatchdog.ps1'
    $pwsh = Join-Path $PSHOME 'pwsh.exe'
    $script:switchPids = @()
    function Invoke-SwitchWatchdog {
        $outFile = Join-Path $root 'wd.out'
        $a = @('-NoProfile', '-NonInteractive', '-File', "`"$script`"", '-AppRoot', "`"$root`"", '-ReleasePath', "`"$current`"", '-ManifestPath', "`"$current\deploy\application.json`"")
        $p = Start-Process -FilePath $pwsh -ArgumentList $a -NoNewWindow -PassThru -RedirectStandardOutput $outFile -RedirectStandardError (Join-Path $root 'wd.err')
        if (-not $p.WaitForExit(60000)) { throw 'watchdog script did not exit within 60 s' }
        return (Get-Content -LiteralPath $outFile | Select-Object -Last 1) | ConvertFrom-Json
    }
    try {
        It 'runs r1 with its runtime, then r2 with its runtime after the switch' {
            $a = Invoke-SwitchWatchdog
            $a.Status | Should Be 'Started'
            $script:switchPids += $a.Pid
            (Get-Content -LiteralPath (Join-Path $root 'shared\run\process.json') -Raw | ConvertFrom-Json).releasePath | Should Be $r1
            $m1 = Read-LifecycleManifest -Path (Join-Path $current 'deploy\application.json') -AppRoot $root -ReleasePath $current
            (Stop-ManagedApp -AppRoot $root -ReleasePath $current -Manifest $m1 -RuntimePath $node -TimeoutSeconds 15).Status | Should Be 'Stopped'

            [IO.Directory]::Delete($current)
            New-Item -ItemType Junction -Path $current -Target $r2 | Out-Null
            Clear-AppMaintenance -AppRoot $root
            $b = Invoke-SwitchWatchdog
            $b.Status | Should Be 'Started'
            $script:switchPids += $b.Pid
            $rec = Get-Content -LiteralPath (Join-Path $root 'shared\run\process.json') -Raw | ConvertFrom-Json
            $rec.releasePath | Should Be $r2
            $rec.executablePath | Should Be $rt2

            $m2 = Read-LifecycleManifest -Path (Join-Path $r2 'deploy\application.json') -AppRoot $root -ReleasePath $r2
            (Test-ManagedAppIdentity -AppRoot $root -ReleasePath $r2 -Manifest $m2 -RuntimePath $rt2).Verified | Should Be $true
            $m1b = Read-LifecycleManifest -Path (Join-Path $r1 'deploy\application.json') -AppRoot $root -ReleasePath $r1
            (Test-ManagedAppIdentity -AppRoot $root -ReleasePath $r1 -Manifest $m1b -RuntimePath $node).Verified | Should Be $false
            (Stop-ManagedApp -AppRoot $root -ReleasePath $current -Manifest $m2 -RuntimePath $rt2 -TimeoutSeconds 15).Status | Should Be 'Stopped'
        }
    }
    finally {
        Set-Content -LiteralPath (Join-Path $root 'shared\run\test-exit') -Value 'exit'
        foreach ($i in $script:switchPids) { $d = [Diagnostics.Stopwatch]::StartNew(); while ((Get-Process -Id $i -ErrorAction SilentlyContinue) -and $d.Elapsed.TotalSeconds -lt 10) { Start-Sleep -Milliseconds 200 } }
        if (Test-Path -LiteralPath $current) { [IO.Directory]::Delete($current) }
        Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Describe 'Headless decision rules' {
    $session = 3
    function New-Evidence {
        param([string]$Role = 'main', [int]$Session = 3, [long]$Window = 0, [int]$Visible = 0, [string]$HostLine = '\??\C:\WINDOWS\system32\conhost.exe 0x4', [int]$HostVisible = 0, [switch]$NoHost, [switch]$Dead)
        if ($Dead) { return [pscustomobject]@{ Role = $Role; Pid = 10; Alive = $false } }
        $hosts = @()
        if (-not $NoHost) { $hosts = @([pscustomobject]@{ Pid = 11; CommandLine = $HostLine; Headless = ($null -ne $HostLine -and $HostLine -match '(^|\s)0x4(\s|$)'); VisibleWindows = $HostVisible }) }
        [pscustomobject]@{ Role = $Role; Pid = 10; Alive = $true; SessionId = $Session; MainWindowHandle = $Window; VisibleWindows = $Visible; ConsoleHosts = $hosts }
    }
    function Get-Decision { param($Processes, [bool]$Out = $true, [bool]$Err = $true, [string]$Identity)
        & (Get-Module Lifecycle) { param($p, $s, $o, $e, $i) Get-HeadlessDecision -Processes $p -CurrentSessionId $s -StdoutLog $o -StderrLog $e -IdentityProblem $i } $Processes $session $Out $Err $Identity
    }
    It 'is Headless when every check passes, including a venv child without its own console host' {
        (Get-Decision @((New-Evidence), (New-Evidence -Role child -NoHost))).Result | Should Be 'Headless'
    }
    $cases = @(
        @{ Name = 'a main window handle'; E = @{ Window = 1234 }; Result = 'NotHeadless'; Message = 'main window' }
        @{ Name = 'a visible top-level window'; E = @{ Visible = 1 }; Result = 'NotHeadless'; Message = 'visible window' }
        @{ Name = 'a console host without 0x4'; E = @{ HostLine = 'C:\WINDOWS\system32\conhost.exe 0xffffffff -ForceV1' }; Result = 'NotHeadless'; Message = 'not headless' }
        @{ Name = 'a visible console window'; E = @{ HostVisible = 1 }; Result = 'NotHeadless'; Message = 'visible window' }
        @{ Name = 'a process in another session'; E = @{ Session = 0 }; Result = 'Unverifiable'; Message = 'session 0' }
        @{ Name = 'an unreadable console host command line'; E = @{ HostLine = $null }; Result = 'Unverifiable'; Message = 'unreadable' }
        @{ Name = 'a main process with no console host'; E = @{ NoHost = $true }; Result = 'Unverifiable'; Message = 'no console host' }
        @{ Name = 'a process that exited'; E = @{ Dead = $true }; Result = 'NotHeadless'; Message = 'not running' }
    )
    foreach ($c in $cases) {
        It "reports $($c.Result) for $($c.Name)" {
            $e = $c.E
            $d = Get-Decision @(New-Evidence @e)
            $d.Result | Should Be $c.Result
            ($d.Problems -join ' | ') | Should Match $c.Message
        }
    }
    It 'reports NotHeadless for a missing log or unverified identity even when windows are clean' {
        (Get-Decision @(New-Evidence) -Err $false).Problems | Should Be 'stderr log missing'
        (Get-Decision @() -Identity 'identity not verified (NotRunning: no-record)').Result | Should Be 'NotHeadless'
    }
    It 'NotHeadless outranks Unverifiable' {
        (Get-Decision @((New-Evidence -Session 0 -Window 5))).Result | Should Be 'NotHeadless'
    }
}

Describe 'Task Scheduler folder \JimlerTech\' {
    function New-FakeScheduler {
        # Fake Schedule.Service: GetFolder throws per $Behavior; CreateFolder records the name.
        param([string]$Behavior)
        $state = [pscustomobject]@{ Behavior = $Behavior; Created = [System.Collections.Generic.List[string]]::new(); Exists = ($Behavior -eq 'exists') }
        $svc = [pscustomobject]@{ State = $state }
        $svc | Add-Member ScriptMethod GetFolder {
            param($path)
            $s = $this.State
            if ($path -eq '\') {
                $root = [pscustomobject]@{ State = $s }
                $root | Add-Member ScriptMethod CreateFolder {
                    param($n)
                    if ($this.State.Behavior -eq 'createDenied') { throw [System.Runtime.InteropServices.COMException]::new('Access is denied.', -2147024891) }
                    $this.State.Created.Add($n); if ($this.State.Behavior -ne 'createVanishes') { $this.State.Exists = $true }
                }
                return $root
            }
            if ($s.Behavior -eq 'readDenied') { throw [System.Runtime.InteropServices.COMException]::new('Access is denied.', -2147024891) }
            if (-not $s.Exists) { throw [System.Runtime.InteropServices.COMException]::new('The system cannot find the file specified.', -2147024894) }
            return [pscustomobject]@{ Path = $path }
        }
        return $svc
    }
    function Invoke-Folder { param($Svc, [string]$Path = '\JimlerTech\')
        & (Get-Module Lifecycle) { param($s, $p) Initialize-AppTaskFolder -TaskPath $p -Service $s } $Svc $Path
    }
    It 'uses \JimlerTech\ as the module task folder' {
        & (Get-Module Lifecycle) { $script:TaskPath } | Should Be '\JimlerTech\'
    }
    It 'leaves an existing folder alone' {
        $svc = New-FakeScheduler 'exists'
        (Invoke-Folder $svc).Created | Should Be $false
        $svc.State.Created.Count | Should Be 0
    }
    It 'creates the folder only when it is not found, then reads it back' {
        $svc = New-FakeScheduler 'missing'
        $r = Invoke-Folder $svc
        $r.Created | Should Be $true
        $r.TaskPath | Should Be '\JimlerTech\'
        @($svc.State.Created) | Should Be @('JimlerTech')
    }
    It 'throws with the HRESULT and never creates when the folder cannot be read' {
        $svc = New-FakeScheduler 'readDenied'
        { Invoke-Folder $svc } | Should Throw '0x80070005'
        $svc.State.Created.Count | Should Be 0
    }
    It 'throws when creation is denied' {
        { Invoke-Folder (New-FakeScheduler 'createDenied') } | Should Throw 'Cannot create Task Scheduler folder \JimlerTech\ (0x80070005'
    }
    It 'throws when the created folder still cannot be read' {
        { Invoke-Folder (New-FakeScheduler 'createVanishes') } | Should Throw 'still not readable'
    }
    It 'rejects nested or malformed folder paths' {
        foreach ($bad in '\JimlerTech\Apps\', 'JimlerTech', '\', '\..\') {
            { Invoke-Folder (New-FakeScheduler 'exists') $bad } | Should Throw 'single folder'
        }
    }
}

Describe 'Get-ManagedAppEnvironment returns the launcher environment without launching' {
    $root = New-TestAppRoot 'envread'
    $release = Join-Path $root 'releases\r1'
    $secretPath = Join-Path $root 'shared\secrets\app.env'
    $port = Get-FreePort
    function Write-Secrets { param([string[]]$Lines) Set-Content -LiteralPath $secretPath -Encoding utf8NoBOM -Value $Lines }
    function Get-Env { param($Manifest = (New-ToyManifest -Port $port)) Get-ManagedAppEnvironment -AppRoot $root -ReleasePath $release -Manifest $Manifest -RuntimePath $node }
    It 'returns expanded launch.environment, parsed secrets, and the stop file variable, and starts nothing' {
        Write-Secrets @('# db', 'DATABASE_URL="postgresql://app:p%40ss@localhost:5432/toy"', 'TOY_SECRET=plain')
        $before = @(Get-Process -Name node -ErrorAction SilentlyContinue).Id
        $e = Get-Env
        $e | Should BeOfType System.Collections.Specialized.OrderedDictionary
        $e['DATABASE_URL'] | Should BeExactly 'postgresql://app:p%40ss@localhost:5432/toy'
        $e['TOY_DATA'] | Should Be (Join-Path $root 'shared\data')
        $e['SOLUTIONDEPLOY_STOP_FILE'] | Should Be (Join-Path $root 'shared\run\STOP')
        @($e.Keys).Count | Should Be 5
        $env:DATABASE_URL | Should BeNullOrEmpty
        @(Get-Process -Name node -ErrorAction SilentlyContinue | Where-Object { $before -notcontains $_.Id }).Count | Should Be 0
        Test-Path (Join-Path $root 'shared\run\process.json') | Should Be $false
        $e.Clear()
    }
    It 'returns no secret names when the manifest has no secretFile' {
        $m = New-ToyManifest -Port $port; $m.launch.Remove('secretFile')
        $e = Get-Env $m
        $e.Contains('DATABASE_URL') | Should Be $false
        @($e.Keys).Count | Should Be 3
    }
    $guards = @(
        @{ Name = 'a repeated name'; Lines = @('DATABASE_URL=postgresql://a:SENTINEL1@h/db', 'DATABASE_URL=postgresql://b:SENTINEL2@h/db'); Message = 'line 2 repeats a name' }
        @{ Name = 'a launch.environment collision'; Lines = @('TOY_DATA=SENTINEL1'); Message = 'TOY_DATA collides with launch.environment' }
        @{ Name = 'the stop file variable'; Lines = @('SOLUTIONDEPLOY_STOP_FILE=SENTINEL1'); Message = 'must not set SOLUTIONDEPLOY_STOP_FILE' }
        @{ Name = 'a malformed line'; Lines = @('SENTINEL1'); Message = 'line 1 is not KEY=VALUE' }
    )
    foreach ($g in $guards) {
        It "throws the launcher guard for $($g.Name) without the value in the message" {
            Write-Secrets $g.Lines
            $err = $null
            try { [void](Get-Env) } catch { $err = $_.Exception.Message }
            $err | Should Match ([regex]::Escape($g.Message))
            $err | Should Not Match 'SENTINEL'
        }
    }
    It 'Start-ManagedApp refuses the same repeated-name file' {
        Write-Secrets @('DATABASE_URL=postgresql://a:SENTINEL1@h/db', 'DATABASE_URL=postgresql://b:SENTINEL2@h/db')
        { Start-ManagedApp -AppRoot $root -ReleasePath $release -Manifest (New-ToyManifest -Port $port) -RuntimePath $node -TimeoutSeconds 5 } | Should Throw 'repeats a name'
        Test-Path (Join-Path $root 'shared\run\process.json') | Should Be $false
    }
}

