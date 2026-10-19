#Requires -Version 7.0
# Pester 3.4. No test makes a network call: every Cloudflare request goes to the in-memory fake below.

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
Import-Module (Join-Path $here '..\src\Cloudflare.psm1') -Force

$script:A = 'acc0000000000000000000000000000a'
$script:Z = 'zone000000000000000000000000000z'
$script:T = '11111111-2222-3333-4444-555555555555'
$script:OldT = '99999999-8888-7777-6666-555555555555'
$script:Idp = 'idp-entra'
$script:Email = 'jim@example.com'
$script:Tok = ConvertTo-SecureString 'fake-token' -AsPlainText -Force
$script:Access = @{ IdentityProviderId = $script:Idp; AllowEmails = @($script:Email) }
# Mirrors environments/production.json schema 2. Hardware UUIDs are fixtures.
$script:Uuid = @{ jimbrownhome = '4C4C4544-0000-1000-8000-00000000000A'; jimbrownhome1 = '4C4C4544-0000-1000-8000-00000000000B' }
$script:Hosts = @{
    jimbrownhome  = @{ host = 'jimbrownhome'; address = '192.168.2.11'; root = 'C:\ProgramData\SolutionDeploy'; routeProfile = 'jimbrownhome' }
    jimbrownhome1 = @{ host = 'jimbrownhome1'; address = '192.168.2.14'; root = 'C:\ProgramData\SolutionDeploy'; routeProfile = 'jimbrownhome1' }
}
function New-Deployment { param([string] $Target = 'jimbrownhome1', [hashtable] $Manifest)
    $t = @{} + $script:Hosts[$Target]; $t.hosts = $script:Hosts
    @{ schemaVersion = 2; app = $Manifest.id; manifest = $Manifest; target = $t
        hostSnapshot = @{ host = $Target; address = $script:Hosts[$Target].address; verified = $true; identity = $script:Uuid[$Target] } } }
$script:Target = @{ Host = 'jimbrownhome1'; Address = '192.168.2.14'; HostIdentity = $script:Uuid.jimbrownhome1; RouteProfile = 'jimbrownhome1' }

function New-Id { [guid]::NewGuid().ToString('N') }

function New-FakeCloudflare {
    $s = @{
        Requests  = [System.Collections.Generic.List[object]]::new()
        Zone      = @{ id = $script:Z; name = 'jimlertech.com'; status = 'active'; account = @{ id = $script:A } }
        Tunnel    = @{ id = $script:T; name = 'jimbrownhome1'; account_tag = $script:A; config_src = 'cloudflare'; remote_config = $true; deleted_at = $null; status = 'healthy' }
        Config    = @{ version = 3; config = @{ 'warp-routing' = @{ enabled = $false }; ingress = @(
                    @{ hostname = 'other.jimlertech.com'; service = 'http://127.0.0.1:9000'; originRequest = @{ noTLSVerify = $true } }
                    @{ service = 'http_status:404' }) } }
        Dns       = [System.Collections.Generic.List[object]]::new()
        Apps      = [System.Collections.Generic.List[object]]::new()
        Policies  = [System.Collections.Generic.List[object]]::new()
        Idps      = @(@{ id = $script:Idp; name = 'Microsoft'; type = 'azureAD' }, @{ id = 'idp-otp'; name = 'OTP'; type = 'onetimepin' })
        RateRules = @(@{ id = 'r1'; ref = 'ferry_tracker_catch_ratelimit'; expression = '(starts_with(http.request.uri.path, "/api/catch"))'; action = 'block'; enabled = $true
                ratelimit = @{ characteristics = @('ip.src', 'cf.colo.id'); period = 10; requests_per_period = 5; mitigation_timeout = 10 } })
        OnWrite   = $null
        IgnorePut = $false
    }
    $s.Dns.Add(@{ id = (New-Id); type = 'A'; name = 'unrelated.jimlertech.com'; content = '1.2.3.4'; proxied = $true })
    $a = $script:A; $z = $script:Z; $t = $script:T
    $s.Transport = {
        param([hashtable] $Request)
        $st = $s
        $st.Requests.Add(@{ Method = $Request.Method; Path = $Request.Path; Body = $Request.Body; BodyJson = $Request.BodyJson })
        if ($Request.Token -ne 'fake-token') { throw 'fake: bad token' }
        if ($Request.Method -ne 'GET' -and $st.OnWrite) { & $st.OnWrite $st $Request }
        $path, $query = $Request.Path -split '\?', 2
        $q = @{}; if ($query) { foreach ($kv in $query -split '&') { $k, $v = $kv -split '=', 2; $q[$k] = $v } }
        $ok = { param($r) @{ success = $true; errors = @(); result = $r; result_info = @{ page = 1; total_pages = 1 } } }
        $expand = { param($app) $c = $app.Clone(); $c.policies = @($app.policyIds | ForEach-Object { $id = $_; $st.Policies | Where-Object { $_.id -eq $id } }); $c.Remove('policyIds'); $c }
        switch -Regex ("$($Request.Method) $path") {
            "^GET /zones/$z$" { return & $ok $st.Zone }
            "^GET /accounts/$a/cfd_tunnel/$t$" { return & $ok $st.Tunnel }
            "^GET /accounts/$a/cfd_tunnel/$t/configurations$" { return & $ok $st.Config }
            "^PUT /accounts/$a/cfd_tunnel/$t/configurations$" {
                if (-not $st.IgnorePut) { $st.Config = @{ version = $st.Config.version + 1; config = $Request.Body.config } }
                return & $ok $st.Config }
            "^GET /zones/$z/dns_records$" { return & $ok @($st.Dns | Where-Object { $_.name -eq $q['name'] }) }
            "^POST /zones/$z/dns_records$" { $r = @{ id = [guid]::NewGuid().ToString('N') } + (ConvertFrom-Json $Request.BodyJson -AsHashtable); $st.Dns.Add($r); return & $ok $r }
            "^PATCH /zones/$z/dns_records/(\w+)$" { $id = $Matches[1]; $r = $st.Dns | Where-Object { $_.id -eq $id }; foreach ($k in $Request.Body.Keys) { $r[$k] = $Request.Body[$k] }; return & $ok $r }
            "^GET /accounts/$a/access/apps$" { return & $ok @($st.Apps | ForEach-Object { & $expand $_ }) }
            "^GET /accounts/$a/access/apps/(\w+)$" { $id = $Matches[1]; return & $ok (& $expand ($st.Apps | Where-Object { $_.id -eq $id })) }
            "^POST /accounts/$a/access/apps$" {
                $b = ConvertFrom-Json $Request.BodyJson -AsHashtable
                $app = @{ id = [guid]::NewGuid().ToString('N') } + $b; $app.policyIds = @($b.policies | ForEach-Object { $_.id }); $app.Remove('policies'); $st.Apps.Add($app)
                return & $ok (& $expand $app) }
            "^GET /accounts/$a/access/policies$" { return & $ok @($st.Policies) }
            "^GET /accounts/$a/access/policies/(\w+)$" { $id = $Matches[1]; return & $ok ($st.Policies | Where-Object { $_.id -eq $id }) }
            "^POST /accounts/$a/access/policies$" { $p = @{ id = [guid]::NewGuid().ToString('N') } + (ConvertFrom-Json $Request.BodyJson -AsHashtable); $st.Policies.Add($p); return & $ok $p }
            "^GET /accounts/$a/access/identity_providers$" { return & $ok $st.Idps }
            "^GET /zones/$z/rulesets$" { return & $ok @(@{ id = 'rs-rate'; phase = 'http_ratelimit'; kind = 'zone' }, @{ id = 'rs-hdr'; phase = 'http_response_headers_transform'; kind = 'zone' }) }
            "^GET /zones/$z/rulesets/rs-rate$" { return & $ok @{ id = 'rs-rate'; version = '4'; phase = 'http_ratelimit'; kind = 'zone'; rules = $st.RateRules } }
            default { throw "fake: unhandled $($Request.Method) $($Request.Path)" }
        }
    }.GetNewClosure()
    return $s
}

function Add-FakeApp {
    param($Fake, [string] $Domain, [string] $Decision = 'allow', [object[]] $Include = @(@{ email = @{ email = $script:Email } }),
        [object[]] $Require = @(@{ login_method = @{ id = $script:Idp } }), [string[]] $Idps = @($script:Idp))
    $pol = @{ id = (New-Id); name = "pol $Domain"; decision = $Decision; include = $Include; exclude = @(); require = $Require }
    $Fake.Policies.Add($pol)
    $Fake.Apps.Add(@{ id = (New-Id); name = "app $Domain"; domain = $Domain; type = 'self_hosted'; allowed_idps = $Idps; policyIds = @($pol.id) })
}

function New-Manifest {
    param([string] $Id = 'site-dock', [int] $Port = 8790, [object[]] $Routes = @(@{ hostname = 'site-dock.jimlertech.com' }))
    @{ schemaVersion = 1; id = $Id; launch = @{ port = $Port }; routes = $Routes }
}

function Get-Snap { param($Fake, [string[]] $Hosts)
    Get-CloudflareSnapshot -AccountId $script:A -ZoneId $script:Z -TunnelId $script:T -Hostname $Hosts -Token $script:Tok -Transport $Fake.Transport }

function Get-Plan { param($Fake, $Manifest, [hashtable] $Extra = @{})
    $hosts = @($Manifest.routes | ForEach-Object { $_.hostname })
    $snap = Get-Snap $Fake $hosts
    $args2 = @{ Target = $script:Target }; foreach ($k in $Extra.Keys) { $args2[$k] = $Extra[$k] }
    New-CloudflareRoutePlan -Manifest $Manifest -Current $snap -TunnelId $script:T -ZoneId $script:Z -AccountId $script:A -Access $script:Access @args2 }

function New-FerryProbe { param([int] $Status = 401, [string] $ErrorText = 'Unauthorized.', [int] $WrongStatus = $Status)
    { param($r) $s = if ($r.Headers.Count) { $WrongStatus } else { $Status }; @{ StatusCode = $s; Body = (@{ error = $ErrorText } | ConvertTo-Json -Compress) } }.GetNewClosure() }
function New-FerryEvidence { param([int] $Status = 401, [string] $Origin = 'http://127.0.0.1:8787', [string] $ErrorText = 'Unauthorized.')
    Test-CloudflareCatchTokenEnforcement -Origin $Origin -Probe (New-FerryProbe -Status $Status -ErrorText $ErrorText) }

$script:FerryRoutes = @(@{ hostname = 'ferry-tracker.jimlertech.com'; catchPath = '/api/catch' }, @{ hostname = 'ferry.jimlertech.com'; catchPath = '/api/catch' })

function Get-Writes { param($Fake) @($Fake.Requests | Where-Object { $_.Method -ne 'GET' }) }

Describe 'Get-CloudflareSnapshot' {
    It 'issues only GET requests and hashes a stable projection' {
        $f = New-FakeCloudflare
        $s1 = Get-Snap $f @('site-dock.jimlertech.com')
        @($f.Requests | Where-Object { $_.Method -ne 'GET' }).Count | Should Be 0
        $s1.SnapshotHash | Should Match '^[0-9a-f]{64}$'
        $f.Tunnel.status = 'degraded'
        (Get-Snap $f @('site-dock.jimlertech.com')).SnapshotHash | Should Be $s1.SnapshotHash
        $f.Dns.Add(@{ id = (New-Id); type = 'TXT'; name = 'site-dock.jimlertech.com'; content = 'x'; proxied = $false })
        (Get-Snap $f @('site-dock.jimlertech.com')).SnapshotHash | Should Not Be $s1.SnapshotHash
    }
    It 'refuses a token reference outside CLOUDFLARE_*' {
        $f = New-FakeCloudflare
        { Get-CloudflareSnapshot -AccountId $script:A -ZoneId $script:Z -TunnelId $script:T -Hostname 'a.jimlertech.com' -TokenEnvironmentVariable 'PATH' -Transport $f.Transport } | Should Throw 'not an approved'
        $f.Requests.Count | Should Be 0
    }
}

Describe 'New-CloudflareRoutePlan' {
    It 'plans Access before ingress before DNS and keeps foreign ingress, config keys, and terminal 404' {
        $f = New-FakeCloudflare
        $p = Get-Plan $f (New-Manifest)
        $p.Status | Should Be 'Ready'
        (@($p.Operations | ForEach-Object { $_.Kind }) -join ',') | Should Be 'AccessPolicyCreate,AccessAppCreate,TunnelIngressUpdate,DnsCreate'
        $pol = $p.Operations[0].Body
        $pol.decision | Should Be 'allow'
        $pol.require[0].login_method.id | Should Be $script:Idp
        $pol.include[0].email.email | Should Be $script:Email
        $cfg = $p.Operations[2].Body.config
        $cfg.ingress.Count | Should Be 3
        $cfg.ingress[0].hostname | Should Be 'other.jimlertech.com'
        $cfg.ingress[0].originRequest.noTLSVerify | Should Be $true
        $cfg.ingress[1].hostname | Should Be 'site-dock.jimlertech.com'
        $cfg.ingress[1].service | Should Be 'http://127.0.0.1:8790'
        $cfg.ingress[2].service | Should Be 'http_status:404'
        $cfg.'warp-routing'.enabled | Should Be $false
        $p.Operations[3].Body.content | Should Be "$($script:T).cfargotunnel.com"
        @($p.Operations | Where-Object { $_.Body.decision -eq 'bypass' }).Count | Should Be 0
        (Assert-CloudflareRoutePlan -Plan $p) | Should Be $true
    }
    It 'blocks a catch bypass for any app other than Ferry' {
        $p = Get-Plan (New-FakeCloudflare) (New-Manifest -Routes @(@{ hostname = 'site-dock.jimlertech.com'; catchPath = '/api/catch' }))
        $p.Status | Should Be 'Blocked'
        ($p.Blockers -join '|') | Should Match 'only ferry-tracker'
    }
    It 'gives each Ferry hostname its own exact catch bypass when rate rule and token probe evidence hold' {
        $f = New-FakeCloudflare
        $p = Get-Plan $f (New-Manifest -Id 'ferry-tracker' -Port 8787 -Routes $script:FerryRoutes) @{ CatchTokenEvidence = (New-FerryEvidence) }
        $p.Status | Should Be 'Ready'
        $catchApps = @($p.Operations | Where-Object { $_.Kind -eq 'CatchAppCreate' })
        (@($catchApps | ForEach-Object { $_.Body.domain } | Sort-Object) -join ',') | Should Be 'ferry-tracker.jimlertech.com/api/catch,ferry.jimlertech.com/api/catch'
        @($p.Operations | Where-Object { $_.Body.decision -eq 'bypass' }).Count | Should Be 2
        @($p.Operations | Where-Object { $_.Kind -eq 'AccessAppCreate' }).Count | Should Be 2
    }
    It 'blocks Ferry without token evidence, with failing evidence, tampered evidence, or the wrong origin' {
        $f = New-FakeCloudflare
        $m = New-Manifest -Id 'ferry-tracker' -Port 8787 -Routes $script:FerryRoutes
        (Get-Plan $f $m).Blockers -join '|' | Should Match 'evidence is missing'
        (Get-Plan $f $m @{ CatchTokenEvidence = (New-FerryEvidence -Status 200) }).Blockers -join '|' | Should Match 'answered 200/200'
        $ev = New-FerryEvidence; $ev.NoTokenStatus = 401; $ev.WrongTokenStatus = 200
        (Get-Plan $f $m @{ CatchTokenEvidence = $ev }).Blockers -join '|' | Should Match 'not an intact probe'
        (Get-Plan $f $m @{ CatchTokenEvidence = (New-FerryEvidence -Origin 'http://127.0.0.1:9999') }).Blockers -join '|' | Should Match 'taken against'
        foreach ($s in 400, 403, 404, 302) { (Get-Plan $f $m @{ CatchTokenEvidence = (New-FerryEvidence -Status $s) }).Blockers -join '|' | Should Match "answered $s/$s" }
        (Get-Plan $f $m @{ CatchTokenEvidence = (New-FerryEvidence -ErrorText 'Forbidden') }).Blockers -join '|' | Should Match 'only 401 Unauthorized. counts'
    }
    It 'blocks Ferry when the catch rate limit rule differs' {
        $f = New-FakeCloudflare
        $f.RateRules[0].ratelimit.requests_per_period = 50
        $p = Get-Plan $f (New-Manifest -Id 'ferry-tracker' -Port 8787 -Routes $script:FerryRoutes) @{ CatchTokenEvidence = (New-FerryEvidence) }
        ($p.Blockers -join '|') | Should Match 'rate limit rule not verified'
    }
    It 'requires every Ferry hostname to declare the catch exception' {
        $p = Get-Plan (New-FakeCloudflare) (New-Manifest -Id 'ferry-tracker' -Port 8787 -Routes @(@{ hostname = 'ferry.jimlertech.com' })) 
        ($p.Blockers -join '|') | Should Match 'every Ferry hostname'
    }
    It 'adopts an existing restrictive Access app and blocks one that is not restrictive' {
        $f = New-FakeCloudflare
        Add-FakeApp $f 'site-dock.jimlertech.com'
        $p = Get-Plan $f (New-Manifest)
        $p.Status | Should Be 'Ready'
        @($p.Operations | Where-Object { $_.Kind -like 'Access*' }).Count | Should Be 0
        $g = New-FakeCloudflare
        Add-FakeApp $g 'site-dock.jimlertech.com' -Require @()
        ((Get-Plan $g (New-Manifest)).Blockers -join '|') | Should Match 'not restrictive.*login_method'
        $h = New-FakeCloudflare
        Add-FakeApp $h 'site-dock.jimlertech.com' -Include @(@{ everyone = @{} })
        ((Get-Plan $h (New-Manifest)).Blockers -join '|') | Should Match 'not a single email'
    }
    It 'blocks when the identity provider is not Microsoft' {
        $f = New-FakeCloudflare
        $snap = Get-Snap $f @('site-dock.jimlertech.com')
        $p = New-CloudflareRoutePlan -Manifest (New-Manifest) -Current $snap -TunnelId $script:T -ZoneId $script:Z -AccountId $script:A -Target $script:Target -Access @{ IdentityProviderId = 'idp-otp'; AllowEmails = @($script:Email) }
        ($p.Blockers -join '|') | Should Match 'is not Microsoft'
    }
    It 'blocks a path-scoped Access app on the host (possible broad bypass)' {
        $f = New-FakeCloudflare
        Add-FakeApp $f 'site-dock.jimlertech.com/admin' -Decision 'bypass' -Include @(@{ everyone = @{} })
        ((Get-Plan $f (New-Manifest)).Blockers -join '|') | Should Match 'scopes a path'
    }
    It 'refuses foreign DNS records and repoints another tunnel only when approved' {
        $f = New-FakeCloudflare
        $f.Dns.Add(@{ id = 'a' * 32; type = 'A'; name = 'site-dock.jimlertech.com'; content = '5.6.7.8'; proxied = $true })
        ((Get-Plan $f (New-Manifest)).Blockers -join '|') | Should Match 'refusing to overwrite'
        $g = New-FakeCloudflare
        $g.Dns.Add(@{ id = 'b' * 32; type = 'CNAME'; name = 'site-dock.jimlertech.com'; content = "$($script:OldT).cfargotunnel.com"; proxied = $true })
        ((Get-Plan $g (New-Manifest)).Blockers -join '|') | Should Match 'AllowDnsRepoint'
        $p = Get-Plan $g (New-Manifest) @{ AllowDnsRepoint = @('site-dock.jimlertech.com') }
        $op = $p.Operations | Where-Object { $_.Kind -eq 'DnsRepoint' }
        $op.Method | Should Be 'PATCH'
        $op.Path | Should Be "/zones/$($script:Z)/dns_records/$('b' * 32)"
        $op.Body.content | Should Be "$($script:T).cfargotunnel.com"
    }
    It 'refuses to replace a differing ingress rule or a non-404 terminal rule' {
        $f = New-FakeCloudflare
        $f.Config.config.ingress = @(@{ hostname = 'site-dock.jimlertech.com'; service = 'http://127.0.0.1:1234' }, @{ service = 'http_status:404' })
        ((Get-Plan $f (New-Manifest)).Blockers -join '|') | Should Match 'refusing to replace'
        $g = New-FakeCloudflare
        $g.Config.config.ingress = @(@{ service = 'http://127.0.0.1:80' })
        ((Get-Plan $g (New-Manifest)).Blockers -join '|') | Should Match 'terminal ingress'
    }
    It 'blocks a snapshot for a different tunnel or a deleted tunnel' {
        $f = New-FakeCloudflare
        $f.Tunnel.deleted_at = '2026-01-01T00:00:00Z'
        ((Get-Plan $f (New-Manifest)).Blockers -join '|') | Should Match 'missing, deleted'
        $snap = Get-Snap (New-FakeCloudflare) @('site-dock.jimlertech.com')
        $p = New-CloudflareRoutePlan -Manifest (New-Manifest) -Current $snap -TunnelId $script:OldT -ZoneId $script:Z -AccountId $script:A -Access $script:Access -Target $script:Target
        ($p.Blockers -join '|') | Should Match 'different account/zone/tunnel'
    }
    It 'blocks a hostname whose DNS was not read' {
        $snap = Get-Snap (New-FakeCloudflare) @('other.jimlertech.com')
        $p = New-CloudflareRoutePlan -Manifest (New-Manifest) -Current $snap -TunnelId $script:T -ZoneId $script:Z -AccountId $script:A -Access $script:Access -Target $script:Target
        ($p.Blockers -join '|') | Should Match 'existence is never assumed'
    }
    It 'rejects a tampered snapshot' {
        $snap = Get-Snap (New-FakeCloudflare) @('site-dock.jimlertech.com')
        $snap.Dns['site-dock.jimlertech.com'] = @(@{ id = 'x'; type = 'A'; name = 'site-dock.jimlertech.com'; content = '1.1.1.1'; proxied = $false })
        { New-CloudflareRoutePlan -Manifest (New-Manifest) -Current $snap -TunnelId $script:T -ZoneId $script:Z -AccountId $script:A -Access $script:Access -Target $script:Target } | Should Throw 'snapshot hash'
    }
}

Describe 'Assert-CloudflareRoutePlan' {
    It 'rejects an edited plan and a blocked plan' {
        $p = Get-Plan (New-FakeCloudflare) (New-Manifest)
        $p.Operations[3].Body.content = 'evil.example.com'
        { Assert-CloudflareRoutePlan -Plan $p } | Should Throw 'Plan hash'
        $b = Get-Plan (New-FakeCloudflare) (New-Manifest -Routes @(@{ hostname = 'site-dock.jimlertech.com'; catchPath = '/api/catch' }))
        { Assert-CloudflareRoutePlan -Plan $b } | Should Throw 'blocked'
    }
}

Describe 'Invoke-CloudflareRoutePlan' {
    It 'previews without any API call' {
        $f = New-FakeCloudflare
        $p = Get-Plan $f (New-Manifest)
        $f.Requests.Clear()
        $r = Invoke-CloudflareRoutePlan -Plan $p
        $r.Mode | Should Be 'Preview'
        $r.Operations.Count | Should Be 4
        $f.Requests.Count | Should Be 0
    }
    It 'refuses to execute without the approved hash or a journal directory' {
        $f = New-FakeCloudflare
        $p = Get-Plan $f (New-Manifest)
        $f.Requests.Clear()
        { Invoke-CloudflareRoutePlan -Plan $p -Execute -ApprovedPlanHash ('0' * 64) -JournalDirectory $TestDrive -Token $script:Tok -Transport $f.Transport } | Should Throw 'ApprovedPlanHash'
        { Invoke-CloudflareRoutePlan -Plan $p -Execute -ApprovedPlanHash $p.PlanHash -JournalDirectory (Join-Path $TestDrive 'missing') -Token $script:Tok -Transport $f.Transport } | Should Throw 'JournalDirectory'
        $f.Requests.Count | Should Be 0
    }
    It 'applies the exact writes in order, verifies read-back, preserves foreign state, and journals prior state' {
        $f = New-FakeCloudflare
        $p = Get-Plan $f (New-Manifest)
        $f.Requests.Clear()
        $j = Join-Path $TestDrive 'ok'; New-Item -ItemType Directory $j | Out-Null
        $r = Invoke-CloudflareRoutePlan -Plan $p -Execute -ApprovedPlanHash $p.PlanHash -JournalDirectory $j -Token $script:Tok -Transport $f.Transport
        $r.Status | Should Be 'Applied'
        $w = Get-Writes $f
        (@($w | ForEach-Object { "$($_.Method) $($_.Path)" }) -join "`n") | Should Be (@(
                "POST /accounts/$($script:A)/access/policies"
                "POST /accounts/$($script:A)/access/apps"
                "PUT /accounts/$($script:A)/cfd_tunnel/$($script:T)/configurations"
                "POST /zones/$($script:Z)/dns_records") -join "`n")
        $w[1].Body.policies[0].id | Should Be $f.Policies[0].id
        $w[1].Body.domain | Should Be 'site-dock.jimlertech.com'
        $w[3].Body.proxied | Should Be $true
        @($w | Where-Object { $_.Method -in 'DELETE' }).Count | Should Be 0
        $f.Config.config.ingress[0].hostname | Should Be 'other.jimlertech.com'
        @($f.Dns | Where-Object { $_.name -eq 'unrelated.jimlertech.com' }).Count | Should Be 1
        $lines = @(Get-Content $r.Journal | ForEach-Object { ConvertFrom-Json $_ })
        (@($lines | ForEach-Object { $_.event }) -join ',') | Should Be 'start,prior,write,written,verified,prior,write,written,verified,prior,write,written,verified,prior,write,written,verified,complete'
        (Get-Content -Raw $r.Journal) | Should Not Match 'fake-token'
        # Re-planning from the new state is a no-op.
        (Get-Plan $f (New-Manifest)).Status | Should Be 'NoChange'
    }
    It 'fails closed with no writes when state drifted after planning' {
        $f = New-FakeCloudflare
        $p = Get-Plan $f (New-Manifest)
        $f.Config.config.ingress = @(@{ hostname = 'new.jimlertech.com'; service = 'http://127.0.0.1:1' }) + $f.Config.config.ingress
        $f.Requests.Clear()
        { Invoke-CloudflareRoutePlan -Plan $p -Execute -ApprovedPlanHash $p.PlanHash -JournalDirectory $TestDrive -Token $script:Tok -Transport $f.Transport } | Should Throw 'drifted'
        (Get-Writes $f).Count | Should Be 0
    }
    It 'stops before a write whose region changed mid-run and journals the failure' {
        $f = New-FakeCloudflare
        $p = Get-Plan $f (New-Manifest)
        $f.OnWrite = { param($st, $req) if ($req.Path -like '*/configurations') { $st.Dns.Add(@{ id = 'c' * 32; type = 'A'; name = 'site-dock.jimlertech.com'; content = '6.6.6.6'; proxied = $false }) } }
        $j = Join-Path $TestDrive 'mid'; New-Item -ItemType Directory $j | Out-Null
        { Invoke-CloudflareRoutePlan -Plan $p -Execute -ApprovedPlanHash $p.PlanHash -JournalDirectory $j -Token $script:Tok -Transport $f.Transport } | Should Throw 'Precondition for dns:site-dock.jimlertech.com'
        @(Get-Writes $f | Where-Object { $_.Path -like '*/dns_records' }).Count | Should Be 0
        (Get-Content -Raw (Get-ChildItem $j).FullName) | Should Match '"event":"failed"'
    }
    It 'refuses to publish ingress when live Access is weakened after the app was created' {
        $f = New-FakeCloudflare
        $p = Get-Plan $f (New-Manifest)
        $f.OnWrite = { param($st, $req) if ($req.Path -like '*/access/apps') { $st.Policies[0].require = @() } }
        { Invoke-CloudflareRoutePlan -Plan $p -Execute -ApprovedPlanHash $p.PlanHash -JournalDirectory $TestDrive -Token $script:Tok -Transport $f.Transport } | Should Throw 'not restrictive'
        @(Get-Writes $f | Where-Object { $_.Method -eq 'PUT' -or $_.Path -like '*/dns_records' }).Count | Should Be 0
    }
    It 'detects a tunnel configuration read-back mismatch' {
        $f = New-FakeCloudflare
        $p = Get-Plan $f (New-Manifest)
        $f.IgnorePut = $true
        { Invoke-CloudflareRoutePlan -Plan $p -Execute -ApprovedPlanHash $p.PlanHash -JournalDirectory $TestDrive -Token $script:Tok -Transport $f.Transport } | Should Throw 'Read-back of tunnel'
        @(Get-Writes $f | Where-Object { $_.Path -like '*/dns_records' }).Count | Should Be 0
    }
    It 'applies Ferry dual-host routes with an exact catch bypass per host' {
        $f = New-FakeCloudflare
        $f.Dns.Add(@{ id = 'd' * 32; type = 'CNAME'; name = 'ferry.jimlertech.com'; content = "$($script:OldT).cfargotunnel.com"; proxied = $true })
        $p = Get-Plan $f (New-Manifest -Id 'ferry-tracker' -Port 8787 -Routes $script:FerryRoutes) @{ CatchTokenEvidence = (New-FerryEvidence); AllowDnsRepoint = @('ferry.jimlertech.com') }
        $p.Status | Should Be 'Ready'
        $probes = [System.Collections.Generic.List[object]]::new(); $inner = New-FerryProbe
        $j = Join-Path $TestDrive 'ferry'; New-Item -ItemType Directory $j | Out-Null
        $r = Invoke-CloudflareRoutePlan -Plan $p -Execute -ApprovedPlanHash $p.PlanHash -JournalDirectory $j -Token $script:Tok -Transport $f.Transport -CatchProbe { param($q) $probes.Add($q); & $inner $q }.GetNewClosure()
        $r.Status | Should Be 'Applied'
        $probes.Count | Should Be 2
        (Get-Content -Raw $r.Journal) | Should Match '"event":"catch-probe"'
        $bypass = @($f.Policies | Where-Object { $_.decision -eq 'bypass' })
        $bypass.Count | Should Be 2
        $bypassApps = @($f.Apps | Where-Object { $bypass.id -contains $_.policyIds[0] } | ForEach-Object { $_.domain } | Sort-Object)
        ($bypassApps -join ',') | Should Be 'ferry-tracker.jimlertech.com/api/catch,ferry.jimlertech.com/api/catch'
        ($f.Dns | Where-Object { $_.name -eq 'ferry.jimlertech.com' }).content | Should Be "$($script:T).cfargotunnel.com"
        @(Get-Writes $f | Where-Object { $_.Method -eq 'PATCH' }).Count | Should Be 1
    }
    It 'makes no write when the live catch probe at execute time is not an exact 401' {
        $f = New-FakeCloudflare
        $p = Get-Plan $f (New-Manifest -Id 'ferry-tracker' -Port 8787 -Routes $script:FerryRoutes) @{ CatchTokenEvidence = (New-FerryEvidence) }
        $p.Status | Should Be 'Ready'
        { Invoke-CloudflareRoutePlan -Plan $p -Execute -ApprovedPlanHash $p.PlanHash -JournalDirectory $TestDrive -Token $script:Tok -Transport $f.Transport -CatchProbe (New-FerryProbe -Status 401 -WrongStatus 400) } | Should Throw 'Live catch probe failed'
        { Invoke-CloudflareRoutePlan -Plan $p -Execute -ApprovedPlanHash $p.PlanHash -JournalDirectory $TestDrive -Token $script:Tok -Transport $f.Transport -CatchProbe (New-FerryProbe -Status 404 -ErrorText 'The catch endpoint is not available.') } | Should Throw 'Live catch probe failed'
        (Get-Writes $f).Count | Should Be 0
    }
}

Describe 'Test-CloudflareCatchTokenEnforcement' {
    It 'sends GET /api/catch with a valid pair, no X-Ferry-Token and then a 64-hex wrong one, to loopback only' {
        $seen = [System.Collections.Generic.List[object]]::new(); $inner = New-FerryProbe
        $ev = Test-CloudflareCatchTokenEnforcement -Origin 'http://127.0.0.1:8787' -Probe { param($r) $seen.Add($r); & $inner $r }.GetNewClosure()
        $seen.Count | Should Be 2
        $seen[0].Method | Should Be 'GET'
        $seen[0].Uri | Should Be 'http://127.0.0.1:8787/api/catch?departingTerminalId=7&arrivingTerminalId=3'
        $seen[0].Headers.Count | Should Be 0
        @($seen[1].Headers.Keys) -join ',' | Should Be 'X-Ferry-Token'
        $seen[1].Headers['X-Ferry-Token'] | Should Match '^[0-9a-f]{64}$'
        $ev.Passed | Should Be $true
        $ev.NoTokenStatus | Should Be 401
        $ev.WrongTokenError | Should Be 'Unauthorized.'
        $ev.EvidenceHash | Should Match '^[0-9a-f]{64}$'
    }
    It 'accepts only an exact 401 Unauthorized. for both probes' {
        (Test-CloudflareCatchTokenEnforcement -Origin 'http://127.0.0.1:8787' -Probe (New-FerryProbe -Status 401 -WrongStatus 400)).Passed | Should Be $false
        (Test-CloudflareCatchTokenEnforcement -Origin 'http://127.0.0.1:8787' -Probe (New-FerryProbe -Status 400 -ErrorText 'Valid, different departingTerminalId and arrivingTerminalId values are required.')).Passed | Should Be $false
        (Test-CloudflareCatchTokenEnforcement -Origin 'http://127.0.0.1:8787' -Probe (New-FerryProbe -Status 404 -ErrorText 'The catch endpoint is not available.')).Passed | Should Be $false
        (Test-CloudflareCatchTokenEnforcement -Origin 'http://127.0.0.1:8787' -Probe (New-FerryProbe -Status 403)).Passed | Should Be $false
        (Test-CloudflareCatchTokenEnforcement -Origin 'http://127.0.0.1:8787' -Probe (New-FerryProbe -Status 401 -ErrorText 'unauthorized')).Passed | Should Be $false
        (Test-CloudflareCatchTokenEnforcement -Origin 'http://127.0.0.1:8787' -Probe { param($r) @{ StatusCode = 401; Body = '<html>login</html>' } }).Passed | Should Be $false
    }
    It 'refuses a non-loopback origin' {
        { Test-CloudflareCatchTokenEnforcement -Origin 'https://ferry.jimlertech.com' -Probe { 401 } } | Should Throw 'must be http://127.0.0.1'
    }
}
Describe 'Assert-CloudflareDeploymentBinding and the parent JSON round trip' {
    # Mirrors Write-DeploymentJson (-Depth 40). Default dates covers older readers; -DateKind String is the current core reader.
    function Get-RoundTrip { param($Plan, [switch] $StringDates) $j = $Plan | ConvertTo-Json -Depth 40; if ($StringDates) { $j | ConvertFrom-Json -AsHashtable -DateKind String } else { $j | ConvertFrom-Json -AsHashtable } }
    function Get-FerryPlan { param($f)
        Get-Plan $f (New-Manifest -Id 'ferry-tracker' -Port 8787 -Routes $script:FerryRoutes) @{ CatchTokenEvidence = (New-FerryEvidence); AllowDnsRepoint = @('ferry.jimlertech.com') } }
    It 'keeps the plan intact through the deployment JSON reader, with case-sensitive PascalCase keys' {
        $f = New-FakeCloudflare
        $f.Dns.Add(@{ id = 'd' * 32; type = 'CNAME'; name = 'ferry.jimlertech.com'; content = "$($script:OldT).cfargotunnel.com"; proxied = $true })
        $route = Get-RoundTrip (Get-FerryPlan $f)
        Assert-CloudflareRoutePlan -Plan $route | Should Be $true
        $route.PlanHash | Should Match '^[0-9a-f]{64}$'
        $stringRoute = Get-RoundTrip (Get-FerryPlan $f) -StringDates
        $stringRoute.CatchEvidence.ObservedAtUtc | Should Match '^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ$'
        Assert-CloudflareRoutePlan -Plan $stringRoute | Should Be $true
        $route.Contains('planHash') | Should Be $false
        $j = Join-Path $TestDrive 'rt'; New-Item -ItemType Directory $j | Out-Null
        $env:CLOUDFLARE_SD_TEST_TOKEN = 'fake-token'
        try { $r = Invoke-CloudflareRoutePlan -Plan $route -Execute -ApprovedPlanHash $route.PlanHash -JournalDirectory $j -TokenEnvironmentVariable 'CLOUDFLARE_SD_TEST_TOKEN' -Transport $f.Transport -CatchProbe (New-FerryProbe) }
        finally { Remove-Item Env:\CLOUDFLARE_SD_TEST_TOKEN -ErrorAction SilentlyContinue }
        # The fake throws 'bad token' on any other value, so success proves the env reference was used.
        $f.Requests.Count | Should BeGreaterThan 0
        $r.Status | Should Be 'Applied'
    }
    It 'emits evidence timestamps that survive the deployment JSON round trip byte for byte' {
        for ($i = 0; $i -lt 20; $i++) {
            $ev = New-FerryEvidence
            $ev.ObservedAtUtc | Should Match '^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ$'
            $rt = Get-RoundTrip @{ e = $ev }
            (ConvertTo-Json -InputObject $rt.e -Compress | ConvertFrom-Json -AsHashtable -DateKind String).ObservedAtUtc | Should BeExactly $ev.ObservedAtUtc
            (Get-RoundTrip @{ e = $ev } -StringDates).e.ObservedAtUtc | Should BeExactly $ev.ObservedAtUtc
        }
    }
    It 'binds a plan to the deployment target, approved tunnel, manifest id, loopback upstream, hostnames, and catch hosts' {
        $f = New-FakeCloudflare
        $f.Dns.Add(@{ id = 'd' * 32; type = 'CNAME'; name = 'ferry.jimlertech.com'; content = "$($script:OldT).cfargotunnel.com"; proxied = $true })
        $route = Get-RoundTrip (Get-FerryPlan $f)
        $m = New-Manifest -Id 'ferry-tracker' -Port 8787 -Routes $script:FerryRoutes
        $d = Get-RoundTrip (New-Deployment -Target 'jimbrownhome1' -Manifest $m) -StringDates
        $b = Assert-CloudflareDeploymentBinding -Plan $route -DeploymentPlan $d -ApprovedTunnelId $script:T
        $b.PlanHash | Should Be $route.PlanHash
        $b.Target.RouteProfile | Should Be 'jimbrownhome1'
        $b.Target.HostIdentity | Should Be $script:Uuid.jimbrownhome1
        $b.Target.Origin | Should Be 'http://127.0.0.1:8787'
        ($b.Hostnames -join ',') | Should Be 'ferry-tracker.jimlertech.com,ferry.jimlertech.com'
        { Assert-CloudflareDeploymentBinding -Plan $route -DeploymentPlan $d -ApprovedTunnelId $script:OldT } | Should Throw 'not the approved tunnel'
        { Assert-CloudflareDeploymentBinding -Plan $route -DeploymentPlan (New-Deployment -Manifest (New-Manifest -Id 'ferry-tracker' -Port 9999 -Routes $script:FerryRoutes)) -ApprovedTunnelId $script:T } | Should Throw 'not the manifest upstream'
        { Assert-CloudflareDeploymentBinding -Plan $route -DeploymentPlan (New-Deployment -Manifest (New-Manifest -Id 'site-dock' -Port 8787 -Routes $script:FerryRoutes)) -ApprovedTunnelId $script:T } | Should Throw "deployment app 'site-dock'"
        { Assert-CloudflareDeploymentBinding -Plan $route -DeploymentPlan (New-Deployment -Manifest (New-Manifest -Id 'ferry-tracker' -Port 8787 -Routes @($script:FerryRoutes[0]))) -ApprovedTunnelId $script:T } | Should Throw 'hostnames'
        $route.Hostnames = @('ferry.jimlertech.com')
        { Assert-CloudflareDeploymentBinding -Plan $route -DeploymentPlan $d -ApprovedTunnelId $script:T } | Should Throw 'Plan hash does not match'
    }
    It 'binds each registered host on its own and rejects a plan made for the other host' {
        $m = New-Manifest
        foreach ($h in 'jimbrownhome', 'jimbrownhome1') {
            $d = New-Deployment -Target $h -Manifest $m
            $tg = Get-CloudflareRouteTarget -DeploymentPlan $d
            ($tg.Host, $tg.Address, $tg.HostIdentity, $tg.RouteProfile) -join '|' | Should Be (($h, $script:Hosts[$h].address, $script:Uuid[$h], $h) -join '|')
            $p = Get-Plan (New-FakeCloudflare) $m @{ Target = $tg }
            $p.Target.Host | Should Be $h
            (Assert-CloudflareDeploymentBinding -Plan $p -DeploymentPlan $d -ApprovedTunnelId $script:T).Target.Host | Should Be $h
            $other = if ($h -eq 'jimbrownhome') { 'jimbrownhome1' } else { 'jimbrownhome' }
            { Assert-CloudflareDeploymentBinding -Plan $p -DeploymentPlan (New-Deployment -Target $other -Manifest $m) -ApprovedTunnelId $script:T } | Should Throw 'is not the deployment target'
        }
    }
    It 'rejects host identity, address, and route profile drift between the plan and the deployment' {
        $m = New-Manifest
        $p = Get-Plan (New-FakeCloudflare) $m
        $d = New-Deployment -Manifest $m; $d.hostSnapshot.identity = '4C4C4544-0000-1000-8000-0000000000FF'
        { Assert-CloudflareDeploymentBinding -Plan $p -DeploymentPlan $d -ApprovedTunnelId $script:T } | Should Throw 'HostIdentity'
        $d = New-Deployment -Manifest $m; $d.hostSnapshot.verified = $false
        { Assert-CloudflareDeploymentBinding -Plan $p -DeploymentPlan $d -ApprovedTunnelId $script:T } | Should Throw 'not verified'
        $d = New-Deployment -Manifest $m; $d.target.routeProfile = 'jimbrownhome'
        { Assert-CloudflareDeploymentBinding -Plan $p -DeploymentPlan $d -ApprovedTunnelId $script:T } | Should Throw 'routeProfile differs from the registered host'
        $d = New-Deployment -Manifest $m; $d.target.address = '192.168.2.99'
        { Assert-CloudflareDeploymentBinding -Plan $p -DeploymentPlan $d -ApprovedTunnelId $script:T } | Should Throw 'address differs from the registered host'
        $d = New-Deployment -Manifest $m; $d.schemaVersion = 1
        { Assert-CloudflareDeploymentBinding -Plan $p -DeploymentPlan $d -ApprovedTunnelId $script:T } | Should Throw 'schema 2'
    }
    It 'blocks a plan whose target is incomplete and rejects schema 1 or edited targets' {
        $m = New-Manifest
        $p = Get-Plan (New-FakeCloudflare) $m @{ Target = @{ Host = 'jimbrownhome1'; Address = '192.168.2.14'; HostIdentity = ''; RouteProfile = 'jimbrownhome1' } }
        $p.Status | Should Be 'Blocked'
        ($p.Blockers -join '|') | Should Match 'host identity'
        $ok = Get-Plan (New-FakeCloudflare) $m
        $old = Get-RoundTrip $ok; $old.SchemaVersion = 1; $old.Remove('Target'); $old.PlanHash = & (Get-Module Cloudflare) { param($x) Get-CfPlanHash $x } $old
        { Assert-CloudflareRoutePlan -Plan $old } | Should Throw 'schema 2'
        $edit = Get-RoundTrip $ok; $edit.Target.TunnelId = $script:OldT; $edit.PlanHash = & (Get-Module Cloudflare) { param($x) Get-CfPlanHash $x } $edit
        { Assert-CloudflareRoutePlan -Plan $edit } | Should Throw 'does not match the plan tunnel'
        $edit = Get-RoundTrip $ok; $edit.Target.Origin = 'http://127.0.0.1:1'; $edit.PlanHash = & (Get-Module Cloudflare) { param($x) Get-CfPlanHash $x } $edit
        { Assert-CloudflareRoutePlan -Plan $edit } | Should Throw 'does not match the plan tunnel and origin'
    }
}
