<#
.SYNOPSIS
    STEP 1 of 3: Backup a Firebird database with live progress.

.DESCRIPTION
    Stops the app server briefly (to avoid backing up mid-write), runs `gbak -b`,
    and restarts the app server. The Firebird service itself is never stopped and
    the live database file is never touched -- this only reads from it.

    Part of a 3-step backup -> restore -> swap workflow used to physically shrink
    a Firebird .FDB file after deleting a large number of rows (Firebird never
    reclaims disk space from deletes on its own; a backup/restore cycle rewrites
    the file without the deleted rows' free space).

.PARAMETER FirebirdBin
    Path to the Firebird installation's bin directory (contains gbak.exe).

.PARAMETER DatabasePath
    Full path to the live .FDB file on disk.

.PARAMETER ConnectionString
    Firebird connection string for the live database, e.g. "localhost/3050:C:\path\to\db.FDB".

.PARAMETER User / -Password
    Firebird credentials. Defaults to SYSDBA / masterkey, Firebird's well-known
    default -- override these if the target database uses different credentials.

.PARAMETER AppServiceName
    Name of the Windows service to stop/start around the backup (the application
    server that writes to the database). Pass $null or omit to skip stopping any
    service, e.g. if you already know the app is idle.

.PARAMETER BackupDir
    Directory to create the timestamped backup folder in. Defaults to a
    "backup_<timestamp>" folder next to the database file.

.EXAMPLE
    .\1-backup-database.ps1 `
        -FirebirdBin "D:\Medoc\Firebird" `
        -DatabasePath "D:\Medoc\db\ZVIT.FDB" `
        -ConnectionString "localhost/3050:D:\Medoc\db\ZVIT.FDB" `
        -AppServiceName "MedocAppServer"
#>

param(
    [Parameter(Mandatory = $true)] [string]$FirebirdBin,
    [Parameter(Mandatory = $true)] [string]$DatabasePath,
    [Parameter(Mandatory = $true)] [string]$ConnectionString,
    [string]$User = "SYSDBA",
    [string]$Password = "masterkey",
    [string]$AppServiceName = $null,
    [string]$BackupDir = $null
)

$ErrorActionPreference = "Stop"

if (-not $BackupDir) {
    $BackupDir = Join-Path (Split-Path $DatabasePath -Parent) "backup_$(Get-Date -Format yyyyMMdd_HHmmss)"
}
$bkFile   = Join-Path $BackupDir "backup.FBK"
$gbakLog  = Join-Path $BackupDir "gbak_backup.log"
$logFile  = Join-Path $BackupDir "1_backup.log"

New-Item -ItemType Directory -Path $BackupDir -Force | Out-Null

function Log($msg) {
    $line = "$(Get-Date -Format o)  $msg"
    Write-Host $line
    Add-Content -Path $logFile -Value $line
}

$srcSize = (Get-Item $DatabasePath).Length
Log "=== Source database size: $([math]::Round($srcSize/1GB,2)) GB ==="

if ($AppServiceName) {
    Log "=== Stop app service '$AppServiceName' to avoid backing up mid-write ==="
    Stop-Service -Name $AppServiceName -Force
    Start-Sleep -Seconds 3
}

Log "=== Starting gbak -b (verbose) -> $bkFile ==="
$proc = Start-Process -FilePath (Join-Path $FirebirdBin "gbak.exe") `
    -ArgumentList @("-b", "-v", "-user", $User, "-password", $Password, $ConnectionString, "$bkFile") `
    -RedirectStandardOutput $gbakLog `
    -RedirectStandardError (Join-Path $BackupDir "gbak_backup_stderr.log") `
    -NoNewWindow -PassThru

$startTime = Get-Date
$lastSize = 0
$lastTable = ""

while (-not $proc.HasExited) {
    Start-Sleep -Seconds 5

    $elapsed = (Get-Date) - $startTime
    $curSize = 0
    if (Test-Path $bkFile) { $curSize = (Get-Item $bkFile).Length }

    $rateStr = ""
    if ($curSize -gt $lastSize) {
        $rateMB = [math]::Round(($curSize - $lastSize) / 1MB / 5, 1)
        $rateStr = " (+$rateMB MB/s)"
    }
    $lastSize = $curSize

    # pull the last "writing ... table" or "records written" line from the verbose log for context
    $tableLine = ""
    if (Test-Path $gbakLog) {
        $tableLine = Get-Content $gbakLog -Tail 5 -ErrorAction SilentlyContinue |
            Where-Object { $_ -match "writing|records" } | Select-Object -Last 1
    }
    if ($tableLine -and $tableLine -ne $lastTable) {
        $lastTable = $tableLine
    }

    $pct = if ($srcSize -gt 0) { [math]::Round(($curSize / $srcSize) * 100, 1) } else { 0 }

    Write-Host ("[{0}] backup file: {1} GB / ~{2} GB source (~{3}%){4}   {5}" -f `
        $elapsed.ToString("hh\:mm\:ss"), `
        [math]::Round($curSize/1GB,2), `
        [math]::Round($srcSize/1GB,2), `
        $pct, `
        $rateStr, `
        $lastTable)
}

Log "=== gbak process exited with code $($proc.ExitCode) ==="

if ($AppServiceName) {
    Log "=== Restart app service '$AppServiceName' ==="
    Start-Service -Name $AppServiceName
}

if (-not (Test-Path $bkFile)) {
    Log "ERROR: Backup file was not created. Check $gbakLog"
    exit 1
}
$bkSize = (Get-Item $bkFile).Length
Log "Backup complete: $bkFile ($([math]::Round($bkSize/1GB,2)) GB, source was $([math]::Round($srcSize/1GB,2)) GB)"

if ($bkSize -lt 1GB) {
    Log "WARNING: Backup file looks suspiciously small (<1GB). Check $gbakLog before proceeding to restore."
}

Log "=== DONE. Backup folder: $BackupDir ==="
Log "Next: run 2-restore-database.ps1 -BackupFile `"$bkFile`""
