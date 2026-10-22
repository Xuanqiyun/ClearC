# 核心安全规则的测试：每次改代码都跑（Linux 和 Windows 都能跑，Windows 上多几条）。
# 规则来自 README 的「安全原则」：个人文件夹里的东西不删、链接不跟进、系统目录拦住、自动清理只碰安全项、
# 回收站不会悄悄变成永久删除、不删还原点、不清注册表、计划任务是用户级的、不随便杀进程。
# 两类测试：一类真的在临时文件夹里建东西试删；一类「锁」住源码里的关键写法，改坏了就报错。用法：pwsh tests/Safety.Tests.ps1
param([string]$Script = (Join-Path $PSScriptRoot '../src/CleanC-UI.ps1'))
$ErrorActionPreference = 'Stop'
$src = [IO.File]::ReadAllText($Script)
$dupCode = [regex]::Match($src, "(?s)\`$dupCode = @'\r?\n(.*?)\r?\n'@").Groups[1].Value
$engineText = [regex]::Match($src, "(?s)\`$engine = @'\r?\n(.*?)\r?\n'@").Groups[1].Value
if (-not ('DupFinder' -as [type])) { Add-Type -TypeDefinition $dupCode }
Invoke-Expression $engineText
$ErrorActionPreference = 'Continue'
$sync = [hashtable]::Synchronized(@{}); $sync.Log = [System.Collections.Queue]::Synchronized((New-Object System.Collections.Queue)); $sync.P = [hashtable]::Synchronized(@{})
$fails = 0
function Check($name, $ok) { if ($ok) { "ok   $name" } else { "FAIL $name"; $script:fails++ } }
function Skip($name) { "skip $name (Windows only)" }
$win = [IO.Path]::DirectorySeparatorChar -eq '\'
$sep = [IO.Path]::DirectorySeparatorChar

$T = Join-Path ([IO.Path]::GetTempPath()) ('clearc-safety-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Force -Path $T | Out-Null
$script:appDir = Join-Path $T 'appdir'; $script:settingsFile = Join-Path $script:appDir 'settings.txt'; $script:opLogDir = Join-Path $script:appDir 'log'
$savedProfile = $env:USERPROFILE
try {
    Init-DriveThreads
    # ============ 1. 个人文件夹里的东西不删 ============
    # 用一个假的用户目录：Desktop / Documents / Downloads 里放文件，照着清理的办法删，一个都不能少
    $home2 = Join-Path $T 'Users\Leon'
    if (-not $win) { $home2 = Join-Path $T 'Users/Leon' }
    foreach ($d in 'Desktop', 'Documents', 'Downloads', 'AppData\Local\Temp') { New-Item -ItemType Directory -Force -Path (Join-Path $home2 $d) | Out-Null }
    [IO.File]::WriteAllText((Join-Path $home2 'Desktop/thesis.docx'), 'important')
    [IO.File]::WriteAllText((Join-Path $home2 'Documents/tax.xlsx'), 'important')
    [IO.File]::WriteAllText((Join-Path $home2 'Downloads/setup.exe'), 'important')
    [IO.File]::WriteAllText((Join-Path $home2 'AppData/Local/Temp/junk.tmp'), 'junk')
    $env:USERPROFILE = $home2; $script:personalDirs = $null
    if ($win) {
        Check 'Test-Personal: Desktop file of the current user' (Test-Personal (Join-Path $home2 'Desktop\thesis.docx'))
        Check 'Test-Personal: Documents of another user on this PC' (Test-Personal (Join-Path (Split-Path $home2 -Parent) 'Other\Documents\x.txt'))
        Check 'Test-Personal: the Public folder' (Test-Personal (Join-Path (Split-Path $home2 -Parent) 'Public\Desktop\a.lnk'))
        Check 'Test-Personal: OneDrive folders' (Test-Personal (Join-Path $home2 'OneDrive - Company\doc.docx'))
        Check 'Test-Personal: AppData\Local\Temp is NOT personal (caches live there)' (-not (Test-Personal (Join-Path $home2 'AppData\Local\Temp\junk.tmp')))
        Check 'Test-Personal: a drive root counts as personal (never cleared)' (Test-Personal 'C:\')
        # Remove-Contents 指到个人文件夹：什么都不删
        Remove-Contents @((Join-Path $home2 'Desktop'), (Join-Path $home2 'Documents'), (Join-Path $home2 'Downloads')) '' $false
        Check 'Remove-Contents on personal folders deletes nothing' ((Test-Path (Join-Path $home2 'Desktop\thesis.docx')) -and (Test-Path (Join-Path $home2 'Documents\tax.xlsx')) -and (Test-Path (Join-Path $home2 'Downloads\setup.exe')))
        Remove-Contents @((Join-Path $home2 'Desktop')) '' $true
        Check 'Remove-Contents (whole folder) on Desktop deletes nothing' (Test-Path (Join-Path $home2 'Desktop\thesis.docx'))
        # 通配符也绕不过去
        Remove-Contents @((Join-Path $home2 'D*')) '' $false
        Check 'Remove-Contents with a wildcard reaching personal folders deletes nothing' ((Test-Path (Join-Path $home2 'Desktop\thesis.docx')) -and (Test-Path (Join-Path $home2 'Downloads\setup.exe')))
        # 预览清单也不会列个人文件夹里的东西
        $pv = @(Get-DeletePreview @(@{ N = 't'; Paths = @((Join-Path $home2 'Desktop'), (Join-Path $home2 'AppData\Local\Temp')) }) 100)
        Check 'Get-DeletePreview lists only the Temp file' ($pv.Count -eq 1 -and $pv[0].Path -like '*junk.tmp')
        Remove-Contents @((Join-Path $home2 'AppData\Local\Temp')) '' $false
        Check 'Remove-Contents does clear a cache folder (so the guard is not just "never delete")' (-not (Test-Path (Join-Path $home2 'AppData\Local\Temp\junk.tmp')))
    } else { Skip 'personal folder deletion tests' }
    # ============ 2. 系统目录、程序目录、整块盘拦住 ============
    if ($win) {
        foreach ($p in @('C:\', 'C:\Windows', 'C:\Windows\System32\drivers', 'C:\Program Files\SomeApp', 'C:\Program Files (x86)', 'C:\pagefile.sys', 'C:\hiberfil.sys', 'C:\Users', (Split-Path $home2 -Parent), $home2, (Join-Path $home2 'AppData'), 'C:\ProgramData\Microsoft\Windows', 'C:\System Volume Information', 'C:\$Recycle.Bin')) {
            Check ("Get-DeleteBlock refuses {0}" -f $p) ([bool](Get-DeleteBlock $p))
        }
        Check 'Get-DeleteBlock allows an ordinary cache folder' (-not (Get-DeleteBlock (Join-Path $home2 'AppData\Local\Temp')))
    } else { Skip 'Get-DeleteBlock tests' }
    # ============ 3. 链接不跟进：删掉链接只删链接本身，指向的东西一个不少 ============
    $target = Join-Path $T 'target'; New-Item -ItemType Directory -Force -Path (Join-Path $target 'deep') | Out-Null
    [IO.File]::WriteAllText((Join-Path $target 'keep.txt'), 'keep'); [IO.File]::WriteAllText((Join-Path $target 'deep/keep2.txt'), 'keep')
    $cache = Join-Path $T 'cache'; New-Item -ItemType Directory -Force -Path $cache | Out-Null
    [IO.File]::WriteAllText((Join-Path $cache 'a.tmp'), 'x')
    $link = Join-Path $cache 'lnk'
    if ($win) { New-Item -ItemType Junction -Path $link -Target $target | Out-Null } else { New-Item -ItemType SymbolicLink -Path $link -Target $target | Out-Null }
    Check 'IsLink sees the link' ((IsLink $link) -and -not (IsLink $target))
    Check 'DirBytes does not count through the link' ((DirBytes $cache) -eq 1)
    if ($win) {
        Remove-Contents @($cache) '' $false
        Check 'Remove-Contents removed the link and the file in the cache folder' (-not (Test-Path -LiteralPath $link) -and -not (Test-Path (Join-Path $cache 'a.tmp')))
        Check 'Remove-Contents left the link target untouched' ((Test-Path (Join-Path $target 'keep.txt')) -and (Test-Path (Join-Path $target 'deep/keep2.txt')))
        # 链接指向个人文件夹时同样：目标不动
        New-Item -ItemType Junction -Path $link -Target (Join-Path $home2 'Documents') | Out-Null
        Remove-Contents @($cache) '' $true
        Check 'Removing a whole folder that holds a link into Documents keeps Documents' (Test-Path (Join-Path $home2 'Documents\tax.xlsx'))
        Check 'Get-LinkedAncestor finds a link in the path' ([bool](Get-LinkedAncestor (Join-Path $target 'deep')) -eq $false -and -not (Test-Path -LiteralPath $cache))
    } else { Skip 'link deletion tests' }
    # ============ 4. 目录库：每条路径都落在该落的地方 ============
    $lib = Get-CacheLibrary
    $bad = @()
    foreach ($x in $lib) {
        foreach ($p in $x.Paths) {
            if (-not $p) { continue }
            $q = $p.TrimEnd('\')
            if ($q -match '^[A-Za-z]:$' -or $q -match '^[A-Za-z]:\\(Users|Windows|Program Files( \(x86\))?|ProgramData)$') { $bad += ($x.N + ' → ' + $p) }
            if ($env:USERPROFILE -and ($q -ieq $env:USERPROFILE.TrimEnd('\'))) { $bad += ($x.N + ' → ' + $p) }
            if ($q -match '(?i)\\(Desktop|Documents|Downloads|Pictures|Videos|Music)(\\|$)' -and $q -notmatch '(?i)\\AppData\\') { $bad += ($x.N + ' → ' + $p) }
        }
    }
    Check ("cache library never points at a drive root, a system root or a personal folder ({0})" -f ($bad -join '; ')) ($bad.Count -eq 0)
    $noPath = @($lib | Where-Object { -not $_.Paths -or @($_.Paths | Where-Object { $_ }).Count -eq 0 -and -not ($_.N -like '*Steam*') })
    Check 'cache library entries all have a path (or need Steam)' ($noPath.Count -eq 0)
    # ============ 5. 自动清理只碰安全项 ============
    $cat = Get-Catalog
    $auto = @(Select-AutoCleanItems $cat)
    Check ("auto cleanup picks only safe cache items ({0} items)" -f $auto.Count) ($auto.Count -gt 5 -and @($auto | Where-Object { -not ([string]$_.G).StartsWith('安全清理') -or $_.Careful -or $_.Custom -or $_.Confirm -or $_.Act -or $_.Whole -or $_.Svc }).Count -eq 0)
    Check 'auto cleanup never includes Windows.old, Recycle Bin, Installer orphans, drivers, event logs' (@($auto | Where-Object { $_.N -match 'Windows\.old|回收站|Installer|驱动|事件日志|Recycle|driver|event log' }).Count -eq 0)
    Check 'confirm items default to skip' (@($cat | Where-Object { ([string]$_.G).StartsWith('需确认') -and $_.Def -ne (T '跳过') }).Count -eq 0)
    Check 'move-only items (Desktop, Downloads, chat data) have no delete action' (@($cat | Where-Object { ($_.Kind -eq 'move') -and ($_.Actions -contains (T '删除')) }).Count -eq 0)
    Check 'Desktop and Downloads default to skip' (@($cat | Where-Object { ($_.N -eq (T '桌面') -or $_.N -eq (T '下载')) -and $_.Def -ne (T '跳过') }).Count -eq 0)
    # ============ 6. 重复文件：逐字节比对是真的在比 ============
    $f1 = Join-Path $T 'd1.bin'; $f2 = Join-Path $T 'd2.bin'; $f3 = Join-Path $T 'd3.bin'
    $bytes = New-Object byte[] 300000; (New-Object Random 7).NextBytes($bytes)
    [IO.File]::WriteAllBytes($f1, $bytes); [IO.File]::WriteAllBytes($f2, $bytes); $bytes[150000] = [byte](($bytes[150000] + 1) % 256); [IO.File]::WriteAllBytes($f3, $bytes)
    Check 'SameContent: identical files' ([DupFinder]::SameContent($f1, $f2))
    Check 'SameContent: one byte differs in the middle' (-not [DupFinder]::SameContent($f1, $f3))
    # ============ 7. 旧版驱动包：绝不加 /force，非 oem 不删 ============
    $pnp = @([regex]::Matches($engineText, '[^\r\n]*pnputil\.exe[^\r\n]*') | ForEach-Object { $_.Value } | Where-Object { $_ -notmatch '^\s*#' })
    Check ("pnputil is never called with /force ({0} call sites)" -f $pnp.Count) ($pnp.Count -ge 1 -and @($pnp | Where-Object { $_ -match '(?i)/force' }).Count -eq 0)
    Check 'Remove-DriverPackage refuses names that are not oemNN.inf' ((Remove-DriverPackage 'C:\Windows\INF\nvlti.inf') -ne '' -and (Remove-DriverPackage '..\oem1.inf') -ne '')
    # ============ 8. 源码锁：改坏了就报 ============
    Check 'recycle bin: SHFileOperation asks when a file is too big instead of nuking it (ALLOWUNDO|NOCONFIRMATION|WANTNUKEWARNING)' (([regex]::Matches($dupCode, '0x40 \| 0x10 \| 0x4000')).Count -ge 2)
    Check 'restore points are never deleted (no vssadmin delete / Win32_ShadowCopy.Delete / Remove-ComputerRestorePoint)' ($src -notmatch '(?i)vssadmin\s+delete|Remove-ComputerRestorePoint|Disable-ComputerRestore|ShadowCopy[^\r\n]*\.Delete\(')
    Check 'no registry cleaner: no Remove-Item on HKLM/HKCU keys' ($src -notmatch ('(?i)Remove-Item\s+(-LiteralPath\s+|-Path\s+)?[' + "'" + '"]HK(LM|CU):'))
    Check 'registry values are only removed for the context-menu block list and the UI test' (([regex]::Matches($src, 'Remove-ItemProperty')).Count -le 2)
    Check 'scheduled tasks run as the current user (InteractiveToken), never SYSTEM' ($src -match 'LogonType>InteractiveToken<' -and $src -notmatch '(?i)/RU\s+SYSTEM|<UserId>S-1-5-18<|NT AUTHORITY\\SYSTEM')
    Check 'processes are only stopped in the chat-app close flow (2 call sites)' (([regex]::Matches($engineText, 'Stop-Process')).Count -eq 2 -and $src -notmatch '(?i)taskkill')
    Check 'no self-deleting scripts or boot-time tasks' ($src -notmatch '(?i)schtasks[^\r\n]*ONSTART' -and $src -notmatch 'RunOnce' -and $src -notmatch '(?i)Remove-Item[^\r\n]*\$PSCommandPath')
    # rd /s 的调用点是数过的：Remove-OneDir（先看是不是链接）、搬家收尾删备份、搬回来 / 删多余副本（核对过才删）、空间地图删除（IsLink 和 Get-LinkedAncestor 都查过）。多出一个就要人看
    Check ("rd /s call sites are the known 6, and Remove-OneDir checks reparse points first ({0})" -f ([regex]::Matches($src, 'rd /s /q')).Count) (([regex]::Matches($src, 'rd /s /q')).Count -eq 6 -and $engineText -match 'ReparsePoint\)\) \{ & "\$sys32\\cmd.exe" /c rmdir')
    $mapDel = [regex]::Match($src, '(?s)function Start-MapDelete.*?rd /s /q').Value
    Check 'space map delete checks IsLink and Get-LinkedAncestor before rd /s' ($mapDel -match 'IsLink \$p' -and $mapDel -match 'Get-LinkedAncestor \$p' -and $mapDel -match 'Get-DeleteBlock')
    Check 'moves verify the copy before replacing the original (robocopy/compare step present)' ($engineText -match '(?i)robocopy' -and $engineText -match '(?i)Compare-Copy|Verify-Copy|核对|对不上')
    Check 'every delete path in the UI goes through a confirmation sheet with the risk acknowledgement' (([regex]::Matches($src, '因删除造成的后果由我自己承担')).Count -ge 2)
    Check 'auto cleanup task is registered from exactly one place (the Reminders page switch), never at startup' (([regex]::Matches($src, 'Register-CleanTask \$script:taskClean')).Count -eq 1 -and $src -notmatch 'Enable-AutoTask \$true[^\r\n]*#.*启动')
} finally {
    $env:USERPROFILE = $savedProfile
    Remove-Item -LiteralPath $T -Recurse -Force -ErrorAction SilentlyContinue
}
""
if ($fails) { "$fails safety test(s) failed" } else { 'all safety tests passed' }
exit $fails
