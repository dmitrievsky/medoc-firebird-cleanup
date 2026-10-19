# Medoc / Firebird ZVIT.FDB cleanup toolkit

**English** · [Українська](README.uk.md) · [Русский](README.ru.md)

Tools and notes for shrinking a **Medoc (M.E.Doc)** accounting system's Firebird
database (`ZVIT.FDB`) by purging old primary documents directly from the database,
and for physically reclaiming the disk space that Firebird never gives back on its
own after a `DELETE`.

This came out of a real cleanup where the built-in Medoc archiving feature
(Адміністрування → Архівування документів) turned out to be too slow to use at
scale — see [Why not use Medoc's built-in archiving](#why-not-use-medocs-built-in-archiving)
below — so we went straight at the database instead. The toolkit is generalized
from that specific run; all company/org-identifying details have been stripped out
and every path/credential is a parameter. **Treat every script here as something to
read and adapt, not run blind against your own database.**

> **This deletes data permanently.** There is no undo for the `DELETE` step short of
> restoring from a backup. Take a full backup before you touch anything, verify it
> restores, and test on a non-production copy first if you possibly can.

## Contents

- `scripts/generate-batch-delete-sql.ps1` — generates a monthly-chunked SQL script
  that deletes documents of a given form/date-range/org directly from `CARD` and its
  cascade.
- `scripts/1-backup-database.ps1` — step 1 of 3: online `gbak` backup.
- `scripts/2-restore-database.ps1` — step 2 of 3: online restore into a new file
  (this is what actually compacts the data — a fresh restore has no deleted-row
  bloat).
- `scripts/3-swap-database.ps1` — step 3 of 3: the only step requiring downtime;
  swaps the compacted file into place.

## Background: why deletes don't shrink the file

Firebird uses MVCC and never frees pages back to the OS on `DELETE` — the `.FDB`
file only grows or stays the same size until you run a backup/restore cycle, which
rewrites the whole database into a fresh file without the dead space. That's what
steps 1–3 above are for. The `DELETE`s themselves (step 0, the SQL generator) don't
touch the file size at all — they're purely about reducing row counts / query cost
going forward, and the backup/restore is what turns that into disk space.

## Why not use Medoc's built-in archiving

The archiving feature in Medoc's UI does a full application-level delete per
document, inside expensive sequential queries (including a full scan of the
largest document-line table per document) inside one long transaction. On any
database with more than a modest number of documents this becomes unusably slow
(observed: 15–30+ seconds *per document*) and doesn't scale to years of
backlog. It's also known to throw
`System.ArgumentException: Column 'PARENTDOCID' does not belong to table DOCRST`
on large periods in some versions.

If you actually need the archive file that this feature produces (e.g. for
compliance reasons), this toolkit is **not** a substitute — it deletes rows outright
with no archive artifact. Only use it if, like the case it came from, you've
confirmed you don't need an archival copy of what you're purging.

## Schema notes (Medoc / Firebird, general — verify against your version)

These are the facts we had to reverse-engineer by inspecting the schema; they held
for Medoc 11.02.x on Firebird 3.0.5 Classic but you should sanity-check them against
your own installation before relying on them (`RDB$TRIGGERS`, `RDB$RELATION_CONSTRAINTS`, etc.):

- **`CARD`** is the central row for every document in the system, of every type
  (reporting forms, tax invoices, adjustment calculations, ...). Primary key `CODE`.
- Each document *type* has its own `_MAIN` (and often `_TAB1` etc.) table, joined via
  `<form>_MAIN.CARDCODE = CARD.CODE`. The **date field is not consistently named**
  across forms — don't assume `DATE`, `N1`, or any other guess; look it up per form
  (see [Finding a document manually](#finding-a-document-manually) below).
- `RDCARD` / `RDCARD_HISTORY` are **not** universal — they're populated only for
  certain document types, and `RDCARD_HISTORY` specifically logs what has actually
  gone through the *official* archiving feature (`ARCH_IDENT` = archive file name),
  not raw document existence.
- Deleting a `CARD` row triggers:
  - A `BEFORE DELETE` trigger that explicitly deletes on the order of 100
    satellite tables (journal entries, signatures, certificates, images, routing,
    tags, and dozens of form-specific tables). Check `RDB$TRIGGERS` for the actual
    trigger body on your installation — table names can shift between versions.
  - An `AFTER DELETE` trigger that cleans up the document's blob storage table.
  - Several hundred formal `FOREIGN KEY ... ON DELETE CASCADE` constraints, covering
    essentially all the `_MAIN`/`_TAB1` tables for every reporting form.
  - **One known gap** we found on our installation: `CARDJOURNALOPERBLOB` (linked
    via `CARDJOURNALOPER.CODE`) has no cascade and needs cleaning up manually before
    the `CARD` delete — `scripts/generate-batch-delete-sql.ps1` does this by default.
    There may be others on a different version; audit before trusting this list
    blindly.
- The database is often **multi-tenant**: one Firebird database can hold multiple
  companies (`ORG` table), and `CARD.IDORG` tells you which. **Always** scope
  deletes by `idorg` — check `select code, edrpou from org order by code;` first, and
  never assume there's only one row.
- Text field encoding is commonly WIN1251 on these older installations — if reading
  values through PowerShell, use `[System.Text.Encoding]::GetEncoding(1251)`.
  `isql` via a POSIX shell (e.g. git-bash) may show mojibake for text but numeric/date
  comparisons are unaffected.

### Finding a document manually

Once you know a form's `_MAIN` table and date field, a targeted lookup looks like:

```sql
select fj.cardcode, fj.<number_field> as num, fj.<date_field> as docdate, fj.edrpou
from <form>_main fj join card c on c.code = fj.cardcode
where fj.<number_field> = '<document number>' and fj.edrpou = '<counterparty EDRPOU>';
```

Find the right field names for a given form via `FORM.CHARCODE` (e.g. `select code,
charcode from form order by charcode;`) and by inspecting a known live document's
row.

## Batch delete method

**Never delete a whole multi-year range in a single transaction** — it causes the
same MVCC garbage-accumulation problem as the built-in archiver, just with SQL
instead of the UI. Always chunk by month, with a `COMMIT` after each month.

`scripts/generate-batch-delete-sql.ps1` generates exactly that pattern — one chunk
looks like:

```sql
select '<year>-<month>: ', count(*) as to_delete
from <main_table> fj join card c on c.code = fj.cardcode
where c.idorg = <idorg> and fj.<date_field> between '<year>-<month>-01' and '<year>-<month>-<last_day>';

delete from cardjournaloperblob where code in (
  select j.code from cardjournaloper j where j.cardcode in (
    select fj.cardcode from <main_table> fj join card c on c.code = fj.cardcode
    where c.idorg = <idorg> and fj.<date_field> between '<year>-<month>-01' and '<year>-<month>-<last_day>'
  )
);

delete from card where code in (
  select fj.cardcode from <main_table> fj join card c on c.code = fj.cardcode
  where c.idorg = <idorg> and fj.<date_field> between '<year>-<month>-01' and '<year>-<month>-<last_day>'
);

commit;
```

Generate and run it (values below are illustrative placeholders, not real data —
substitute your own form's `_main` table, date field, org code, and year range):

```powershell
.\scripts\generate-batch-delete-sql.ps1 -MainTable <form>_main -DateField <date_field> `
    -IdOrg <your_idorg> -YearStart <year_from> -YearEnd <year_to> -OutFile .\delete.sql
```

```bash
isql.exe -user SYSDBA -password <your_password> "localhost/3050:C:\path\to\db.FDB" -i delete.sql -q > output.txt
```

**Verify afterwards**: sum the `to_delete` counts printed per month and compare
against a fresh `count(*)` over the whole original range — it should now be 0 (or
match whatever you intentionally left untouched), and the sum should equal what you
saw in the preview before running.

## Backup / restore / swap workflow (physical disk-space reclaim)

Run in this order, with any gap you like between steps 1–2 and step 3 (e.g. steps
1–2 during the day, step 3 during a maintenance window):

1. **`scripts/1-backup-database.ps1`** — briefly stops the app service (to avoid
   backing up mid-write), runs `gbak -b` with a live progress readout (growing file
   size, % of source, last table processed), restarts the app service. The
   Firebird service itself stays up throughout; the live database file is never
   touched.
2. **`scripts/2-restore-database.ps1`** — restores the backup into a **new,
   separate file**, ideally on a different physical disk if space is tight. Fully
   online — nothing is stopped, the live database keeps serving the app. This is
   the slow step (well over an hour is normal for a multi-GB backup) but needs no
   downtime.
3. **`scripts/3-swap-database.ps1`** — **the only step with real downtime.** Stops
   Firebird and the app service, renames the current live file aside (never
   deletes it), copies the new compacted file into place, verifies the copied size
   matches, deletes the restore-source copy, restarts services, and runs an
   optional sanity-check query.

### Known gotchas

- **Locked file on swap (Firebird Classic Server)**: `Stop-Service` doesn't always
  kill already-running per-connection `firebird.exe` worker processes that Classic
  Server spawns, which can leave the database file locked and the copy step failing
  with an `IOException`. Fix: list and kill any lingering `firebird.exe` processes,
  then re-run — the swap script is idempotent and safe to repeat.
- **Progress indicator jumping to 100% early during the swap copy**: NTFS can
  reserve a file's full size instantly (sparse allocation) at the start of
  `Copy-Item`, so the printed "copied X / Y (100%)" can look done long before the
  actual bytes have landed. Not a bug or a hang — the script still correctly waits
  for the background job to finish and verifies the final size.
- Nothing in step 3 deletes the old database automatically, by design — verify the
  app works correctly against the swapped-in database before removing
  `<name>_before_restore_<timestamp>.FDB` and the intermediate `.FBK` backup
  yourself.

## Alternative: Medoc's own BackupManager

Medoc ships its own tool (`BackupManager.exe` in the installation directory, also
reachable from the application menu) that can do a full cold backup/restore cycle
in one step, producing a `.BKZ` file:

- **Backup** ("Створити архів") stops both the app service *and* the Firebird
  service for the whole operation (unlike the `gbak` scripts above, where Firebird
  stays live) — progress is shown as an object/block count, not bytes. Worth
  enabling "Створювати архів з перевіркою бази" (verify while backing up) and a
  retention limit on kept copies so they don't accumulate forever.
- **Restore** ("Відновити з архіву") is also cold, but works cleanly: stop
  services → confirm no lingering `firebird.exe` processes → move the live file
  aside → point the GUI at the `.BKZ` → let it bring services back up → sanity
  check with a cheap query.

Both paths get you a working result. The `gbak` scripts avoid stopping Firebird
during the (slow) backup step; `BackupManager` is simpler and more "official" but
costs more downtime.

## Disclaimer

This is a description of one specific cleanup, generalized into reusable scripts —
not an officially supported Medoc tool. Schema details (table names, trigger
behavior, cascade coverage) can and do vary across Medoc versions; verify every
assumption above against your own installation (`RDB$TRIGGERS`,
`RDB$RELATION_CONSTRAINTS`, a scoped `COUNT(*)` before any delete) before running
anything. Always back up first.

## License

MIT — see [LICENSE](LICENSE).
