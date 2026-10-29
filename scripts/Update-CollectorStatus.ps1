[CmdletBinding()]
param(
    [string]$AppsRoot = 'C:\ProgramData\SolutionDeploy\apps',
    [string]$OutputPath = 'C:\ProgramData\SolutionDeploy\apps\solution-deploy\data\collector-status.json',
    [string]$PsqlPath = 'C:\Program Files\PostgreSQL\18\bin\psql.exe',
    [int]$RunDays = 30,
    [int]$AuditDays = 30
)
# Builds collector-status.json (schema v1) for the Solution Directory /collectors page.
# Database access is read-only: every session runs with default_transaction_read_only=on.
$ErrorActionPreference = 'Stop'
$errors = [System.Collections.Generic.List[string]]::new()

# Schedules mirror stock-collector\collector\model.py, collector\reference.py and
# web-options\collector\model.py. Times are Pacific.
$jobs = @(
    [ordered]@{ id = 'stock-prices'; name = 'Stock prices'; app = 'Web Portfolio'
        schedule = 'Trading days: Session every 10 minutes 06:00-12:50, Close 13:00, Settle 13:10. Every day: Final settle 17:00.' }
    [ordered]@{ id = 'indices'; name = 'Index closes'; app = 'Web Portfolio'; schedule = 'Daily 03:00. Weekdays: Daily 20:00.' }
    [ordered]@{ id = 'earnings'; name = 'Earnings dates'; app = 'Web Portfolio'; schedule = 'Daily 05:00.' }
    [ordered]@{ id = 'splits'; name = 'Stock splits'; app = 'Web Portfolio'; schedule = 'Weekdays: Daily 06:45.' }
    [ordered]@{ id = 'option-quotes'; name = 'Option quotes'; app = 'Web Options'
        schedule = 'Trading days: Session every 10 minutes 06:35-12:55, Close 13:00. Weekdays: Settle 13:10.' }
    [ordered]@{ id = 'stock-audit'; name = 'Stock audit'; app = 'Web Portfolio'; schedule = 'Daily 17:30.' }
    [ordered]@{ id = 'options-audit'; name = 'Options audit'; app = 'Web Options'; schedule = 'Daily 13:30.' }
)

$stockSql = @"
SELECT json_build_object(
  'runs', COALESCE((SELECT json_agg(r ORDER BY r."scheduledAt") FROM (
    SELECT 'stock-prices' AS job, capture_kind AS kind, scheduled_at AS "scheduledAt", started_at AS "startedAt",
           finished_at AS "finishedAt", status, expected_count AS expected, ok_count AS ok,
           NULLIF(concat_ws(', ', NULLIF(stale_count, 0) || ' stale', NULLIF(missing_count, 0) || ' missing',
                            discovery_error), '') AS detail
    FROM public.stock_collection_run WHERE scheduled_at >= now() - interval '$RunDays days' AND scheduled_at <= now()
    UNION ALL
    SELECT job, job, scheduled_at, started_at, finished_at, status, expected_count, returned_count,
           NULLIF(concat_ws(', ', NULLIF(no_data_count, 0) || ' no data', NULLIF(failed_count, 0) || ' failed', error), '')
    FROM public.reference_run WHERE scheduled_at >= now() - interval '$RunDays days' AND scheduled_at <= now()
  ) r), '[]'::json),
  'health', COALESCE((SELECT json_agg(h) FROM (
    SELECT 'stock-prices' AS job, heartbeat_at AS "heartbeatAt", last_error AS "lastError" FROM public.collector_health
    UNION ALL
    SELECT job, heartbeat_at, last_error FROM public.reference_job_health
  ) h), '[]'::json));
"@
$optionsSql = @"
SELECT json_build_object(
  'runs', COALESCE((SELECT json_agg(r ORDER BY r."scheduledAt") FROM (
    SELECT 'option-quotes' AS job, capture_kind AS kind, scheduled_at AS "scheduledAt", started_at AS "startedAt",
           finished_at AS "finishedAt", status, expected_count AS expected,
           LEAST(price_count, delta_count, iv_count) AS ok,
           NULLIF(concat_ws(', ', CASE WHEN expected_count > 0 THEN
                                'price ' || price_count || ', delta ' || delta_count || ', IV ' || iv_count END,
                            discovery_error), '') AS detail
    FROM public.option_collection_run WHERE scheduled_at >= now() - interval '$RunDays days' AND scheduled_at <= now()
  ) r), '[]'::json),
  'health', COALESCE((SELECT json_agg(h) FROM (
    SELECT 'option-quotes' AS job, heartbeat_at AS "heartbeatAt", last_error AS "lastError" FROM public.collector_health
  ) h), '[]'::json));
"@

function Read-Database([string]$Name, [string]$ConfigPath, [string]$Sql) {
    try {
        $conninfo = (Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json).postgres
        if (-not $conninfo) { throw 'config has no postgres connection' }
        $sqlFile = New-TemporaryFile
        try {
            Set-Content -LiteralPath $sqlFile -Value $Sql -Encoding utf8NoBOM
            $env:PGOPTIONS = '-c default_transaction_read_only=on -c statement_timeout=30000'
            $env:PGCONNECT_TIMEOUT = '10'
            $output = & $PsqlPath -X -q -A -t -v ON_ERROR_STOP=1 -d $conninfo -f $sqlFile 2>&1
            if ($LASTEXITCODE) { throw "psql exit $LASTEXITCODE`: $(($output | Out-String).Trim())" }
            return (($output | Out-String).Trim() | ConvertFrom-Json)
        }
        finally { Remove-Item -LiteralPath $sqlFile -Force -ErrorAction SilentlyContinue }
    }
    catch {
        $errors.Add("$Name database: $($_.Exception.Message)")
        return [pscustomobject]@{ runs = @(); health = @() }
    }
}

$stock = Read-Database 'web_portfolio' "$AppsRoot\web-portfolio\shared\secrets\stock-collector\collector.json" $stockSql
$options = Read-Database 'web_options' "$AppsRoot\web-options\shared\secrets\collector\collector.json" $optionsSql

$cutoff = (Get-Date).Date.AddDays(-$AuditDays)
$audits = foreach ($source in @(
        @{ Job = 'stock-audit'; Audit = 'Stock'; Path = "$AppsRoot\web-portfolio\shared\logs\audit"; Filter = 'stock-*.json' }
        @{ Job = 'options-audit'; Audit = 'Options'; Path = "$AppsRoot\web-options\shared\logs\audit"; Filter = 'options-*.json' }
    )) {
    if (-not (Test-Path -LiteralPath $source.Path)) { $errors.Add("$($source.Audit) audit folder is missing."); continue }
    foreach ($file in Get-ChildItem -LiteralPath $source.Path -Filter $source.Filter | Where-Object LastWriteTime -GE $cutoff) {
        $written = $file.LastWriteTime.ToString('o')
        try { $report = Get-Content -LiteralPath $file.FullName -Raw | ConvertFrom-Json }
        catch {
            [ordered]@{ job = $source.Job; audit = $source.Audit; date = ($file.BaseName -replace '^\w+-', ''); subject = $file.Name
                status = 'unreadable'; informational = $false; writtenAt = $written }
            continue
        }
        foreach ($section in $report.sections.PSObject.Properties) {
            [ordered]@{ job = $source.Job; audit = $source.Audit; date = [string]$report.date; subject = $section.Name
                status = [string]$section.Value.status; informational = [bool]$section.Value.informational; writtenAt = $written
                reportStatus = [string]$report.status
                counts = $section.Value.counts; error = [string]$section.Value.error }
        }
    }
}

$alertPath = Join-Path (Split-Path -Parent $OutputPath) 'collector-alerts.json'
$alertCutoff = (Get-Date).AddDays(-$AuditDays)
$alerts = @()
if (Test-Path -LiteralPath $alertPath) {
    # Alert history is written by the monitor; an unreadable file is not a collector error.
    try {
        $alerts = @(Get-Content -LiteralPath $alertPath -Raw | ConvertFrom-Json -ErrorAction Stop |
                Where-Object { $_.sentAt -and [datetimeoffset]$_.sentAt -ge $alertCutoff })
    }
    catch { Write-Warning "Alert history unreadable: $($_.Exception.Message)" }
}

$snapshot = [ordered]@{
    schemaVersion = 1
    generatedAt = (Get-Date).ToString('o')
    timeZone = 'America/Los_Angeles'
    jobs = $jobs
    runs = @($stock.runs) + @($options.runs)
    health = @($stock.health) + @($options.health)
    audits = @($audits)
    alerts = @($alerts)
    errors = @($errors)
}
$folder = Split-Path -Parent $OutputPath
New-Item -ItemType Directory -Force -Path $folder | Out-Null
$temp = Join-Path $folder ".collector-status.$PID.tmp"
$snapshot | ConvertTo-Json -Depth 8 -Compress | Set-Content -LiteralPath $temp -Encoding utf8NoBOM
Move-Item -LiteralPath $temp -Destination $OutputPath -Force
if ($errors.Count) { Write-Warning ($errors -join '; ') }
"collector-status: $($snapshot.runs.Count) runs, $($snapshot.audits.Count) audit rows, $($errors.Count) errors"
