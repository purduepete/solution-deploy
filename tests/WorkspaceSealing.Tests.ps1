$root=Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $root 'src\Deployment.psm1') -Force -DisableNameChecking
function Invoke-WorkspaceSealing([string]$Path){
    & (Get-Module Deployment) {param($Release) Convert-NodeWorkspaceLinks $Release} $Path
}
function Assert-WorkspaceThrows([scriptblock]$Action){
    $thrown=$false
    try{&$Action|Out-Null}catch{$thrown=$true}
    $thrown|Should Be $true
}
Describe 'Link-free npm workspace release sealing' {
    BeforeEach {
        $script:release=Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path (Join-Path $script:release 'shared'),(Join-Path $script:release 'node_modules\@test')|Out-Null
        Write-DeploymentJson (Join-Path $script:release 'package.json') @{workspaces=@('shared')}
        Write-DeploymentJson (Join-Path $script:release 'shared\package.json') @{name='@test/shared'}
        [IO.File]::WriteAllText((Join-Path $script:release 'shared\index.js'),'export const value = 42;')
        New-Item -ItemType Junction -Path (Join-Path $script:release 'node_modules\@test\shared') -Target (Join-Path $script:release 'shared')|Out-Null
    }
    It 'replaces the declared internal link with independently inventoried files' {
        Invoke-WorkspaceSealing $script:release
        $link=Get-Item -LiteralPath (Join-Path $script:release 'node_modules\@test\shared')
        [bool]($link.Attributes -band [IO.FileAttributes]::ReparsePoint)|Should Be $false
        [IO.File]::ReadAllText((Join-Path $link.FullName 'index.js'))|Should Be 'export const value = 42;'
        @(Get-ReleaseInventory $script:release).Count|Should Be 5
    }
    It 'refuses a workspace link redirected to another directory' {
        $link=Join-Path $script:release 'node_modules\@test\shared'
        [IO.Directory]::Delete($link)
        $other=Join-Path $TestDrive ('other-'+[guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $other|Out-Null
        New-Item -ItemType Junction -Path $link -Target $other|Out-Null
        Assert-WorkspaceThrows {Invoke-WorkspaceSealing $script:release}
        [bool]((Get-Item -LiteralPath $link).Attributes -band [IO.FileAttributes]::ReparsePoint)|Should Be $true
    }
    It 'refuses nested links inside a declared workspace before deleting its package link' {
        New-Item -ItemType Junction -Path (Join-Path $script:release 'shared\nested') -Target $TestDrive|Out-Null
        Assert-WorkspaceThrows {Invoke-WorkspaceSealing $script:release}
        [bool]((Get-Item -LiteralPath (Join-Path $script:release 'node_modules\@test\shared')).Attributes -band [IO.FileAttributes]::ReparsePoint)|Should Be $true
    }
    It 'refuses patterns instead of expanding an unreviewed workspace list' {
        Write-DeploymentJson (Join-Path $script:release 'package.json') @{workspaces=@('packages/*')}
        Assert-WorkspaceThrows {Invoke-WorkspaceSealing $script:release}
    }
}
