<#
.SYNOPSIS
    Generates a monthly-chunked DELETE script for purging old Medoc/Firebird CARD-based
    documents directly from the database (bypassing Medoc's own, much slower, archiving UI).

.DESCRIPTION
    Medoc (M.E.Doc) stores every document type (tax invoices, adjustment calculations,
    reporting forms, etc.) as a row in the central CARD table, with a form-specific
    "_MAIN" table joined via CARDCODE = CARD.CODE. Deleting a CARD row cascades through
    ~490 FK constraints (ON DELETE CASCADE) plus a BEFORE/AFTER DELETE trigger pair that
    together clean up on the order of 100 satellite tables -- so deleting from CARD is
    both correct and sufficient for almost everything. See README.md for the one known
    gap (CARDJOURNALOPERBLOB), which this script cleans up explicitly before each CARD
    delete, in the same chunk.

    IMPORTANT: never delete a large date range in a single transaction -- Firebird's
    MVCC will accumulate garbage exactly like the slow built-in archiver does, and the
    delete will get progressively slower. This script always chunks by month, with a
    COMMIT after each month, and prints a COUNT(*) preview per chunk so you can verify
    the total against a post-run row count.

    This only generates the .sql file -- it does not run it and does not touch any
    database. Review the generated file before running it.

.PARAMETER MainTable
    The form-specific "_MAIN" table for the document type you want to purge, e.g.
    fj1201002_main. Find yours via: select code, charcode from form order by charcode;
    and select cardcode from <candidate>_main where cardcode = <card.code you found>;

.PARAMETER DateField
    The column in MainTable holding the document date. Varies per form -- do NOT assume
    it's called DATE or N1; inspect the table (e.g. it was N11 for one form and N15 for
    a related one in the case this toolkit was built from). Verify with a manual lookup
    query first (see README.md).

.PARAMETER IdOrg
    The ORG.CODE (i.e. CARD.IDORG) whose documents you want to purge. Firebird/Medoc
    installations are often multi-tenant (multiple companies in one database) -- always
    scope by idorg to avoid touching a different company's data. Check `select code,
    edrpou from org order by code;` first.

.PARAMETER YearStart / -YearEnd
    Inclusive calendar-year range to purge, chunked into one DELETE per month.

.PARAMETER OutFile
    Path to write the generated .sql script to.

.PARAMETER SkipCardJournalOperBlobCleanup
    Set this if you've independently verified CARDJOURNALOPERBLOB isn't relevant for
    your Medoc version/schema (e.g. it's empty for this document type) and want a
    slightly simpler generated script. Leave it off unless you've checked.

.EXAMPLE
    .\generate-batch-delete-sql.ps1 -MainTable fj1201002_main -DateField n11 `
        -IdOrg 100 -YearStart 2019 -YearEnd 2020 -OutFile .\delete_2019_2020.sql

    Then review delete_2019_2020.sql and run it with:
        isql.exe -user SYSDBA -password masterkey "localhost/3050:C:\path\to\db.FDB" -i delete_2019_2020.sql -q > output.txt
#>

param(
    [Parameter(Mandatory = $true)] [string]$MainTable,
    [Parameter(Mandatory = $true)] [string]$DateField,
    [Parameter(Mandatory = $true)] [int]$IdOrg,
    [Parameter(Mandatory = $true)] [int]$YearStart,
    [Parameter(Mandatory = $true)] [int]$YearEnd,
    [Parameter(Mandatory = $true)] [string]$OutFile,
    [string]$CardCodeField = "cardcode",
    [switch]$SkipCardJournalOperBlobCleanup
)

$ErrorActionPreference = "Stop"

function Get-LastDayOfMonth([int]$year, [int]$month) {
    return [DateTime]::DaysInMonth($year, $month)
}

$lines = New-Object System.Collections.Generic.List[string]

for ($year = $YearStart; $year -le $YearEnd; $year++) {
    for ($month = 1; $month -le 12; $month++) {
        $mm = $month.ToString("00")
        $lastDay = Get-LastDayOfMonth $year $month
        $from = "${year}-${mm}-01"
        $to = "${year}-${mm}-$lastDay"

        $baseSelect = "select fj.$CardCodeField from $MainTable fj join card c on c.code=fj.$CardCodeField where c.idorg=$IdOrg and fj.$DateField between '$from' and '$to'"

        $lines.Add("select '${year}-${mm}: ', count(*) as to_delete from $MainTable fj join card c on c.code=fj.$CardCodeField where c.idorg=$IdOrg and fj.$DateField between '$from' and '$to';")

        if (-not $SkipCardJournalOperBlobCleanup) {
            $lines.Add("delete from cardjournaloperblob where code in (select j.code from cardjournaloper j where j.cardcode in ($baseSelect));")
        }

        $lines.Add("delete from card where code in ($baseSelect);")
        $lines.Add("commit;")
    }
}

Set-Content -Path $OutFile -Value $lines -Encoding ASCII
Write-Host "Generated $($lines.Count) statements ($YearStart-$YearEnd, $MainTable) -> $OutFile"
Write-Host "Review the file, then run it with isql. See README.md for the full workflow."
