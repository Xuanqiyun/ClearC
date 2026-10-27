# The parts of the source

`src/CleanC-UI.ps1` is these files **joined verbatim in the order given by `order.txt`**; the result is byte-for-byte identical to the single file.

Edit the files here, then run:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File build\merge.ps1
```

`build\build.ps1` checks that the two sides match before it builds the exe and stops if they don't; `tests\Checks.ps1` checks that `src\CleanC-UI.ps1` is up to date.

| Folder | Contents |
|---|---|
| `glue/` | The PowerShell that joins the parts together: administrator rights, loading the C# types, the background modes for scheduled tasks (`/check`, `/autoclean`, `/selftest`) and so on |
| `cs/` | The C# code. `RowTypes.cs` is `$rowCode`; the others are joined in order into `$dupCode` and compiled together: duplicate finding, batched folder reads and multi-threaded statistics (`DirReader.cs`), reading the NTFS file table and change journal directly (`Mft.cs`), the space map's folder tree (`DiskMap.cs`), dark-mode colors (`Theme.cs`), small file-system helpers, the core rules (`Core.cs`: path rules and the state machine for move progress, pure functions the engine calls), and the rows of each page's lists |
| `engine/` | `$engine`: the core logic for cleaning, moving, delete protection, logging and the self-check, shared by the UI thread and every background job |
| `i18n/en.tsv` | The English UI translation table: one "Chinese original<Tab>English" pair per line, `\n` for a line break |
| `ui/` | `main.xaml` is the main window and `help-en.xaml` the English help page; `10-…` to `99-…` hold each page's UI logic, one file per page |

Notes:

- `engine/SettingsStore.ps1` is a standalone persistence service: `Write-SettingsFile` takes a file path, key, value and lock timeout and returns `{ Ok, Error, Stage }`. It does not read UI state or application globals and can be loaded by itself for tests.
- `engine/TransferPolicy.ps1` contains pure copy-result and complete-count checks. `engine/Engine.ps1` adapts these services to application state, translations and filesystem operations. The files are joined inside the engine here-string, so the executable still needs no sidecar modules.
- New move journals use normalized-path SHA-256 identities in `ClearCCore.JournalIdentity`. Recovery reads legacy records too, prefers a new-format record for the same source, and only clears matching legacy records.

- These files are **fragments**. They can't run or compile on their own; only the joined file is the complete program.
- `cs/RowTypes.cs` and `ui/main.xaml` sit inside double-quoted here-strings: don't write `$` or backticks in them.
- The files are UTF-8 with CRLF line endings; `glue/00-start.ps1` starts with a BOM (Windows PowerShell 5.1 needs it to read Chinese).
