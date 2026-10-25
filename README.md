
<p align="center"><img src="docs/icon.png" width="96" alt="ClearC"></p>

<h1 align="center">ClearC (腾挪 ClearC)</h1>

<p align="center">A small tool that frees up space on drive C: on Windows 10 / 11 (formerly "C盘清理工具"): it cleans caches, moves chat data and apps to another drive, and finds large and duplicate files.<br>A single exe: double-click it and it runs, with nothing to install.</p>

<p align="center">English · <a href="README.zh-CN.md">中文</a></p>

---

## What it does

| Page | What it does |
|---|---|
| **Clean up C:** | After a scan, the items that can be handled are listed in tabs by group (the tabs stick to the top as you scroll, so switching groups doesn't mean scrolling back up). Each item can be set to Delete, Move to another drive or Skip; the headers sort by name and size, and a drop-down shows only one kind of action. Things that are rebuilt automatically after deletion, such as caches, temporary files and logs, are selected by default; things that come at a cost, such as Windows.old, the Recycle Bin, orphaned Windows Installer packages, leftover driver extracts, broken shortcuts and event logs, are skipped by default. There is also One-click cleanup, which only deletes and never moves; when chat data takes a lot of space it gets its own card on the cleanup page and is only moved when you click "Move chat history". Cleanup has four tiers: Safe to clean (deleted by default), Rebuilt after cleaning (browser caches, shader caches, download caches and other things that have to be regenerated; also deleted by default, but grouped separately and listed separately before running), Skipped by default, and Protected (never touched). Before running you can open "View file list", and in Settings you can have deletes go to the Recycle Bin first; the free space before and after each item is written to the activity log. A scan usually takes a few seconds: folder sizes come from the file table, the few items that need to ask Windows (orphaned installer packages, old driver packages, the Delivery Optimization cache) are asked at the same time, and the C: file table is read in the background whenever ClearC is idle. The items come from a cache library with dozens of entries: Windows' own temporary files, update cache and logs; the web cache of Chrome, Edge, Firefox, Brave, 360, QQ and other browsers; graphics shader caches; the caches of Steam, Epic, Adobe, Teams, Discord, Slack, VS Code, Spotify, NetEase Cloud Music and other apps; and the download caches of developer tools such as pip, npm, NuGet, Go and Rust. Only caches are deleted, never cookies, history, passwords or saved data. You can also add your own folders and exclude folders. |
| **Moving chat data** | The chat history and data of WeChat (new and old versions), QQ, WeCom, Tencent Meeting, Feishu, DingTalk, Telegram, Discord, Slack, Signal, LINE, Viber, KakaoTalk and Zoom are moved as a whole to another drive, and a link is left in the original location on C:, so the apps keep working as usual. If an app is open, ClearC first asks whether it should close it for you. |
| **Duplicates** | Finds files with exactly the same content. The search options are in four tabs that fold away once the search starts, so the results fill the page. When looking for files of 1 MB or more on an NTFS drive, files are listed straight from the file table instead of reading folder by folder. You can delete the extra copies, or use "Merge into one copy" (hard links: the file is still in every location but takes the space of one copy). "Similar photos" finds photos that look the same by a 64-bit fingerprint (including different resolutions, re-compression and slight crops); these can only go to the Recycle Bin or be archived. Keep rules: keep the newest / the oldest / the one outside C: / the one in a given folder / the one with the shortest path. "Archive checked…" doesn't delete anything: it moves the files into one folder, keeping their original paths. |
| **Save space** | Pick an item in the contents list on the left and only that item is shown on the right. Space can be saved without deleting files: system compression (CompactOS), NTFS folder compression, moving the page file to another drive, a smaller hibernation file, compacting WSL / Docker virtual disks, moving WSL distributions (wsl --manage --move), emulators and virtual machines as a whole, making OneDrive files online-only, turning off Windows reserved storage, keeping only small crash dumps, moving the temp folder to another drive, and letting DISM analyze how much the component store can reclaim. It also shows how much space system restore points take (view only, never deleted; to change it, open Windows' "System Protection"). |
| **Space map** | Scans a whole drive and lets you click down level by level to see which folders take the space, also as a treemap. On NTFS drives it reads the file table (MFT) on the disk directly, so hundreds of thousands of files are usually scanned in a few seconds to a dozen or so; when that isn't possible it falls back to scanning folder by folder (you can also turn off "Fast scan"). "Find files" filters large files by size, how long since they changed, type and name; you can select several and delete them together, or look only at the large files inside chat data (view only). "Since last scan" shows which folders are growing. Every row has a check box (like File Explorer's item check boxes), you can also hold the left or right mouse button and drag up or down to select a run of rows, and the right-click menu can open, copy the path, compress and delete. With the fast scan, the actual size on disk (compressed, sparse and cloud-only files take less than their size) and hard links (many files in WinSxS are the same copy as in System32) are noted, and "Space breakdown" explains what the used space consists of and why it doesn't match the sum of file sizes. At the top of the page each drive has a health card: usage, health status and, for SSDs, temperature, wear and power-on time, colored by level. One overview line shows used / total and a segmented bar of system and apps, personal files, cleanable caches, other, and free space; the treemap and the list are linked (clicking a tile selects its row, and the selected row's tile is outlined); "By type" sorts every file on the drive into ten groups by extension; "Find files" shows up to 1,000 files, sorted by size or time and filtered by owner; "Recent changes" reads the change journal (USN) and lists the folders where files were created or rewritten most in the last few days; "Since last scan" keeps dated snapshots so you can compare with a few days ago, and says in one sentence how much the used space grew and where (Docker, WSL, browser caches, Windows Update…). There are back and forward (mouse side buttons, Alt+← / Alt+→) and a clickable path; the "Delete list" collects files to delete from different folders and deletes them together, showing all along roughly how much space the drive will have left and, afterwards, how much was actually freed; "Worth a look" lists large folders whose names say they are caches, dependency packages, build output or virtual environments; the treemap is colored by what the folders hold, with caches hatched. Lists can be exported to CSV, and the whole drive can be exported as a web report (which the browser can save as a PDF). |
| **Apps** | Installed apps sorted by the space they take. They can be uninstalled, after which ClearC checks for leftover folders; apps installed on C: can also be moved as a whole to another drive without reinstalling. "Check for updates" uses winget, which comes with Windows, to see which apps have new versions, and "Update" upgrades them in a terminal. Four more views: startup items (the same sources as Task Manager), third-party scheduled tasks, third-party context menu extensions (all of which can be disabled and re-enabled without deleting anything), and folders that uninstalled apps may have left behind (only a guess; look first, then move them to the Recycle Bin). Every row can be ticked (or dragged over with the left button), so you can uninstall several apps in one go (each app's own uninstaller opens in turn, the next one after the previous one finishes), disable or enable several items, or move several leftovers to the Recycle Bin, each with one confirmation first. |
| **System health** | A row of tabs next to the title; click one and only that section is shown. Blue screens and crashes has three smaller tabs, and in Common fixes you pick a problem on the left and see the fixes on the right. **Hardware**: CPU (load, clock speed, throttling judged from performance counters, ACPI temperature), memory (used, committed, hard faults, WHEA memory errors), each drive (SMART health, temperature, wear, read errors), battery, graphics card, and Windows (version, uptime, pending restart, recent updates, devices with problems, whether the clock was set back); anything that can't be read is shown as unreadable. **Boot time** and the programs that slow down startup. **Blue screens and crashes**: ClearC parses minidumps itself (the bug check code, parameters, disk-read status codes, the process involved, the probable driver, drivers on the stack) and explains each blue screen in one sentence; "Diagnosis" looks at several blue screens, the event logs, drive health, the clock and the Windows version together (for example, disk-read failures plus a system process exiting repeatedly means the system drive dropped out), and under each finding there are "Fix as suggested" (the steps ClearC can do, done in one go, confirmed first and undoable) and "Things to do yourself" (backups, BIOS and driver updates, the vendor's hardware diagnostics…, with how old this PC's versions are), plus a link to the vendor's driver download page for the service tag; the report can be copied and a diagnostics package exported (dumps, 30 days of logs, systeminfo, the driver list). **Common fixes**: the fixes most often recommended on forums, listed by problem (blue screens, drives dropping out, system files, Windows Update, network, time, sleep and wake, sound, icons and the Store, slow startup); all of them are commands that come with Windows, run in a visible terminal; anything that changes something asks first, anything that can be undone saves the old state first, and nothing deletes files or ends programs. **Activity monitor** (click a column name to sort by CPU, memory, write speed or amount written) and **Windows events**. All of this is read in the background after ClearC opens, so there is no wait when you open the page; plugging or unplugging a drive refreshes it automatically. |
| **Moved folders** | "Can be moved" lists the chat data, apps and other large folders on C: that can still be moved; tick several and move them in one go. Apps that aren't suitable for moving are listed separately with the reason. The contents list on the left shows one group at a time. "Moved" shows the current state of every folder that was moved; each can be moved back to C:, have its broken link repaired, or have an extra copy left by an unfinished move deleted. |
| **Reminders** | A notification in the bottom-right corner when free space on C: drops below a set value or cleanable caches exceed a set value (checked after each sign-in and once a day at noon); and an automatic cache cleanup on a schedule, on one day a week or every day. Both are off by default and run from Windows Task Scheduler, so ClearC doesn't need to stay open. |
| **Activity log** | Every delete, move, merge, compression, uninstall and system setting change is recorded as a txt file and can be viewed by category and time. Logs are kept for six months by default; this can be changed. |
| **Settings** | The contents list on the left is split into "General", "Interface" and "Cleanup and scanning"; click an item and only that item is shown. **Mode**: Home user, Engineer, and Developer and IT decide how much the window shows (asked once on first start, changeable at any time without losing settings). Appearance and language, and what the window shows: pages you don't use, the buttons at the bottom left, page descriptions, and the space map's check boxes and columns can all be turned off; the fast scan switch; letting other programs go first while finding duplicates (Windows background mode, with low disk and memory priority); the cleanup list: send deletes to the Recycle Bin first, add your own folders to clean, exclude folders you don't want touched. |

**Three modes**, each with more features than the one before; switching modes keeps every setting and record:

| Mode | For | What it has |
|---|---|---|
| **Home user** | People who just want a clean C: | Clean up C:, Save space, Space map, Apps, System health (hardware, blue screens and crashes, common fixes) and Help. The cleanup list only has common caches and temporary files that apps rebuild automatically; items that come at a cost are still skipped by default. |
| **Engineer** | People who maintain their own PC | Adds Duplicates, Moved folders, Reminders and the Activity log; Find files, Since last scan, Recent changes, export and compression in the space map; the page file, restore points, compressed folders, virtual disks and merging duplicates in Save space; startup items, leftover folders, Check for updates and moving apps to another drive in Apps; boot time, the activity monitor and the fixes that change more (resetting the network, resetting the update components, checking C: at startup, turning off drive power saving, turning off Fast Startup) in System health; developer tool caches and driver leftovers in the cleanup list. |
| **Developer and IT** | Developers, operations, IT support | Everything. Adds scheduled tasks, context menus, reserved storage, component store analysis, blue-screen dumps, the temp folder location, a custom cleanup list and exclusions, the fast scan switch, Space breakdown, Check scanning, the run log, repairing system files, the Windows event summary, and items such as orphaned Installer packages, event logs, old driver packages and the NuGet / Gradle / Maven / JetBrains caches. |

The interface comes in **Chinese and English**, **light and dark**; switch in Settings or with "English / 中文" and "Appearance" at the bottom of the sidebar. On the Help page you can **check for updates** (it only goes online when you click it) and run **Check scanning**, which verifies the fast scan on your PC and gives a result you can send to the developer.

## Screenshots

<p align="center"><img src="docs/screenshots/clean-en.png" width="860" alt="Clean up C:: the items that can be handled, listed by group after a scan"></p>

<table>
  <tr>
    <td width="50%"><img src="docs/screenshots/map-en.png" width="100%" alt="Space map"><br><sub>Space map: see level by level which folders take the space; every row has a check box</sub></td>
    <td width="50%"><img src="docs/screenshots/map-tree.png" width="100%" alt="The space map's treemap"><br><sub>Treemap: the bigger the tile, the more space it takes</sub></td>
  </tr>
  <tr>
    <td><img src="docs/screenshots/save.png" width="100%" alt="Save space"><br><sub>Save space: system compression, page file, hibernation file and restore points, without deleting files</sub></td>
    <td><img src="docs/screenshots/settings.png" width="100%" alt="Settings"><br><sub>Settings: appearance, language and what the window shows</sub></td>
  </tr>
  <tr>
    <td><img src="docs/screenshots/help-en.png" width="100%" alt="Help"><br><sub>Help: contents on the left; click an item to read it on the right</sub></td>
    <td><img src="docs/screenshots/dark.png" width="100%" alt="Dark mode"><br><sub>Dark mode</sub></td>
  </tr>
</table>

The screenshots are taken by an automated test machine on GitHub (the UI self-test also scans that machine's C: drive, measuring only and deleting nothing), so the folders and sizes are the test machine's and differ from an ordinary PC. Some of them show the Chinese interface.

## Safety rules

- **Nothing in personal folders is ever deleted**: Desktop, Documents, Downloads, Pictures, Videos, Music, Favorites and OneDrive, including the personal folders of other accounts on this PC and the "Public" folders. Even if selected by mistake, they are skipped automatically.
- **Deletes must be confirmed**: every delete requires ticking the box confirming that the files are no longer needed before the Delete button can be clicked.
- **System locations can't be deleted**: the Windows folder, software install folders (uninstall from "Apps" instead), the places that store passwords and certificates, software installer caches, and moved data are all blocked, with the reason shown.
- **Moves verify before deleting**: after copying to the target drive, the file count and total size on both sides must match before the original location is replaced by a link and the copy on C: is deleted. If the check fails or a file is in use, the original folder is left exactly as it was.
- **Can be cancelled midway**: long operations can be cancelled at any time and stop at a safe point. Cancelling a move while it is still copying leaves the original folder on C: untouched; steps that can't stop halfway, such as replacing a folder with a link, finish that step first and then stop.
- **Everything is on record**: every change is written to the activity log.
- **"Move to Recycle Bin" means the Recycle Bin**: for network locations, USB drives, a disabled Recycle Bin, or files bigger than the Recycle Bin, Windows silently deletes permanently instead; ClearC checks beforehand, and in those cases doesn't delete and explains why.
- **It does what you confirmed**: at run time each item is checked against what the scan listed; if the cleanup list changed after the scan, scan again.
- **Links are not followed**: when a delete meets a directory junction or symbolic link, only the link itself is removed and not a single file in the folder it points to is touched; items inside OneDrive-synced folders are not moved.

How each path can lose data, what guards it now, which problems were fixed and which postponed, and which safety tests run automatically on every code change: see [docs/SAFETY.md](docs/SAFETY.md).

## How moving works

Where an app reads and writes its data is decided by the app itself, and most of them can't be changed (for example `AppData\Roaming\Tencent`). So to move it, ClearC copies the whole folder to another drive (by default into the `CDriveMoved` folder on the drive with the most free space), verifies the copy, puts a **directory junction** in the original location on C:, and then deletes the original folder on C:.

The link takes almost no space. When the app opens its old path, Windows redirects it to the target drive; the app notices no change, and there is nothing to reconfigure or reinstall.

Keep in mind: the target drive must stay connected, and please don't delete, rename or move the `CDriveMoved` folder. You can move things back to C: from "Moved folders" at any time.

## Download and use

1. Download the latest `ClearC-vX.X.exe` from [Releases](../../releases) (it is 腾挪 ClearC; the file name is in English because GitHub doesn't support Chinese download file names).
2. Put it somewhere permanent (for example `D:\Tools\`) and double-click it. It needs administrator rights, so a UAC prompt appears.
3. The first start shows a risk notice that you must agree to before using it. "Help" in the sidebar has the full instructions.

Requirements: Windows 10 or 11. It uses the Windows PowerShell 5.1 and .NET Framework 4.8 that come with Windows, so nothing else needs to be installed.

The exe is not code-signed yet, so Windows SmartScreen may say "Windows protected your PC"; click "More info" → "Run anyway". If you'd rather not, build it yourself from the source as described below.

The release notes for each version (with the exe's SHA256) are in [docs/releases](docs/releases/README.md). After downloading, run `Get-FileHash .\ClearC-vX.exe` in PowerShell; if it matches the notes, the file hasn't been altered.

### If your antivirus blocks or deletes it

The exe has no code signature and is a PowerShell script packaged as a program, so Windows Defender's machine-learning detection sometimes reports a new version as a trojan by mistake and deletes it after download (3.6.1 was reported as `Trojan:Win32/Bearfoos.B!ml`; the `!ml` at the end means a machine-learning heuristic). Each version is submitted to Microsoft for review before it is published, and 3.6.2 has been confirmed as a false positive. If it gets blocked:

- Don't turn off your antivirus. Wait a day or two and download again, or click "Check for updates" under Windows Security → "Virus & threat protection updates" and then download again.
- If you need it right away, download the source and double-click `src/run-from-source.bat` to run it directly, without the exe.

Nothing happens on double-click: before 3.6.3, ClearC sometimes stayed in the background after its window closed, and double-clicking again assumed one was already open and quit. From 3.6.3 on, closing the window ends the program, and if a copy is still stuck, double-clicking asks whether to end it and open again. On older versions, end the processes whose names start with `ClearC` in Task Manager.

The maintainer's release process (including every field of the Microsoft review submission) is in [docs/RELEASING.md](docs/RELEASING.md).

## Run or build from source

The whole program is one PowerShell script, `src/CleanC-UI.ps1`, and the exe only wraps it. The script is assembled from files split by function under `src/parts/` (see [src/parts/README.md](src/parts/README.md)): to change the code, edit the files in `src/parts/` and then run `build\merge.ps1`.

**Run the source directly**: double-click `src/run-from-source.bat` (it asks for administrator rights). It works the same as the exe, except that scheduled tasks such as reminders and weekly cleanup are only supported by the exe.

**Build the exe on Windows** (it only uses the C# compiler that comes with Windows; no Visual Studio needed):

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File build\build.ps1
```

The exe is written to `out\`. On Linux / macOS, run `build/build-roslyn.ps1` with PowerShell 7; the preparation steps are at the top of the file.

### Code layout

```
src/parts/               the source, split by function (joined, it is src/CleanC-UI.ps1)
  ├─ cs/                   C#: duplicate finding, batched folder reads and multi-threaded statistics, reading the NTFS file table (MFT) and change journal, the space map, dark-mode colors, list rows
  ├─ engine/Engine.ps1     the core logic for cleaning, moving, delete protection, logging and the self-check; shared by the UI thread and every background job
  │                        cleanup items live in its cache library $script:cacheLib, one "name | path | description | options" entry per line; add entries here and put the English in i18n/en.tsv
  ├─ i18n/en.tsv           the English UI translation table
  ├─ ui/                   the WPF interface (main.xaml, the English help page) and each page's UI logic
  └─ glue/                 joins the parts: administrator rights, loading the C# types, scheduled-task modes (/check, /autoclean, /selftest)
src/CleanC-UI.ps1        the whole program, joined (used both to run the source and to build the exe)
src/run-from-source.bat  runs the source directly, without building
build/merge.ps1          joins src/parts/ into src/CleanC-UI.ps1 (-Check only checks that it is up to date)
build/launcher.cs        the exe launcher: holds the script as an embedded resource and runs it in an in-process PowerShell 5.1
build/app.manifest       requests administrator rights and long path support
build/build.ps1          builds the exe on Windows (joins the parts first; signs it if a certificate is configured)
build/build-roslyn.ps1   builds the exe on other systems
tests/                   tests, see below
```

### Tests

| Test | Where it runs | How to run it |
|---|---|---|
| Syntax, C# compile, XAML, control names, translations | Any system with PowerShell | `pwsh tests/Checks.ps1` |
| Core logic (size statistics, searching, size lookups in the tree, dark-mode colors and so on) | Windows PowerShell 5.1 or PowerShell 7 | `pwsh tests/Engine.Tests.ps1` |
| Reading the file table directly, incremental updates from changes | Linux, as root, with ntfs-3g and PowerShell 7 | `sudo bash tests/ntfs/run.sh`: builds real NTFS images with mkntfs and ntfs-3g (hard links, sparse files, fragmentation, alternate data streams, very deep paths, various cluster sizes) and compares them with folder-by-folder counts of the mounted image. Symbolic links created by ntfs-3g are ordinary files, unlike on Windows, so a few differences are allowed |
| Dark-mode contrast | Any system with PowerShell and Python | `bash tests/theme/run.sh`: computes the contrast of each piece of text against its background (approximately) |
| Checking the fast scan on real Windows | Windows | "Help" → "Check scanning" in the program; or `ClearC.exe /selftest`, with the result in `%LOCALAPPDATA%\CleanC\selftest.txt` (set the `CLEANC_REPORT` environment variable to change the location and `CLEANC_QUIET=1` to suppress the prompt); the exit code is the number of failed checks. It also checks that the size on disk (sparse, NTFS compression, system compression, hard links) matches what Windows itself reports |
| UI features | Windows | `ClearC.exe /uitest`: opens the window (off screen), clicks through every page, the settings switches, the item check boxes, right-button drag selection, the right-click menu and Space breakdown, treats every dialog as cancelled, and closes itself when done; the result is in `%LOCALAPPDATA%\CleanC\uitest.txt` (`CLEANC_REPORT` changes it), and the exit code is the number of failed checks. Settings are put back as they were afterwards. With `CLEANC_SHOTS=1` it also really scans C: (measuring only, deleting nothing) and saves several pages as PNGs next to the report; the automated tests on GitHub run it once each in English light, Chinese light and Chinese dark, which is where the screenshots in this README come from |

### Code signing

With a signed exe, SmartScreen warns far less often (the publisher's reputation builds up gradually with downloads, so a newly signed version may still warn at first). `build\build.ps1` already supports signing: set the environment variables `CLEARC_SIGN_PFX` (a .pfx certificate) and `CLEARC_SIGN_PASSWORD`, or `CLEARC_SIGN_THUMBPRINT` (a certificate installed under "Current User → Personal"), and after the build it signs with the Windows SDK's signtool and adds a timestamp. Ways to get a certificate:

- **SignPath Foundation** (free, for open-source projects): apply at [signpath.org](https://signpath.org/). The requirements include an OSI-approved open-source license (this project is MIT), an exe built from source by a public automated build (such as GitHub Actions), every signing approved by hand by the maintainer, and a code signing policy on the project page.
- **Azure Artifact Signing** (formerly Trusted Signing, about USD 10 a month): currently limited to individual developers in the US and Canada, and organizations in the US, Canada, the EU and the UK.
- An OV code signing certificate bought from a certificate authority also works.

### Download mirror in China

If downloading from GitHub is slow in China, a repository with the same name on [Gitee](https://gitee.com/) can serve as a mirror: Gitee's "import repository from GitHub" can sync the code on a schedule; when releasing, also upload the exe to the Gitee repository's releases and add the download link here.

### What the program leaves on your PC

- `%LOCALAPPDATA%\CleanC\`: settings (settings.txt), the C: space history (history.txt), the activity log, and space map snapshots.
- `CDriveMoved\` on each drive: data moved to that drive.
- The `CleanC` folder in Task Scheduler: only created when reminders or weekly cleanup are turned on, and deleted when they are turned off.

## Risk notice

ClearC deletes or moves files on your PC as you choose. Deleted files may not be recoverable, so there is a risk of data loss. Before every delete, make sure the files really are no longer needed and that deleting them won't cause you any loss; back up important files first.

**You are responsible for any data loss or other damage caused by using ClearC; the developer accepts no liability.**

## Feedback

- Open an [Issue](https://github.com/Xuanqiyun/ClearC/issues) in this repository, ideally with a screenshot and the diagnostic information copied from "Help" → "Feedback and updates" in the program; if scan results look wrong, attach the result of "Check scanning". "Help" → "Feedback" in the program also has buttons that open the project page and the issue form.

## License

[MIT](LICENSE)
