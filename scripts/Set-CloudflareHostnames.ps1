[CmdletBinding()]
param([switch]$Apply, [switch]$EnableGoogleSignIn, [switch]$PublishWorkLog, [switch]$PublishWebInventory,
    [switch]$PublishWebPortfolio, [switch]$PublishWebOptions, [switch]$PublishDirectory, [switch]$PublishTeamScoreboard,
    [switch]$RemoveRetiredFerryHeaderRule, [switch]$PublishFitTrackOAuthPages, [switch]$PublishTeamScoreboardCalendar,
    [switch]$PublishIdeaNotes, [string]$AddGoogleEmail)
# Enforces the complete public hostname allowlist for the jimbrownhome1 tunnel: exactly one name per app.
# Without -Apply it only reports drift. Adding an app means adding one line to $allowed.
$ErrorActionPreference='Stop'
if($PSBoundParameters.ContainsKey('AddGoogleEmail')){
    if($AddGoogleEmail -notmatch '^[^@\s*]+@[^@\s*]+\.[^@\s*]+$'){throw 'AddGoogleEmail requires an exact email address.'}
    if(@($PSBoundParameters.Keys|Where-Object {$_ -notin 'AddGoogleEmail','Apply'}).Count){throw 'Add a Google email separately from other changes.'}
}
if($PublishFitTrackOAuthPages -and ($RemoveRetiredFerryHeaderRule -or $EnableGoogleSignIn -or $PublishWorkLog -or $PublishWebInventory -or $PublishWebPortfolio -or $PublishWebOptions -or $PublishDirectory -or $PublishTeamScoreboard -or $PublishTeamScoreboardCalendar)){
    throw 'Publish the Fit Track OAuth pages separately from other changes.'
}
if($PublishTeamScoreboardCalendar -and ($RemoveRetiredFerryHeaderRule -or $EnableGoogleSignIn -or $PublishWorkLog -or $PublishWebInventory -or $PublishWebPortfolio -or $PublishWebOptions -or $PublishDirectory -or $PublishTeamScoreboard)){
    throw 'Publish the Team Scoreboard calendar feed separately from other changes.'
}
if($RemoveRetiredFerryHeaderRule -and ($EnableGoogleSignIn -or $PublishWorkLog -or $PublishWebInventory -or $PublishWebPortfolio -or $PublishWebOptions -or $PublishDirectory)){
    throw 'Remove the retired Ferry header rule separately from other changes.'
}
$allowed=[ordered]@{
    'ferry-tracker.jimlertech.com'=8787
    'home-automation.jimlertech.com'=8788
    'site-dock.jimlertech.com'=8790
    'fit-track.jimlertech.com'=8791
    'web-bookmarks.jimlertech.com'=8792
    'plex.jimlertech.com'=18793  # internal port; Tailscale serve owns 8793 on the tailnet address
    'work-log.jimlertech.com'=18794  # HttpListener origin is separate from Tailscale HTTPS 8794
    'web-inventory.jimlertech.com'=18795
    'web-portfolio.jimlertech.com'=18796
    'web-options.jimlertech.com'=18797
    'solution-deploy.jimlertech.com'=18798
    'team-scoreboard.jimlertech.com'=8801
    'idea-notes.jimlertech.com'=8802
}
if(@(@($PublishWorkLog,$PublishWebInventory,$PublishWebPortfolio,$PublishWebOptions,$PublishDirectory,$PublishTeamScoreboard,$PublishIdeaNotes)|Where-Object {[bool]$_}).Count -gt 1){throw 'Publish one application at a time.'}
$publishName=if($PublishWorkLog){'work-log.jimlertech.com'}elseif($PublishWebInventory){'web-inventory.jimlertech.com'}elseif($PublishWebPortfolio){'web-portfolio.jimlertech.com'}elseif($PublishWebOptions){'web-options.jimlertech.com'}elseif($PublishDirectory){'solution-deploy.jimlertech.com'}elseif($PublishTeamScoreboard){'team-scoreboard.jimlertech.com'}elseif($PublishIdeaNotes){'idea-notes.jimlertech.com'}else{''}
$catchHosts=@('ferry-tracker.jimlertech.com/api/catch','fit-track.jimlertech.com/oauth/*','team-scoreboard.jimlertech.com/calendar/*')
$account='/accounts/ec74856ed4fe9f15833c5419011f2507'
$zone='/zones/84715a1ddfee0e7c6e92fdc39a3085d2'
$tunnelId='209bf0e7-20c1-45b9-bba9-fca92fc58344'
$tunnel="$account/cfd_tunnel/$tunnelId/configurations"
$readOnly=@('id','uid','aud','created_at','updated_at')
$token=Import-Clixml (Join-Path $env:LOCALAPPDATA 'JimlerTech\SolutionDeploy\cloudflare-token.dpapi.xml')
function Api([string]$Method,[string]$Path,$Body){
    $a=@{Uri=('https://api.cloudflare.com/client/v4'+$Path);Authentication='Bearer';Token=$token;Method=$Method;TimeoutSec=20;MaximumRetryCount=0}
    if($null -ne $Body){$a.Body=$Body|ConvertTo-Json -Depth 60 -Compress;$a.ContentType='application/json'}
    try{$v=Invoke-RestMethod @a}catch{throw "Cloudflare $Method $Path failed; inspect before retry. Response withheld."}
    if(-not $v.success){throw "Cloudflare $Method refused."}
    $v.result|ConvertTo-Json -Depth 60|ConvertFrom-Json -AsHashtable -DateKind String
}
function Comparable($App){
    $c=[ordered]@{}
    foreach($k in ($App.Keys|Where-Object {$_ -notin $readOnly -and $_ -notin 'domain','self_hosted_domains','destinations','policies'}|Sort-Object)){$c[$k]=$App[$k]}
    $c.policies=(@($App.policies|ForEach-Object {"$($_.id):$($_.precedence)"})|Sort-Object) -join ','
    $c|ConvertTo-Json -Depth 60 -Compress
}
$report=[ordered]@{applied=[bool]$Apply;dnsRemoved=@();ingressRemoved=@();accessTrimmed=@();missing=@()}
try{
    if($AddGoogleEmail){
        $email=$AddGoogleEmail.ToLowerInvariant()
        $policies=@(Api Get "$account/access/policies?per_page=100" $null)
        $matches=@($policies|Where-Object name -eq 'SolutionDeploy owner - Google')
        if($matches.Count -ne 1){throw 'Expected exactly one reusable Google allow policy.'}
        $policy=$matches[0]
        if($policy.decision -ne 'allow' -or @($policy.include).Count -eq 0 -or
            @($policy.include|Where-Object {-not $_.email.email}).Count -or
            @($policy.require).Count -ne 1 -or -not $policy.require[0].login_method.id){throw 'Unexpected Google policy rules.'}
        $providers=@(Api Get "$account/access/identity_providers" $null)
        if(@($providers|Where-Object {$_.id -eq $policy.require[0].login_method.id -and $_.type -eq 'google'}).Count -ne 1){throw 'Policy must require Google sign-in.'}
        $apps=@(Api Get "$account/access/apps?per_page=100" $null)
        $targets=@($apps|Where-Object {$_.domain -in $allowed.Keys -and $policy.id -in @($_.policies.id)})
        if($targets.Count -ne $allowed.Count -or @($apps|Where-Object {$policy.id -in @($_.policies.id)}).Count -ne $targets.Count){throw 'Google policy attachments differ from the public app allowlist.'}
        $report.googleEmail=$email
        $report.applications=@($targets.domain)
        $report.added=$false
        if(-not $Apply -or $email -in @($policy.include|ForEach-Object {$_.email.email})){return}
        $before=$policy|ConvertTo-Json -Depth 60 -Compress
        $path="$account/access/policies/$($policy.id)"
        if(((Api Get $path $null)|ConvertTo-Json -Depth 60 -Compress) -cne $before){throw 'Google policy changed concurrently; nothing written.'}
        $body=@{name=$policy.name;decision=$policy.decision;include=@($policy.include)+@(@{email=@{email=$email}})
            exclude=$policy.exclude;require=$policy.require}
        $null=Api Put $path $body
        $read=Api Get $path $null
        foreach($key in $body.Keys){
            if(($read[$key]|ConvertTo-Json -Depth 60 -Compress) -cne ($body[$key]|ConvertTo-Json -Depth 60 -Compress)){throw "Google policy readback differs: $key"}
        }
        $after=@(Api Get "$account/access/apps?per_page=100" $null)
        foreach($app in $targets){
            $updated=@($after|Where-Object id -eq $app.id)
            if($updated.Count -ne 1 -or (Comparable $updated[0]) -cne (Comparable $app)){throw "Application settings changed: $($app.domain)"}
        }
        $report.added=$true
        return
    }
    if($PublishFitTrackOAuthPages -or $PublishTeamScoreboardCalendar){
        # Path-specific Everyone bypass beside an owner-protected parent application.
        $bypass=if($PublishFitTrackOAuthPages){
            @{label='Fit Track';parentHost='fit-track.jimlertech.com';domain='fit-track.jimlertech.com/oauth/*'
                name='Fit Track OAuth information';policy='Public informational pages only'}
        }else{
            @{label='Team Scoreboard';parentHost='team-scoreboard.jimlertech.com';domain='team-scoreboard.jimlertech.com/calendar/*'
                name='Team Scoreboard calendar feed';policy='Calendar feed, origin checks the token'}
        }
        $domain=$bypass.domain
        $apps=@(Api Get "$account/access/apps?per_page=100" $null)
        $parent=@($apps|Where-Object domain -eq $bypass.parentHost)
        if($parent.Count -ne 1){throw "Expected exactly one protected $($bypass.label) application."}
        $before=Api Get "$account/access/apps/$($parent[0].id)" $null
        if(-not @($before.policies|Where-Object decision -eq 'allow').Count -or @($before.policies|Where-Object decision -eq 'bypass').Count){
            throw "$($bypass.label) parent access policies require inspection."
        }
        $public=@($apps|Where-Object domain -eq $domain)
        if($public.Count -gt 1){throw "Duplicate $($bypass.label) public-path applications."}
        $report.publicPages=$domain
        if(-not $Apply){return}
        if(-not $public.Count){
            $body=@{name=$bypass.name;type='self_hosted';domain=$domain
                self_hosted_domains=@($domain);destinations=@(@{type='public';uri=$domain})
                policies=@(@{name=$bypass.policy;decision='bypass';precedence=1;include=@(@{everyone=@{}})})}
            $public=@(Api Post "$account/access/apps" $body)
        }
        $read=Api Get "$account/access/apps/$($public[0].id)" $null
        if($read.domain -cne $domain -or (@($read.self_hosted_domains) -join ',') -cne $domain -or
            (@($read.destinations|ForEach-Object uri) -join ',') -cne $domain -or @($read.policies).Count -ne 1){
            throw 'Public-page Access application readback differs.'
        }
        $policy=Api Get "$account/access/apps/$($read.id)/policies/$($read.policies[0].id)" $null
        if($policy.decision -cne 'bypass' -or @($policy.include).Count -ne 1 -or -not $policy.include[0].ContainsKey('everyone') -or
            @($policy.require|Where-Object {$null -ne $_}).Count -or @($policy.exclude|Where-Object {$null -ne $_}).Count){throw 'Expected only an Everyone bypass for the informational path.'}
        if(((Api Get "$account/access/apps/$($parent[0].id)" $null)|ConvertTo-Json -Depth 60 -Compress) -cne
            ($before|ConvertTo-Json -Depth 60 -Compress)){throw "$($bypass.label) parent application changed during publication."}
        $report.parentUnchanged=$true
        return
    }
    if($RemoveRetiredFerryHeaderRule){
        $entrypoint="$zone/rulesets/phases/http_response_headers_transform/entrypoint"
        $ruleset=Api Get $entrypoint $null
        $expression='(http.host eq "ferry.jimlertech.com" and not starts_with(http.request.uri.path, "/cdn-cgi/"))'
        $targets=@($ruleset.rules|Where-Object expression -ceq $expression)
        if($targets.Count -gt 1){throw 'Multiple retired Ferry header rules found; inspect before removing.'}
        $report.retiredFerryHeaderRule=@($targets|ForEach-Object id)
        if($Apply -and $targets.Count){
            $before=$ruleset|ConvertTo-Json -Depth 60 -Compress
            if(((Api Get $entrypoint $null)|ConvertTo-Json -Depth 60 -Compress) -cne $before){throw 'Header rules changed concurrently; nothing removed.'}
            $null=Api Delete "$zone/rulesets/$($ruleset.id)/rules/$($targets[0].id)" $null
            $remaining=Api Get $entrypoint $null
            if(@($remaining.rules|Where-Object expression -ceq $expression).Count){throw 'Retired Ferry header rule remains after deletion.'}
            $expected=@($ruleset.rules|Where-Object id -ne $targets[0].id)
            # Cloudflare omits rules entirely when the last rule is deleted.
            $actual=@($remaining.rules|Where-Object {$null -ne $_})
            if((ConvertTo-Json -InputObject $actual -Depth 60 -Compress) -cne (ConvertTo-Json -InputObject $expected -Depth 60 -Compress)){
                throw 'Other header rules changed during deletion; inspect the ruleset.'
            }
            $report.retiredFerryHeaderRuleRemoved=$true
        }
        return
    }
    # Every allowlisted name must already be fully published; this script only removes extras.
    $dnsAll=@(Api Get "$zone/dns_records?type=CNAME&content=$tunnelId.cfargotunnel.com&per_page=100" $null)
    # Portfolio is published first; Options remains pending during that single cutover.
    $existingNames=@($allowed.Keys|Where-Object {$_ -ne $publishName -and -not ($PublishWebPortfolio -and $_ -eq 'web-options.jimlertech.com')})
    foreach($name in $existingNames){if(@($dnsAll|Where-Object name -eq $name).Count -ne 1){$report.missing+="dns:$name"}}
    $config=(Api Get $tunnel $null).config
    foreach($name in $existingNames){if(@($config.ingress|Where-Object {$_.hostname -eq $name -and $_.service -eq "http://127.0.0.1:$($allowed[$name])"}).Count -ne 1){$report.missing+="ingress:$name"}}
    if($report.missing.Count){throw "Allowlisted names are not fully published: $($report.missing -join ', ')"}
    if($config.ingress[-1].service -cne 'http_status:404' -or $config.ingress[-1].hostname){throw 'Tunnel terminal fallback changed.'}

    $apps=@(Api Get "$account/access/apps?per_page=100" $null)
    if($publishName){
        if(-not $Apply){$report.publish=$publishName;return}
        $name=$publishName
        $service="http://127.0.0.1:$($allowed[$name])"
        $template=@($apps|Where-Object domain -eq 'site-dock.jimlertech.com')
        if($template.Count -ne 1){throw 'Expected the SiteDock Access policy template.'}
        $app=@($apps|Where-Object domain -eq $name)
        if($app.Count -gt 1){throw 'Duplicate WorkLog Access applications.'}
        if(-not $app.Count){
            $policies=@($template[0].policies|Where-Object decision -eq 'allow')
            if($policies.Count -ne 2 -or @($template[0].allowed_idps).Count -ne 2){throw 'Template must support both owner sign-in methods.'}
            $body=@{name=($name -replace '\.jimlertech\.com$','');type='self_hosted';domain=$name;self_hosted_domains=@($name)
                destinations=@(@{type='public';uri=$name});session_duration=$template[0].session_duration
                allowed_idps=$template[0].allowed_idps;auto_redirect_to_identity=$false
                policies=@($policies|ForEach-Object {@{id=$_.id;precedence=[int]$_.precedence}})}
            $app=@(Api Post "$account/access/apps" $body)
        }
        $secured=Api Get "$account/access/apps/$($app[0].id)" $null
        if(($secured.policies.id|Sort-Object) -join ',' -cne (($template[0].policies.id|Sort-Object) -join ',') -or
            ($secured.allowed_idps|Sort-Object) -join ',' -cne (($template[0].allowed_idps|Sort-Object) -join ',') -or
            @($secured.policies|Where-Object decision -ne 'allow').Count){throw 'WorkLog Access readback differs from owner policies.'}
        $rules=@($config.ingress|Where-Object hostname -eq $name)
        $legacy=if($PublishWorkLog){'http://127.0.0.1:8794'}else{$service}
        if($rules.Count -gt 1 -or ($rules.Count -eq 1 -and $rules[0].service -notin $legacy,$service)){throw "Conflicting tunnel rule: $name"}
        if(-not $rules.Count -or $rules[0].service -ne $service){
            $before=$config|ConvertTo-Json -Depth 60 -Compress
            $config.ingress=@($config.ingress|Where-Object {$_.hostname -and $_.hostname -ne $name})+@(@{hostname=$name;service=$service},@{service='http_status:404'})
            if(((Api Get $tunnel $null).config|ConvertTo-Json -Depth 60 -Compress) -cne $before){throw 'Tunnel changed concurrently.'}
            $null=Api Put $tunnel @{config=$config}
            $config=(Api Get $tunnel $null).config
            if(@($config.ingress|Where-Object {$_.hostname -eq $name -and $_.service -eq $service}).Count -ne 1){throw "Tunnel readback differs: $name"}
        }
        $dns=@(Api Get "$zone/dns_records?name=$name" $null)
        if($dns.Count -gt 1 -or ($dns.Count -eq 1 -and ($dns[0].type -ne 'CNAME' -or $dns[0].content -ne "$tunnelId.cfargotunnel.com" -or -not $dns[0].proxied))){throw 'Conflicting WorkLog DNS record.'}
        if(-not $dns.Count){$null=Api Post "$zone/dns_records" @{type='CNAME';name=$name;content="$tunnelId.cfargotunnel.com";proxied=$true;ttl=1}}
        $dns=@(Api Get "$zone/dns_records?name=$name" $null)
        if($dns.Count -ne 1 -or $dns[0].content -ne "$tunnelId.cfargotunnel.com" -or -not $dns[0].proxied){throw 'WorkLog DNS readback differs.'}
        $dnsAll=@(Api Get "$zone/dns_records?type=CNAME&content=$tunnelId.cfargotunnel.com&per_page=100" $null)
        $apps=@(Api Get "$account/access/apps?per_page=100" $null)
        $report.publish=$name
    }
    $extraDns=@($dnsAll|Where-Object {$_.name -notin $allowed.Keys})
    $extraIngress=@($config.ingress|Where-Object {$_.hostname -and $_.hostname -notin $allowed.Keys})
    if($EnableGoogleSignIn){
        $google=@(Api Get "$account/access/identity_providers" $null|Where-Object type -eq 'google')
        if($google.Count -ne 1){throw 'Expected exactly one configured Google identity provider.'}
        $targets=@($apps|Where-Object {$_.domain -in $allowed.Keys})
        $expectedCount=if($PublishWebPortfolio){$allowed.Count-1}else{$allowed.Count}
        if($targets.Count -ne $expectedCount){throw 'Expected one Access application per published public hostname.'}
        $policyName='SolutionDeploy owner - Google'
        $policies=@(Api Get "$account/access/policies?per_page=100" $null)
        $googlePolicy=@($policies|Where-Object name -eq $policyName)
        if($googlePolicy.Count -gt 1){throw 'Duplicate Google owner policies; inspect before applying.'}
        $source=@($targets[0].policies|Where-Object {$_.decision -eq 'allow' -and $_.name -ne $policyName})
        if($source.Count -ne 1 -or -not $source[0].include.Count){throw 'Expected a single existing owner allow policy.'}
        if(@($source[0].require).Count -ne 1 -or -not $source[0].require[0].login_method.id){
            throw 'Owner policy has additional requirements; inspect before adding Google.'
        }
        if(@($source[0].include|Where-Object {-not $_.email.email}).Count){
            throw 'Owner policy must contain only explicit email addresses.'
        }
        foreach($app in $targets){
            $owner=@($app.policies|Where-Object { $_.decision -eq 'allow' -and $_.name -ne $policyName })
            if($owner.Count -ne 1 -or (Comparable $owner[0]) -cne (Comparable $source[0])){throw "Owner policy differs on $($app.domain)."}
        }
        $body=@{
            name=$policyName;decision='allow'
            include=$source[0].include;exclude=$source[0].exclude
            require=@(@{login_method=@{id=$google[0].id}})
        }
        if($googlePolicy.Count){
            foreach($key in 'include','exclude','require','decision'){
                if(($googlePolicy[0][$key]|ConvertTo-Json -Depth 20 -Compress) -cne ($body[$key]|ConvertTo-Json -Depth 20 -Compress)){throw "Existing Google policy differs: $key"}
            }
        }
        if($Apply){
            if(-not $googlePolicy.Count){$googlePolicy=@(Api Post "$account/access/policies" $body)}
            foreach($app in $targets){
                $put=[ordered]@{}
                foreach($key in ($app.Keys|Where-Object {$_ -notin $readOnly})){$put[$key]=$app[$key]}
                $put.allowed_idps=@(@($app.allowed_idps)+@($google[0].id)|Select-Object -Unique)
                $put.auto_redirect_to_identity=$false
                $put.policies=@($app.policies|ForEach-Object {@{id=$_.id;precedence=$_.precedence}})
                if($googlePolicy[0].id -notin @($app.policies.id)){
                    $put.policies+=@{id=$googlePolicy[0].id;precedence=([int]($app.policies.precedence|Measure-Object -Maximum).Maximum+1)}
                }
                $null=Api Put "$account/access/apps/$($app.id)" $put
                $read=Api Get "$account/access/apps/$($app.id)" $null
                if($google[0].id -notin $read.allowed_idps -or $googlePolicy[0].id -notin $read.policies.id -or $read.auto_redirect_to_identity){throw "Google sign-in readback differs on $($app.domain)."}
                foreach($id in $app.allowed_idps){if($id -notin $read.allowed_idps){throw "Existing identity provider removed on $($app.domain)."}}
                foreach($id in $app.policies.id){if($id -notin $read.policies.id){throw "Existing policy removed on $($app.domain)."}}
            }
        }
        $report.googleSignIn=@($targets.domain)
        $apps=@(Api Get "$account/access/apps?per_page=100" $null)
    }
    $trim=@($apps|Where-Object {@($_.self_hosted_domains|Where-Object {$_ -notin $allowed.Keys -and $_ -notin $catchHosts}).Count})
    $report.dnsRemoved=@($extraDns|ForEach-Object name)
    $report.ingressRemoved=@($extraIngress|ForEach-Object hostname)
    $report.accessTrimmed=@($trim|ForEach-Object {"$($_.name): $(@($_.self_hosted_domains|Where-Object {$_ -notin $allowed.Keys -and $_ -notin $catchHosts}) -join ',')"})
    if(-not $Apply){return}

    # 1. DNS first, so extra names stop resolving while Access still covers them.
    foreach($d in $extraDns){
        $null=Api Delete "$zone/dns_records/$($d.id)" $null
        if(@(Api Get "$zone/dns_records?name=$($d.name)" $null).Count){throw "DNS delete readback differs for $($d.name)."}
    }
    # 2. Tunnel ingress, with a concurrent-writer check because the API has no revision guard.
    if($extraIngress.Count){
        $snapshotJson=$config|ConvertTo-Json -Depth 60 -Compress
        $config.ingress=@($config.ingress|Where-Object {-not $_.hostname -or $_.hostname -in $allowed.Keys})
        $expectedJson=$config|ConvertTo-Json -Depth 60 -Compress
        if(((Api Get $tunnel $null).config|ConvertTo-Json -Depth 60 -Compress) -cne $snapshotJson){throw 'Tunnel config changed concurrently; nothing written to the tunnel.'}
        $null=Api Put $tunnel @{config=$config}
        if(((Api Get $tunnel $null).config|ConvertTo-Json -Depth 60 -Compress) -cne $expectedJson){throw 'Tunnel readback differs from expected config.'}
    }
    # 3. Access apps: drop extra hostnames only, keeping every other setting.
    foreach($app in $trim){
        $keepHosts=@($app.self_hosted_domains|Where-Object {$_ -in $allowed.Keys -or $_ -in $catchHosts})
        if(-not $keepHosts.Count){throw "Access app $($app.name) would have no hostnames left; inspect manually."}
        $put=[ordered]@{}
        foreach($k in ($app.Keys|Where-Object {$_ -notin $readOnly})){$put[$k]=$app[$k]}
        $put.domain=$keepHosts[0]
        $put.self_hosted_domains=$keepHosts
        $put.destinations=@($keepHosts|ForEach-Object {@{type='public';uri=$_}})
        $put.policies=@($app.policies|ForEach-Object {@{id=$_.id;precedence=$_.precedence}})
        $null=Api Put "$account/access/apps/$($app.id)" $put
        $read=Api Get "$account/access/apps/$($app.id)" $null
        if((@($read.self_hosted_domains) -join ',') -cne ($keepHosts -join ',') -or (@($read.destinations|ForEach-Object uri) -join ',') -cne ($keepHosts -join ',') -or (Comparable $read) -cne (Comparable $app)){throw "Access readback differs for $($app.name)."}
    }
}finally{
    $token.Dispose()
    $report|ConvertTo-Json -Depth 5
}
