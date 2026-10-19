#requires -Version 7.5
# Packs a frozen export (transfer.json plus only its declared files) into one create-only ZIP.
# Runs locally on the source; makes no database, service or network calls.
[CmdletBinding(SupportsShouldProcess,ConfirmImpact='Medium')]
param(
    [Parameter(Mandatory)][string]$ExportDirectory,
    [Parameter(Mandatory)][string]$ApprovedTransferSHA256,
    [Parameter(Mandatory)][string]$OutputRoot,
    [Parameter(Mandatory)][string]$ArchiveName,
    [ValidateSet('Fastest','Optimal','SmallestSize')][string]$CompressionLevel='Optimal'
)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$framework=Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $framework 'src\Deployment.psm1') -DisableNameChecking
Import-Module (Join-Path $framework 'src\Transfer.psm1') -DisableNameChecking
if($PSCmdlet.ShouldProcess((Join-Path $OutputRoot $ArchiveName),"Create transfer archive from $ExportDirectory")){
    $clock=[Diagnostics.Stopwatch]::StartNew()
    $result=New-TransferArchive -ExportDirectory $ExportDirectory -ApprovedTransferSHA256 $ApprovedTransferSHA256 `
        -OutputRoot $OutputRoot -ArchiveName $ArchiveName -CompressionLevel $CompressionLevel
    $result.elapsedSeconds=[math]::Round($clock.Elapsed.TotalSeconds,1)
    [pscustomobject]$result
}