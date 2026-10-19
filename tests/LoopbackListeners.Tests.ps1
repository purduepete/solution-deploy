#Requires -Version 7.5
Import-Module (Join-Path $PSScriptRoot '..\src\Lifecycle.psm1') -Force

Describe 'Loopback origin listener ownership' {
    InModuleScope Lifecycle {
        It 'ignores a same-port Tailscale listener' {
            Mock Get-NetTCPConnection {
                [pscustomobject]@{ LocalAddress = '100.89.203.69'; OwningProcess = 5308 }
            }
            $ids = Get-PortListenerProcessId -Port 8788
            $ids.Count | Should Be 0
        }

        It 'keeps loopback and wildcard conflicts while ignoring other interfaces' {
            Mock Get-NetTCPConnection {
                foreach ($address in @('127.0.0.1', '0.0.0.0', '::1', '::', '::ffff:127.0.0.1')) {
                    [pscustomobject]@{ LocalAddress = $address; OwningProcess = 1234 }
                }
                [pscustomobject]@{ LocalAddress = '192.168.2.14'; OwningProcess = 5678 }
            }
            $ids = Get-PortListenerProcessId -Port 8788
            $ids.Count | Should Be 1
            $ids[0] | Should Be 1234
        }
    }
}
