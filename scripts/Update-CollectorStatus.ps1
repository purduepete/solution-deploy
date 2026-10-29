[CmdletBinding()]
param(
    [string]$AppsRoot = 'C:\ProgramData\SolutionDeploy\apps',
    [string]$OutputPath = 'C:\ProgramData\SolutionDeploy\apps\solution-deploy\data\collector-status.json',
    [string]$PsqlPath = 'C:\Program Files\PostgreSQL\18\bin\psql.exe',
    [int]$RunDays = 30,
    [int]$AlertDays = 30,
    [string]$MonitorPath = 'C:\ProgramData\SolutionDeploy\apps\solution-deploy\data\collector-monitor.json'
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
)

# deadline lets the monitor judge a run only after its retry window closes.
# vixOnly mirrors repository.expired_run: a run whose only shortfall is a stale VIX quote is acceptable.
$stockSql = @"
SELECT json_build_object(
  'runs', COALESCE((SELECT json_agg(r ORDER BY r."scheduledAt") FROM (
    SELECT 'stock-prices' AS job, r.capture_kind AS kind, r.scheduled_at AS "scheduledAt", r.deadline,
           r.started_at AS "startedAt", r.finished_at AS "finishedAt", r.status, r.expected_count AS expected,
           r.ok_count AS ok,
           (r.status='partial' AND r.stale_count=1 AND r.missing_count=0 AND r.ok_count+r.stale_count=r.expected_count
            AND EXISTS (SELECT 1 FROM public.stock_quote q WHERE q.run_id=r.id AND q.symbol='VIX' AND q.status='stale'))
             AS "vixOnly",
           NULLIF(concat_ws(', ', NULLIF(r.stale_count, 0) || ' stale', NULLIF(r.missing_count, 0) || ' missing',
                            r.discovery_error), '') AS detail
    FROM public.stock_collection_run r WHERE r.scheduled_at >= now() - interval '$RunDays days' AND r.scheduled_at <= now()
    UNION ALL
    SELECT job, job, scheduled_at, deadline, started_at, finished_at, status, expected_count, returned_count, false,
           NULLIF(concat_ws(', ', NULLIF(no_data_count, 0) || ' no data', NULLIF(failed_count, 0) || ' failed', error), '')
    FROM public.reference_run WHERE scheduled_at >= now() - interval '$RunDays days' AND scheduled_at <= now()
  ) r), '[]'::json),
  'health', COALESCE((SELECT json_agg(h) FROM (
    SELECT 'stock-prices' AS job, heartbeat_at AS "heartbeatAt", last_error AS "lastError", NULL::timestamptz AS "lastSuccessAt"
    FROM public.collector_health
    UNION ALL
    SELECT job, heartbeat_at, last_error, last_success_at FROM public.reference_job_health
  ) h), '[]'::json));
"@
# ok counts contracts with price, delta and IV all present, not the smallest of the three counts.
$optionsSql = @"
SELECT json_build_object(
  'runs', COALESCE((SELECT json_agg(r ORDER BY r."scheduledAt") FROM (
    SELECT 'option-quotes' AS job, r.capture_kind AS kind, r.scheduled_at AS "scheduledAt", r.deadline,
           r.started_at AS "startedAt", r.finished_at AS "finishedAt", r.status, r.expected_count AS expected,
           (SELECT count(*) FROM public.broker_option_quote q WHERE q.run_id=r.id
              AND q.price_status='ok' AND q.delta_status='ok' AND q.iv_status='ok')::int AS ok,
           NULLIF(concat_ws(', ', CASE WHEN r.expected_count > 0 THEN
                                'price ' || r.price_count || ', delta ' || r.delta_count || ', IV ' || r.iv_count END,
                            r.discovery_error), '') AS detail
    FROM public.option_collection_run r WHERE r.scheduled_at >= now() - interval '$RunDays days' AND r.scheduled_at <= now()
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

$alertPath = Join-Path (Split-Path -Parent $OutputPath) 'collector-alerts.json'
$alertCutoff = (Get-Date).AddDays(-$AlertDays)
$alerts = @()
if (Test-Path -LiteralPath $alertPath) {
    # Alert history is written by the monitor; an unreadable file is not a collector error.
    try {
        $alerts = @(Get-Content -LiteralPath $alertPath -Raw | ConvertFrom-Json -ErrorAction Stop |
                Where-Object { $_.sentAt -and [datetimeoffset]$_.sentAt -ge $alertCutoff })
    }
    catch { Write-Warning "Alert history unreadable: $($_.Exception.Message)" }
}
# Current monitor result, written each minute by Test-CollectorHealth.ps1. Shown on the page only.
$monitor = $null
if (Test-Path -LiteralPath $MonitorPath) {
    try { $monitor = Get-Content -LiteralPath $MonitorPath -Raw | ConvertFrom-Json -ErrorAction Stop }
    catch { Write-Warning "Monitor result unreadable: $($_.Exception.Message)" }
}

$snapshot = [ordered]@{
    schemaVersion = 1
    generatedAt = (Get-Date).ToString('o')
    timeZone = 'America/Los_Angeles'
    jobs = $jobs
    runs = @($stock.runs) + @($options.runs)
    health = @($stock.health) + @($options.health)
    monitor = $monitor
    alerts = @($alerts)
    errors = @($errors)
}
$folder = Split-Path -Parent $OutputPath
New-Item -ItemType Directory -Force -Path $folder | Out-Null
$temp = Join-Path $folder ".collector-status.$PID.tmp"
$snapshot | ConvertTo-Json -Depth 8 -Compress | Set-Content -LiteralPath $temp -Encoding utf8NoBOM
Move-Item -LiteralPath $temp -Destination $OutputPath -Force
if ($errors.Count) { Write-Warning ($errors -join '; ') }
"collector-status: $($snapshot.runs.Count) runs, $($errors.Count) errors"
