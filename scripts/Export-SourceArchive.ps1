#requires -Version 7.4
[CmdletBinding()]
param([Parameter(Mandatory)][string]$PlanPath,[Parameter(Mandatory)][string]$OutputPath)
$ErrorActionPreference='Stop'
Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'src\Deployment.psm1') -DisableNameChecking
$plan = Read-DeploymentJson $PlanPath
Assert-PlanInputs $plan
$root = Split-Path -Parent $PSScriptRoot
$environment = Get-DeploymentEnvironment $plan.environment
$manifest = [IO.Path]::GetFullPath((Join-Path $root $environment.Value.apps[$plan.app].manifest))
$repository = Split-Path -Parent (Split-Path -Parent $manifest)
$git = (Get-Command git -CommandType Application).Source
$dirty = Invoke-DeploymentCommand $git @('--no-optional-locks','status','--porcelain','--untracked-files=normal') $repository -Capture
if ($dirty) { throw 'Commit the reviewed app changes before producing a production artifact.' }
if (Test-Path -LiteralPath $OutputPath) { throw 'Choose a new artifact output path.' }
[IO.Directory]::CreateDirectory((Split-Path -Parent ([IO.Path]::GetFullPath($OutputPath)))) | Out-Null
Invoke-DeploymentCommand $git @('archive','--format=zip',('-o'+[IO.Path]::GetFullPath($OutputPath)),$plan.sourceCommit) $repository
@{planHash=$plan.planHash;sourceArchiveSHA256=(Get-FileHash -LiteralPath $OutputPath).Hash.ToLowerInvariant();sourceCommit=$plan.sourceCommit}
