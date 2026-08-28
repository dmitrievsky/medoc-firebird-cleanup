<#
.SYNOPSIS
    STEP 2 of 3: Restore a backup into a NEW, separate database file, with live progress.

.DESCRIPTION
    Restores a .FBK backup produced by 1-backup-database.ps1 into a brand-new
    database file. Does NOT touch the live database or stop any services -- the
    restore target is new, so this runs fully online while the app keeps working
    against the live database. This is the slow step (can take well over an hour
    for a multi-GB database) but requires no downtime.

.PARAMETER FirebirdBin
    Path to the Firebird installation's bin directory (contains gbak.exe).

.PARAMETER BackupFile
    Path to the .FBK file produced by 1-backup-database.ps1.

.PARAMETER RestoreDbPath
    Full path for the new restored database file. Prefer a different physical
    disk than the live database if space is tight on the live disk -- the restore
    doesn't need to share space with the original.

.PARAMETER RestoreConnectionString
    Firebird connection string for the new database, e.g. "localhost/3050:E:\restore\db_new.FDB".

.PARAMETER LiveDatabasePath
    Path to the current live .FDB, used only to print a size comparison at the end.

.EXAMPLE
    .\2-restore-database.ps1 `
        -FirebirdBin "D:\Medoc\Firebird" `
        -BackupFile "D:\Medoc\db\backup_20260709_180000\backup.FBK" `
        -RestoreDbPath "E:\restore\db_new.FDB" `
        -RestoreConnectionString "localhost/3050:E:\restore\db_new.FDB" `
        -LiveDatabasePath "D:\Medoc\db\ZVIT.FDB"
#>

param(
    [Parameter(Mandatory = $true)] [string]$FirebirdBin,
    [Parameter(Mandatory = $true)] [string]$BackupFile,
    [Parameter(Mandatory = $true)] [string]$RestoreDbPath,
    [Parameter(Mandatory = $true)] [string]$RestoreConnectionString,
    [string]$LiveDatabasePath,
    [string]$User = "SYSDBA",
    [string]$Password = "masterkey"
)

$ErrorActionPreference = "Stop"

$bkDir    = Split-Path $BackupFile -Parent
$gbakLog  = Join-Path $bkDir "gbak_restore.log"
$logFile  = Join-Path $bkDir "2_restore.log"

New-Item -ItemType Directory -Path (Split-Path $RestoreDbPath -Parent) -Force | Out-Null

function Log($msg) {
    $line = "$(Get-Date -Format o)  $msg"
    Write-Host $line
    Add-Content -Path $logFile -Value $line
}

if (-not (Test-Path $BackupFile)) {
    Log "ERROR: Backup file not found: $BackupFile"
    exit 1
}

if (Test-Path $RestoreDbPath) {
    Log "ERROR: $RestoreDbPath already exists. Remove or rename it before restoring again."
    exit 1
}

$bkSize = (Get-Item $BackupFile).Length
Log "=== Backup file size: $([math]::Round($bkSize/1GB,2)) GB ==="
Log "=== Starting gbak -c (verbose) $BackupFile -> $RestoreDbPath ==="
Log "Firebird server stays running the whole time; the live database is untouched."

$proc = Start-Process -FilePath (Join-Path $FirebirdBin "gbak.exe") `
    -ArgumentList @("-c", "-v", "-user", $User, "-password", $Password, "$BackupFile", $RestoreConnectionString) `
    -RedirectStandardOutput $gbakLog `
    -RedirectStandardError (Join-Path $bkDir "gbak_restore_stderr.log") `
    -NoNewWindow -PassThru

$startTime = Get-Date
$lastSize = 0
$lastTable = ""

while (-not $proc.HasExited) {
    Start-Sleep -Seconds 5

    $elapsed = (Get-Date) - $startTime
    $curSize = 0
    if (Test-Path $RestoreDbPath) { $curSize = (Get-Item $RestoreDbPath).Length }

    $rateStr = ""
    if ($curSize -gt $lastSize) {
        $rateMB = [math]::Round(($curSize - $lastSize) / 1MB / 5, 1)
        $rateStr = " (+$rateMB MB/s)"
    }
    $lastSize = $curSize

    $tableLine = ""
    if (Test-Path $gbakLog) {
        $tableLine = Get-Content $gbakLog -Tail 5 -ErrorAction SilentlyContinue |
            Where-Object { $_ -match "writing|records|creating" } | Select-Object -Last 1
    }
    if ($tableLine -and $tableLine -ne $lastTable) {
        $lastTable = $tableLine
    }

    $pct = if ($bkSize -gt 0) { [math]::Round(($curSize / $bkSize) * 100, 1) } else { 0 }

    Write-Host ("[{0}] restored file: {1} GB / ~{2} GB backup (~{3}%){4}   {5}" -f `
        $elapsed.ToString("hh\:mm\:ss"), `
        [math]::Round($curSize/1GB,2), `
        [math]::Round($bkSize/1GB,2), `
        $pct, `
        $rateStr, `
        $lastTable)
}

Log "=== gbak process exited with code $($proc.ExitCode) ==="

if (-not (Test-Path $RestoreDbPath)) {
    Log "ERROR: Restore did not produce $RestoreDbPath. Check $gbakLog."
    exit 1
}

$newSize = (Get-Item $RestoreDbPath).Length
Log "Restore complete: $RestoreDbPath ($([math]::Round($newSize/1GB,2)) GB)"

if ($LiveDatabasePath -and (Test-Path $LiveDatabasePath)) {
    $oldSize = (Get-Item $LiveDatabasePath).Length
    Log "Current live database is: $([math]::Round($oldSize/1GB,2)) GB"
}

Log "=== DONE. New compacted file ready at $RestoreDbPath ==="
Log "Next: when convenient (requires brief app downtime), run 3-swap-database.ps1"
