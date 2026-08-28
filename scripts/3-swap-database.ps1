<#
.SYNOPSIS
    STEP 3 of 3: Swap the live database for the freshly restored (compacted) copy.

.DESCRIPTION
    The ONLY step in the backup/restore/swap workflow that requires downtime.
    Stops the Firebird service and the app service, moves the current live
    database aside (never deletes it), copies the restored/compacted database
    into its place, verifies the size, then restarts services and runs a sanity
    check query. Idempotent -- safe to re-run if it fails partway (e.g. a locked
    file) once the underlying cause is fixed.

.PARAMETER LiveDatabasePath
    Path to the current live .FDB file.

.PARAMETER RestoreDbPath
    Path to the compacted database produced by 2-restore-database.ps1.

.PARAMETER FirebirdServiceName
    Windows service name for the Firebird server itself.

.PARAMETER AppServiceName
    Windows service name for the application server that connects to the database.

.PARAMETER SanityCheckQuery
    A cheap query run against the swapped-in database to confirm it's readable,
    e.g. "select count(*) from some_core_table;". Optional.

.PARAMETER FirebirdBin
    Path to the Firebird installation's bin directory (contains isql.exe).
    Required only if -SanityCheckQuery is used.

.PARAMETER ConnectionString
    Firebird connection string for the live database, used for the sanity check.

.NOTES
    Known gotcha (Firebird Classic Server): stopping the Firebird service does not
    always kill already-running per-connection worker processes, which can leave
    the database file locked. If the copy step fails with an IOException about the
    file being in use, check for and kill lingering firebird.exe processes, then
    re-run this script -- it's safe to repeat.

.EXAMPLE
    .\3-swap-database.ps1 `
        -LiveDatabasePath "D:\Medoc\db\ZVIT.FDB" `
        -RestoreDbPath "E:\restore\db_new.FDB" `
        -FirebirdServiceName "Firebird server - MyInstance" `
        -AppServiceName "MedocAppServer" `
        -FirebirdBin "D:\Medoc\Firebird" `
        -ConnectionString "localhost/3050:D:\Medoc\db\ZVIT.FDB" `
        -SanityCheckQuery "select count(*) from card;"
#>

param(
    [Parameter(Mandatory = $true)] [string]$LiveDatabasePath,
    [Parameter(Mandatory = $true)] [string]$RestoreDbPath,
    [Parameter(Mandatory = $true)] [string]$FirebirdServiceName,
    [string]$AppServiceName = $null,
    [string]$SanityCheckQuery = $null,
    [string]$FirebirdBin = $null,
    [string]$ConnectionString = $null,
    [string]$User = "SYSDBA",
    [string]$Password = "masterkey"
)

$ErrorActionPreference = "Stop"

$dbOldSafe = Join-Path (Split-Path $LiveDatabasePath -Parent) `
    "$([IO.Path]::GetFileNameWithoutExtension($LiveDatabasePath))_before_restore_$(Get-Date -Format yyyyMMdd_HHmmss)$([IO.Path]::GetExtension($LiveDatabasePath))"
$logFile = Join-Path (Split-Path $LiveDatabasePath -Parent) "3_swap.log"

function Log($msg) {
    $line = "$(Get-Date -Format o)  $msg"
    Write-Host $line
    Add-Content -Path $logFile -Value $line
}

if (-not (Test-Path $RestoreDbPath)) {
    Log "ERROR: $RestoreDbPath not found. Run 2-restore-database.ps1 first."
    exit 1
}

if ($AppServiceName) {
    Log "=== Stop app service '$AppServiceName' ==="
    Stop-Service -Name $AppServiceName -Force
}
Log "=== Stop Firebird service '$FirebirdServiceName' ==="
Stop-Service -Name $FirebirdServiceName -Force
Start-Sleep -Seconds 3

Log "=== Move current live database aside (safety copy, NOT deleted) ==="
Move-Item -Path $LiveDatabasePath -Destination $dbOldSafe -Force
Log "Old database preserved at: $dbOldSafe"

Log "=== Copying restored database into place ==="
$srcSize = (Get-Item $RestoreDbPath).Length
Log "Source size: $([math]::Round($srcSize/1GB,2)) GB"

$copyJob = Start-Job -ScriptBlock {
    param($src, $dst)
    Copy-Item -Path $src -Destination $dst -Force
} -ArgumentList $RestoreDbPath, $LiveDatabasePath

$startTime = Get-Date
while ($copyJob.State -eq 'Running') {
    Start-Sleep -Seconds 5
    $elapsed = (Get-Date) - $startTime
    $curSize = 0
    if (Test-Path $LiveDatabasePath) { $curSize = (Get-Item $LiveDatabasePath).Length }
    $pct = if ($srcSize -gt 0) { [math]::Round(($curSize / $srcSize) * 100, 1) } else { 0 }
    Write-Host ("[{0}] copied: {1} GB / {2} GB (~{3}%)  -- note: on NTFS this can jump to 100% almost" -f `
        $elapsed.ToString("hh\:mm\:ss"), `
        [math]::Round($curSize/1GB,2), `
        [math]::Round($srcSize/1GB,2), `
        $pct)
    Write-Host "      immediately (sparse allocation); the script still waits for the copy job to finish."
}
Receive-Job $copyJob -ErrorAction Stop | Out-Null
Remove-Job $copyJob

$copiedSize = (Get-Item $LiveDatabasePath).Length
if ($copiedSize -ne $srcSize) {
    Log "CRITICAL ERROR: Copied file size ($copiedSize) does not match source ($srcSize)! Restoring old file immediately."
    Remove-Item -Path $LiveDatabasePath -Force -ErrorAction SilentlyContinue
    Move-Item -Path $dbOldSafe -Destination $LiveDatabasePath -Force
    Start-Service -Name $FirebirdServiceName
    if ($AppServiceName) { Start-Service -Name $AppServiceName }
    exit 1
}
Log "Copy verified (size matches). Removing source to free that space."
Remove-Item -Path $RestoreDbPath -Force

Log "=== Restart Firebird service and app service ==="
Start-Service -Name $FirebirdServiceName
Start-Sleep -Seconds 3
if ($AppServiceName) {
    Start-Service -Name $AppServiceName
    Start-Sleep -Seconds 3
}

if (-not (Test-Path $LiveDatabasePath)) {
    Log "CRITICAL ERROR: $LiveDatabasePath missing after swap! Restoring old file immediately."
    Move-Item -Path $dbOldSafe -Destination $LiveDatabasePath -Force
    Start-Service -Name $FirebirdServiceName
    if ($AppServiceName) { Start-Service -Name $AppServiceName }
    exit 1
}

$newSize = (Get-Item $LiveDatabasePath).Length
$oldSize = (Get-Item $dbOldSafe).Length
Log "Swap complete. Old size: $([math]::Round($oldSize/1GB,2)) GB -> New size: $([math]::Round($newSize/1GB,2)) GB"

if ($SanityCheckQuery -and $FirebirdBin -and $ConnectionString) {
    Log "=== Sanity check: querying restored database ==="
    $checkOut = $SanityCheckQuery | & (Join-Path $FirebirdBin "isql.exe") -user $User -password $Password $ConnectionString -q 2>&1
    Log "Sanity check output: $checkOut"
}

Log "=== DONE. Old database kept at $dbOldSafe -- verify everything works, then delete manually to reclaim that disk space too. ==="
