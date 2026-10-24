[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ReleasePath,
    [string]$PythonPath,
    [Parameter(Mandatory)][string]$ConfigPath,
    [string[]]$WritableDirectories = @(),
    [Alias('ReadPath')][string[]]$AdditionalReadFiles = @(),
    [string]$PowerShellPath = 'C:\ProgramData\SolutionDeploy\runtime\powershell\7\pwsh.exe',
    [string]$CollectorAccessModulePath = 'C:\ProgramData\SolutionDeploy\control\framework\src\CollectorAccess.psm1',
    [ValidateRange(10, 300)][int]$TimeoutSeconds = 300
)
$ErrorActionPreference = 'Stop'
if (-not (Test-Path -LiteralPath $CollectorAccessModulePath -PathType Leaf)) {
    throw "Shared collector access helper missing: $CollectorAccessModulePath. Specify -CollectorAccessModulePath or install the control framework."
}
Import-Module $CollectorAccessModulePath -Force
$arguments = @{
    ReleasePath = $ReleasePath; PythonPath = $PythonPath; ConfigPath = $ConfigPath
    WritableDirectories = $WritableDirectories; AdditionalReadFiles = $AdditionalReadFiles
    PowerShellPath = $PowerShellPath; TimeoutSeconds = $TimeoutSeconds
}
Invoke-CollectorAccessPreflight @arguments
