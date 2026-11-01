$root=Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $root 'src\Deployment.psm1') -DisableNameChecking

Describe 'Release command master list' {
    $inventory=Read-DeploymentJson (Join-Path $root 'environments\releases.json')
    $controllers=@((Read-DeploymentJson (Join-Path $root 'environments\production.json')).apps.Keys)
    $sites=(Read-DeploymentJson (Join-Path $root 'site\sites.json')).sites
    $rows=@(Get-Content (Join-Path $root 'docs\ReleaseCommands.md') |
        Where-Object {$_ -match '^\| `[a-z0-9-]+`'} |
        ForEach-Object {
            $cells=@($_.Trim('|').Split('|')|ForEach-Object {$_.Replace('`','').Trim()})
            [pscustomobject]@{App=$cells[0];Component=$cells[1];Flags=$cells[2];Procedure=$cells[3]}
        })

    It 'lists every app in the release inventory and nothing else' {
        (@($rows.App|Sort-Object -Unique) -join ',')|Should Be (@($inventory.apps.Keys|Sort-Object) -join ',')
    }
    It 'gives controller apps one row with no -Component and their Tailscale URL when the manifest lacks it' {
        foreach($app in $controllers){
            $row=@($rows|Where-Object App -eq $app)
            $row.Count|Should Be 1
            $row[0].Procedure|Should Be controller
            $row[0].Flags|Should Not Match '-Component'
            $row[0].Flags|Should Match "-App $app( |$)"
            if($row[0].Flags -match '-TailscaleUrl (\S+)'){
                $site=$sites|Where-Object id -eq $app
                $Matches[1].TrimEnd('/')|Should Be ([string]$site.tailscaleUrl).TrimEnd('/')
            }
        }
    }
    It 'gives every other component its own row with the matching procedure and flags' {
        foreach($app in @($inventory.apps.Keys|Where-Object {$_ -notin $controllers})){
            $entry=$inventory.apps[$app]
            $listed=@($rows|Where-Object App -eq $app)
            (@($listed.Component|Sort-Object) -join ',')|Should Be (@($entry.components|Sort-Object) -join ',')
            foreach($row in $listed){
                $external=$entry.ContainsKey('externalComponents') -and $entry.externalComponents.ContainsKey($row.Component)
                $expected=if($external){'external'}
                    elseif($entry.ContainsKey('jobs') -and $entry.jobs.ContainsKey($row.Component)){'pinned-job'}
                    elseif($entry.ContainsKey('componentProcedures')){$entry.componentProcedures[$row.Component]}
                    else{$entry.procedure}
                $row.Procedure|Should Be $expected
                if($expected -in @('external','manual')){continue}
                $row.Flags|Should Match "-App $app( |$)"
                $defaulted=$entry.ContainsKey('defaultComponents') -and @($entry.defaultComponents) -contains $row.Component
                $needsComponent=$listed.Count -gt 1 -or ($entry.ContainsKey('explicitComponents') -and $entry.explicitComponents)
                if($needsComponent -and -not $defaulted){$row.Flags|Should Match "-Component $($row.Component)( |$)"}
                if($row.Flags -match '-Component (\S+)'){$Matches[1]|Should Be $row.Component}
            }
        }
    }
}
