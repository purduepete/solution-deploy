#Requires -Version 7.5
Import-Module (Join-Path $PSScriptRoot '..\src\Lifecycle.psm1') -Force

Describe 'Loopback origin listener ownership' {
    InModuleScope Lifecycle {
        It 'ignores a same-port Tailscale listener' {
            Mock Get-NetTCPConnection {
                [pscustomobject]@{ LocalAddress = '100.89.203.69'; RemotePort = 0; OwningProcess = 5308 }
            }
            $ids = Get-PortListenerProcessId -Port 8788
            $ids.Count | Should Be 0
        }

        It 'keeps loopback and wildcard conflicts while ignoring other interfaces' {
            Mock Get-NetTCPConnection {
                foreach ($address in @('127.0.0.1', '0.0.0.0', '::1', '::', '::ffff:127.0.0.1')) {
                    [pscustomobject]@{ LocalAddress = $address; RemotePort = 0; OwningProcess = 1234 }
                }
                [pscustomobject]@{ LocalAddress = '192.168.2.14'; RemotePort = 0; OwningProcess = 5678 }
            }
            $ids = Get-PortListenerProcessId -Port 8788
            $ids.Count | Should Be 1
            $ids[0] | Should Be 1234
        }

        It 'finds a listener whose State is misreported and ignores accepted connections' {
            Mock Get-NetTCPConnection {
                [pscustomobject]@{ LocalAddress = '127.0.0.1'; RemotePort = 0; State = 0; OwningProcess = 4321 }
                [pscustomobject]@{ LocalAddress = '127.0.0.1'; RemotePort = 61383; State = 5; OwningProcess = 9999 }
            }
            $ids = Get-PortListenerProcessId -Port 8802
            $ids.Count | Should Be 1
            $ids[0] | Should Be 4321
            Assert-MockCalled Get-NetTCPConnection -Times 1 -Exactly -Scope It -ParameterFilter { -not $PSBoundParameters.ContainsKey('State') }
        }
    }
}
