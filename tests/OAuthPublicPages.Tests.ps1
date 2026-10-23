# Requires Pester 3.4. Every API request is mocked.
$publisher = Join-Path $PSScriptRoot '..\scripts\Set-CloudflareHostnames.ps1'
Describe 'Fit Track public OAuth pages' {
    BeforeEach {
        $global:OAuthPagesFixture = @{
            Parent = @{id='parent';domain='fit-track.jimlertech.com';policies=@(@{id='owner';decision='allow'})}
            Public = $null
            Writes = 0
        }
        Mock Import-Clixml { ConvertTo-SecureString 'fixture' -AsPlainText -Force }
        Mock Invoke-RestMethod {
            param($Uri,$Method,$Body)
            $path=([uri]$Uri).AbsolutePath
            $base='/client/v4/accounts/ec74856ed4fe9f15833c5419011f2507/access/apps'
            if($Method -eq 'Get' -and $path -eq $base){
                $result=@($global:OAuthPagesFixture.Parent)
                if($global:OAuthPagesFixture.Public){$result+=,$global:OAuthPagesFixture.Public}
            }elseif($Method -eq 'Get' -and $path -eq "$base/parent"){
                $result=$global:OAuthPagesFixture.Parent
            }elseif($Method -eq 'Post' -and $path -eq $base){
                $global:OAuthPagesFixture.Writes++
                $global:OAuthPagesFixture.Public=ConvertFrom-Json $Body -AsHashtable
                $global:OAuthPagesFixture.Public.id='public'
                $global:OAuthPagesFixture.Public.policies[0].id='bypass'
                $result=$global:OAuthPagesFixture.Public
            }elseif($Method -eq 'Get' -and $path -eq "$base/public"){
                $result=$global:OAuthPagesFixture.Public
            }elseif($Method -eq 'Get' -and $path -eq "$base/public/policies/bypass"){
                $result=$global:OAuthPagesFixture.Public.policies[0]
            }else{throw "Unexpected API request: $Method $path"}
            @{success=$true;result=$result}
        }
        AfterEach { Remove-Variable OAuthPagesFixture -Scope Global }
    }
    It 'previews without creating an exception' {
        & $publisher -PublishFitTrackOAuthPages | Out-Null
        $global:OAuthPagesFixture.Writes | Should Be 0
    }
    It 'creates only the informational exception and preserves its parent' {
        $before=$global:OAuthPagesFixture.Parent|ConvertTo-Json -Depth 20 -Compress
        & $publisher -PublishFitTrackOAuthPages -Apply | Out-Null
        $global:OAuthPagesFixture.Writes | Should Be 1
        $global:OAuthPagesFixture.Public.domain | Should Be 'fit-track.jimlertech.com/oauth/*'
        $global:OAuthPagesFixture.Public.policies[0].decision | Should Be 'bypass'
        ($global:OAuthPagesFixture.Parent|ConvertTo-Json -Depth 20 -Compress) | Should Be $before
        & $publisher -PublishFitTrackOAuthPages -Apply | Out-Null
        $global:OAuthPagesFixture.Writes | Should Be 1
    }
    It 'refuses a parent with an existing bypass' {
        $global:OAuthPagesFixture.Parent.policies+=@{id='unsafe';decision='bypass'}
        { & $publisher -PublishFitTrackOAuthPages -Apply } | Should Throw 'parent access policies require inspection'
        $global:OAuthPagesFixture.Writes | Should Be 0
    }
    It 'refuses an exception that also contains a private path' {
        $domain='fit-track.jimlertech.com/oauth/*'
        $global:OAuthPagesFixture.Public=@{id='public';domain=$domain;self_hosted_domains=@($domain,'fit-track.jimlertech.com/api/*')
            destinations=@(@{uri=$domain});policies=@(@{id='bypass';decision='bypass';include=@(@{everyone=@{}})})}
        { & $publisher -PublishFitTrackOAuthPages -Apply } | Should Throw 'readback differs'
        $global:OAuthPagesFixture.Writes | Should Be 0
    }
    It 'creates the Team Scoreboard calendar bypass beside its own parent' {
        $global:OAuthPagesFixture.Parent.domain='team-scoreboard.jimlertech.com'
        $before=$global:OAuthPagesFixture.Parent|ConvertTo-Json -Depth 20 -Compress
        & $publisher -PublishTeamScoreboardCalendar -Apply | Out-Null
        $global:OAuthPagesFixture.Writes | Should Be 1
        $global:OAuthPagesFixture.Public.domain | Should Be 'team-scoreboard.jimlertech.com/calendar/*'
        $global:OAuthPagesFixture.Public.policies[0].decision | Should Be 'bypass'
        ($global:OAuthPagesFixture.Parent|ConvertTo-Json -Depth 20 -Compress) | Should Be $before
    }
    It 'refuses the calendar bypass combined with another change' {
        { & $publisher -PublishTeamScoreboardCalendar -PublishTeamScoreboard } | Should Throw 'separately'
        $global:OAuthPagesFixture.Writes | Should Be 0
    }
}
