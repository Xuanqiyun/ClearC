# Improvement backlog

Source: the three reviews of 2026-10-24 (safety and operations, user experience, architecture), based on 3.5.2. Done one item at a time.

How:
1. For each item, first write a test that fails, then change the code until it passes.
2. One commit per item, with the item number in the commit message.
3. When done, write the version number in the "Status" column.

Order: P0 first, then P1, then P2. Within the same priority, follow the "Priority" column, lower numbers first.

## Security (SEC)

| ID | Priority | Problem | Fix | Status |
|---|---|---|---|---|
| SEC-1 | P0 | The exe, running as administrator, loads the assembly named by the environment variable `CLEANC_SMA` | Remove this switch from the launcher | 3.6 |
| SEC-2 | P0 | The scheduled task runs with the highest privileges, points to an exe the user can change, and automatically repoints itself to newer exes | When turning the task on, copy the exe to `Program Files\ClearC` and point the task there; check before repointing | 3.6 |
| SEC-3 | P0 | Moved chat data, Desktop and Documents inherit the permissions of the D: root, so other accounts can read and change them | Every move carries the original permissions; CDriveMoved is only for the user, SYSTEM and administrators; earlier moves can be fixed | 3.6 |
| SEC-4 | P1 | When C: is encrypted and the target drive isn't, a move puts the data on an unencrypted drive | Say so in the confirmation | 3.6 |
| SEC-5 | P1 | System program paths are taken from the `SystemRoot` environment variable | Use `[Environment]::SystemDirectory` and `GetFolderPath('Windows')` | 3.6 |
| SEC-6 | P1 | Vendor download pages and the run log open the browser and Notepad as administrator | Open them all through File Explorer | 3.6 |
| SEC-7 | P1 | Folders that hold passwords, certificates and keys were only blocked for the current account | Apply to `AppData\…\Microsoft\Protect` and the like for every account | 3.6 |
| SEC-8 | P1 | Deleting duplicates doesn't write the activity log | Write one entry per deleted file | 3.6 |
| SEC-9 | P2 | The exe is unsigned and no SHA256 is published | Release notes include the SHA256, and "About" shows the hash of the exe on this PC; signing needs the maintainer to apply for a certificate | 3.6 (signing needs the maintainer to apply for a certificate) |
| SEC-10 | P2 | The diagnostics package contains memory dumps, the user name and the computer name | List the contents before exporting, with the option to leave out dumps | 3.6 |

## Operations (OPS)

| ID | Priority | Problem | Fix | Status |
|---|---|---|---|---|
| OPS-1 | P0 | Two windows can be open at once; automatic cleanup can run at the same time as a delete or move in the window | Single-instance window; a lock during deletes and moves, and automatic cleanup skips that run if it can't get the lock | 3.6 |
| OPS-2 | P0 | The settings file is rewritten in full every time, so a full C: or two processes writing at once truncates it; when it can't be read, the exclusion list is empty and deletes go ahead anyway | Write a temporary file first, then swap it in; if the file exists but can't be read, don't delete | 3.6 |
| OPS-3 | P1 | When C: is nearly full, ClearC's own log, snapshots and settings can't be written, silently | Warn at startup; say so in the window when the activity log can't be written | 3.6 |
| OPS-4 | P1 | The PC can sleep during long operations; moving a large folder on battery gives no warning | Prevent sleep during operations; warn first on battery or low charge | 3.6 |
| OPS-5 | P1 | When elevated with a different administrator account, cleanup and moves act on that account | Compare at startup and explain if they differ | 3.6 |
| OPS-6 | P1 | icacls uses English group names; the confirmation letters of takeown and chkdsk change with the system language | Use the SID `*S-1-5-32-544`; take the confirmation letter from the system language | 3.6 |
| OPS-7 | P1 | There is no overview of "what ClearC changed" | Add a change overview: each item shows its current state and how to undo it; optionally create a restore point before changing system settings | 3.6 |
| OPS-8 | P2 | The run log is in %TEMP%, which ClearC itself cleans, and isn't rotated | Move it to `%LOCALAPPDATA%\CleanC\logs` and rotate it | 3.6 |
| OPS-9 | P2 | Under AppLocker or WDAC, PowerShell enters the constrained language mode and the program just errors out | Detect it at startup and give a one-line explanation | 3.6 |
| OPS-10 | P2 | The "Reminders" page doesn't show the task's last run result | Show the last and next run times and the result | 3.6 |

## User experience (UX)

| ID | Priority | Problem | Fix | Status |
|---|---|---|---|---|
| UX-1 | P0 | With only C:, one-click cleanup fails entirely (chat data is moved by default, and with no target it quits) | With no target drive, move items are skipped by default; when the target is gone, offer "Skip moving, only clean" | 3.6 |
| UX-2 | P0 | The move target can be an automatically picked USB drive | Recognize USB drives and leave them out of the automatic choice; confirm again when picked by hand | 3.6 |
| UX-3 | P0 | One-click cleanup also moves chat data, which the button doesn't show; Home user mode can't see the move status | One-click cleanup only deletes; chat data gets its own card; show Moved folders once there is a move record; warn about broken links | 3.6 |
| UX-4 | P1 | The first start has no clear first step | Scan automatically after agreeing; the first screen shows only the conclusion and one main button | 3.6 |
| UX-5 | P1 | The cleanup page shows one group at a time but runs all of them | Tabs show the selected count; "Skip all in this group"; totals split into delete and move | 3.6 |
| UX-6 | P1 | Confirmation dialogs pop up one after another; the colors of the space map's delete dialog are reversed | Merge into one confirmation whose main button says what it does; permanent delete is red | 3.6 |
| UX-7 | P1 | Apps that can't be moved still have a "Move to another drive" button in Apps | Show the reason directly for those that can't be moved | 3.6 |
| UX-8 | P1 | Description text has a contrast of 3.6:1, and some text is 11 pt | Use #6E6E73, a 12 pt minimum, and a test threshold of 4.5 | 3.6 |
| UX-9 | P1 | Keyboard focus is invisible, and screen readers can't read icon buttons | Focus ring, AutomationProperties.Name | 3.6 |
| UX-10 | P1 | Help describes features the current mode doesn't show | Hide or label them by mode | 3.6 |
| UX-11 | P1 | "Careful cleanup", "needs confirmation" and "run selected actions" are easily misread | Rename them | 3.6 |
| UX-12 | P2 | Changing the appearance or language needs a restart, and the scan results are lost | Return to the same page and results after reopening | 3.6 |
| UX-13 | P2 | No feedback for several seconds after entering the administrator password | The launcher first shows "Opening" | 3.6 |
| UX-14 | P2 | Errors show Windows' original text | Group them and say what to do next | 3.6 |
| UX-15 | P2 | App list icons are first letters | Read each app's own icon | 3.6 |

## Architecture (ARC)

| ID | Priority | Problem | Fix | Status |
|---|---|---|---|---|
| ARC-1 | P0 | The checks and the execution of deletes are written separately in six places | Merge them into one `Invoke-SafeRemove`, with a test locking it as the only thing that deletes | 3.6 |
| ARC-2 | P0 | A move isn't a transaction, so a power cut midway can only be fixed by hand | Record each step, so the next start can continue or undo it; verification requires zero differences | 3.6 |
| ARC-3 | P0 | `DirStat`'s counters are static fields, so concurrent measurements overwrite each other, and the move's safety check reads exactly those | Each measurement returns its own result | 3.6 |
| ARC-4 | P1 | Errors are swallowed, and nobody reads background threads' errors; `Write-LogFile` is called before it is defined | Write background errors to the log; define the log functions earlier | 3.6 |
| ARC-5 | P1 | Background jobs are strung together in four places by the Mode string | Declare start, cancel and completion together | 3.6 (the text on the progress card is still chosen by name) |
| ARC-6 | P1 | UI text doubles as data (branches decided by the translated "Delete") | Stable identifiers and enumerations | 3.6 |
| ARC-7 | P1 | Safety tests count the source with regular expressions; moving has no test that really runs it | Assert on the syntax tree; CI mounts a virtual disk and really runs a move | 3.6 (some of the locks on coding patterns still use regular expressions) |
| ARC-8 | P1 | The photo fingerprint C# is compiled at every start | Compile it when first used | 3.6 |
| ARC-9 | P1 | Two copies of the source, and the version number changed by hand in two places | One source for the version number | 3.6 |
| ARC-10 | P2 | The main window XAML is parsed all at once; dark mode relies on string replacement | Split it by page and load each page when first used | 3.6 (the largest, the help page, was split off first, so about a fifth less XAML is parsed when the window opens; the other pages and the dark-mode approach are unchanged) |
| ARC-11 | P2 | Move to C# in the long run | Start with the core library (path rules, the delete entry point, the move state machine) | 3.6 (the path rules and the move-progress state machine are in `cs/Core.cs`; the delete entry point is still in PowerShell) |
