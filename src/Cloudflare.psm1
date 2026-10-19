#Requires -Version 7.0
<#
    Cloudflare route transitions for SolutionDeploy.

    Scope is deliberately narrow: exact-host Access applications, the Ferry /api/catch bypass,
    owned ingress rules on one destination tunnel, and proxied CNAMEs to that tunnel. Nothing here
    deletes, renames, or edits a Cloudflare object it did not plan from a hashed snapshot.

    Every API call goes through an injectable transport scriptblock so tests never touch the network.
    Transport contract: param([hashtable] $Request) where $Request has Method, Path, Body (object or
    $null), BodyJson (canonical string or $null), and Token (plain string). It returns the Cloudflare
    response envelope (success, errors, result, result_info) as a hashtable or PSCustomObject.
#>

Set-StrictMode -Version Latest

$script:ZoneName = 'jimlertech.com'
$script:FerryAppId = 'ferry-tracker'
$script:CatchPath = '/api/catch'
$script:TerminalService = 'http_status:404'
$script:CatchTokenHeader = 'X-Ferry-Token'
$script:CatchProbeQuery = 'departingTerminalId=7&arrivingTerminalId=3'
$script:CatchRefusal = @{ Status = 401; Error = 'Unauthorized.' }
$script:MicrosoftIdpType = 'azureAD'
$script:OwnedPrefix = 'SolutionDeploy'
# Mirrors ferry_tracker\deploy\Setup-Cloudflare.ps1 (free plan: 10 s period, ip.src + cf.colo.id).
$script:CatchRateRule = @{
    Ref               = 'ferry_tracker_catch_ratelimit'
    Expression        = '(starts_with(http.request.uri.path, "/api/catch"))'
    Action            = 'block'
    Period            = 10
    RequestsPerPeriod = 5
    MitigationTimeout = 10
    Characteristics   = @('cf.colo.id', 'ip.src')
}
$script:EvidenceMaxAgeMinutes = 60
$script:Limitations = @(
    'Cloudflare offers no conditional (If-Match) writes for tunnel configuration, DNS records, or Access objects. Drift is detected by re-reading the affected region immediately before each write and by read-back after it; a concurrent edit landing between that read and the write is not prevented.'
    'Tunnel ingress is only writable as a whole configuration (PUT). The write copies every non-ingress key and every foreign ingress rule verbatim from the snapshot, adds only owned exact-host rules before the terminal rule, and verifies the read-back.'
    'Local runs are serialized per tunnel with a named mutex. Dashboard or other-machine edits are not serialized.'
    'No automatic rollback. The journal holds the prior state of every region before its write so a reviewed manual rollback is possible.'
    'Catch token enforcement is proven by a loopback origin probe (GET /api/catch, no and wrong X-Ferry-Token, exact 401 Unauthorized.). Plan evidence is caller-supplied; -Execute re-probes live before any write and cannot prove the configured token is the one the watch uses. The rate limit rule is proven from the snapshot and re-read before routing.'
)

# ------------------------------------------------------------------ canonical data and hashing

function ConvertTo-CfData {
    param($InputObject)
    if ($null -eq $InputObject) { return $null }
    if ($InputObject -is [string] -or $InputObject -is [ValueType]) { return $InputObject }
    $json = ConvertTo-Json -InputObject $InputObject -Depth 64 -Compress
    return ConvertFrom-Json -InputObject $json -AsHashtable -Depth 64 -NoEnumerate -DateKind String
}

function ConvertTo-CanonicalJson {
    param($InputObject)
    $sb = [System.Text.StringBuilder]::new()
    Add-CanonicalJson -Builder $sb -Value $InputObject
    return $sb.ToString()
}

function Add-CanonicalJson {
    param([System.Text.StringBuilder] $Builder, $Value)
    if ($null -eq $Value) { [void]$Builder.Append('null'); return }
    if ($Value -is [bool]) { [void]$Builder.Append($(if ($Value) { 'true' } else { 'false' })); return }
    if ($Value -is [string] -or $Value -is [char] -or $Value -is [datetime] -or $Value -is [guid]) {
        $s = if ($Value -is [datetime]) { $Value.ToUniversalTime().ToString('o') } else { [string]$Value }
        [void]$Builder.Append((ConvertTo-Json -InputObject $s -Compress)); return
    }
    if ($Value -is [System.Collections.IDictionary]) {
        [void]$Builder.Append('{')
        $first = $true
        foreach ($k in ($Value.Keys | ForEach-Object { [string]$_ } | Sort-Object -CaseSensitive)) {
            if (-not $first) { [void]$Builder.Append(',') }
            $first = $false
            [void]$Builder.Append((ConvertTo-Json -InputObject $k -Compress)).Append(':')
            Add-CanonicalJson -Builder $Builder -Value $Value[$k]
        }
        [void]$Builder.Append('}'); return
    }
    if ($Value -is [System.Management.Automation.PSCustomObject]) {
        Add-CanonicalJson -Builder $Builder -Value (ConvertTo-CfData $Value); return
    }
    if ($Value -is [System.Collections.IEnumerable]) {
        [void]$Builder.Append('[')
        $first = $true
        foreach ($item in $Value) {
            if (-not $first) { [void]$Builder.Append(',') }
            $first = $false
            Add-CanonicalJson -Builder $Builder -Value $item
        }
        [void]$Builder.Append(']'); return
    }
    [void]$Builder.Append((ConvertTo-Json -InputObject $Value -Compress))
}

function Get-CfHash {
    param($InputObject)
    $bytes = [System.Text.Encoding]::UTF8.GetBytes((ConvertTo-CanonicalJson $InputObject))
    return [Convert]::ToHexString([System.Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
}

function Get-CfValue {
    param($Map, [string] $Key, $Default = $null)
    if ($Map -is [System.Collections.IDictionary] -and $Map.Contains($Key)) { return $Map[$Key] }
    return $Default
}

# ------------------------------------------------------------------ token and transport

function Resolve-CfToken {
    param([securestring] $Token, [string] $TokenEnvironmentVariable)
    if ($Token) { $plain = [System.Net.NetworkCredential]::new('', $Token).Password }
    elseif ($TokenEnvironmentVariable) {
        if ($TokenEnvironmentVariable -cnotmatch '^CLOUDFLARE_[A-Z0-9_]+$') {
            throw "Token environment variable '$TokenEnvironmentVariable' is not an approved CLOUDFLARE_* reference."
        }
        $plain = [Environment]::GetEnvironmentVariable($TokenEnvironmentVariable)
    }
    else { throw 'A Cloudflare token reference is required: -Token or -TokenEnvironmentVariable.' }
    $plain = "$plain".Trim()
    if ([string]::IsNullOrWhiteSpace($plain)) { throw 'The Cloudflare token reference resolved to an empty value.' }
    return $plain
}

$script:DefaultTransport = {
    param([hashtable] $Request)
    $params = @{
        Method             = $Request.Method
        Uri                = "https://api.cloudflare.com/client/v4$($Request.Path)"
        Headers            = @{ Authorization = "Bearer $($Request.Token)" }
        ContentType        = 'application/json'
        SkipHttpErrorCheck = $true
    }
    if ($null -ne $Request.BodyJson) { $params.Body = $Request.BodyJson }
    return Invoke-RestMethod @params
}

function Invoke-CfRequest {
    param(
        [Parameter(Mandatory)][hashtable] $Context,
        [Parameter(Mandatory)][ValidateSet('GET', 'POST', 'PUT', 'PATCH')][string] $Method,
        [Parameter(Mandatory)][string] $Path,
        $Body,
        [switch] $Envelope
    )
    if ($Context.ReadOnly -and $Method -ne 'GET') { throw "Read-only context refused $Method $Path." }
    $request = @{
        Method   = $Method
        Path     = $Path
        Body     = $Body
        BodyJson = $(if ($null -ne $Body) { ConvertTo-CanonicalJson $Body } else { $null })
        Token    = $Context.Token
    }
    $response = ConvertTo-CfData (& $Context.Transport $request)
    if ($response -isnot [System.Collections.IDictionary] -or -not (Get-CfValue $response 'success' $false)) {
        $errors = Get-CfValue $response 'errors' @()
        $text = @($errors | ForEach-Object {
                if ($_ -is [System.Collections.IDictionary]) { "$(Get-CfValue $_ 'code' ''): $(Get-CfValue $_ 'message' '')" } else { "$_" }
            }) -join ' | '
        throw "Cloudflare $Method $Path failed. $text"
    }
    if ($Envelope) { return $response }
    return , (Get-CfValue $response 'result')
}

function Get-CfAll {
    param([hashtable] $Context, [string] $Path)
    $items = [System.Collections.Generic.List[object]]::new()
    $page = 1
    while ($true) {
        $sep = if ($Path.Contains('?')) { '&' } else { '?' }
        $resp = Invoke-CfRequest -Context $Context -Method GET -Path "$Path${sep}page=$page&per_page=50" -Envelope
        foreach ($i in @(Get-CfValue $resp 'result' @())) { if ($null -ne $i) { $items.Add($i) } }
        $info = Get-CfValue $resp 'result_info'
        $total = [int](Get-CfValue $info 'total_pages' 1)
        if ($page -ge $total -or $page -ge 100) { break }
        $page++
    }
    return $items.ToArray()
}

function New-CfContext {
    param([securestring] $Token, [string] $TokenEnvironmentVariable, [scriptblock] $Transport, [switch] $ReadOnly)
    return @{
        Token     = (Resolve-CfToken -Token $Token -TokenEnvironmentVariable $TokenEnvironmentVariable)
        Transport = $(if ($Transport) { $Transport } else { $script:DefaultTransport })
        ReadOnly  = [bool]$ReadOnly
    }
}

# ------------------------------------------------------------------ projections (drop volatile fields)

function Select-CfKeys {
    param($Map, [string[]] $Keys)
    $out = [ordered]@{}
    foreach ($k in $Keys) { if ($Map -is [System.Collections.IDictionary] -and $Map.Contains($k)) { $out[$k] = $Map[$k] } }
    return $out
}

function Get-CfPolicyProjection {
    param($Policy)
    return Select-CfKeys $Policy @('id', 'name', 'decision', 'include', 'exclude', 'require', 'precedence')
}

function Get-CfAppProjection {
    param($App)
    $p = Select-CfKeys $App @('id', 'name', 'domain', 'type', 'self_hosted_domains', 'destinations', 'allowed_idps', 'auto_redirect_to_identity')
    $p['policies'] = if ($App.Contains('policies') -and $null -ne $App['policies']) {
        @($App['policies'] | ForEach-Object { if ($_ -is [System.Collections.IDictionary]) { Get-CfPolicyProjection $_ } else { @{ id = "$_" } } })
    }
    else { $null }
    return $p
}

function Get-CfAppDomains {
    param($App)
    $domains = [System.Collections.Generic.List[string]]::new()
    $d = Get-CfValue $App 'domain'
    if ($d) { $domains.Add(([string]$d).ToLowerInvariant()) }
    foreach ($x in @(Get-CfValue $App 'self_hosted_domains' @())) { if ($x) { $domains.Add(([string]$x).ToLowerInvariant()) } }
    foreach ($x in @(Get-CfValue $App 'destinations' @())) {
        $uri = Get-CfValue $x 'uri'
        if ($uri) { $domains.Add(([string]$uri).ToLowerInvariant()) }
    }
    return , @($domains | Select-Object -Unique)
}

function Test-CfDomainCoversHost {
    <# True when an Access domain entry (host or host/path, possibly wildcard) applies to $HostName. #>
    param([string] $Domain, [string] $HostName)
    $hostPart = ($Domain -split '/', 2)[0]
    if ($hostPart -eq $HostName) { return $true }
    if ($hostPart.StartsWith('*.')) { return $HostName.EndsWith($hostPart.Substring(1)) }
    return $false
}

function Find-CfAppsWithDomain {
    param([object[]] $Apps, [string] $Domain)
    return , @($Apps | Where-Object { (Get-CfAppDomains $_) -contains $Domain } | Sort-Object { Get-CfValue $_ 'id' })
}

# ------------------------------------------------------------------ evidence tests (exported)

function Test-CloudflareAccessPolicy {
    <#
    .SYNOPSIS
        Returns @{ Passed; Reasons } for one Access application as read from Cloudflare.
        Restrictive means: exactly one domain equal to -Domain, self_hosted, allowed_idps exactly
        the Microsoft provider, at least one policy, every policy allow, include only listed
        emails, and require login_method = that provider.
    #>
    param(
        [Parameter(Mandatory)] $App,
        [Parameter(Mandatory)][string] $Domain,
        [Parameter(Mandatory)][AllowEmptyString()][string] $IdentityProviderId,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]] $AllowEmails
    )
    $App = ConvertTo-CfData $App
    $reasons = [System.Collections.Generic.List[string]]::new()
    $domains = Get-CfAppDomains $App
    if ($domains.Count -ne 1 -or $domains[0] -ne $Domain.ToLowerInvariant()) { $reasons.Add("domains [$($domains -join ', ')] are not exactly $Domain") }
    if ((Get-CfValue $App 'type') -ne 'self_hosted') { $reasons.Add("type '$(Get-CfValue $App 'type')' is not self_hosted") }
    $idps = @(Get-CfValue $App 'allowed_idps' @())
    if ($idps.Count -ne 1 -or $idps[0] -ne $IdentityProviderId) { $reasons.Add("allowed_idps [$($idps -join ', ')] is not exactly [$IdentityProviderId]") }
    $policies = Get-CfValue $App 'policies'
    if ($null -eq $policies -or @($policies).Count -eq 0) { $reasons.Add('no policies are attached, or they were not returned') }
    $allowed = @($AllowEmails | ForEach-Object { $_.ToLowerInvariant() })
    foreach ($p in @($policies)) {
        if ($null -eq $p) { continue }
        $name = Get-CfValue $p 'name' (Get-CfValue $p 'id' '?')
        if ((Get-CfValue $p 'decision') -ne 'allow') { $reasons.Add("policy '$name' decision '$(Get-CfValue $p 'decision')' is not allow") }
        $include = @(Get-CfValue $p 'include' @())
        if ($include.Count -eq 0) { $reasons.Add("policy '$name' has no include rules") }
        foreach ($rule in $include) {
            $keys = @($rule.Keys)
            if ($keys.Count -ne 1 -or $keys[0] -ne 'email') { $reasons.Add("policy '$name' include rule [$($keys -join ',')] is not a single email"); continue }
            $email = ([string](Get-CfValue $rule['email'] 'email' '')).ToLowerInvariant()
            if ($allowed -notcontains $email) { $reasons.Add("policy '$name' allows unlisted email '$email'") }
        }
        $require = @(Get-CfValue $p 'require' @())
        $login = @($require | Where-Object { $_.Contains('login_method') -and (Get-CfValue $_['login_method'] 'id') -eq $IdentityProviderId })
        if (-not $IdentityProviderId -or $login.Count -eq 0) { $reasons.Add("policy '$name' does not require login_method $IdentityProviderId") }
    }
    return @{ Passed = ($reasons.Count -eq 0); Reasons = @($reasons) }
}

function Test-CloudflareCatchBypass {
    <# The catch app must be path-exact and carry exactly one bypass policy whose include is everyone. #>
    param([Parameter(Mandatory)] $App, [Parameter(Mandatory)][string] $HostName)
    $App = ConvertTo-CfData $App
    $reasons = [System.Collections.Generic.List[string]]::new()
    $domain = "$HostName$($script:CatchPath)"
    $domains = Get-CfAppDomains $App
    if ($domains.Count -ne 1 -or $domains[0] -ne $domain) { $reasons.Add("domains [$($domains -join ', ')] are not exactly $domain") }
    if ((Get-CfValue $App 'type') -ne 'self_hosted') { $reasons.Add('type is not self_hosted') }
    $policies = @(Get-CfValue $App 'policies' @())
    if ($policies.Count -ne 1) { $reasons.Add("expected exactly 1 policy, found $($policies.Count)") }
    foreach ($p in $policies) {
        if ((Get-CfValue $p 'decision') -ne 'bypass') { $reasons.Add('policy decision is not bypass') }
        $inc = @(Get-CfValue $p 'include' @())
        if ($inc.Count -ne 1 -or (@($inc[0].Keys) -join ',') -ne 'everyone') { $reasons.Add('bypass include is not exactly everyone') }
    }
    return @{ Passed = ($reasons.Count -eq 0); Reasons = @($reasons) }
}

function Test-CloudflareCatchRateRule {
    <# Checks a zone http_ratelimit ruleset (snapshot projection) for the exact Ferry catch rule. #>
    param([Parameter(Mandatory)] $Ruleset)
    $Ruleset = ConvertTo-CfData $Ruleset
    $want = $script:CatchRateRule
    $rules = @(@(Get-CfValue $Ruleset 'rules' @()) | Where-Object { (Get-CfValue $_ 'ref') -eq $want.Ref })
    if ($rules.Count -ne 1) { return @{ Passed = $false; Reasons = @("expected 1 rule with ref $($want.Ref), found $($rules.Count)") } }
    $r = $rules[0]
    $reasons = [System.Collections.Generic.List[string]]::new()
    if ((Get-CfValue $r 'enabled' $true) -ne $true) { $reasons.Add('rule is disabled') }
    if ((Get-CfValue $r 'expression') -ne $want.Expression) { $reasons.Add("expression '$(Get-CfValue $r 'expression')' differs") }
    if ((Get-CfValue $r 'action') -ne $want.Action) { $reasons.Add('action is not block') }
    $rl = Get-CfValue $r 'ratelimit' @{}
    if ([int](Get-CfValue $rl 'period' 0) -ne $want.Period) { $reasons.Add('period differs') }
    if ([int](Get-CfValue $rl 'requests_per_period' 0) -ne $want.RequestsPerPeriod) { $reasons.Add('requests_per_period differs') }
    if ([int](Get-CfValue $rl 'mitigation_timeout' 0) -ne $want.MitigationTimeout) { $reasons.Add('mitigation_timeout differs') }
    $ch = @(@(Get-CfValue $rl 'characteristics' @()) | Sort-Object)
    if (($ch -join ',') -ne ($want.Characteristics -join ',')) { $reasons.Add('characteristics differ') }
    return @{ Passed = ($reasons.Count -eq 0); Reasons = @($reasons) }
}

function Get-CfEvidenceHash {
    param([System.Collections.IDictionary] $Evidence)
    $copy = [ordered]@{}
    foreach ($k in $Evidence.Keys) { if ($k -ne 'EvidenceHash') { $copy[$k] = $Evidence[$k] } }
    return Get-CfHash $copy
}

function Test-CfCatchRefusal {
    param($Response)
    $status = [int](Get-CfValue $Response 'StatusCode' 0)
    $err = $null
    try { $err = Get-CfValue (ConvertFrom-Json ([string](Get-CfValue $Response 'Body' '')) -AsHashtable) 'error' $null } catch { $err = $null }
    return [ordered]@{ Status = $status; Error = $err; Refused = ($status -eq $script:CatchRefusal.Status -and $err -ceq $script:CatchRefusal.Error) }
}

function Test-CloudflareCatchTokenEnforcement {
    <#
    .SYNOPSIS
        Probes Ferry's loopback origin directly (never the public host, so Cloudflare Access
        cannot answer for it) with GET /api/catch and a valid terminal pair, once with no
        X-Ferry-Token and once with a random 64-hex wrong token. ferry_tracker server/src/app.ts
        checks the token before the query, so only an exact 401 {"error":"Unauthorized."} counts.
        404 means the token is unset (route off), 400 means the token check did not run first,
        and 3xx/403 means something other than Ferry answered. -Probe is injectable:
        param([hashtable] $Request) with Method, Uri, Headers; returns @{ StatusCode; Body }.
    #>
    param(
        [Parameter(Mandatory)][string] $Origin,
        [scriptblock] $Probe
    )
    if ($Origin -notmatch '^http://127\.0\.0\.1:\d+$') { throw "Catch probe origin must be http://127.0.0.1:<port>, got '$Origin'." }
    if (-not $Probe) {
        $Probe = {
            param([hashtable] $Request)
            $r = Invoke-WebRequest -Method $Request.Method -Uri $Request.Uri -Headers $Request.Headers -SkipHttpErrorCheck -MaximumRedirection 0 -TimeoutSec 10
            @{ StatusCode = [int]$r.StatusCode; Body = [string]$r.Content }
        }
    }
    $uri = "$Origin$($script:CatchPath)?$($script:CatchProbeQuery)"
    $wrong = [Convert]::ToHexString([System.Security.Cryptography.RandomNumberGenerator]::GetBytes(32)).ToLowerInvariant()
    $none = Test-CfCatchRefusal (& $Probe @{ Method = 'GET'; Uri = $uri; Headers = @{} })
    $bad = Test-CfCatchRefusal (& $Probe @{ Method = 'GET'; Uri = $uri; Headers = @{ $script:CatchTokenHeader = $wrong } })
    $evidence = [ordered]@{
        Kind             = 'CatchTokenProbe'
        Origin           = $Origin
        Path             = $script:CatchPath
        Query            = $script:CatchProbeQuery
        TokenHeaderName  = $script:CatchTokenHeader
        NoTokenStatus    = $none.Status
        NoTokenError     = $none.Error
        WrongTokenStatus = $bad.Status
        WrongTokenError  = $bad.Error
        # Whole seconds: ConvertFrom-Json turns ISO strings into DateTime and ConvertTo-Json drops
        # trailing fractional zeros, so a 7-digit 'o' stamp changes the plan hash after a JSON round trip.
        ObservedAtUtc    = [datetime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ', [cultureinfo]::InvariantCulture)
        Passed           = ($none.Refused -and $bad.Refused)
    }
    $evidence['EvidenceHash'] = Get-CfEvidenceHash $evidence
    return $evidence
}

function Test-CfCatchEvidence {
    param($Evidence, [string] $Service)
    if ((Get-CfValue $Evidence 'Kind') -ne 'CatchTokenProbe' -or (Get-CfEvidenceHash $Evidence) -ne (Get-CfValue $Evidence 'EvidenceHash')) { return 'catch token evidence is not an intact probe record' }
    if ($Evidence.Origin -ne $Service -or $Evidence.Path -ne $script:CatchPath -or (Get-CfValue $Evidence 'Query') -ne $script:CatchProbeQuery -or (Get-CfValue $Evidence 'TokenHeaderName') -ne $script:CatchTokenHeader) { return "catch token evidence was taken against $($Evidence.Origin)$($Evidence.Path), not $Service$($script:CatchPath) with $($script:CatchTokenHeader)" }
    foreach ($k in 'NoToken', 'WrongToken') {
        if ([int](Get-CfValue $Evidence "${k}Status" 0) -ne $script:CatchRefusal.Status -or (Get-CfValue $Evidence "${k}Error" $null) -cne $script:CatchRefusal.Error) { return "catch endpoint answered $($Evidence.NoTokenStatus)/$($Evidence.WrongTokenStatus) without a valid token; only 401 Unauthorized. counts" }
    }
    return $null
}

# ------------------------------------------------------------------ snapshot

function Read-CfAccessApps {
    param([hashtable] $Context, [string] $AccountId)
    return , @(Get-CfAll -Context $Context -Path "/accounts/$AccountId/access/apps" | ForEach-Object { Get-CfAppProjection $_ } | Sort-Object { $_['id'] })
}

function Read-CfDns {
    param([hashtable] $Context, [string] $ZoneId, [string] $HostName)
    $records = Get-CfAll -Context $Context -Path "/zones/$ZoneId/dns_records?name=$HostName"
    return , @($records | Where-Object { ([string](Get-CfValue $_ 'name')).ToLowerInvariant() -eq $HostName } |
            ForEach-Object { Select-CfKeys $_ @('id', 'type', 'name', 'content', 'proxied', 'comment') } | Sort-Object { $_['id'] })
}

function Read-CfTunnelConfig {
    param([hashtable] $Context, [string] $AccountId, [string] $TunnelId)
    $r = Invoke-CfRequest -Context $Context -Method GET -Path "/accounts/$AccountId/cfd_tunnel/$TunnelId/configurations"
    $cfg = Get-CfValue $r 'config'
    return [ordered]@{ config = $(if ($null -eq $cfg) { [ordered]@{} } else { $cfg }); version = (Get-CfValue $r 'version') }
}

function Read-CfRateRuleset {
    param([hashtable] $Context, [string] $ZoneId)
    $sets = @(Get-CfAll -Context $Context -Path "/zones/$ZoneId/rulesets" | Where-Object { (Get-CfValue $_ 'phase') -eq 'http_ratelimit' -and (Get-CfValue $_ 'kind') -eq 'zone' })
    if ($sets.Count -eq 0) { return $null }
    $d = Invoke-CfRequest -Context $Context -Method GET -Path "/zones/$ZoneId/rulesets/$($sets[0]['id'])"
    $out = Select-CfKeys $d @('id', 'version', 'phase', 'kind')
    $out['rules'] = @(@(Get-CfValue $d 'rules' @()) | ForEach-Object { Select-CfKeys $_ @('id', 'ref', 'expression', 'action', 'enabled', 'ratelimit') })
    return $out
}

function Get-CfSnapshotHash {
    param([System.Collections.IDictionary] $Snapshot)
    $copy = [ordered]@{}
    foreach ($k in $Snapshot.Keys) { if ($k -notin 'SnapshotHash', 'CapturedAtUtc') { $copy[$k] = $Snapshot[$k] } }
    return Get-CfHash $copy
}

function Get-CloudflareSnapshot {
    <#
    .SYNOPSIS
        Read-only, hashed snapshot of every Cloudflare region a route plan depends on. The request
        context refuses any method other than GET.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $AccountId,
        [Parameter(Mandatory)][string] $ZoneId,
        [Parameter(Mandatory)][string] $TunnelId,
        [Parameter(Mandatory)][string[]] $Hostname,
        [securestring] $Token,
        [string] $TokenEnvironmentVariable,
        [scriptblock] $Transport
    )
    $ctx = New-CfContext -Token $Token -TokenEnvironmentVariable $TokenEnvironmentVariable -Transport $Transport -ReadOnly
    $hosts = @($Hostname | ForEach-Object { $_.ToLowerInvariant() } | Sort-Object -Unique)
    $zone = Invoke-CfRequest -Context $ctx -Method GET -Path "/zones/$ZoneId"
    $tunnel = Invoke-CfRequest -Context $ctx -Method GET -Path "/accounts/$AccountId/cfd_tunnel/$TunnelId"
    $dns = [ordered]@{}
    foreach ($h in $hosts) { $dns[$h] = Read-CfDns -Context $ctx -ZoneId $ZoneId -HostName $h }
    $snapshot = [ordered]@{
        SchemaVersion       = 1
        Kind                = 'SolutionDeploy.CloudflareSnapshot'
        AccountId           = $AccountId
        ZoneId              = $ZoneId
        TunnelId            = $TunnelId
        Hostnames           = $hosts
        Zone                = [ordered]@{ id = (Get-CfValue $zone 'id'); name = (Get-CfValue $zone 'name'); status = (Get-CfValue $zone 'status'); accountId = (Get-CfValue (Get-CfValue $zone 'account' @{}) 'id') }
        Tunnel              = (Select-CfKeys $tunnel @('id', 'name', 'account_tag', 'config_src', 'remote_config', 'deleted_at'))
        TunnelConfiguration = (Read-CfTunnelConfig -Context $ctx -AccountId $AccountId -TunnelId $TunnelId)
        Dns                 = $dns
        AccessApps          = (Read-CfAccessApps -Context $ctx -AccountId $AccountId)
        AccessPolicies      = @(Get-CfAll -Context $ctx -Path "/accounts/$AccountId/access/policies" | ForEach-Object { Get-CfPolicyProjection $_ } | Sort-Object { $_['id'] })
        IdentityProviders   = @(Get-CfAll -Context $ctx -Path "/accounts/$AccountId/access/identity_providers" | ForEach-Object { Select-CfKeys $_ @('id', 'name', 'type') } | Sort-Object { $_['id'] })
        RateLimitRuleset    = (Read-CfRateRuleset -Context $ctx -ZoneId $ZoneId)
    }
    $snapshot = ConvertTo-CfData $snapshot
    $snapshot['SnapshotHash'] = Get-CfSnapshotHash $snapshot
    $snapshot['CapturedAtUtc'] = [datetime]::UtcNow.ToString('o')
    return $snapshot
}

# ------------------------------------------------------------------ plan

function Get-CfIngressMatch {
    <# Non-terminal ingress rules that would take traffic for $HostName (exact or wildcard host). #>
    param([object[]] $Rules, [string] $HostName)
    return , @($Rules | Where-Object {
            $h = ([string](Get-CfValue $_ 'hostname' '')).ToLowerInvariant()
            $h -and ($h -eq $HostName -or ($h.StartsWith('*') -and $HostName.EndsWith($h.TrimStart('*'))))
        })
}

function New-CloudflareRoutePlan {
    <#
    .SYNOPSIS
        Builds a hashed, gated plan from an application manifest and a Get-CloudflareSnapshot
        result. Makes no API calls. Status is Ready, NoChange, or Blocked with reasons.
    .PARAMETER Access
        @{ IdentityProviderId = '<Microsoft Entra ID provider id>'; AllowEmails = @('...') }
    .PARAMETER CatchTokenEvidence
        Output of Test-CloudflareCatchTokenEnforcement against this app's origin (Ferry only).
    .PARAMETER AllowDnsRepoint
        Hostnames whose existing proxied CNAME to another tunnel may move to this tunnel.
    .PARAMETER TunnelName
        Expected destination tunnel name; checked against the snapshot when given.
    .PARAMETER Target
        The selected registered host from the deployment plan (use Get-CloudflareRouteTarget):
        @{ Host; Address; HostIdentity; RouteProfile }. It is hashed into the plan with the explicit
        -TunnelId and the loopback origin. The tunnel is never inferred from a host or profile name.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable] $Manifest,
        [Parameter(Mandatory)][System.Collections.IDictionary] $Current,
        [Parameter(Mandatory)][string] $TunnelId,
        [Parameter(Mandatory)][string] $ZoneId,
        [Parameter(Mandatory)][string] $AccountId,
        [Parameter(Mandatory)][hashtable] $Access,
        [Parameter(Mandatory)][System.Collections.IDictionary] $Target,
        [System.Collections.IDictionary] $CatchTokenEvidence,
        [string[]] $AllowDnsRepoint = @(),
        [string] $TunnelName
    )
    $m = ConvertTo-CfData $Manifest
    $snap = ConvertTo-CfData $Current
    $blockers = [System.Collections.Generic.List[string]]::new()
    $findings = [System.Collections.Generic.List[string]]::new()
    $ops = [System.Collections.Generic.List[object]]::new()

    $appId = [string](Get-CfValue $m 'id')
    $port = Get-CfValue (Get-CfValue $m 'launch' @{}) 'port'
    $service = "http://127.0.0.1:$port"
    $routes = @(Get-CfValue $m 'routes' @())
    $hosts = @($routes | ForEach-Object { ([string](Get-CfValue $_ 'hostname')).ToLowerInvariant() })
    $idpId = [string](Get-CfValue $Access 'IdentityProviderId' '')
    $emails = @(@(Get-CfValue $Access 'AllowEmails' @()) | ForEach-Object { ([string]$_).ToLowerInvariant() } | Sort-Object -Unique)
    $repoint = @($AllowDnsRepoint | ForEach-Object { $_.ToLowerInvariant() })
    $tg = ConvertTo-CfData $Target
    $targetRecord = [ordered]@{
        Host         = [string](Get-CfValue $tg 'Host' '')
        Address      = [string](Get-CfValue $tg 'Address' '')
        HostIdentity = [string](Get-CfValue $tg 'HostIdentity' '')
        RouteProfile = [string](Get-CfValue $tg 'RouteProfile' '')
        TunnelId     = $TunnelId
        Origin       = $service
    }

    # ---- snapshot integrity and ownership ids
    if ((Get-CfValue $snap 'Kind') -ne 'SolutionDeploy.CloudflareSnapshot') { throw 'Current is not a Get-CloudflareSnapshot result.' }
    $snapHash = Get-CfSnapshotHash $snap
    if ($snapHash -ne (Get-CfValue $snap 'SnapshotHash')) { throw 'Current snapshot hash does not match its content.' }
    if ($appId -notmatch '^[a-z][a-z0-9-]{1,39}$') { $blockers.Add("manifest id '$appId' is invalid") }
    if (-not ($port -is [int] -or $port -is [long]) -or $port -lt 1024 -or $port -gt 65535) { $blockers.Add('manifest launch.port is missing or out of range') }
    if ($hosts.Count -eq 0) { $blockers.Add('manifest declares no routes') }
    if (@($hosts | Select-Object -Unique).Count -ne $hosts.Count) { $blockers.Add('manifest repeats a hostname') }
    foreach ($h in $hosts) { if ($h -notmatch '^[a-z0-9-]+\.jimlertech\.com$') { $blockers.Add("hostname '$h' is not an exact jimlertech.com host") } }
    $targetProblem = Test-CfTarget $targetRecord
    if ($targetProblem) { $blockers.Add($targetProblem) }
    if ($snap.AccountId -ne $AccountId -or $snap.ZoneId -ne $ZoneId -or $snap.TunnelId -ne $TunnelId) { $blockers.Add('snapshot was taken for different account/zone/tunnel ids') }
    if ($snap.Zone.id -ne $ZoneId -or $snap.Zone.name -ne $script:ZoneName -or $snap.Zone.accountId -ne $AccountId) { $blockers.Add("zone $ZoneId is not $($script:ZoneName) in account $AccountId") }
    if ((Get-CfValue $snap.Tunnel 'id') -ne $TunnelId -or $null -ne (Get-CfValue $snap.Tunnel 'deleted_at') -or (Get-CfValue $snap.Tunnel 'account_tag') -ne $AccountId) { $blockers.Add("tunnel $TunnelId is missing, deleted, or in another account") }
    if (-not (Get-CfValue $snap.Tunnel 'remote_config' $false) -and (Get-CfValue $snap.Tunnel 'config_src') -ne 'cloudflare') { $blockers.Add('tunnel is locally managed; remote ingress writes would have no effect') }
    if ($TunnelName -and (Get-CfValue $snap.Tunnel 'name') -ne $TunnelName) { $blockers.Add("tunnel name '$(Get-CfValue $snap.Tunnel 'name')' is not the destination tunnel '$TunnelName'") }
    foreach ($h in $hosts) { if (-not $snap.Dns.Contains($h)) { $blockers.Add("snapshot did not read DNS for $h; existence is never assumed") } }

    # ---- Microsoft identity provider, bound to the snapshot
    $idp = @($snap.IdentityProviders | Where-Object { $_.id -eq $idpId })
    if (-not $idpId -or $idp.Count -ne 1) { $blockers.Add("identity provider '$idpId' is not in the snapshot") }
    elseif ($idp[0].type -ne $script:MicrosoftIdpType) { $blockers.Add("identity provider '$idpId' type '$($idp[0].type)' is not Microsoft ($($script:MicrosoftIdpType))") }
    if ($emails.Count -eq 0 -or @($emails | Where-Object { $_ -notmatch '^[^@\s*]+@[^@\s*]+\.[^@\s*]+$' }).Count -gt 0) { $blockers.Add('Access.AllowEmails must list exact email addresses') }

    # ---- catch path: Ferry only, every Ferry host, rate rule + token probe evidence
    $catchHosts = @($routes | Where-Object { Get-CfValue $_ 'catchPath' } | ForEach-Object { ([string]$_['hostname']).ToLowerInvariant() })
    foreach ($r in $routes) { $cp = Get-CfValue $r 'catchPath'; if ($cp -and $cp -ne $script:CatchPath) { $blockers.Add("catchPath '$cp' is not $($script:CatchPath)") } }
    if ($appId -ne $script:FerryAppId -and $catchHosts.Count -gt 0) { $blockers.Add("only $($script:FerryAppId) may declare a catch bypass") }
    if ($appId -eq $script:FerryAppId -and $catchHosts.Count -ne $hosts.Count) { $blockers.Add('every Ferry hostname must declare its own /api/catch exception') }
    $evidenceRecord = $null
    if ($catchHosts.Count -gt 0) {
        $rate = if ($snap.RateLimitRuleset) { Test-CloudflareCatchRateRule $snap.RateLimitRuleset } else { @{ Passed = $false; Reasons = @('no zone http_ratelimit ruleset') } }
        if (-not $rate.Passed) { $blockers.Add("catch rate limit rule not verified: $($rate.Reasons -join '; ')") }
        else { $findings.Add("catch rate limit rule $($script:CatchRateRule.Ref) verified from the snapshot") }
        if (-not $CatchTokenEvidence) { $blockers.Add('catch token enforcement evidence is missing (run Test-CloudflareCatchTokenEnforcement)') }
        else {
            $ev = ConvertTo-CfData $CatchTokenEvidence
            $observed = [datetimeoffset]::MinValue
            [void][datetimeoffset]::TryParse([string](Get-CfValue $ev 'ObservedAtUtc' ''), [ref]$observed)
            $age = [datetimeoffset]::UtcNow - $observed
            $evProblem = Test-CfCatchEvidence -Evidence $ev -Service $service
            if ($evProblem) { $blockers.Add($evProblem) }
            elseif ($age.TotalMinutes -gt $script:EvidenceMaxAgeMinutes -or $age.TotalMinutes -lt -5) { $blockers.Add("catch token evidence is older than $($script:EvidenceMaxAgeMinutes) minutes") }
            else { $evidenceRecord = $ev; $findings.Add("caller-supplied catch probe at $($ev.ObservedAtUtc) shows 401/401; its hash proves only that it was not edited, so -Execute re-probes the loopback origin live before any catch write") }
        }
    }

    $apps = @($snap.AccessApps)

    # ---- Access per host, always ordered before ingress and DNS
    foreach ($h in $hosts) {
        foreach ($a in $apps) {
            foreach ($d in (Get-CfAppDomains $a)) {
                if (-not (Test-CfDomainCoversHost $d $h) -or $d -eq $h -or $d -eq "$h$($script:CatchPath)") { continue }
                if ($d.StartsWith('*.') -and -not $d.Contains('/')) { $findings.Add("wildcard Access app '$(Get-CfValue $a 'name')' ($d) also covers $h; the exact-host app takes precedence"); continue }
                $blockers.Add("Access app '$(Get-CfValue $a 'name')' ($d) scopes a path on $h; it could override the exact-host policy")
            }
        }
        $root = Find-CfAppsWithDomain $apps $h
        $policyName = "$($script:OwnedPrefix) $appId $h"
        if ($root.Count -gt 1) { $blockers.Add("$h has $($root.Count) exact-host Access apps") }
        elseif ($root.Count -eq 1) {
            $t = Test-CloudflareAccessPolicy -App $root[0] -Domain $h -IdentityProviderId $idpId -AllowEmails $emails
            if ($t.Passed) { $findings.Add("Access app $($root[0].id) on $h verified restrictive from the snapshot") }
            else { $blockers.Add("existing Access app $($root[0].id) on $h is not restrictive: $($t.Reasons -join '; ')") }
        }
        else {
            if (@($snap.AccessPolicies | Where-Object { $_.name -eq $policyName }).Count -gt 0) { $blockers.Add("policy '$policyName' already exists unattached (interrupted run?); review before planning") }
            $pre = @{ Region = 'access-root'; Hash = (Get-CfHash @()) }
            $polId = "access-policy:$h"
            $ops.Add([ordered]@{ Id = $polId; Kind = 'AccessPolicyCreate'; Hostname = $h; Method = 'POST'; Path = "/accounts/$AccountId/access/policies"
                    Body = [ordered]@{ name = $policyName; decision = 'allow'; include = @($emails | ForEach-Object { @{ email = @{ email = $_ } } }); exclude = @(); require = @(@{ login_method = @{ id = $idpId } }) }
                    Precondition = $pre })
            $ops.Add([ordered]@{ Id = "access-app:$h"; Kind = 'AccessAppCreate'; Hostname = $h; Method = 'POST'; Path = "/accounts/$AccountId/access/apps"
                    Body = [ordered]@{ name = $policyName; domain = $h; type = 'self_hosted'; session_duration = '24h'; allowed_idps = @($idpId); auto_redirect_to_identity = $true; app_launcher_visible = $true; policies = @(@{ id = "{{op:$polId}}"; precedence = 1 }) }
                    Precondition = $pre })
        }
        if ($catchHosts -contains $h) {
            $catch = Find-CfAppsWithDomain $apps "$h$($script:CatchPath)"
            $catchName = "$($script:OwnedPrefix) $appId $h$($script:CatchPath) bypass"
            if ($catch.Count -gt 1) { $blockers.Add("$h$($script:CatchPath) has $($catch.Count) Access apps") }
            elseif ($catch.Count -eq 1) {
                $t = Test-CloudflareCatchBypass -App $catch[0] -HostName $h
                if ($t.Passed) { $findings.Add("catch bypass $($catch[0].id) on $h$($script:CatchPath) verified from the snapshot") }
                else { $blockers.Add("existing catch app on $h is not an exact bypass: $($t.Reasons -join '; ')") }
            }
            else {
                if (@($snap.AccessPolicies | Where-Object { $_.name -eq $catchName }).Count -gt 0) { $blockers.Add("policy '$catchName' already exists unattached; review before planning") }
                $pre = @{ Region = 'access-catch'; Hash = (Get-CfHash @()) }
                $polId = "catch-policy:$h"
                $ops.Add([ordered]@{ Id = $polId; Kind = 'CatchPolicyCreate'; Hostname = $h; Method = 'POST'; Path = "/accounts/$AccountId/access/policies"
                        Body = [ordered]@{ name = $catchName; decision = 'bypass'; include = @(@{ everyone = @{} }); exclude = @(); require = @() }
                        Precondition = $pre })
                $ops.Add([ordered]@{ Id = "catch-app:$h"; Kind = 'CatchAppCreate'; Hostname = $h; Method = 'POST'; Path = "/accounts/$AccountId/access/apps"
                        Body = [ordered]@{ name = $catchName; domain = "$h$($script:CatchPath)"; type = 'self_hosted'; app_launcher_visible = $false; policies = @(@{ id = "{{op:$polId}}"; precedence = 1 }) }
                        Precondition = $pre })
            }
        }
    }

    # ---- tunnel ingress: keep every foreign rule, add owned exact-host rules before the terminal 404
    $cfg = Get-CfValue $snap.TunnelConfiguration 'config' @{}
    $ingress = @(Get-CfValue $cfg 'ingress' @())
    $terminal = $null
    if ($ingress.Count -gt 0) {
        $last = $ingress[-1]
        if ((Get-CfValue $last 'hostname') -or (Get-CfValue $last 'path') -or (Get-CfValue $last 'service') -ne $script:TerminalService) { $blockers.Add("tunnel terminal ingress rule is not a bare $($script:TerminalService)") }
        else { $terminal = $last }
    }
    $kept = [System.Collections.Generic.List[object]]::new()
    if ($ingress.Count -gt 1) { foreach ($r in $ingress[0..($ingress.Count - 2)]) { $kept.Add($r) } }
    $added = 0
    foreach ($h in $hosts) {
        $match = Get-CfIngressMatch -Rules $kept.ToArray() -HostName $h
        if ($match.Count -eq 0) { $kept.Add([ordered]@{ hostname = $h; service = $service; originRequest = [ordered]@{} }); $added++; continue }
        $exact = @($match | Where-Object { $_.hostname -eq $h -and -not (Get-CfValue $_ 'path') -and $_.service -eq $service })
        if ($match.Count -eq 1 -and $exact.Count -eq 1) { $findings.Add("ingress for $h -> $service already present") }
        else { $blockers.Add("tunnel already has ingress for $h that differs (service, path, or wildcard); refusing to replace it") }
    }
    if ($added -gt 0) {
        $newCfg = [ordered]@{}
        foreach ($k in $cfg.Keys) { if ($k -ne 'ingress') { $newCfg[$k] = $cfg[$k] } }
        $newCfg['ingress'] = @($kept.ToArray()) + @($(if ($terminal) { $terminal } else { [ordered]@{ service = $script:TerminalService } }))
        $ops.Add([ordered]@{ Id = 'tunnel-ingress'; Kind = 'TunnelIngressUpdate'; Hostname = ($hosts -join ','); Method = 'PUT'; Path = "/accounts/$AccountId/cfd_tunnel/$TunnelId/configurations"
                Body = [ordered]@{ config = $newCfg }; Precondition = @{ Region = 'tunnel-config'; Hash = (Get-CfHash $cfg) } })
    }

    # ---- DNS last, exact names only
    $cnameTarget = "$TunnelId.cfargotunnel.com"
    foreach ($h in $hosts) {
        if (-not $snap.Dns.Contains($h)) { continue }
        $recs = @($snap.Dns[$h])
        $pre = @{ Region = 'dns'; Hash = (Get-CfHash $recs) }
        if ($recs.Count -eq 0) {
            $ops.Add([ordered]@{ Id = "dns:$h"; Kind = 'DnsCreate'; Hostname = $h; Method = 'POST'; Path = "/zones/$ZoneId/dns_records"
                    Body = [ordered]@{ type = 'CNAME'; name = $h; content = $cnameTarget; proxied = $true; comment = "$($script:OwnedPrefix) $appId" }; Precondition = $pre })
        }
        elseif ($recs.Count -eq 1 -and $recs[0].type -eq 'CNAME' -and $recs[0].content -eq $cnameTarget -and $recs[0].proxied -eq $true) { $findings.Add("DNS for $h already targets $cnameTarget") }
        elseif ($recs.Count -eq 1 -and $recs[0].type -eq 'CNAME' -and $recs[0].proxied -eq $true -and $recs[0].content -match '^[0-9a-f-]{36}\.cfargotunnel\.com$') {
            if ($repoint -contains $h) {
                $findings.Add("DNS for $h moves from $($recs[0].content) to $cnameTarget (approved repoint)")
                $ops.Add([ordered]@{ Id = "dns:$h"; Kind = 'DnsRepoint'; Hostname = $h; Method = 'PATCH'; Path = "/zones/$ZoneId/dns_records/$($recs[0].id)"
                        Body = [ordered]@{ content = $cnameTarget; proxied = $true }; Precondition = $pre })
            }
            else { $blockers.Add("DNS for $h points at another tunnel ($($recs[0].content)); pass -AllowDnsRepoint $h to move it") }
        }
        else { $blockers.Add("DNS for $h has $($recs.Count) record(s) not pointing at a tunnel; refusing to overwrite") }
    }

    $i = 0
    foreach ($op in $ops) { $op['Sequence'] = ++$i }
    $status = if ($blockers.Count -gt 0) { 'Blocked' } elseif ($ops.Count -eq 0) { 'NoChange' } else { 'Ready' }
    $plan = ConvertTo-CfData ([ordered]@{
            SchemaVersion = 2
            Kind          = 'SolutionDeploy.CloudflareRoutePlan'
            AppId         = $appId
            Target        = $targetRecord
            AccountId     = $AccountId
            ZoneId        = $ZoneId
            TunnelId      = $TunnelId
            Service       = $service
            Hostnames     = $hosts
            CatchHosts    = $catchHosts
            Access        = [ordered]@{ IdentityProviderId = $idpId; IdentityProviderType = $(if ($idp.Count -eq 1) { $idp[0].type } else { $null }); AllowEmails = $emails }
            CatchEvidence = $evidenceRecord
            SnapshotHash  = $snapHash
            Status        = $status
            Blockers      = @($blockers)
            Findings      = @($findings)
            Operations    = @($ops)
            Limitations   = $script:Limitations
        })
    $plan['PlanHash'] = Get-CfPlanHash $plan
    return $plan
}

function Get-CfPlanHash {
    param([System.Collections.IDictionary] $Plan)
    $copy = [ordered]@{}
    foreach ($k in $Plan.Keys) { if ($k -ne 'PlanHash') { $copy[$k] = $Plan[$k] } }
    return Get-CfHash $copy
}

function Assert-CloudflareRoutePlan {
    <# Throws unless the plan is intact, Ready or NoChange, and every write is one of the narrow allowed shapes in a safe order. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][System.Collections.IDictionary] $Plan)
    $p = ConvertTo-CfData $Plan
    if ((Get-CfValue $p 'Kind') -ne 'SolutionDeploy.CloudflareRoutePlan' -or (Get-CfValue $p 'SchemaVersion') -ne 2) { throw 'Not a schema 2 SolutionDeploy Cloudflare route plan; replan with a registered host target.' }
    if ((Get-CfPlanHash $p) -ne (Get-CfValue $p 'PlanHash')) { throw 'Plan hash does not match plan content.' }
    $tg = Get-CfValue $p 'Target'
    if ($null -eq $tg -or (Test-CfTarget $tg) -or $tg.TunnelId -cne $p.TunnelId -or $tg.Origin -cne $p.Service) { throw 'Plan target is missing, invalid, or does not match the plan tunnel and origin.' }
    if ($p.Status -eq 'Blocked') { throw "Plan is blocked: $(@($p.Blockers) -join ' | ')" }
    if ($p.Status -notin 'Ready', 'NoChange') { throw "Plan status '$($p.Status)' is not executable." }
    $a = [regex]::Escape($p.AccountId); $z = [regex]::Escape($p.ZoneId); $t = [regex]::Escape($p.TunnelId)
    $allowed = @{
        AccessPolicyCreate  = @('POST', "^/accounts/$a/access/policies$")
        AccessAppCreate     = @('POST', "^/accounts/$a/access/apps$")
        CatchPolicyCreate   = @('POST', "^/accounts/$a/access/policies$")
        CatchAppCreate      = @('POST', "^/accounts/$a/access/apps$")
        TunnelIngressUpdate = @('PUT', "^/accounts/$a/cfd_tunnel/$t/configurations$")
        DnsCreate           = @('POST', "^/zones/$z/dns_records$")
        DnsRepoint          = @('PATCH', "^/zones/$z/dns_records/[0-9A-Za-z]+$")
    }
    $planned = @($p.Operations | ForEach-Object { $_.Id })
    $seen = @{}
    foreach ($op in @($p.Operations)) {
        $rule = $allowed[[string]$op.Kind]
        if (-not $rule -or $op.Method -ne $rule[0] -or $op.Path -cnotmatch $rule[1]) { throw "Operation $($op.Id) ($($op.Method) $($op.Path)) is outside the allowed write set." }
        if ($op.Kind -ne 'TunnelIngressUpdate' -and $p.Hostnames -notcontains $op.Hostname) { throw "Operation $($op.Id) targets an unplanned host." }
        switch ($op.Kind) {
            'AccessPolicyCreate' { if ($op.Body.decision -ne 'allow' -or @($op.Body.require).Count -eq 0) { throw "Operation $($op.Id) is not a restrictive allow policy." } }
            'AccessAppCreate' { if ($op.Body.domain -ne $op.Hostname) { throw "Operation $($op.Id) is not exact-host." } }
            { $_ -in 'CatchPolicyCreate', 'CatchAppCreate' } {
                if ($p.AppId -ne $script:FerryAppId -or $p.CatchHosts -notcontains $op.Hostname -or $null -eq $p.CatchEvidence) { throw "Catch bypass $($op.Id) is not allowed for this plan." }
                if ($op.Kind -eq 'CatchAppCreate' -and $op.Body.domain -ne "$($op.Hostname)$($script:CatchPath)") { throw "Catch app $($op.Id) is not path-exact." }
            }
            'TunnelIngressUpdate' {
                $ing = @($op.Body.config.ingress)
                if ($ing[-1].service -ne $script:TerminalService -or (Get-CfValue $ing[-1] 'hostname')) { throw 'Ingress update does not end with the terminal 404.' }
                foreach ($h in $p.Hostnames) { foreach ($need in "access-app:$h", "catch-app:$h") { if ($planned -contains $need -and -not $seen[$need]) { throw "Ingress is ordered before $need." } } }
            }
            { $_ -in 'DnsCreate', 'DnsRepoint' } {
                if ($op.Body.content -ne "$($p.TunnelId).cfargotunnel.com" -or $op.Body.proxied -ne $true) { throw "DNS operation $($op.Id) is not a proxied CNAME to the plan tunnel." }
                foreach ($need in "access-app:$($op.Hostname)", "catch-app:$($op.Hostname)", 'tunnel-ingress') { if ($planned -contains $need -and -not $seen[$need]) { throw "DNS for $($op.Hostname) is ordered before $need." } }
            }
        }
        $seen[$op.Id] = $true
    }
    return $true
}

function Test-CfTarget {
    param($Target)
    if ([string](Get-CfValue $Target 'Host' '') -notmatch '^[A-Za-z0-9][A-Za-z0-9-]{0,62}$') { return 'target host is missing or invalid' }
    if ([string](Get-CfValue $Target 'Address' '') -notmatch '^\d{1,3}(\.\d{1,3}){3}$') { return 'target address is missing or invalid' }
    if ([string](Get-CfValue $Target 'HostIdentity' '') -notmatch '^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$') { return 'target host identity (hardware UUID) is missing or invalid' }
    if ([string]::IsNullOrWhiteSpace([string](Get-CfValue $Target 'RouteProfile' ''))) { return 'target route profile is missing' }
    return $null
}

function Get-CloudflareRouteTarget {
    <#
    .SYNOPSIS
        Returns @{ Host; Address; HostIdentity; RouteProfile } for New-CloudflareRoutePlan -Target
        from a schema 2 deployment plan. Throws unless the selected host is registered with that
        exact route profile and the destination identity was verified.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][System.Collections.IDictionary] $DeploymentPlan)
    $d = ConvertTo-CfData $DeploymentPlan
    if ((Get-CfValue $d 'schemaVersion') -ne 2) { throw 'Deployment plan is not schema 2 (host registry).' }
    $t = Get-CfValue $d 'target' @{}
    $snap = Get-CfValue $d 'hostSnapshot' @{}
    $registered = Get-CfValue (Get-CfValue $t 'hosts' @{}) ([string](Get-CfValue $t 'host' '')) $null
    if ($null -eq $registered) { throw "Target host '$($t.host)' is not in the deployment plan host registry." }
    foreach ($k in 'host', 'address', 'routeProfile') {
        if ([string](Get-CfValue $registered $k '') -cne [string](Get-CfValue $t $k '')) { throw "Target $k differs from the registered host record." }
    }
    if ((Get-CfValue $snap 'verified' $false) -ne $true -or [string](Get-CfValue $snap 'host' '') -ine $t.host -or [string](Get-CfValue $snap 'address' '') -cne $t.address) { throw 'Destination host identity was not verified for the selected target.' }
    $target = [ordered]@{ Host = [string]$t.host; Address = [string]$t.address; HostIdentity = [string]$snap.identity; RouteProfile = [string]$t.routeProfile }
    $problem = Test-CfTarget $target
    if ($problem) { throw "Deployment target is not routable: $problem." }
    return $target
}

function Assert-CloudflareDeploymentBinding {
    <#
    .SYNOPSIS
        Throws unless an intact schema 2 route plan belongs to this exact deployment: its Target
        equals Get-CloudflareRouteTarget of the deployment plan (host, address, hardware UUID, route
        profile), its tunnel equals -ApprovedTunnelId, its origin is the manifest loopback upstream,
        its AppId/hostnames/catch hosts are the manifest's, and every planned ingress rule and any
        catch evidence point at that upstream. Plan keys are PascalCase and case-sensitive.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary] $Plan,
        [Parameter(Mandatory)][System.Collections.IDictionary] $DeploymentPlan,
        [Parameter(Mandatory)][string] $ApprovedTunnelId
    )
    Assert-CloudflareRoutePlan -Plan $Plan | Out-Null
    $p = ConvertTo-CfData $Plan
    $d = ConvertTo-CfData $DeploymentPlan
    $expected = Get-CloudflareRouteTarget -DeploymentPlan $d
    foreach ($k in 'Host', 'Address', 'HostIdentity', 'RouteProfile') {
        if ([string]$p.Target[$k] -cne [string]$expected[$k]) { throw "Route plan target $k '$($p.Target[$k])' is not the deployment target '$($expected[$k])'." }
    }
    if ($ApprovedTunnelId -notmatch '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' -or $p.TunnelId -cne $ApprovedTunnelId -or $p.Target.TunnelId -cne $ApprovedTunnelId) { throw "Route plan tunnel '$($p.TunnelId)' is not the approved tunnel '$ApprovedTunnelId'." }
    $m = Get-CfValue $d 'manifest' @{}
    $appId = [string](Get-CfValue $m 'id' '')
    $port = Get-CfValue (Get-CfValue $m 'launch' @{}) 'port'
    $service = "http://127.0.0.1:$port"
    $routes = @(Get-CfValue $m 'routes' @())
    $hosts = @($routes | ForEach-Object { ([string](Get-CfValue $_ 'hostname' '')).ToLowerInvariant() } | Sort-Object)
    $catch = @($routes | Where-Object { Get-CfValue $_ 'catchPath' } | ForEach-Object { ([string]$_['hostname']).ToLowerInvariant() } | Sort-Object)
    if (-not ($port -is [int] -or $port -is [long]) -or $port -lt 1 -or $port -gt 65535) { throw 'Manifest launch.port is missing or invalid.' }
    if ([string](Get-CfValue $d 'app' '') -cne $appId -or (Get-CfValue $p 'AppId') -cne $appId) { throw "Route plan is for '$($p.AppId)', not deployment app '$appId'." }
    if ((Get-CfValue $p 'Service') -cne $service -or $p.Target.Origin -cne $service) { throw "Route plan origin '$($p.Service)' is not the manifest upstream $service." }
    if ((@($p.Hostnames | Sort-Object) -join ',') -cne ($hosts -join ',')) { throw "Route plan hostnames ($(@($p.Hostnames) -join ',')) are not the manifest routes ($($hosts -join ','))." }
    if ((@($p.CatchHosts | Sort-Object) -join ',') -cne ($catch -join ',')) { throw 'Route plan catch hosts are not the manifest routes that declare catchPath.' }
    foreach ($op in @($p.Operations | Where-Object { $_.Kind -eq 'TunnelIngressUpdate' })) {
        foreach ($rule in @($op.Body.config.ingress | Where-Object { $hosts -contains [string](Get-CfValue $_ 'hostname' '') })) {
            if ($rule.service -cne $service) { throw "Planned ingress for $($rule.hostname) points at $($rule.service), not $service." }
        }
    }
    $ev = Get-CfValue $p 'CatchEvidence'
    if ($null -ne $ev -and $ev.Origin -cne $service) { throw "Catch evidence was taken against $($ev.Origin), not $service." }
    return [ordered]@{ PlanHash = $p.PlanHash; AppId = $appId; Target = $p.Target; TunnelId = $p.TunnelId; Service = $service; Hostnames = $hosts; CatchHosts = $catch; Status = $p.Status }
}

# ------------------------------------------------------------------ execution

function Resolve-CfRefs {
    param($Value, [hashtable] $Created)
    if ($Value -is [string] -and $Value -match '^\{\{op:(.+)\}\}$') {
        if (-not $Created.ContainsKey($Matches[1])) { throw "Operation reference $Value has no created id." }
        return $Created[$Matches[1]]
    }
    if ($Value -is [System.Collections.IDictionary]) { $o = [ordered]@{}; foreach ($k in $Value.Keys) { $o[$k] = Resolve-CfRefs $Value[$k] $Created }; return $o }
    if ($Value -is [System.Collections.IEnumerable] -and $Value -isnot [string]) { return , @($Value | ForEach-Object { Resolve-CfRefs $_ $Created }) }
    return $Value
}

function Write-CfJournal {
    param([string] $Path, [string] $Event, $Data)
    $line = ConvertTo-CanonicalJson ([ordered]@{ at = [datetime]::UtcNow.ToString('o'); event = $Event; data = $Data })
    Add-Content -LiteralPath $Path -Value $line -Encoding utf8NoBOM
}

function Assert-CfAccessLive {
    <# Re-reads Access and the catch rate rule; refuses public routing unless every host is protected right now. #>
    param([hashtable] $Context, [System.Collections.IDictionary] $Plan, [string[]] $Hosts)
    $apps = Read-CfAccessApps -Context $Context -AccountId $Plan.AccountId
    foreach ($h in $Hosts) {
        $root = Find-CfAppsWithDomain $apps $h
        if ($root.Count -ne 1) { throw "Access precondition failed: $h has $($root.Count) exact-host apps." }
        $t = Test-CloudflareAccessPolicy -App $root[0] -Domain $h -IdentityProviderId $Plan.Access.IdentityProviderId -AllowEmails @($Plan.Access.AllowEmails)
        if (-not $t.Passed) { throw "Access precondition failed on ${h}: $($t.Reasons -join '; ')" }
        foreach ($a in $apps) {
            foreach ($d in (Get-CfAppDomains $a)) {
                if ((Test-CfDomainCoversHost $d $h) -and $d.Contains('/') -and $d -ne "$h$($script:CatchPath)") { throw "Access precondition failed: path app $d covers $h." }
            }
        }
        if ($Plan.CatchHosts -contains $h) {
            $c = Find-CfAppsWithDomain $apps "$h$($script:CatchPath)"
            if ($c.Count -ne 1 -or -not (Test-CloudflareCatchBypass -App $c[0] -HostName $h).Passed) { throw "Catch precondition failed on $h." }
            $rs = Read-CfRateRuleset -Context $Context -ZoneId $Plan.ZoneId
            if (-not $rs -or -not (Test-CloudflareCatchRateRule $rs).Passed) { throw 'Catch rate limit rule is no longer in place.' }
        }
    }
}

function Read-CfRegion {
    param([hashtable] $Context, [System.Collections.IDictionary] $Plan, $Op)
    switch ($Op.Precondition.Region) {
        'access-root' { return , (Find-CfAppsWithDomain (Read-CfAccessApps -Context $Context -AccountId $Plan.AccountId) $Op.Hostname) }
        'access-catch' { return , (Find-CfAppsWithDomain (Read-CfAccessApps -Context $Context -AccountId $Plan.AccountId) "$($Op.Hostname)$($script:CatchPath)") }
        'tunnel-config' { return (Read-CfTunnelConfig -Context $Context -AccountId $Plan.AccountId -TunnelId $Plan.TunnelId)['config'] }
        'dns' { return , (Read-CfDns -Context $Context -ZoneId $Plan.ZoneId -HostName $Op.Hostname) }
        default { throw "Unknown precondition region '$($Op.Precondition.Region)'." }
    }
}

function Test-CfReadback {
    param([hashtable] $Context, [System.Collections.IDictionary] $Plan, $Op, $Body, $Result)
    $a = $Plan.AccountId
    switch ($Op.Kind) {
        { $_ -in 'AccessPolicyCreate', 'CatchPolicyCreate' } {
            $got = Get-CfPolicyProjection (Invoke-CfRequest -Context $Context -Method GET -Path "/accounts/$a/access/policies/$($Result.id)")
            foreach ($k in 'name', 'decision', 'include', 'require') {
                $want = if ($k -in 'name', 'decision') { $Body[$k] } else { , @($Body[$k]) }
                $have = if ($k -in 'name', 'decision') { Get-CfValue $got $k $null } else { , @(Get-CfValue $got $k @()) }
                if ((Get-CfHash $have) -ne (Get-CfHash $want)) { throw "Read-back of policy $($Result.id) differs on $k." }
            }
        }
        'AccessAppCreate' {
            $got = Get-CfAppProjection (Invoke-CfRequest -Context $Context -Method GET -Path "/accounts/$a/access/apps/$($Result.id)")
            $t = Test-CloudflareAccessPolicy -App $got -Domain $Op.Hostname -IdentityProviderId $Plan.Access.IdentityProviderId -AllowEmails @($Plan.Access.AllowEmails)
            if (-not $t.Passed) { throw "Read-back of Access app on $($Op.Hostname) is not restrictive: $($t.Reasons -join '; ')" }
        }
        'CatchAppCreate' {
            $got = Get-CfAppProjection (Invoke-CfRequest -Context $Context -Method GET -Path "/accounts/$a/access/apps/$($Result.id)")
            if (-not (Test-CloudflareCatchBypass -App $got -HostName $Op.Hostname).Passed) { throw "Read-back of catch app on $($Op.Hostname) is not an exact bypass." }
        }
        'TunnelIngressUpdate' {
            $got = (Read-CfTunnelConfig -Context $Context -AccountId $a -TunnelId $Plan.TunnelId)['config']
            if ((Get-CfHash $got) -ne (Get-CfHash $Body.config)) { throw 'Read-back of tunnel configuration differs from what was written.' }
        }
        { $_ -in 'DnsCreate', 'DnsRepoint' } {
            $got = @(Read-CfDns -Context $Context -ZoneId $Plan.ZoneId -HostName $Op.Hostname)
            if ($got.Count -ne 1 -or $got[0].type -ne 'CNAME' -or $got[0].content -ne "$($Plan.TunnelId).cfargotunnel.com" -or $got[0].proxied -ne $true) { throw "Read-back of DNS for $($Op.Hostname) is not the expected proxied CNAME." }
        }
    }
    return $got
}

function Invoke-CloudflareRoutePlan {
    <#
    .SYNOPSIS
        Without -Execute, returns a preview and makes no API calls. With -Execute it requires the
        approved plan hash and a journal directory, takes the per-tunnel mutex, re-snapshots and
        fails closed on drift, re-probes the Ferry catch token live when the plan bypasses /api/catch, then for each operation: re-reads its region, journals the prior
        state, re-verifies live Access before any ingress or DNS write, writes, and verifies by
        read-back. Stops at the first failure; no automatic rollback.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary] $Plan,
        [securestring] $Token,
        [string] $TokenEnvironmentVariable,
        [string] $ApprovedPlanHash,
        [string] $JournalDirectory,
        [scriptblock] $Transport,
        [scriptblock] $CatchProbe,
        [switch] $Execute
    )
    $p = ConvertTo-CfData $Plan
    Assert-CloudflareRoutePlan -Plan $p | Out-Null
    $preview = [ordered]@{
        Mode        = 'Preview'
        PlanHash    = $p.PlanHash
        Status      = $p.Status
        Operations  = @(@($p.Operations) | ForEach-Object { "$($_.Sequence). $($_.Kind) $($_.Method) $($_.Path) [$($_.Hostname)]" })
        Limitations = $p.Limitations
    }
    if (-not $Execute) { return $preview }
    if ($ApprovedPlanHash -cne $p.PlanHash) { throw 'ApprovedPlanHash does not match this plan; refusing to write.' }
    if (-not $JournalDirectory -or -not (Test-Path -LiteralPath $JournalDirectory -PathType Container)) { throw 'An existing -JournalDirectory is required for -Execute.' }
    if ($p.Status -eq 'NoChange') { return [ordered]@{ Mode = 'Execute'; PlanHash = $p.PlanHash; Status = 'NoChange'; Completed = @() } }

    $ctx = New-CfContext -Token $Token -TokenEnvironmentVariable $TokenEnvironmentVariable -Transport $Transport
    $roCtx = $ctx.Clone(); $roCtx.ReadOnly = $true
    $journal = Join-Path $JournalDirectory ('cloudflare-{0}-{1}.jsonl' -f [datetime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ'), $p.PlanHash.Substring(0, 12))
    if (Test-Path -LiteralPath $journal) { throw "Journal $journal already exists." }
    $mutex = [System.Threading.Mutex]::new($false, "Global\SolutionDeploy-Cloudflare-$($p.TunnelId)")
    $owned = $false
    try { $owned = $mutex.WaitOne([TimeSpan]::FromSeconds(5)) } catch [System.Threading.AbandonedMutexException] { $owned = $true }
    if (-not $owned) { $mutex.Dispose(); throw "Another run holds the Cloudflare lock for tunnel $($p.TunnelId)." }
    $completed = [System.Collections.Generic.List[string]]::new()
    try {
        $fresh = Get-CloudflareSnapshot -AccountId $p.AccountId -ZoneId $p.ZoneId -TunnelId $p.TunnelId -Hostname @($p.Hostnames) -Token $Token -TokenEnvironmentVariable $TokenEnvironmentVariable -Transport $ctx.Transport
        Write-CfJournal $journal 'start' ([ordered]@{ planHash = $p.PlanHash; target = $p.Target; expectedSnapshotHash = $p.SnapshotHash; snapshot = $fresh })
        if ($fresh.SnapshotHash -ne $p.SnapshotHash) { throw 'Cloudflare state drifted since the plan snapshot; re-plan and re-approve.' }
        if (@(@($p.Operations) | Where-Object { $_.Kind -in 'CatchPolicyCreate', 'CatchAppCreate' }).Count -gt 0) {
            # Plan evidence is caller-supplied, so token enforcement is re-proven live before any write.
            $live = Test-CloudflareCatchTokenEnforcement -Origin $p.Service -Probe $CatchProbe
            Write-CfJournal $journal 'catch-probe' $live
            $liveProblem = Test-CfCatchEvidence -Evidence $live -Service $p.Service
            if ($liveProblem) { throw "Live catch probe failed: $liveProblem" }
        }

        $created = @{}
        foreach ($op in @($p.Operations)) {
            $prior = Read-CfRegion -Context $roCtx -Plan $p -Op $op
            Write-CfJournal $journal 'prior' ([ordered]@{ op = $op.Id; region = $op.Precondition.Region; state = $prior })
            if ((Get-CfHash $prior) -ne $op.Precondition.Hash) { throw "Precondition for $($op.Id) failed: $($op.Precondition.Region) changed before the write." }
            if ($op.Kind -in 'TunnelIngressUpdate', 'DnsCreate', 'DnsRepoint') {
                $hosts = if ($op.Kind -eq 'TunnelIngressUpdate') { @($p.Hostnames) } else { @($op.Hostname) }
                Assert-CfAccessLive -Context $roCtx -Plan $p -Hosts $hosts
            }
            $body = Resolve-CfRefs $op.Body $created
            Write-CfJournal $journal 'write' ([ordered]@{ op = $op.Id; method = $op.Method; path = $op.Path; body = $body })
            $result = Invoke-CfRequest -Context $ctx -Method $op.Method -Path $op.Path -Body $body
            if ($op.Kind -in 'AccessPolicyCreate', 'AccessAppCreate', 'CatchPolicyCreate', 'CatchAppCreate', 'DnsCreate') {
                if (-not (Get-CfValue $result 'id')) { throw "$($op.Id) returned no id." }
                $created[$op.Id] = $result.id
            }
            Write-CfJournal $journal 'written' ([ordered]@{ op = $op.Id; id = (Get-CfValue $result 'id') })
            $readback = Test-CfReadback -Context $roCtx -Plan $p -Op $op -Body $body -Result $result
            Write-CfJournal $journal 'verified' ([ordered]@{ op = $op.Id; readback = $readback })
            $completed.Add($op.Id)
        }
        Write-CfJournal $journal 'complete' ([ordered]@{ completed = @($completed) })
    }
    catch {
        if (Test-Path -LiteralPath $journal) { Write-CfJournal $journal 'failed' ([ordered]@{ error = $_.Exception.Message; completed = @($completed) }) }
        throw
    }
    finally { $mutex.ReleaseMutex(); $mutex.Dispose() }
    return [ordered]@{ Mode = 'Execute'; PlanHash = $p.PlanHash; Status = 'Applied'; Completed = @($completed); Journal = $journal }
}

Export-ModuleMember -Function New-CloudflareRoutePlan, Assert-CloudflareRoutePlan, Assert-CloudflareDeploymentBinding, Get-CloudflareRouteTarget, Invoke-CloudflareRoutePlan, Get-CloudflareSnapshot,
    Test-CloudflareAccessPolicy, Test-CloudflareCatchBypass, Test-CloudflareCatchRateRule, Test-CloudflareCatchTokenEnforcement
