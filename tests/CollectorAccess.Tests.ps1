Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'src\CollectorAccess.psm1') -Force

InModuleScope CollectorAccess {
    Describe 'Scoped collector access preflight (no host tasks or accounts)' {
        BeforeEach {
            $script:fixture = Join-Path (Get-Location) ('.local\collector-access-fixtures\' + [guid]::NewGuid().ToString('N'))
            foreach ($directory in @('releases\one\collector', 'python', 'powershell', 'config', 'logs', 'control')) {
                New-Item -ItemType Directory -Path (Join-Path $script:fixture $directory) -Force | Out-Null
            }
            $script:release = Join-Path $script:fixture 'releases\one'
            $script:python = Join-Path $script:fixture 'python\python.exe'
            $script:pwsh = Join-Path $script:fixture 'powershell\pwsh.exe'
            $script:config = Join-Path $script:fixture 'config\collector.json'
            Set-Content (Join-Path $script:release 'collector\__init__.py') '# fixture'
            Set-Content $script:python 'not executed'
            Set-Content $script:pwsh 'not executed'
            Set-Content $script:config '{}'
            $script:arguments = @{
                ReleasePath = $script:release; PythonPath = $script:python; ConfigPath = $script:config
                PowerShellPath = $script:pwsh; ControlPath = (Join-Path $script:fixture 'control')
                WritableDirectories = @((Join-Path $script:fixture 'logs')); TimeoutSeconds = 10
            }
            Mock Assert-CollectorElevated {}
            Mock Assert-CollectorAdminDirectory {}
            # ACL writes and all scheduler operations are mocked, even on fixtures.
            $script:aclWrites = @()
            Mock Set-Acl {
                $script:aclWrites += [pscustomobject]@{ Path = $LiteralPath; Sddl = $AclObject.Sddl }
            }
            Mock Register-ScheduledTask {}
            Mock Stop-ScheduledTask {}
            Mock Unregister-ScheduledTask {}
            Mock Get-ScheduledTask { [pscustomobject]@{ Principal = [pscustomobject]@{ UserId = 'S-1-5-19'; LogonType = 'ServiceAccount' } } }
            Mock Start-ScheduledTask {
                $manifest = Get-ChildItem (Join-Path $script:fixture 'control') -Filter manifest.json -Recurse |
                    Get-Content -Raw | ConvertFrom-Json
                $script:probeReadFiles = $manifest.ReadFiles
                @{ Success = $true; Sid = 'S-1-5-19'; Error = '' } | ConvertTo-Json |
                    Set-Content -LiteralPath $manifest.ResultPath
            }
        }
        AfterEach {
            Remove-Item -LiteralPath $script:fixture -Recurse -Force
        }
        It 'grants only selected release code and keeps an original SDDL snapshot' {
            $result = Invoke-CollectorAccessPreflight @script:arguments
            $result.Success | Should Be $true
            $saved = @(Get-Content $result.AclSnapshot -Raw | ConvertFrom-Json)
            $saved.Count | Should Be 3
            foreach ($entry in $saved) {
                $entry.Path.StartsWith($script:release) | Should Be $true
                [string]::IsNullOrEmpty($entry.Sddl) | Should Be $false
            }
            Assert-MockCalled Set-Acl -Times 0 -Scope It -ParameterFilter {
                $LiteralPath -eq (Split-Path -Parent $script:release) -or
                $LiteralPath -eq $script:config -or $LiteralPath -eq $script:python
            }
            Assert-MockCalled Set-Acl -Times 1 -Exactly -Scope It -ParameterFilter { $LiteralPath.StartsWith($script:release) }
            Assert-MockCalled Register-ScheduledTask -Times 1 -Exactly -Scope It -ParameterFilter { $TaskPath -eq '\JimlerTech\' }
            $copiedModule = @($script:probeReadFiles | Where-Object { $_ -like '*\control\*\CollectorAccess.psm1' })
            $copiedModule.Count | Should Be 1
            Test-Path -LiteralPath $copiedModule[0] | Should Be $true
            ($script:probeReadFiles -contains (Join-Path (Split-Path -Parent $PSScriptRoot) 'src\CollectorAccess.psm1')) | Should Be $false
            Assert-MockCalled Unregister-ScheduledTask -Times 1 -Exactly -Scope It
            foreach ($write in ($script:aclWrites | Where-Object { $_.Path.StartsWith($script:release) })) {
                $write.Sddl | Should Match '\(A;(OICI|);0x1200a9;;;LS\)'
                $write.Sddl | Should Not Match '\(A;[^;]*;(FA|FW|0x1f01ff);;;LS\)'
            }
        }
        It 'handles a moved release with blocked inheritance without changing parents' {
            $moved = Join-Path $script:fixture 'releases\two'
            Move-Item -LiteralPath $script:release -Destination $moved
            $script:arguments.ReleasePath = $moved
            Mock Get-Acl {
                $protectedAcl = [Security.AccessControl.DirectorySecurity]::new()
                $protectedAcl.SetAccessRuleProtection($true, $true)
                $protectedAcl
            } -ParameterFilter { $LiteralPath -like '*\releases\two\collector' }
            (Invoke-CollectorAccessPreflight @script:arguments).Success | Should Be $true
            Assert-MockCalled Set-Acl -Times 0 -Exactly -Scope It -ParameterFilter { $LiteralPath -like '*\releases\two\collector' }
        }
        It 'rejects secret-like files before grants or probe registration' {
            Set-Content (Join-Path $script:release '.env') 'fixture only'
            { Invoke-CollectorAccessPreflight @script:arguments } | Should Throw 'Secret-like'
            Assert-MockCalled Set-Acl -Times 0 -Scope It
            Assert-MockCalled Register-ScheduledTask -Times 0 -Scope It
        }
        It 'rejects a release junction before any ACL mutation' {
            $target = Join-Path $script:fixture 'outside'
            New-Item -ItemType Directory -Path $target | Out-Null
            $link = Join-Path $script:release 'linked'
            New-Item -ItemType Junction -Path $link -Target $target | Out-Null
            try {
                { Invoke-CollectorAccessPreflight @script:arguments } | Should Throw 'Reparse'
                Assert-MockCalled Set-Acl -Times 0 -Scope It
                Assert-MockCalled Register-ScheduledTask -Times 0 -Scope It
            }
            finally { [IO.Directory]::Delete($link) }
        }
        It 'includes venv dependencies and base runtime without granting either tree' {
            $venv = Join-Path $script:fixture 'venv'
            $base = Join-Path $script:fixture 'base'
            foreach ($directory in @("$venv\Scripts", "$venv\Lib\site-packages", "$base\Lib")) {
                New-Item -ItemType Directory -Path $directory -Force | Out-Null
            }
            Set-Content "$venv\pyvenv.cfg" "home = $base"
            Set-Content "$venv\Scripts\python.exe" 'not executed'
            Set-Content "$base\python.exe" 'not executed'
            $script:arguments.PythonPath = "$venv\Scripts\python.exe"
            Mock Start-ScheduledTask {
                $manifest = Get-ChildItem (Join-Path $script:fixture 'control') -Filter manifest.json -Recurse |
                    Get-Content -Raw | ConvertFrom-Json
                $script:manifestTrees = $manifest.ReadTrees
                @{ Success = $true; Sid = 'S-1-5-19'; Error = '' } | ConvertTo-Json |
                    Set-Content -LiteralPath $manifest.ResultPath
            }
            (Invoke-CollectorAccessPreflight @script:arguments).Success | Should Be $true
            ($script:manifestTrees -contains (Join-Path $script:fixture 'venv')) | Should Be $true
            ($script:manifestTrees -contains (Join-Path $script:fixture 'base')) | Should Be $true
            Assert-MockCalled Set-Acl -Times 0 -Scope It -ParameterFilter { $LiteralPath -like '*\venv*' -or $LiteralPath -like '*\base*' }
        }
        It 'fails closed on denied descendants before any ACL mutation' {
            Set-Content (Join-Path $script:release 'collector\denied.py') '# fixture'
            Mock Get-Acl { throw 'Access denied fixture' } -ParameterFilter { $LiteralPath -like '*\denied.py' }
            { Invoke-CollectorAccessPreflight @script:arguments } | Should Throw 'Access denied'
            Assert-MockCalled Set-Acl -Times 0 -Scope It
            Assert-MockCalled Register-ScheduledTask -Times 0 -Scope It
        }
        It 'can probe non-Python application files without running the application' {
            $script:arguments.Remove('PythonPath')
            $executable = Join-Path $script:release 'Example.Api.exe'
            Set-Content $executable 'never executed'
            $script:arguments.ReadPath = @($executable)
            Mock Start-ScheduledTask {
                $manifest = Get-ChildItem (Join-Path $script:fixture 'control') -Filter manifest.json -Recurse |
                    Get-Content -Raw | ConvertFrom-Json
                $script:manifestPython = $manifest.PythonPath
                $script:manifestFiles = $manifest.ReadFiles
                @{ Success = $true; Sid = 'S-1-5-19'; Error = '' } | ConvertTo-Json |
                    Set-Content -LiteralPath $manifest.ResultPath
            }
            (Invoke-CollectorAccessPreflight @script:arguments).Success | Should Be $true
            [string]::IsNullOrEmpty($script:manifestPython) | Should Be $true
            ($script:manifestFiles -contains $executable) | Should Be $true
        }
        It 'rolls back release ACLs and removes the temporary probe on denied runtime or config access' {
            Mock Start-ScheduledTask {
                $manifest = Get-ChildItem (Join-Path $script:fixture 'control') -Filter manifest.json -Recurse |
                    Get-Content -Raw | ConvertFrom-Json
                @{ Success = $false; Sid = 'S-1-5-19'; Error = 'runtime/config access denied fixture' } |
                    ConvertTo-Json | Set-Content -LiteralPath $manifest.ResultPath
            }
            { Invoke-CollectorAccessPreflight @script:arguments } | Should Throw 'runtime/config access denied'
            Assert-MockCalled Set-Acl -Times 4 -Exactly -Scope It -ParameterFilter { $LiteralPath.StartsWith($script:release) }
            Assert-MockCalled Unregister-ScheduledTask -Times 1 -Exactly -Scope It
            $failure = Get-ChildItem (Join-Path $script:fixture 'control') -Filter failure.json -Recurse |
                Get-Content -Raw | ConvertFrom-Json
            $failure.Error | Should Match 'runtime/config access denied'
            Test-Path $failure.AclSnapshot | Should Be $true
        }
        It 'rejects an unexpected scheduled principal before starting the probe' {
            Mock Get-ScheduledTask { [pscustomobject]@{ Principal = [pscustomobject]@{ UserId = 'NT AUTHORITY\SYSTEM'; LogonType = 'ServiceAccount' } } }
            { Invoke-CollectorAccessPreflight @script:arguments } | Should Throw 'principal read-back'
            Assert-MockCalled Start-ScheduledTask -Times 0 -Scope It
        }
        It 'rejects config inside code before granting anything' {
            $script:arguments.ConfigPath = Join-Path $script:release 'config.json'
            { Invoke-CollectorAccessPreflight @script:arguments } | Should Throw 'outside the release'
            Assert-MockCalled Set-Acl -Times 0 -Scope It
        }
    }
}

Describe 'Collector installer registration gates' {
    Mock Register-ScheduledTask {}
    Mock Invoke-CollectorAccessPreflight { throw 'Synthetic denied runtime/config' }
    $installers = @(
        'C:\Files\Dev\main\web-options\scripts\Install-CollectorTasks.ps1',
        'C:\Files\Dev\main\web-portfolio\stock-collector\scripts\Install-StockCollectorTasks.ps1',
        'C:\Files\Dev\main\web-portfolio\stock-collector\scripts\Install-ReferenceTasks.ps1'
    )
    foreach ($installer in $installers) {
        It "gates registration on access failure: $installer" {
            $text = Get-Content -LiteralPath $installer -Raw
            $text.IndexOf('Invoke-CollectorAccessPreflight') | Should BeLessThan $text.IndexOf('Register-ScheduledTask')
            $text | Should Match 'if \(-not \$access.Success -or \$access.Sid -ne ''S-1-5-19''\) \{ throw'
            $text | Should Not Match 'Get-Command pwsh'
            $text | Should Match 'C:\\ProgramData\\SolutionDeploy\\runtime\\powershell\\7\\pwsh.exe'
            # Run the exact access gate with a failed helper, with no installer side effects.
            $gate = [regex]::Match($text, 'if \(-not \$access.Success[^\r\n]+').Value
            $access = [pscustomobject]@{ Success = $false; Sid = 'S-1-5-19' }
            { & ([scriptblock]::Create($gate)) } | Should Throw 'tasks unchanged'
            $ReleasePath = 'C:\fixture\releases\one'
            $root = $ReleasePath
            $PythonPath = 'C:\fixture\python.exe'
            $ConfigPath = 'C:\fixture\config.json'
            $PowerShellPath = 'C:\fixture\pwsh.exe'
            $writeDirectories = @('C:\fixture\logs')
            $logs = $writeDirectories[0]
            $tail = $text.Substring($text.IndexOf('$access = Invoke-CollectorAccessPreflight'))
            { & ([scriptblock]::Create($tail)) } | Should Throw 'Synthetic denied'
            Assert-MockCalled Register-ScheduledTask -Times 0 -Scope It
        }
    }
}
