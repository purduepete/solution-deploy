$script:hostnamesScript=Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts\Set-CloudflareHostnames.ps1'
Describe 'Google sign-in on allowlisted applications' {
    BeforeEach {
        $global:cfTest_names=@('ferry-tracker','home-automation','site-dock','fit-track','web-bookmarks','plex','work-log','web-inventory','web-portfolio','web-options',        'solution-deploy','team-scoreboard','the-workbench')
                $global:cfTest_ports=@(8787,8788,8790,8791,8792,18793,18794,18795,18796,18797,18798,8801,8802)
        $global:cfTest_owner=@{
            id='owner';name='Owner';decision='allow';precedence=1
            include=@(@{email=@{email='owner@example.com'}})
            exclude=@();require=@(@{login_method=@{id='microsoft'}})
        }
        $global:cfTest_fakePolicies=@($global:cfTest_owner)
        $global:cfTest_fakeApps=@(foreach($name in $global:cfTest_names){
            @{id=$name;name=$name;domain="$name.jimlertech.com";self_hosted_domains=@("$name.jimlertech.com")
              allowed_idps=@('microsoft');auto_redirect_to_identity=$false;policies=@($global:cfTest_owner)}
        })
        $global:cfTest_fakeApps+=@{id='catch';domain='ferry-tracker.jimlertech.com/api/catch';self_hosted_domains=@('ferry-tracker.jimlertech.com/api/catch');policies=@(@{id='bypass';decision='bypass'})}
        $global:cfTest_dns=@(foreach($name in $global:cfTest_names){
            @{id=$name;name="$name.jimlertech.com";type='CNAME';content='209bf0e7-20c1-45b9-bba9-fca92fc58344.cfargotunnel.com';proxied=$true}
        })
        $global:cfTest_config=@{ingress=@(
            for($i=0;$i -lt $global:cfTest_names.Count;$i++){
                @{hostname="$($global:cfTest_names[$i]).jimlertech.com";service="http://127.0.0.1:$($global:cfTest_ports[$i])"}
            }
            @{service='http_status:404'}
        )}
        $global:cfTest_writes=0
        Mock Import-Clixml {ConvertTo-SecureString 'synthetic' -AsPlainText -Force}
        Mock Invoke-RestMethod {
            param($Uri,$Method,$Body)
            $result=$null
            if($Uri -match '/policies/([^/?]+)$'){
                $id=$Matches[1]
                if($Method -eq 'Put'){
                    $global:cfTest_writes++
                    $new=$Body|ConvertFrom-Json -AsHashtable
                    $new.id=$id
                    $global:cfTest_fakePolicies=@($global:cfTest_fakePolicies|Where-Object id -ne $id)+@($new)
                }
                $result=$global:cfTest_fakePolicies|Where-Object id -eq $id
            }elseif($Uri -match '/dns_records' -and $Method -eq 'Post'){
                $global:cfTest_writes++
                $new=$Body|ConvertFrom-Json -AsHashtable
                $new.id=$new.name
                $global:cfTest_dns+=,$new
                $result=$new
            }elseif($Uri -match '/dns_records/([^/?]+)$' -and $Method -eq 'Delete'){
                $global:cfTest_writes++
                $id=$Matches[1]
                $global:cfTest_dns=@($global:cfTest_dns|Where-Object id -ne $id)
                $result=$null
            }elseif($Uri -match '/configurations$' -and $Method -eq 'Put'){
                $global:cfTest_writes++
                $new=$Body|ConvertFrom-Json -AsHashtable
                $global:cfTest_config=$new.config
                $result=@{config=$global:cfTest_config}
            }elseif($Uri -match '/configurations$'){
                $result=@{config=$global:cfTest_config}
            }elseif($Method -eq 'Post'){
                $global:cfTest_writes++
                $new=$Body|ConvertFrom-Json -AsHashtable
                $new.id='google-owner'
                $global:cfTest_fakePolicies+=,$new
                $result=$new
            }elseif($Method -eq 'Put'){
                $global:cfTest_writes++
                $new=$Body|ConvertFrom-Json -AsHashtable
                $new.id=($Uri -split '/')[-1]
                foreach($policy in $new.policies){
                    if($policy.precedence -isnot [long] -and $policy.precedence -isnot [int]){throw 'Policy precedence must be an integer.'}
                }
                $new.policies=@(foreach($policy in $new.policies){
                    $attached=@{}+($global:cfTest_fakePolicies|Where-Object id -eq $policy.id)
                    $attached.precedence=$policy.precedence
                    $attached
                })
                $global:cfTest_fakeApps=@($global:cfTest_fakeApps|Where-Object id -ne $new.id)+@($new)
                $result=$new
            }elseif($Uri -match '/dns_records'){
                $result=$global:cfTest_dns
                if($Uri -match '\?name=([^&]+)$'){$result=@($result|Where-Object name -eq $Matches[1])}
            }elseif($Uri -match '/identity_providers$'){
                $result=@(@{id='google';type='google'},@{id='microsoft';type='azureAD'})
            }elseif($Uri -match '/policies\?'){
                $result=$global:cfTest_fakePolicies
            }elseif($Uri -match '/apps\?'){
                $result=$global:cfTest_fakeApps
            }elseif($Uri -match '/apps/'){
                $id=($Uri -split '/')[-1]
                $result=$global:cfTest_fakeApps|Where-Object id -eq $id
            }else{throw "Unexpected API request: $Method $Uri"}
            @{success=$true;result=$result}
        }
    }
    It 'adds a Google-only email once while preserving owner access and app settings' {
        $google=@{id='google-owner';name='SolutionDeploy owner - Google';decision='allow'
            include=@(@{email=@{email='owner@example.com'}});exclude=@();require=@(@{login_method=@{id='google'}})}
        $global:cfTest_fakePolicies+=,$google
        foreach($app in $global:cfTest_fakeApps|Where-Object id -ne 'catch'){$app.policies+=,$google}
        $before=$global:cfTest_fakeApps|ConvertTo-Json -Depth 30 -Compress
        $preview=& $script:hostnamesScript -AddGoogleEmail 'guest@gmail.com'|ConvertFrom-Json
        $preview.applications.Count|Should Be 13
        $global:cfTest_writes|Should Be 0
        $result=& $script:hostnamesScript -AddGoogleEmail 'guest@gmail.com' -Apply|ConvertFrom-Json
        $result.added|Should Be $true
        $global:cfTest_writes|Should Be 1
        ($global:cfTest_fakePolicies|Where-Object id -eq 'google-owner').include.Count|Should Be 2
        ($global:cfTest_fakePolicies|Where-Object id -eq 'owner').include.Count|Should Be 1
        ($global:cfTest_fakeApps|ConvertTo-Json -Depth 30 -Compress)|Should Be $before
        $null=& $script:hostnamesScript -AddGoogleEmail 'guest@gmail.com' -Apply
        $global:cfTest_writes|Should Be 1
    }
    It 'rejects wildcard email access before making API requests' {
        $rejected=$false
        try { & $script:hostnamesScript -AddGoogleEmail '*@gmail.com' -Apply } catch { $rejected=$true }
        $rejected|Should Be $true
        $global:cfTest_writes|Should Be 0
    }
    It 'previews all thirteen applications without writing' {
        $report=& $script:hostnamesScript -EnableGoogleSignIn|ConvertFrom-Json
        $report.googleSignIn.Count|Should Be 13
        $global:cfTest_writes|Should Be 0
    }
    It 'previews WorkLog publication without writing' {
        $report=& $script:hostnamesScript -PublishWorkLog|ConvertFrom-Json
        $report.publish|Should Be 'work-log.jimlertech.com'
        $global:cfTest_writes|Should Be 0
    }
    It 'renames the Workbench hostname and preserves its owner policy' {
        $global:cfTest_names=@($global:cfTest_names|Where-Object {$_ -ne 'the-workbench'})+@('idea-notes')
        $global:cfTest_ports=@($global:cfTest_ports|Where-Object {$_ -ne 8802})+@(8802)
        $global:cfTest_fakeApps=@($global:cfTest_fakeApps|Where-Object id -ne 'the-workbench')
        $global:cfTest_fakeApps+=@{
            id='idea-notes';name='Idea Notes';domain='idea-notes.jimlertech.com'
            self_hosted_domains=@('idea-notes.jimlertech.com')
            destinations=@(@{type='public';uri='idea-notes.jimlertech.com'})
            allowed_idps=@('microsoft');auto_redirect_to_identity=$false;policies=@($global:cfTest_owner)
        }
        $global:cfTest_dns=@(foreach($name in $global:cfTest_names){
            @{id=$name;name="$name.jimlertech.com";type='CNAME';content='209bf0e7-20c1-45b9-bba9-fca92fc58344.cfargotunnel.com';proxied=$true}
        })
        $global:cfTest_config=@{ingress=@(
            for($i=0;$i -lt $global:cfTest_names.Count;$i++){
                @{hostname="$($global:cfTest_names[$i]).jimlertech.com";service="http://127.0.0.1:$($global:cfTest_ports[$i])"}
            }
            @{service='http_status:404'}
        )}

        $report=& $script:hostnamesScript -PublishTheWorkbench -Apply|ConvertFrom-Json

        $report.hostnameRenamed|Should Be $true
        $global:cfTest_writes|Should Be 5
        $app=$global:cfTest_fakeApps|Where-Object id -eq 'idea-notes'
        $app.name|Should Be 'The Workbench'
        $app.domain|Should Be 'the-workbench.jimlertech.com'
        $app.self_hosted_domains|Should Be @('the-workbench.jimlertech.com')
        $app.policies[0].id|Should Be 'owner'
        @($global:cfTest_dns|Where-Object name -eq 'idea-notes.jimlertech.com').Count|Should Be 0
        @($global:cfTest_dns|Where-Object name -eq 'the-workbench.jimlertech.com').Count|Should Be 1
        @($global:cfTest_config.ingress|Where-Object hostname -eq 'idea-notes.jimlertech.com').Count|Should Be 0
        @($global:cfTest_config.ingress|Where-Object hostname -eq 'the-workbench.jimlertech.com').Count|Should Be 1
    }
    It 'previews WebInventory publication without writing' {
        $report=& $script:hostnamesScript -PublishWebInventory|ConvertFrom-Json
        $report.publish|Should Be 'web-inventory.jimlertech.com'
        $global:cfTest_writes|Should Be 0
    }
    It 'previews Portfolio publication with Options still pending' {
        $global:cfTest_names=@($global:cfTest_names|Where-Object {$_ -ne 'web-options'})
        $global:cfTest_ports=@($global:cfTest_ports|Where-Object {$_ -ne 18797})
        $report=& $script:hostnamesScript -PublishWebPortfolio|ConvertFrom-Json
        $report.publish|Should Be 'web-portfolio.jimlertech.com'
        $global:cfTest_writes|Should Be 0
    }
    It 'previews Options publication without writing' {
        $report=& $script:hostnamesScript -PublishWebOptions|ConvertFrom-Json
        $report.publish|Should Be 'web-options.jimlertech.com'
        $global:cfTest_writes|Should Be 0
    }
    It 'previews directory publication without requiring its existing route' {
        $global:cfTest_names=@($global:cfTest_names|Where-Object {$_ -ne 'solution-deploy'})
        $global:cfTest_ports=@($global:cfTest_ports|Where-Object {$_ -ne 18798})
        $report=& $script:hostnamesScript -PublishDirectory|ConvertFrom-Json
        $report.publish|Should Be 'solution-deploy.jimlertech.com'
        $global:cfTest_writes|Should Be 0
    }
    It 'preserves an already published directory and its owner policies' {
        $null=& $script:hostnamesScript -EnableGoogleSignIn -Apply
        $before=$global:cfTest_writes
        $report=& $script:hostnamesScript -PublishDirectory -Apply|ConvertFrom-Json
        $report.publish|Should Be 'solution-deploy.jimlertech.com'
        $global:cfTest_writes|Should Be $before
    }
    It 'rejects simultaneous publication requests' {
        $thrown=$false
        try{& $script:hostnamesScript -PublishWebPortfolio -PublishWebOptions|Out-Null}catch{$thrown=$true}
        $thrown|Should Be $true
        $global:cfTest_writes|Should Be 0
    }
    It 'preserves an already published WebInventory route without writes' {
        $null=& $script:hostnamesScript -EnableGoogleSignIn -Apply
        $before=$global:cfTest_writes
        $report=& $script:hostnamesScript -PublishWebInventory -Apply|ConvertFrom-Json
        $report.publish|Should Be 'web-inventory.jimlertech.com'
        $global:cfTest_writes|Should Be $before
    }
    It 'preserves an already published WorkLog route without writes' {
        $null=& $script:hostnamesScript -EnableGoogleSignIn -Apply
        $before=$global:cfTest_writes
        $report=& $script:hostnamesScript -PublishWorkLog -Apply|ConvertFrom-Json
        $report.publish|Should Be 'work-log.jimlertech.com'
        $global:cfTest_writes|Should Be $before
    }
    It 'refuses to remove additional owner policy requirements' {
        foreach($app in ($global:cfTest_fakeApps|Where-Object id -ne 'catch')){
            $app.policies[0].require=@(@{login_method=@{id='microsoft'}},@{country=@{country_code='US'}})
        }
        $thrown=$false
        try{& $script:hostnamesScript -EnableGoogleSignIn -Apply|Out-Null}catch{$thrown=$true}
        $thrown|Should Be $true
        $global:cfTest_writes|Should Be 0
    }
    It 'preserves Microsoft, owner emails and the catch bypass when applied twice' {
        $null=& $script:hostnamesScript -EnableGoogleSignIn -Apply
        $null=& $script:hostnamesScript -EnableGoogleSignIn -Apply
        @($global:cfTest_fakePolicies|Where-Object id -eq 'google-owner').Count|Should Be 1
        foreach($app in ($global:cfTest_fakeApps|Where-Object id -ne 'catch')){
            ($app.allowed_idps -contains 'google')|Should Be $true
            ($app.allowed_idps -contains 'microsoft')|Should Be $true
            ($app.policies.id -contains 'owner')|Should Be $true
            ($app.policies.id -contains 'google-owner')|Should Be $true
        }
        $google=$global:cfTest_fakePolicies|Where-Object id -eq 'google-owner'
        $google.include[0].email.email|Should Be 'owner@example.com'
        $google.require[0].login_method.id|Should Be 'google'
        ($global:cfTest_fakeApps|Where-Object id -eq 'catch').policies[0].id|Should Be 'bypass'
    }
    AfterEach {
        Remove-Variable -Scope Global -Name cfTest_names,cfTest_ports,cfTest_owner,cfTest_fakePolicies,cfTest_fakeApps,cfTest_dns,cfTest_config,cfTest_writes -ErrorAction SilentlyContinue
    }
}
