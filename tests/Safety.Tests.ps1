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
try { & {
    # 测试里某条检查的表达式自己抛了异常，也算失败，不能悄悄跳过（trap 只管这一段，引擎加载不受影响）
    trap { "FAIL error in the test script: $($_.Exception.Message) (line $($_.InvocationInfo.ScriptLineNumber))"; $script:fails++; continue }
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
    $savedTemp4 = $env:TEMP; $env:TEMP = Join-Path $home2 (Join-Path 'AppData' (Join-Path 'Local' 'Temp'))   # 假用户目录配它自己的 TEMP
    try { $lib = Get-CacheLibrary } finally { $env:TEMP = $savedTemp4 }
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
    # ============ 7b. 审计后补的规则 ============
    # Windows.old：先拆里面的链接再删；不进「一键清理」
    $wo = @($cat | Where-Object { $_.N -eq 'Windows.old' })[0]
    Check 'Windows.old is never part of one-click cleanup and is removed through Remove-WindowsOld' ($wo -and $wo.One -eq (T '跳过') -and ([string]$wo.Act) -match 'Remove-WindowsOld' -and $src -notmatch "Remove-Item 'C:\\Windows\.old' -Recurse")
    if ($win) {
        $old = Join-Path $T 'winold'; $live = Join-Path $T 'live'
        New-Item -ItemType Directory -Force -Path (Join-Path $old 'Users\me'), $live | Out-Null
        [IO.File]::WriteAllText((Join-Path $live 'alive.txt'), 'alive'); [IO.File]::WriteAllText((Join-Path $old 'Users\me\old.txt'), 'old')
        New-Item -ItemType Junction -Path (Join-Path $old 'Users\me\Application Data') -Target $live | Out-Null
        $n = Remove-LinksInside $old
        Check "Remove-LinksInside removes the junction only ($n)" ($n -eq 1 -and -not (Test-Path -LiteralPath (Join-Path $old 'Users\me\Application Data')) -and (Test-Path (Join-Path $live 'alive.txt')) -and (Test-Path (Join-Path $old 'Users\me\old.txt')))
        # 任何盘根下的回收站、还原点
        foreach ($p in @('D:\$Recycle.Bin', 'D:\$Recycle.Bin\S-1-5-21-1\x.txt', 'E:\System Volume Information', 'D:\Recovery', 'D:\EFI\Boot')) { Check ("Get-DeleteBlock refuses {0} on any drive" -f $p) ([bool](Get-DeleteBlock $p)) }
        Check 'Get-DeleteBlock still allows D:\Games' (-not (Get-DeleteBlock 'D:\Games'))
        # 同一个文件的两个名字
        $h1 = Join-Path $T 'h1.bin'; $h2 = Join-Path $T 'h2.bin'
        [IO.File]::WriteAllText($h1, 'same'); New-Item -ItemType HardLink -Path $h2 -Target $h1 | Out-Null
        Check 'SameFile: hard link names are the same file' ([FsTools]::SameFile($h1, $h2))
        Check 'SameFile: different files are not' (-not [FsTools]::SameFile($f1, $f2))
    } else { Skip 'Windows.old links, drive-root block, SameFile tests' }
    # OneDrive 同步目录里的不搬
    $savedOd = $env:OneDrive; $env:OneDrive = 'X:\Users\me\OneDrive'
    Check 'Test-InOneDrive: inside the sync root' ((Test-InOneDrive 'X:\Users\me\OneDrive\Documents\xwechat_files') -and (Test-InOneDrive 'X:\Users\me\OneDrive'))
    Check 'Test-InOneDrive: a sibling folder is not' (-not (Test-InOneDrive 'X:\Users\me\OneDriveTemp\a') -and -not (Test-InOneDrive 'X:\Users\me\Documents'))
    $env:OneDrive = $savedOd
    Check 'moves refuse sources inside OneDrive (code path present)' ($engineText -match 'Test-InOneDrive \$src')
    Check 'reused move copies only use robocopy /MIR when the copy has no extra files' ($engineText -match "if \(\`$reuse -and \`$extra -eq 0\) \{ '/MIR' \}")
    Check 'a failed mklink that cannot be rolled back is reported, not swallowed' ($engineText -match '没能把原目录改回来')
    # 重复文件：查找根是链接的不进
    $dupRoot = Join-Path $T 'dups'; New-Item -ItemType Directory -Force -Path $dupRoot | Out-Null
    [IO.File]::WriteAllBytes((Join-Path $dupRoot 'x1.bin'), (New-Object byte[] 5000)); [IO.File]::WriteAllBytes((Join-Path $dupRoot 'x2.bin'), (New-Object byte[] 5000))
    $dupLink = Join-Path $T 'dups-link'
    if ($win) { New-Item -ItemType Junction -Path $dupLink -Target $dupRoot | Out-Null } else { New-Item -ItemType SymbolicLink -Path $dupLink -Target $dupRoot | Out-Null }
    $g1 = [DupFinder]::Find([string[]]@($dupRoot), 1, 0, $false, $null, $true, [string[]]@())
    $g2 = [DupFinder]::Find([string[]]@($dupLink), 1, 0, $false, $null, $true, [string[]]@())
    Check "duplicate finder scans a real folder ($($g1.Count) group) but skips a link root ($($g2.Count))" ($g1.Count -eq 1 -and $g2.Count -eq 0)
    Check 'duplicate deletion checks the modification time and the file identity before deleting' ($src -match 'fi\.LastWriteTime\.Ticks -ne \[long\]\$p\.Mtime' -and ([regex]::Matches($src, '\[FsTools\]::SameFile\(')).Count -ge 3)
    Check 'duplicates never use the VisualBasic recycle call that can silently delete permanently' ($src -notmatch 'VisualBasic\.FileIO\.FileSystem\]::DeleteFile')
    # 自动清理：一天内写过的临时文件不碰；本轮放进过回收站就不清空回收站
    $tmpd = Join-Path $T 'autotemp'; New-Item -ItemType Directory -Force -Path $tmpd | Out-Null
    [IO.File]::WriteAllText((Join-Path $tmpd 'fresh.tmp'), 'x'); [IO.File]::WriteAllText((Join-Path $tmpd 'stale.tmp'), 'x')
    (Get-Item (Join-Path $tmpd 'stale.tmp')).LastWriteTime = (Get-Date).AddDays(-3)
    $script:autoMinAge = (Get-Date).AddDays(-1)
    try { Remove-Contents @($tmpd) '' $false } finally { $script:autoMinAge = $null }
    Check 'automatic cleanup leaves files written in the last day alone' ((Test-Path (Join-Path $tmpd 'fresh.tmp')) -and -not (Test-Path (Join-Path $tmpd 'stale.tmp')))
    Check 'the Recycle Bin is not emptied in the same run that moved files into it' ($engineText -match 'recycledThisRun\) \{ Log')
    # ============ 7c. 「放进回收站」不会悄悄变成永久删除 ============
    Check 'recycle verdict: a Fixed drive with default settings is fine' ((Get-RecycleVerdict 10MB 'Fixed' $false 0 -1 500GB) -eq '')
    Check 'recycle verdict: network, removable and CD drives have no Recycle Bin' ((Get-RecycleVerdict 1 'Network' $false 0 -1 0) -and (Get-RecycleVerdict 1 'Removable' $false 0 -1 0) -and (Get-RecycleVerdict 1 'CDRom' $false 0 -1 0))
    Check 'recycle verdict: Recycle Bin turned off by policy' ([bool](Get-RecycleVerdict 1 'Fixed' $true 0 -1 500GB))
    Check 'recycle verdict: the drive is set to delete immediately (NukeOnDelete)' ([bool](Get-RecycleVerdict 1 'Fixed' $false 1 -1 500GB))
    Check 'recycle verdict: bigger than the Recycle Bin of that drive' ((Get-RecycleVerdict 2GB 'Fixed' $false 0 1024 500GB) -and -not (Get-RecycleVerdict 500MB 'Fixed' $false 0 1024 500GB))
    Check 'recycle verdict: a 0 MB Recycle Bin takes nothing' ([bool](Get-RecycleVerdict 1KB 'Fixed' $false 0 0 500GB))
    Check 'recycle verdict: no settings yet means about 5% of the drive' ((Get-RecycleVerdict 30GB 'Fixed' $false 0 -1 500GB) -and -not (Get-RecycleVerdict 10GB 'Fixed' $false 0 -1 500GB))
    Check 'Test-RecycleOk refuses UNC paths' ((Test-RecycleOk '\\server\share\a.txt' 1) -and (Test-RecycleOk '\\?\UNC\server\share\a.txt' 1))
    # Recycle 只在删除入口里调用，调用前先问过 Test-RecycleOk；RecycleMany 只处理入口攒下的那一批（入口里同样问过）
    $sr = [regex]::Match($engineText, '(?s)function Invoke-SafeRemove \{.*?\r?\n\}').Value
    $recCalls = [regex]::Matches($src, '\[FsTools\]::Recycle(Many)?\(').Count
    Check ("every Recycle call is in the delete entry, after Test-RecycleOk ({0} calls)" -f $recCalls) ($recCalls -eq 2 -and $sr -match '(?s)Test-RecycleOk \$full \$Bytes.*?recycleBatch\.Add.*?\[FsTools\]::Recycle\(' -and ([regex]::Matches($src, 'recycleBatch\.Add\(')).Count -eq 1)
    if ($win) {
        Check 'Test-RecycleOk: a small file on the system drive can be recycled' (-not (Test-RecycleOk (Join-Path $env:SystemDrive '\x.txt') 1KB))
        # 回收模式下清一个里面有链接的缓存文件夹：链接目标不动，文件进了回收站
        $rt = Join-Path $T 'rec-target'; $rc = Join-Path $T 'rec-cache'
        New-Item -ItemType Directory -Force -Path $rt, (Join-Path $rc 'sub') | Out-Null
        [IO.File]::WriteAllText((Join-Path $rt 'precious.txt'), 'keep'); [IO.File]::WriteAllText((Join-Path $rc 'sub\c.tmp'), 'x')
        New-Item -ItemType Junction -Path (Join-Path $rc 'sub\lnk') -Target $rt | Out-Null
        $script:recycleNow = $true
        try { Remove-Contents @($rc) '' $false } finally { $script:recycleNow = $false }
        Check 'recycle-mode cleanup of a folder holding a junction keeps the junction target' ((Test-Path (Join-Path $rt 'precious.txt')) -and -not (Test-Path -LiteralPath (Join-Path $rc 'sub')))
    } else { Skip 'Test-RecycleOk on the system drive, recycle-mode cleanup with a junction' }
    # ============ 7d. 审计第二轮 ============
    # 路径里的 [ ] 不当通配符（用户名是 a[1] 时不会删到 a1 的东西）
    $b1 = Join-Path $T 'a[1]'; $b2 = Join-Path $T 'a1'
    [void][IO.Directory]::CreateDirectory($b1); [void][IO.Directory]::CreateDirectory($b2)
    [IO.File]::WriteAllText((Join-Path $b1 'f.tmp'), 'x'); [IO.File]::WriteAllText((Join-Path $b2 'f.tmp'), 'y')
    $g1 = @(Get-PathItems (Join-Path $b1 'f.tmp')); $g2 = @(Get-PathItems (Join-Path $b1 '*.tmp'))
    Check ("brackets in a path are not wildcards (literal {0}, with * {1})" -f $g1.Count, $g2.Count) ($g1.Count -eq 1 -and $g2.Count -eq 1 -and $g1[0].FullName -eq (Join-Path $b1 'f.tmp') -and $g2[0].FullName -eq (Join-Path $b1 'f.tmp'))
    Remove-Contents @($b1) '' $false
    Check 'cleaning a folder named a[1] leaves the folder a1 alone' ((Test-Path -LiteralPath (Join-Path $b2 'f.tmp')) -and -not (Test-Path -LiteralPath (Join-Path $b1 'f.tmp')))
    Check 'every wildcard Get-Item in the program goes through Get-PathItems' ($src -notmatch 'Get-Item -Path \$p -Force')
    # TEMP 被改到 D:\Work 这类地方：不当临时文件夹清
    if ([Environment]::ExpandEnvironmentVariables('%TEMP%') -ne '%TEMP%') {
        $savedTemp = $env:TEMP
        # Expand-LibPath 用 ,@() 返回一组路径：直接赋值拿到的就是那一组（外面再包 @() 会多一层）
        $mt = Join-Path $T 'Temp'; New-Item -ItemType Directory -Force -Path $mt | Out-Null; [IO.File]::WriteAllText((Join-Path $mt '.cleanc-temp'), 'x')   # 本工具建的临时文件夹有这个标记
        try { $env:TEMP = Join-Path $T 'Work'; $w = Expand-LibPath '%TEMP%'; $env:TEMP = $mt; $t2 = Expand-LibPath '%TEMP%' } finally { $env:TEMP = $savedTemp }
        Check ("a TEMP that points at a non-temp folder (like D:\Work) is not emptied ({0} / {1})" -f @($w).Count, @($t2).Count) (@($w).Count -eq 0 -and @($t2).Count -eq 1 -and ([string]@($t2)[0]) -like '*Temp')
    } else { "skip TEMP expansion test (no %VAR% expansion here)" }
    # 清理的路径本身是链接：不跟进去
    $lt = Join-Path $T 'lt-target'; New-Item -ItemType Directory -Force -Path $lt | Out-Null; [IO.File]::WriteAllText((Join-Path $lt 'p.txt'), 'keep')
    $ll = Join-Path $T 'lt-link'
    if ($win) { New-Item -ItemType Junction -Path $ll -Target $lt | Out-Null } else { New-Item -ItemType SymbolicLink -Path $ll -Target $lt | Out-Null }
    Remove-Contents @($ll) '' $false; Remove-Contents @($ll) '' $true
    Check 'a cleanup path that is itself a link is skipped and its target keeps its files' ((Test-Path (Join-Path $lt 'p.txt')) -and (Test-Path -LiteralPath $ll))
    # 自己加的清理文件夹：删的时候再查
    Check 'custom cleanup folders are re-checked (Get-DeleteBlock, IsLink) at delete time' ($engineText -match '(?s)if \(\$it\.Custom\) \{\s*\$paths = @\(\$paths \| Where-Object \{ \$why = Get-DeleteBlock \$_; if \(-not \$why -and \(IsLink \$_\)\)')
    # found.000 只认三位编号，而且要确认
    $fl = @($lib | Where-Object { $_.N -like '*found.000*' })[0]
    Check 'chkdsk leftovers match found.??? only and need confirmation' ($fl -and $fl.Confirm -and $fl.Whole -and @($fl.Paths | Where-Object { $_ -match 'found\.\?\?\?$' }).Count -eq 1)
    # 一键清理不碰「需确认」和自己加的
    Check 'one-click cleanup never selects needs-confirmation or custom items' ((Get-OneClickAction @{ G = '需确认（有代价）'; Kind = 'cache'; Def = (T '删除') }) -eq (T '跳过') -and (Get-OneClickAction @{ G = '安全清理'; Kind = 'cache'; Def = (T '删除'); Custom = $true }) -eq (T '跳过') -and [regex]::Match($src, '(?s)function Apply-OneClick.*?\r?\n\}').Value -match 'Get-OneClickAction')
    # 行和后台的项对不上就不动
    Check 'item fingerprints tell two custom folders with the same name apart' ((Get-ItemSig @{ N = 'cache'; Paths = @('D:\a\cache') }) -ne (Get-ItemSig @{ N = 'cache'; Paths = @('E:\b\cache') }))
    Check 'the run worker compares each item fingerprint before acting' ($src -match '\(Get-ItemSig \$it\) -ne \$p\.Sig')
    Check 'editing the cleanup list voids the old scan rows' ($src -match '(?s)function Save-CleanList.*?\$script:rows = \$null')
    # Hyper-V：有检查点的磁盘不压缩
    $vd = Join-Path $T 'vd'; New-Item -ItemType Directory -Force -Path $vd | Out-Null
    foreach ($n in 'base.vhdx', 'base_6B1F2C.avhdx', 'solo.vhdx') { [IO.File]::WriteAllText((Join-Path $vd $n), 'x') }
    Check 'Hyper-V: a disk with a checkpoint is never compacted, a lone disk can be' ((Test-HasCheckpoint (Join-Path $vd 'base.vhdx')) -and (Test-HasCheckpoint (Join-Path $vd 'base_6B1F2C.avhdx')) -and -not (Test-HasCheckpoint (Join-Path $vd 'solo.vhdx')))
    $vres = @{}; Invoke-CompactVdisk (Join-Path $vd 'base.vhdx') 'hyperv' $vres
    Check 'Invoke-CompactVdisk refuses a disk with a checkpoint before calling diskpart' (-not $vres.Ok -and $vres.Out -and $vres.After -eq $vres.Before)
    # 商店版聊天软件的数据在空间地图里也只看不删
    Check 'Microsoft Store chat apps are locked in the space map' ($src -match "'\*WhatsAppDesktop\*', 'MSTeams\*'")
    # 搬回 C 盘后，目标盘上的那份只有是本工具搬过去的才删
    $mr = Join-Path $T 'CDriveMoved'; New-Item -ItemType Directory -Force -Path (Join-Path $mr 'Tencent') | Out-Null
    Set-Setting 'MoveRoots' $mr
    try {
        Check 'move-back deletes the far copy only inside a ClearC move root, never a folder the user linked by hand' ((Test-OurMoveCopy 'C:\Users\me\AppData\Roaming\Tencent' (Join-Path $mr 'Tencent')) -and -not (Test-OurMoveCopy 'C:\Users\me\Documents\xwechat_files' (Join-Path $T 'WeChat')))
    } finally { Set-Setting 'MoveRoots' '' }
    Check 'move-back asks Test-OurMoveCopy before deleting the far copy' ($engineText -match '(?s)if \(-not \(Test-OurMoveCopy \$src \$dst\)\).{0,600}rd /s /q')
    # 相似照片：根重叠、根是链接时，每张照片只列一次（否则勾掉一份就是唯一一份）
    if ($win) {
        $photoCode = [regex]::Match($src, "(?s)\`$script:photoCode = @'\r?\n(.*?)\r?\n'@").Groups[1].Value
        if (-not ('PhotoHash' -as [type])) { Add-Type -TypeDefinition $photoCode -ReferencedAssemblies PresentationCore, WindowsBase, System.Xaml }
        $ph = Join-Path $T 'photos'; New-Item -ItemType Directory -Force -Path (Join-Path $ph 'sub') | Out-Null
        foreach ($n in 'a.jpg', 'sub\b.jpg') { [IO.File]::WriteAllBytes((Join-Path $ph $n), (New-Object byte[] 20000)) }
        $phl = Join-Path $T 'photos-link'; New-Item -ItemType Junction -Path $phl -Target $ph | Out-Null
        $pitems = @([PhotoHash]::Scan([string[]]@($ph, (Join-Path $ph 'sub'), $phl), 1, 0, 1000))
        $ppaths = @($pitems | ForEach-Object { $_.Path })
        Check ("similar photos: overlapping and linked roots list each photo once ({0})" -f $ppaths.Count) ($ppaths.Count -eq 2 -and @($ppaths | Select-Object -Unique).Count -eq 2)
    } else { Skip 'similar photo root dedup' }
    # ============ 7e. 审计第三轮（独立审查找到的） ============
    # 聊天数据：在里面的、把它包在里面的都不能删；重复文件里不管个人文件夹开关
    $savedChat = $script:chatDataPaths
    $script:chatDataPaths = @('C:\Users\me\AppData\Roaming\Tencent', 'D:\CDriveMoved\xwechat_files', 'C:\Users\me\AppData\Local\LINE\Data')
    try {
        Check 'chat data: inside a chat folder is blocked' ([bool](Test-ChatData 'C:\Users\me\AppData\Roaming\Tencent\WeChat\x.db'))
        Check 'chat data: a folder that contains chat data is blocked (deleting Local\LINE)' ([bool](Test-ChatData 'C:\Users\me\AppData\Local\LINE'))
        Check 'chat data: the moved copy on another drive is blocked' ([bool](Test-ChatData 'D:\CDriveMoved\xwechat_files\a.jpg'))
        Check 'chat data: a sibling folder is not' (-not (Test-ChatData 'C:\Users\me\AppData\Roaming\TencentMeeting') -and -not (Test-ChatData 'C:\Users\me\AppData\Local\LINEUpdater'))
        Check 'duplicates: chat data stays blocked even with the personal-folder switch off' ([bool](Get-DupBlock 'C:\Users\me\AppData\Roaming\Tencent\a.jpg' $true))
        Check 'duplicates: an ordinary personal file is left to the switch' (-not (Get-DupBlock 'C:\Users\me\Pictures\a.jpg' $true))
    } finally { $script:chatDataPaths = $savedChat }
    Check 'Get-DeleteBlock ends with the chat-data check' ($engineText -match '(?s)\$chat = Test-ChatData \$full\s*\r?\n\s*if \(\$chat\) \{ return \$chat \}\s*\r?\n\s*return ''''\s*\r?\n\}')
    Check 'duplicate delete, merge and archive workers all ask Get-DupBlock' (([regex]::Matches($src, '\$why = Get-DupBlock \$p\.Path \(Test-Personal \$p\.Path\)')).Count -eq 3)
    Check 'duplicate rows that are blocked can never be ticked' ($src -match '\$r\.CanDelete = -not \$r\.Blocked -and -not \(\$protectOn -and \$r\.Protected\)' -and $src -match '\$r\.CanDelete = -not \$r\.Blocked -and -not \(\$on -and \$r\.Protected\)')
    Check 'duplicates: the kept copy must be unchanged since the scan (delete and merge)' ($src -match 'KeepTicks\.ContainsKey' -and $src -match '\$p\.KeepMtime -and \$ki\.LastWriteTime\.Ticks -ne')
    # 清理：路径经过一个链接（上级被搬走了）就不碰，也不算大小
    $mvT = Join-Path $T 'moved-discord'; New-Item -ItemType Directory -Force -Path (Join-Path $mvT 'Cache') | Out-Null
    [IO.File]::WriteAllText((Join-Path $mvT 'Cache/f_0001'), ('x' * 4000))
    $apd = Join-Path $T 'roaming'; New-Item -ItemType Directory -Force -Path $apd | Out-Null
    $dl = Join-Path $apd 'discord'
    if ($win) { New-Item -ItemType Junction -Path $dl -Target $mvT | Out-Null } else { New-Item -ItemType SymbolicLink -Path $dl -Target $mvT | Out-Null }
    $cachePath = Join-Path $dl 'Cache'
    Check ("a cache path under a moved (linked) folder measures 0 ({0})" -f (Get-Size @($cachePath) '')) ((Get-Size @($cachePath) '') -eq 0)
    Remove-Contents @($cachePath) '' $false
    Check 'cleanup does not follow a moved parent folder: the moved cache is untouched' (Test-Path (Join-Path $mvT 'Cache/f_0001'))
    Check 'the delete preview does not list it either' (@(Get-DeletePreview @(@{ N = 't'; Paths = @($cachePath) }) 100).Count -eq 0)
    # 临时文件夹：只有 Windows 默认的、系统的、本工具建的（有标记）才当临时文件夹清
    $defTemp = Join-Path $env:USERPROFILE (Join-Path 'AppData' (Join-Path 'Local' 'Temp'))
    $userTemp = Join-Path $T 'UserTemp'; New-Item -ItemType Directory -Force -Path $userTemp | Out-Null   # 像用户自己的 D:\Temp：没有标记
    $okDefault = Test-TempOk $defTemp; $okUser = Test-TempOk $userTemp
    [IO.File]::WriteAllText((Join-Path $userTemp '.cleanc-temp'), 'x'); $okMarked = Test-TempOk $userTemp
    Check ("TEMP: the Windows default is cleaned, a D:\Temp of the user is not, a ClearC-made one is ({0}/{1}/{2})" -f $okDefault, $okUser, $okMarked) ($okDefault -and -not $okUser -and $okMarked)
    Check 'moving the temp folder uses a dedicated CleanC-Temp with a marker and refuses an existing non-empty one' ($src -match '\$p = "\$d\\CleanC-Temp"' -and $src -match "Join-Path \`$p '\.cleanc-temp'" -and $src -match '这个文件夹里已经有东西了')
    # cmd 会展开 %名字%：带 % 的路径不交给 cmd
    Check 'paths with % or quotes are never handed to cmd' (-not (Test-CmdPathOk 'C:\x\%USERNAME%') -and -not (Test-CmdPathOk 'C:\x\a"b') -and (Test-CmdPathOk 'C:\x\cache'))
    $rdLines = @($src -split "`r?`n" | Where-Object { $_ -match 'rd /s /q' -and $_ -notmatch '^\s*#' })
    $rdGuarded = @($rdLines | Where-Object { $_ -match 'Test-CmdPathOk|IsDir\) \{ & ' })
    Check ("every rd /s call is guarded against % paths ({0} of {1})" -f $rdGuarded.Count, $rdLines.Count) ($sr -match '(?s)\$isDir -and -not \(Test-CmdPathOk \$Path\).*?rd /s /q' -and ([regex]::Matches($engineText, 'Test-CmdPathOk \$(bak|dst|tmp)')).Count -ge 4)
    # 不用会跟进链接的 Remove-Item -Recurse（界面自测删它自己建的临时文件夹除外）
    $progLines = @(($engineText + "`n" + ($src -replace '(?s)function Invoke-UiTest.*', '')) -split "`r?`n" | Where-Object { $_ -notmatch '^\s*#' -and $_ -match 'Remove-Item\b.*-Recurse' })
    Check ("no Remove-Item -Recurse in program code ({0})" -f ($progLines -join ' | ')) ($progLines.Count -eq 0)
    # 搬家
    Check 'a reused or dropped copy must have zero files that C: lacks (no 5% tolerance any more)' (([regex]::Matches($engineText, 'if \(\$extra -ne 0\) \{')).Count -eq 2 -and $engineText -notmatch 'Max\(20, \$(haveFiles|nf) \* 0\.05\)')
    Check 'robocopy mismatches (exit bit 4) stop the move' ($engineText -match '\(\$rc\.Code -band 4\) -ne 0')
    Check 'move-back refuses when the link on C: no longer points at the recorded copy' ($engineText -match '\$lt = LinkTarget \$src' -and $engineText -match '和记录里的')
    Check 'deleting a leftover copy refuses when another link still uses it' ($engineText -match '(?s)function Invoke-DropCopy.*?Get-MoveRecords.*?IsLink \(\[string\]\$r\.Src\)')
    Check 'repairing a broken link never picks a folder another link is using' ($engineText -match '(?s)\$taken = @\(Get-MovedTargets\).*?别的链接正指着它')
    Check 'the move destination can not be inside a cleanup-list folder or a temp folder' ($src -match '这里不能放搬过去的数据')
    # 中途停了的搬家：找得到
    $hs = Join-Path $T 'halfsrc'; New-Item -ItemType Directory -Force -Path ($hs + '.moved_backup') | Out-Null
    $hr = Join-Path $T 'HalfRoot'; New-Item -ItemType Directory -Force -Path $hr | Out-Null
    Save-MoveMap $hr $hs (Join-Path $hr 'halfsrc')
    Set-Setting 'MoveRoots' $hr
    try { $half = @(Find-HalfMoves) } finally { Set-Setting 'MoveRoots' '' }
    Check ("an interrupted move (folder left as *.moved_backup) is found at startup ({0})" -f $half.Count) (@($half | Where-Object { $_.Bak -like '*halfsrc.moved_backup' }).Count -eq 1 -and $src -match 'Show-HalfMoves; (Show-LooseMoves; )?(Show-BrokenMoves; )?return')
    # Windows.old、Installer、失效快捷方式、回收站说明
    Check 'Windows.old: takeown skips symbolic links, icacls works on links themselves, links are removed again after taking ownership' ($engineText -match 'takeown\.exe" /F \$p /R /A /D Y /SKIPSL' -and $engineText -match 'icacls\.exe" \$p /grant Administrators:F /T /C /L /Q' -and $engineText -match '\$more = Remove-LinksInside \$p')
    Check 'Installer orphans: nothing is judged when the Windows Installer query fails or the registry has no packages' ($engineText -match 'if \(\$null -eq \$viaApi\) \{ return @\(\) \}   # 接口读不了' -and $engineText -match 'if \(\$fromReg -eq 0\) \{ return @\(\) \}' -and ([regex]::Match($src, '(?s)public static List<string> FromInstaller\(\).*?\r?\n    \}').Value) -match '(?s)CreateInstance\(t\); \} catch \{ return null; \}.*?\} catch \{ return null; \}')
    Check 'broken shortcuts: a target inside a moved (linked) folder is not counted' ($engineText -match 'if \(Get-LinkedAncestor \$t\) \{ continue \}')
    Check 'with the Recycle Bin on, the confirm text names the items that are deleted permanently' ($src -match '由系统命令处理，不能放进回收站，会直接删除')
    # 自动清理：文件夹按里面最近一次写入算；SameFile 读不到时当成同一个；subst 盘不当查找位置
    Check 'auto cleanup judges a folder by its newest file' ($engineText -match '\[FsTools\]::NewestWrite\(\$it\.FullName\)')
    if ($win) {
        $nw = Join-Path $T 'nw'; New-Item -ItemType Directory -Force -Path (Join-Path $nw 'old\deep'), (Join-Path $nw 'stale') | Out-Null
        [IO.File]::WriteAllText((Join-Path $nw 'old\deep\fresh.tmp'), 'x'); [IO.File]::WriteAllText((Join-Path $nw 'stale\x.tmp'), 'x')
        $past = (Get-Date).AddDays(-3)
        foreach ($p in @((Join-Path $nw 'stale\x.tmp'), (Join-Path $nw 'stale'), (Join-Path $nw 'old\deep'), (Join-Path $nw 'old'))) { (Get-Item -LiteralPath $p -Force).LastWriteTime = $past }
        $script:autoMinAge = (Get-Date).AddDays(-1)
        try { Remove-Contents @($nw) '' $false } finally { $script:autoMinAge = $null }
        Check 'auto cleanup keeps an old-looking folder with a fresh file deep inside, and removes a fully stale one' ((Test-Path (Join-Path $nw 'old\deep\fresh.tmp')) -and -not (Test-Path (Join-Path $nw 'stale')))
        Check 'SameFile: a path that can not be read counts as the same file (so nothing is deleted)' ([FsTools]::SameFile($f1, (Join-Path $T 'no-such-file.bin')))
        $lk = [IO.File]::Open($f2, 'Open', 'Read', 'None')
        try { Check 'SameFile works on a file another program holds exclusively' (-not [FsTools]::SameFile($f1, $f2)) } finally { $lk.Close() }
        $free = @(68..90 | ForEach-Object { [string][char]$_ + ':' } | Where-Object { -not (Test-Path ($_ + '\')) }) | Select-Object -Last 1
        if ($free) {
            & subst.exe $free $T 2>$null | Out-Null
            try { Check ("subst drive {0} is recognized and not used as a duplicates root" -f $free) ([FsTools]::IsSubst($free) -and -not [FsTools]::IsSubst($env:SystemDrive)) } finally { & subst.exe $free /D 2>$null | Out-Null }
        } else { Skip 'subst drive test (no free letter)' }
        # 带 % 的文件夹：不交给 cmd，同一层同名的别的文件夹也不会被删
        $pc = Join-Path $T 'pct'; [void][IO.Directory]::CreateDirectory((Join-Path $pc '%USERNAME%')); [void][IO.Directory]::CreateDirectory((Join-Path $pc $env:USERNAME))
        [IO.File]::WriteAllText((Join-Path (Join-Path $pc $env:USERNAME) 'keep.txt'), 'keep')
        [void](Invoke-SafeRemove -Item (Get-Item -LiteralPath (Join-Path $pc '%USERNAME%') -Force) -Scope list -How delete)
        Check 'a folder literally named %USERNAME% is not handed to cmd, and the folder named after the user survives' ((Test-Path -LiteralPath (Join-Path $pc '%USERNAME%')) -and (Test-Path -LiteralPath (Join-Path (Join-Path $pc $env:USERNAME) 'keep.txt')))
    } else { Skip 'auto cleanup newest-write, SameFile fail-closed, subst drives, % paths' }
    # OneDrive「仅在线」：OneDrive 自己的文件（云端类型的重解析点）要处理，真正的链接不碰
    Check 'cloud reparse tags (OneDrive) are told apart from links' ([FsTools]::IsCloudTag([Convert]::ToUInt32('9000001A', 16)) -and [FsTools]::IsCloudTag([Convert]::ToUInt32('9000101A', 16)) -and -not [FsTools]::IsCloudTag([Convert]::ToUInt32('A0000003', 16)) -and -not [FsTools]::IsCloudTag([Convert]::ToUInt32('A000000C', 16)))
    if ($win) { Check 'a junction reports the mount-point reparse tag, so OneDrive online-only leaves it alone' (([FsTools]::ReparseTag($dl) -eq [Convert]::ToUInt32('A0000003', 16))) }
    # ============ 7f. 系统健康的「常见问题修复」：不删文件、不结束进程、会改动的先确认、能撤销的先留底 ============
    $fc = Get-FixCatalog
    $cmds = @($fc.Steps.Keys | ForEach-Object { [string]$fc.Steps[$_].Cmd } | Where-Object { $_ })
    $danger = @($cmds | Where-Object { $_ -match '(?i)(^|[\s&|])(del|erase|rd|rmdir|format|diskpart|bcdedit|vssadmin|cipher|taskkill|sdelete|cleanmgr|takeown|icacls)(\s|$)|reg(\.exe)?\s+delete|Remove-Item|Stop-Process|/RU\s+SYSTEM|schtasks' })
    Check ("repair commands never delete, format, kill or schedule anything ({0})" -f ($danger -join ' | ')) ($cmds.Count -ge 15 -and $danger.Count -eq 0)
    $noAsk = @($fc.Steps.Keys | Where-Object { $st = $fc.Steps[$_]; ($st.Kind -eq 'fix' -and -not $st.Harmless -and -not $st.Confirm) -or ($st.Kind -eq 'special' -and $_ -in 'diskpower', 'faststartup' -and -not $st.Confirm) })
    Check ("every repair that changes the system has its own confirmation text ({0})" -f ($noAsk -join ',')) ($noAsk.Count -eq 0)
    $harm = @($fc.Steps.Keys | Where-Object { $fc.Steps[$_].Harmless })
    Check ("only cache-flush style steps skip the confirmation ({0})" -f ($harm -join ',')) (@($harm | Where-Object { $_ -notin 'flushdns', 'icons', 'wsreset', 'audiorestart', 'timesync', 'chkundo' }).Count -eq 0)
    $wu = [string]$fc.Steps['wureset'].Cmd
    $stops = @([regex]::Matches($wu, 'net stop (\w+)') | ForEach-Object { $_.Groups[1].Value }); $starts = @([regex]::Matches($wu, 'net start (\w+)') | ForEach-Object { $_.Groups[1].Value })
    Check 'Windows Update reset renames the caches with a time stamp and restarts every service it stopped' ($wu -match 'ren "[^"]+\\SoftwareDistribution" SoftwareDistribution\.bak-\d{8}-\d{6}' -and $wu -match 'catroot2\.bak-\d{8}-\d{6}' -and $stops.Count -eq 4 -and @($stops | Where-Object { $starts -notcontains $_ }).Count -eq 0)
    $svc = @($cmds | ForEach-Object { [regex]::Matches($_, 'net stop (\w+)') | ForEach-Object { $_.Groups[1].Value } } | Select-Object -Unique)
    Check ("repairs only stop the update and audio services, and start them again ({0})" -f ($svc -join ',')) (@($svc | Where-Object { $_ -notin 'wuauserv', 'cryptSvc', 'bits', 'msiserver', 'audiosrv' }).Count -eq 0)
    Check 'chkdsk /f is only scheduled for the system drive and can be cancelled with chkntfs /x' ([string]$fc.Steps['chkfix'].Cmd -match ('chkdsk ' + [regex]::Escape($(if ($env:SystemDrive) { $env:SystemDrive } else { 'C:' })) + ' /f') -and [string]$fc.Steps['chkundo'].Cmd -match 'chkntfs /x' -and $fc.Steps['chkfix'].Reboot)
    $pf = [regex]::Match($engineText, '(?s)function Set-DiskPowerFix.*?\r?\n\}').Value
    Check 'disk power fix saves the old values before it changes anything, and keeps the first saved copy' ($pf -match "(?s)Set-Setting 'PowerFixUndo'.*?return @\{ Ok = \`$false; Why = \(T '没能记下原来的设置.*?/setacvalueindex \`$g" -and $pf -match "if \(-not \(Get-Setting 'PowerFixUndo' ''\)\) \{ Set-Setting")
    Check 'Fast Startup switch only writes HiberbootEnabled' (([regex]::Match($engineText, '(?s)function Set-FastStartup.*?\r?\n\}').Value) -match "-Name HiberbootEnabled" -and ([regex]::Matches($src, 'HiberbootEnabled -Value')).Count -eq 1)
    $dp = [regex]::Match($engineText, '(?s)function Export-DiagPack.*?\r?\nfunction ').Value
    Check 'diagnostics package never overwrites a file and cleans its temp folder without recursion' ($dp -match 'FileMode\]::CreateNew' -and $dp -match '\[IO\.Directory\]::Delete\(\$tmp, \$false\)' -and $dp -notmatch 'Remove-Item' -and $dp -notmatch 'Recurse')
    $ifs = [regex]::Match($src, '(?s)function Invoke-FixStep.*?\r?\n\}').Value
    Check 'repair runner: the UI self-test never starts a command, and changing steps go through a confirmation sheet first' ($ifs -match '(?s)Show-Sheet -Kind warn.*?if \(\$script:uiTest\) \{ \$script:uiFixRuns\.Add\(\$id\); return \}.*?Start-Process' -and $ifs -match "if \(\`$s\.Kind -eq 'fix' -and -not \`$s\.Harmless -and -not \`$Quiet\)" -and ([regex]::Matches($src, 'Invoke-FixStep \$id -Quiet')).Count -eq 1 -and ([regex]::Matches($src, '-Quiet\b')).Count -le 2)
    # 「按建议处理」：只做能撤销、不删东西的几步，先列出来确认一次；硬盘驱动指南只给步骤，不替你运行 bcdedit
    $planIds = @([regex]::Matches(([regex]::Match($engineText, '(?s)function Get-CrashVerdict.*?\r?\n\}').Value), "(?:Plan|\`$plan) = ([^;\r\n]*)") | ForEach-Object { [regex]::Matches($_.Groups[1].Value, "'(\w+)'") | ForEach-Object { $_.Groups[1].Value } } | Select-Object -Unique)
    Check ("fix-as-suggested plans only use reversible, non-deleting steps ({0})" -f ($planIds -join ',')) ($planIds.Count -ge 4 -and @($planIds | Where-Object { $_ -notin 'diskpower', 'faststartup', 'timesync', 'datetime', 'sfcrepair', 'memtest' }).Count -eq 0)
    $rp = [regex]::Match($src, '(?s)function Invoke-RepairPlan.*?\r?\n\}').Value
    Check 'fix-as-suggested lists the steps and asks once before doing anything' ($rp -match "(?s)Show-Sheet -Kind warn.*?if \(\`$ans -ne \(T '开始处理'\)\) \{ return \}.*?Set-DiskPowerFix" -and $rp -match 'OpLog')
    Check 'the AHCI guide never runs bcdedit itself' ($src -notmatch '(?i)(Start-Process|&\s*"?[^\r\n"]*)[^\r\n]*bcdedit\.exe' -and ([regex]::Match($src, '(?s)function Show-AhciGuide.*?\r?\n\}').Value) -notmatch 'Start-Process')
    # 空间地图点盘卡片、清理页打开文件夹：只看不改
    $op = [regex]::Match($src, '(?s)function Get-CleanOpenPaths.*?function Update-CleanMore').Value
    Check 'opening a cleanup row only opens folders (no delete, move or write)' ($op.Length -gt 500 -and $op -notmatch '(?i)Remove-|Move-Item|rd /s|Delete\(|Set-Content|Out-File|Copy-Item')
    # 一次处理几个（3.4）：批量卸载先确认一次、用每个软件自己的卸载程序一个一个来、不加静默参数；批量移走残留和单个走同一段后台代码
    $bu = [regex]::Match($src, '(?s)function Start-BatchUninstall.*?function Test-UninstChild').Value
    $sq = [regex]::Match($src, '(?s)function Step-UninstQueue.*?\r?\n\}').Value
    Check 'batch uninstall asks once first and only then starts the queue' ($bu -match "(?s)Show-Sheet -Kind warn.*?-ne \(T '卸载'\)\) \{ return \}.*?Step-UninstQueue")
    Check 'batch uninstall opens one uninstaller at a time (waits for it to exit), never silently, and the UI self-test never starts one' ($sq -match '(?s)HasExited.*?if \(\$script:uiTest\) \{ \$script:uiFixRuns\.Add\(''uninstall:'' \+ \$r\.Name\) \}\s*\r?\n\s*elseif \(\$pc\[1\]\) \{ \$q\.Proc = Start-Process' -and ($bu + $sq) -notmatch '(?i)QuietUninstall|/quiet|/qn\b|/silent|/verysilent|-WindowStyle Hidden')
    Check 'batch leftover recycling reuses the leftover worker, which only recycles through the delete entry (leftover checks)' (([regex]::Matches($src, 'Start-Worker \$script:leftDelCode')).Count -eq 2 -and ([regex]::Match($src, "(?s)\`$script:leftDelCode = @'.*?'@").Value) -match 'Invoke-SafeRemove -Path \$x\.Path -Scope leftover -How recycle')
    Check 'batch disable / enable never touches ClearC''s own entries or leftovers' ([regex]::Match($src, '(?s)function Start-BatchToggle.*?\r?\n\}').Value -match "-not \`$_\.Ours -and \`$_\.Kind -ne 'leftover'")
    Check 'the space-map delete list deletes through Start-MapDelete (same checks as a normal delete)' ($src -match '\$ctl\.BtnMarkDelete\.Add_Click\(\{[^\r\n]*Start-MapDelete @\(\$script:mapMarks\.Values\)')
    # ============ 8. 源码锁：改坏了就报 ============
    Check 'recycle bin: SHFileOperation asks when a file is too big instead of nuking it (ALLOWUNDO|NOCONFIRMATION|WANTNUKEWARNING)' (([regex]::Matches($dupCode, '0x40 \| 0x10 \| 0x4000')).Count -ge 2)
    Check 'restore points are never deleted (no vssadmin delete / Win32_ShadowCopy.Delete / Remove-ComputerRestorePoint)' ($src -notmatch '(?i)vssadmin\s+delete|Remove-ComputerRestorePoint|Disable-ComputerRestore|ShadowCopy[^\r\n]*\.Delete\(')
    Check 'no registry cleaner: no Remove-Item on HKLM/HKCU keys' ($src -notmatch ('(?i)Remove-Item\s+(-LiteralPath\s+|-Path\s+)?[' + "'" + '"]HK(LM|CU):'))
    Check 'registry values are only removed for the context-menu block list and the UI test' (([regex]::Matches($src, 'Remove-ItemProperty')).Count -le 2)
    Check 'scheduled tasks run as the current user (InteractiveToken), never SYSTEM' ($src -match 'LogonType>InteractiveToken<' -and $src -notmatch '(?i)/RU\s+SYSTEM|<UserId>S-1-5-18<|NT AUTHORITY\\SYSTEM')
    Check 'processes are only stopped in the chat-app close flow (2 call sites)' (([regex]::Matches($engineText, 'Stop-Process')).Count -eq 2 -and $src -notmatch '(?i)taskkill')
    Check 'no self-deleting scripts or boot-time tasks' ($src -notmatch '(?i)schtasks[^\r\n]*ONSTART' -and $src -notmatch 'RunOnce' -and $src -notmatch '(?i)Remove-Item[^\r\n]*\$PSCommandPath')
    # rd /s 的调用点：删除入口（先看是不是链接）、搬家收尾删备份、搬回来 / 删多余副本（核对过才删）、撤回没搬完的副本。全部调用点见第 14 节
    Check ("rd /s call sites are the known 5 ({0})" -f ([regex]::Matches($src, 'rd /s /q')).Count) (([regex]::Matches($src, 'rd /s /q')).Count -eq 5 -and $sr -match 'if \(\$isLink\) \{ & "\$sys32\\cmd.exe" /c rmdir')
    $mapDel = [regex]::Match($src, "(?s)function Start-MapDelete.*?'@ @\{").Value
    Check 'space map delete goes through the delete entry with the strict checks (Get-DeleteBlock, links, linked parents)' ($mapDel -match 'Invoke-SafeRemove -Path \$p -Scope pick' -and $mapDel -notmatch 'rd /s|Remove-Item|\[FsTools\]::Recycle')
    Check 'moves verify the copy before replacing the original (robocopy/compare step present)' ($engineText -match '(?i)robocopy' -and $engineText -match '(?i)Compare-Copy|Verify-Copy|核对|对不上')
    Check 'every delete path in the UI goes through a confirmation sheet with the risk acknowledgement' (([regex]::Matches($src, '因删除造成的后果由我自己承担')).Count -ge 2)
    Check 'auto cleanup task is registered from exactly one place (the Reminders page switch), never at startup' (([regex]::Matches($src, 'Register-CleanTask \$script:taskClean')).Count -eq 1 -and $src -notmatch 'Enable-AutoTask \$true[^\r\n]*#.*启动')
    # ============ 9. 提权运行时不信任普通权限就能改的东西（3.6 安全评审） ============
    $launcher = [IO.File]::ReadAllText((Join-Path $PSScriptRoot '../build/launcher.cs'))
    Check 'SEC-1 the launcher loads PowerShell only from the system, never from a path in an environment variable' ($launcher -notmatch 'CLEANC_SMA' -and $launcher -notmatch 'LoadFrom\(' -and $launcher -notmatch 'LoadFile\(')
    $reg = [regex]::Match($src, '(?s)function Register-CleanTask.*?\r?\n\}').Value
    $rep = [regex]::Match($src, '(?s)function Repair-AutoTasks.*?\r?\n\}').Value
    Check 'SEC-2 scheduled tasks run the copy in Program Files (only admins can change it), never the exe the user started' ($reg -match 'Install-TaskExe' -and $reg -notmatch '<Command>\$\(\$esc::Escape\(\$exe\)\)' -and $src -match "GetFolderPath\('ProgramFiles'\)" -and $rep -notmatch '\$repoint')
    if ($win) {
        Check 'SEC-2 Program Files is not writable by ordinary users' (-not (Test-UserWritable ([Environment]::GetFolderPath('ProgramFiles'))))
        $pub = Join-Path $T 'pubdir'; New-Item -ItemType Directory -Force -Path $pub | Out-Null
        $acl = Get-Acl -LiteralPath $pub; $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule ((New-Object System.Security.Principal.SecurityIdentifier 'S-1-5-32-545'), 'Modify', 'Allow'))); Set-Acl -LiteralPath $pub -AclObject $acl
        Check 'SEC-2 a folder where Users can write is refused for the task copy' (Test-UserWritable $pub)
    } else { Skip 'SEC-2 folder permission checks' }
    $mv = [regex]::Match($engineText, '(?s)function Invoke-Move\(.*?\r?\n\}').Value
    Check 'SEC-3 every move gives the target the same permissions the source had on C: (not only app moves)' ($mv -match '\$acc = if \(\$it\.Sddl\)' -and $mv -match 'Get-AccessSddl \$src' -and $mv -match 'Set-DirAccess \$dst \$acc' -and $mv -match 'Test-OthersCanRead \$dst')
    if ($win) {
        $priv = Join-Path $T 'acl-src'; $open = Join-Path $T 'acl-open'; New-Item -ItemType Directory -Force -Path $priv, $open | Out-Null
        $me = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
        $sp = New-Object System.Security.AccessControl.DirectorySecurity; $sp.SetSecurityDescriptorSddlForm("D:P(A;OICI;FA;;;$me)(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)"); [IO.Directory]::SetAccessControl($priv, $sp)
        $so = Get-Acl -LiteralPath $open; $so.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule ((New-Object System.Security.Principal.SecurityIdentifier 'S-1-5-32-545'), 'ReadAndExecute', 'ContainerInherit, ObjectInherit', 'None', 'Allow'))); Set-Acl -LiteralPath $open -AclObject $so
        $kid = Join-Path $open 'WeChat Files'; New-Item -ItemType Directory -Force -Path $kid | Out-Null; [IO.File]::WriteAllText((Join-Path $kid 'msg.db'), 'x')
        Check 'SEC-3 a folder that inherits Users read is seen as open to other accounts' ((Test-OthersCanRead $kid) -and -not (Test-OthersCanRead $priv))
        [void](Set-DirAccess $kid (Get-AccessSddl $priv))
        Check 'SEC-3 after copying the permissions, other accounts can no longer open the folder or the files in it' (-not (Test-OthersCanRead $kid) -and -not (Test-OthersCanRead (Join-Path $kid 'msg.db')))
    } else { Skip 'SEC-3 permission behaviour' }
    # ============ 10. 设置文件：写一半不会留下截断的文件；读不出来时不当成「没有排除」去删（3.6 运维评审） ============
    New-Item -ItemType Directory -Force -Path $script:appDir | Out-Null
    $script:settingsBad = $false
    Set-Setting 'Exclude' (Join-Path $T 'keepme'); Set-Setting 'Other' '1'
    Check 'OPS-2 settings are written whole, with nothing left behind' ((Get-Setting 'Exclude' '') -eq (Join-Path $T 'keepme') -and (Get-Setting 'Other' '') -eq '1' -and -not (Test-Path ($script:settingsFile + '.tmp')))
    $lock = [IO.File]::Open($script:settingsFile, 'Open', 'ReadWrite', 'None')
    try {
        $script:settingsBad = $false
        $got = Get-Setting 'Exclude' 'DEFAULT'
        Check 'OPS-2 an unreadable settings file is noticed (not taken as empty)' ($script:settingsBad -and $got -eq 'DEFAULT')
        Set-Setting 'Other' '2'
    } finally { $lock.Close() }
    $script:settingsBad = $false
    Check 'OPS-2 a write while the file cannot be read does not wipe the other settings' ((Get-Setting 'Exclude' '') -eq (Join-Path $T 'keepme'))
    $kd = Join-Path $T 'keepme'; New-Item -ItemType Directory -Force -Path $kd | Out-Null; [IO.File]::WriteAllText((Join-Path $kd 'a.tmp'), 'x')
    $lock = [IO.File]::Open($script:settingsFile, 'Open', 'ReadWrite', 'None')
    try { $script:settingsBad = $false; Remove-Contents2 @((Join-Path $T 'keepme')) '' $false } finally { $lock.Close() }
    Check 'OPS-2 cleanup deletes nothing while the exclusion list cannot be read' (Test-Path (Join-Path $kd 'a.tmp'))
    $script:settingsBad = $false; Set-Setting 'Exclude' ''
    # ============ 11. 同一时间只做一件会改东西的事（3.6 运维评审） ============
    $script:busyHeld = $false
    Check 'OPS-1 the busy lock can be taken and given back' ((Enter-BusyLock) -and $script:busyHeld)
    $other = [powershell]::Create(); $null = $other.AddScript('$m = New-Object System.Threading.Mutex($false, "Local\ClearC-Busy"); $m.WaitOne(0)')
    $theirs = @($other.Invoke())[0]; $other.Dispose()
    Check 'OPS-1 while it is held, another thread (the scheduled cleanup) cannot take it' ($theirs -eq $false)
    Exit-BusyLock
    $other = [powershell]::Create(); $null = $other.AddScript('$m = New-Object System.Threading.Mutex($false, "Local\ClearC-Busy"); $r = $m.WaitOne(0); if ($r) { $m.ReleaseMutex() }; $r')
    $theirs = @($other.Invoke())[0]; $other.Dispose()
    Check 'OPS-1 after it is given back, others can take it' ($theirs -eq $true -and -not $script:busyHeld)
    $ac = [regex]::Match($src, "(?s)if \(\`$script:mode -match '\(\?i\)/autoclean'\) \{.*?\r?\n\}").Value
    Check 'OPS-1 the scheduled cleanup skips its run while the window is changing things' ($ac -match 'Enter-BusyLock' -and $ac.IndexOf('Enter-BusyLock') -lt $ac.IndexOf('Invoke-AutoClean'))
    $sw = [regex]::Match($src, '(?s)function Start-Worker\(.*?\r?\n\}').Value
    Check 'OPS-1 every worker that changes things takes the busy lock first; only one window opens' ($sw -match 'Enter-BusyLock' -and $src -match "Local\\ClearC-UI")
    # ============ 12. 搬家目标不自动选移动硬盘（3.6 体验评审） ============
    $oldSys = $env:SystemDrive; if (-not $env:SystemDrive) { $env:SystemDrive = 'C:' }
    try {
        $dc = @(Get-DestChoices @(@{ Drive = 'D:'; Free = 100; Plug = $false }, @{ Drive = 'E:'; Free = 900; Plug = $true }, @{ Drive = 'F:'; Free = 300; Plug = $false }, @{ Drive = $env:SystemDrive; Free = 999; Plug = $false }))
        Check 'UX-2 move targets: C: is not offered, local disks by free space first, USB disks last' (($dc | ForEach-Object { $_.Drive }) -join ',' -eq 'F:,D:,E:' -and $dc[0].Path -eq 'F:\CDriveMoved')
        Check 'UX-2 only the local disk with the most free space is picked automatically, never a USB disk' ($dc[0].Auto -and -not $dc[1].Auto -and -not $dc[2].Auto -and $dc[2].Plug)
        $dc = @(Get-DestChoices @(@{ Drive = 'E:'; Free = 900; Plug = $true }))
        Check 'UX-2 when the only other disk is a USB disk, nothing is picked automatically' ($dc.Count -eq 1 -and -not $dc[0].Auto)
    } finally { $env:SystemDrive = $oldSys }
    Check 'UX-2 a drive whose bus can not be read is not taken for a USB disk' (-not (Test-PluggableDrive 'Q:'))
    $fd = [regex]::Match($src, '(?s)function Fill-DestChoices\(.*?\r?\n\}').Value
    Check 'UX-2 the move target list uses these choices, and picking a USB disk by hand asks first' ($fd -match 'Get-DestChoices' -and $src -match 'function Confirm-PlugDest' -and ([regex]::Matches($src, 'Confirm-PlugDest ')).Count -ge 3)
    # ============ 13. 重复文件的删除也记进操作日志（3.6 安全评审） ============
    $dw = [regex]::Match($src, "(?s)\`$sync\.Mode = 'dupdel'.*?'@ @\{ Plan").Value
    Check 'SEC-8 every duplicate that is deleted, or fails to delete, is written to the activity log' ($dw -match 'Invoke-SafeRemove -Item \$fi -Scope dup' -and $dw -match '-What \$how' -and $sr -match "(?s)\`$finish = \{.*?OpLog '删除' \`$What \`$Path")
    # ============ 14. 删除只有一个入口（3.6 架构评审） ============
    # 用语法树找出所有会删东西的调用，按所在的函数（或后台代码、事件处理）归类。删用户数据的只能是 Invoke-SafeRemove；
    # 其余每一处都写明为什么可以，数量也锁住。要加一处，先在这里写清楚它删的是什么、为什么安全
    . (Join-Path $PSScriptRoot 'DeleteSites.ps1')
    $allowed = [ordered]@{
        'Invoke-SafeRemove'     = 4   # 唯一的删除入口：Recycle、链接只拆链接（rmdir）、rd /s、删文件
        'Recycle-Flush'         = 1   # 入口攒下的一批交给回收站（每一项进批之前都在入口里查过）
        'Remove-LinksInside'    = 2   # 只拆链接本身（rmdir、不递归的 Directory.Delete），从不删数据
        'Invoke-Move'           = 1   # 搬家：建链接失败时去掉 C 盘上那个位置的空文件夹，再把原目录改回来
        'Remove-MovedOriginal'  = 1   # 搬家核对一致、链接建好以后，删 C 盘上改了名的原目录（rd /s，先拆里面的链接）
        'Resume-Move'           = 3   # 上次没做完的搬家：C 盘那个位置是空文件夹（软件重新建的）时删掉它（不递归，有内容就删不掉）；撤回时只拆链接
        'Clear-MoveStep'        = 1   # 本工具自己的搬家进度记录
        'Invoke-MoveBack'       = 2   # 搬回：去掉链接；核对一致后删目标盘上的旧副本（Test-OurMoveCopy）
        'Invoke-DropCopy'       = 1   # 删没搬完留下的多余副本：副本里有 C 盘没有的文件就不删
        'Undo-MoveBackCopy'     = 1   # 搬回中途失败：删掉刚复制回 C 盘的那份
        'Invoke-FixLink'        = 1   # 修断掉的链接：只拆坏链接
        'Invoke-CompactVdisk'   = 1   # 本工具自己写的 diskpart 脚本
        'Export-DiagPack'       = 3   # 诊断包自己的临时文件和没写完的 zip
        'Install-TaskExe'       = 1   # 定时任务用的副本：核对不一致时删掉刚复制的临时文件
        'Remove-TaskExeIfUnused' = 2  # Program Files\ClearC 里本工具自己的副本
        'Set-Setting'           = 1   # 设置文件的临时文件
        'Test-AppDirWritable'   = 1   # 试写本工具文件夹时写的小文件
        'Prune-OpLog'           = 1   # 一年前的操作日志
        'Update-Growth'         = 2   # 本工具自己的空间快照
        'Register-CleanTask'    = 1   # 注册任务用的临时 XML
        'Invoke-SelfTest'       = 4   # 自检在自己建的临时文件夹里试删
        'Invoke-UiTest'         = 9   # 界面自测删它自己建的临时文件和设置
    }
    $sites = @(Get-DeleteSites $src)
    $byFn = @{}; foreach ($x in $sites) { $fn = ($x.Where -split '/')[-1]; if (-not $byFn.ContainsKey($fn)) { $byFn[$fn] = 0 }; $byFn[$fn]++ }
    $extra = @($byFn.Keys | Where-Object { -not $allowed.Contains($_) -or $byFn[$_] -gt $allowed[$_] } | ForEach-Object { "{0} ({1})" -f $_, $byFn[$_] })
    Check ("ARC-1 nothing deletes files outside the delete entry and the listed own-file / move steps ({0})" -f ($extra -join ', ')) ($sites.Count -gt 20 -and $extra.Count -eq 0)
    Check 'ARC-1 the finder sees deletes inside background code too (the entry is found inside the engine text)' (@($sites | Where-Object { $_.Where -eq '$engine/worker/Invoke-SafeRemove' }).Count -eq 4)
    $uses = @{ 'cleanup list' = [regex]::Match($engineText, '(?s)function Remove-Path\(.*?\r?\n\}').Value; 'duplicates' = $dw; 'space map' = $mapDel
               'app leftovers' = [regex]::Match($src, "(?s)\`$script:leftDelCode = @'.*?'@").Value; 'leftover folder' = [regex]::Match($src, '(?s)\$ctl\.StartList\.AddHandler.*?\}\)').Value
               'Installer orphans and broken shortcuts' = [regex]::Match($engineText, "(?s)Get-InstallerOrphans\)\) \{ \`$r = Invoke-SafeRemove.*?Get-BrokenShortcuts\)\) \{ if \(\(Invoke-SafeRemove").Value; 'Windows.old' = [regex]::Match($engineText, '(?s)function Remove-WindowsOld.*?\r?\n\}').Value }
    $miss = @($uses.Keys | Where-Object { $uses[$_] -notmatch 'Invoke-SafeRemove ' })
    Check ("ARC-1 all six user-facing delete paths go through Invoke-SafeRemove ({0})" -f ($miss -join ', ')) ($miss.Count -eq 0)
    # 入口本身的行为：真的建文件试
    $sd = Join-Path $T 'saferemove'; [void][IO.Directory]::CreateDirectory($sd)
    $f1 = Join-Path $sd 'a.tmp'; [IO.File]::WriteAllText($f1, 'x'); (Get-Item -LiteralPath $f1).Attributes = 'ReadOnly'
    $r = Invoke-SafeRemove -Path $f1 -Scope pick -How delete -Bytes 1 -What 'ARC-1 test'
    $log = (Get-ChildItem -LiteralPath $script:opLogDir -Filter '*.txt' -ErrorAction SilentlyContinue | ForEach-Object { [IO.File]::ReadAllText($_.FullName) }) -join "`n"
    Check 'ARC-1 the entry deletes a read-only file, checks it is gone and writes the activity log' ($r.Ok -and -not (Test-Path -LiteralPath $f1) -and $log -match [regex]::Escape($f1))
    $r = Invoke-SafeRemove -Path '' -How delete
    Check 'ARC-1 an empty path is refused' (-not $r.Ok -and $r.Stage -eq 'block')
    $mv = Join-Path $sd 'CDriveMoved'; [void][IO.Directory]::CreateDirectory($mv); [IO.File]::WriteAllText((Join-Path $mv 'data.db'), 'x')
    $r = Invoke-SafeRemove -Path $mv -Scope pick -How delete -What 'ARC-1 test'
    Check 'ARC-1 moved data (CDriveMoved) is refused and left in place' (-not $r.Ok -and $r.Stage -eq 'block' -and (Test-Path -LiteralPath (Join-Path $mv 'data.db')))
    $f2 = Join-Path $sd 'b.tmp'; [IO.File]::WriteAllText($f2, 'x')
    if (-not $win) {
        $r = Invoke-SafeRemove -Path $f2 -Scope pick -How recycle -What 'ARC-1 test'
        Check 'ARC-1 "move to Recycle Bin" where there is no Recycle Bin deletes nothing' (-not $r.Ok -and $r.Stage -eq 'recycle' -and (Test-Path -LiteralPath $f2))
    }
    $bad = $false; try { [void](Invoke-SafeRemove -Path $f2 -Scope everything -How delete) } catch { $bad = $true }
    Check 'ARC-1 an unknown scope is an error, not a delete' ($bad -and (Test-Path -LiteralPath $f2))
    if ($win) {
        # 文件夹链接：点选的不删；清理列表里的只拆链接，链接指向的数据不动；链接下面的文件不删
        $tgt = Join-Path $sd 'target'; [void][IO.Directory]::CreateDirectory($tgt); [IO.File]::WriteAllText((Join-Path $tgt 'keep.txt'), 'keep')
        $jn = Join-Path $sd 'junction'; & "$env:SystemRoot\System32\cmd.exe" /c mklink /J "$jn" "$tgt" | Out-Null
        $r = Invoke-SafeRemove -Path $jn -Scope pick -How delete
        Check 'ARC-1 a picked folder link is refused' (-not $r.Ok -and (Test-Path -LiteralPath $jn))
        $r = Invoke-SafeRemove -Path (Join-Path $jn 'keep.txt') -Scope pick -How delete
        Check 'ARC-1 a file under a linked folder is refused (it lives somewhere else)' (-not $r.Ok -and (Test-Path -LiteralPath (Join-Path $tgt 'keep.txt')))
        $r = Invoke-SafeRemove -Path $jn -Scope list -How delete
        Check 'ARC-1 a cleanup-list folder link only loses the link, the data it points to stays' ($r.Ok -and -not (Test-Path -LiteralPath $jn) -and (Test-Path -LiteralPath (Join-Path $tgt 'keep.txt')))
        $r = Invoke-SafeRemove -Path (Join-Path $home2 'Desktop\thesis.docx') -Scope list -How delete
        Check 'ARC-1 even the cleanup list can not delete in personal folders' (-not $r.Ok -and (Test-Path -LiteralPath (Join-Path $home2 'Desktop\thesis.docx')))
        $r = Invoke-SafeRemove -Path (Join-Path $home2 'Desktop\thesis.docx') -Scope dup -How delete
        Check 'ARC-1 duplicates in personal folders are refused unless the page switch allows them' (-not $r.Ok -and (Test-Path -LiteralPath (Join-Path $home2 'Desktop\thesis.docx')))
    } else { Skip 'ARC-1 links and personal folders' }
    # ============ 15. 统计文件夹大小：每次统计有自己的结果（3.6 架构评审） ============
    # 以前个数和大小记在 DirStat 的静态字段里，两处同时统计会互相覆盖，搬家「文件个数一个不能少」的核对读的就是它
    $big = Join-Path $T 'count-big'; $small = Join-Path $T 'count-small'
    foreach ($i in 1..60) { $d = Join-Path $big "d$i"; [void][IO.Directory]::CreateDirectory($d); foreach ($j in 1..25) { [IO.File]::WriteAllText((Join-Path $d "f$j.bin"), 'abcd') } }
    [void][IO.Directory]::CreateDirectory($small); foreach ($j in 1..7) { [IO.File]::WriteAllText((Join-Path $small "s$j.bin"), 'xy') }
    $jobs = foreach ($dir in $big, $small, $big, $small) { $ps = [powershell]::Create(); $null = $ps.AddScript('param($d) [DirStat]::Count($d)').AddArgument($dir); @{ PS = $ps; H = $ps.BeginInvoke() } }
    $got = @(foreach ($j in $jobs) { $o = @($j.PS.EndInvoke($j.H))[0]; $j.PS.Dispose(); $o })
    Check 'ARC-3 four counts at the same time each get their own file count and size' ($got.Count -eq 4 -and $got[0].Files -eq 1500 -and $got[0].Bytes -eq 6000 -and $got[1].Files -eq 7 -and $got[1].Bytes -eq 14 -and $got[2].Files -eq 1500 -and $got[3].Files -eq 7 -and -not $got[1].Cancelled)
    Check 'ARC-3 the move checks read their own count, not the shared progress counters' ($engineText -notmatch '\[DirStat\]::(Files|Bytes|Reparse)' -and ([regex]::Matches($engineText, 'DirCount \$')).Count -ge 6)
    # ============ 16. 搬家每一步都有记录，断电后能接着做完或撤回；核对要零差异（3.6 架构评审） ============
    $js = Join-Path $T 'journal-src'
    Check 'ARC-2 a move step is written down and read back' ((Set-MoveStep @{ Kind = 'move'; Src = $js; Dst = 'D:\CDriveMoved\x'; Bak = "$js.moved_backup"; Cp = '/COPY:DAT'; Step = 'renamed' }) -and @(Get-MoveJournal | Where-Object { $_.Src -eq $js -and $_.Step -eq 'renamed' -and $_.Bak -eq "$js.moved_backup" }).Count -eq 1)
    [void](Set-MoveStep @{ Kind = 'move'; Src = $js; Dst = 'D:\CDriveMoved\x'; Bak = "$js.moved_backup"; Cp = '/COPY:DAT'; Step = 'linked' })
    Check 'ARC-2 a later step replaces the earlier one for the same folder' (@(Get-MoveJournal | Where-Object { $_.Src -eq $js }).Count -eq 1 -and @(Get-MoveJournal | Where-Object { $_.Src -eq $js })[0].Step -eq 'linked')
    Clear-MoveStep $js
    Check 'ARC-2 a finished move leaves no record' (@(Get-MoveJournal | Where-Object { $_.Src -eq $js }).Count -eq 0)
    $a = [pscustomobject]@{ Files = 1500; Bytes = 6000; Cancelled = $false }
    Check 'ARC-2 the copy check needs both sides exactly the same (one byte off fails)' ((Test-SameCount $a ([pscustomobject]@{ Files = 1500; Bytes = 6000; Cancelled = $false })) -and -not (Test-SameCount $a ([pscustomobject]@{ Files = 1500; Bytes = 6001; Cancelled = $false })) -and -not (Test-SameCount $a ([pscustomobject]@{ Files = 1501; Bytes = 6000; Cancelled = $false })) -and -not (Test-SameCount $a ([pscustomobject]@{ Files = 1500; Bytes = 6000; Cancelled = $true })))
    $im = [regex]::Match($engineText, '(?s)function Invoke-Move\(.*?\r?\n\}').Value
    $order = @("Step = 'copying'", 'robocopy.exe', "Step = 'renamed'", 'mklink /J', "Step = 'linked'", "Step = 'cleanup'", 'Remove-MovedOriginal', 'Clear-MoveStep')
    $pos = @($order | ForEach-Object { if ($_ -eq 'Clear-MoveStep') { $im.LastIndexOf($_) } else { $im.IndexOf($_) } })
    Check 'ARC-2 the move writes each step before going on to the next (copy, rename, link, delete the old folder)' (@($pos | Where-Object { $_ -lt 0 }).Count -eq 0 -and (($pos | Sort-Object) -join ',') -eq ($pos -join ',') -and $im -match 'Test-SameCount \$sc \$dc')
    $ib = [regex]::Match($engineText, '(?s)function Invoke-MoveBack\(.*?\r?\n\}').Value
    $order = @("Step = 'copying'", 'Test-SameCount', 'rmdir', "Step = 'unlinked'", '[IO.Directory]::Move($tmp, $src)', "Step = 'swapped'", "Step = 'cleanup'", 'Clear-MoveStep')
    $pos = @($order | ForEach-Object { if ($_ -eq 'Clear-MoveStep') { $ib.LastIndexOf($_) } else { $ib.IndexOf($_) } })
    Check 'ARC-2 the move back writes its steps in order too' (@($pos | Where-Object { $_ -lt 0 }).Count -eq 0 -and (($pos | Sort-Object) -join ',') -eq ($pos -join ','))
    Check 'ARC-2 an unfinished move found at startup can be finished or undone' ($src -match "(?s)function Show-HalfMoves.*?Get-MoveJournal.*?'moveresume'" -and $src -match 'Resume-Move \$x \$arg\.How')
    if ($win) {
        $mvRoot = Join-Path $T 'jroot'; [void][IO.Directory]::CreateDirectory($mvRoot)
        $mk = {
            param([string]$name, [string]$step)
            $s = Join-Path $T $name; $d = Join-Path $mvRoot $name; $b = "$s.moved_backup"
            [void][IO.Directory]::CreateDirectory($s); foreach ($i in 1..5) { [IO.File]::WriteAllText((Join-Path $s "f$i.txt"), "data $i") }
            & "$env:SystemRoot\System32\robocopy.exe" $s $d /E /COPY:DAT /NJH /NJS /NFL /NDL /NP | Out-Null
            [IO.Directory]::Move($s, $b)
            if ($step -eq 'linked') { & "$env:SystemRoot\System32\cmd.exe" /c mklink /J "$s" "$d" | Out-Null }
            [void](Set-MoveStep @{ Kind = 'move'; Src = $s; Dst = $d; Bak = $b; Cp = '/COPY:DAT'; Step = $step })
            return @{ S = $s; D = $d; B = $b }
        }
        $sync.Stop = $false
        $x = & $mk 'jr-fin' 'renamed'; $r = Resume-Move (@(Get-MoveJournal | Where-Object { $_.Src -eq $x.S })[0]) 'finish'
        Check 'ARC-2 power cut after the rename: "finish" links the folder, all files reachable, old copy removed, no record left' ($r.Ok -and (IsLink $x.S) -and (Test-Path (Join-Path $x.S 'f5.txt')) -and -not (Test-Path $x.B) -and @(Get-MoveJournal | Where-Object { $_.Src -eq $x.S }).Count -eq 0)
        $x = & $mk 'jr-undo' 'renamed'; $r = Resume-Move (@(Get-MoveJournal | Where-Object { $_.Src -eq $x.S })[0]) 'undo'
        Check 'ARC-2 power cut after the rename: "undo" puts the real folder back' ($r.Ok -and -not (IsLink $x.S) -and ([IO.File]::ReadAllText((Join-Path $x.S 'f3.txt')) -eq 'data 3') -and -not (Test-Path $x.B))
        $x = & $mk 'jr-link' 'linked'; $r = Resume-Move (@(Get-MoveJournal | Where-Object { $_.Src -eq $x.S })[0]) 'undo'
        Check 'ARC-2 power cut after the link: "undo" removes only the link and puts the real folder back (the far copy stays)' ($r.Ok -and -not (IsLink $x.S) -and (Test-Path (Join-Path $x.S 'f1.txt')) -and (Test-Path (Join-Path $x.D 'f1.txt')))
        $x = & $mk 'jr-link2' 'linked'; [IO.File]::WriteAllText((Join-Path $x.B 'late.txt'), 'written after the check')
        $r = Resume-Move (@(Get-MoveJournal | Where-Object { $_.Src -eq $x.S })[0]) 'finish'
        Check 'ARC-2 power cut after the link: "finish" copies the files written late, then removes the old folder' ($r.Ok -and (Test-Path (Join-Path $x.S 'late.txt')) -and -not (Test-Path $x.B))
        $x = & $mk 'jr-new' 'renamed'; [void][IO.Directory]::CreateDirectory($x.S); [IO.File]::WriteAllText((Join-Path $x.S 'new.db'), 'the app started again')
        $r1 = Resume-Move (@(Get-MoveJournal | Where-Object { $_.Src -eq $x.S })[0]) 'finish'; $r2 = Resume-Move (@(Get-MoveJournal | Where-Object { $_.Src -eq $x.S })[0]) 'undo'
        Check 'ARC-2 if the app made a new folder with data in the old place, neither choice touches anything' (-not $r1.Ok -and -not $r2.Ok -and (Test-Path (Join-Path $x.S 'new.db')) -and (Test-Path (Join-Path $x.B 'f1.txt')) -and (Test-Path (Join-Path $x.D 'f1.txt')))
        Clear-MoveStep $x.S
        $x = & $mk 'jr-old' 'copying'
        Check 'ARC-2 a record that says "copying" but finds the folder already renamed is treated as renamed' ((Get-JournalStep (@(Get-MoveJournal | Where-Object { $_.Src -eq $x.S })[0])) -eq 'renamed')
        Clear-MoveStep $x.S
    } else { Skip 'ARC-2 finishing and undoing interrupted moves' }
    # ============ 17. 换掉已有文件（File.Replace）：PowerShell 把 $null 当成空字符串传进去，会直接报错 ============
    & {
        function Get-TaskExePath { Join-Path (Join-Path $T 'pf-clearc') 'ClearC.exe' }
        function Test-UserWritable($d) { $false }
        $self = Join-Path $T 'self.exe'; [IO.File]::WriteAllText($self, 'version 1')
        $old = $env:CLEANC_SELF; $env:CLEANC_SELF = $self
        try {
            $r1 = Install-TaskExe
            [IO.File]::WriteAllText($self, 'version 2')
            $r2 = Install-TaskExe
            Check 'SEC-2 opening a newer version replaces the task copy (it used to fail on File.Replace)' ($r1.Path -and $r2.Path -and -not $r2.Err -and [IO.File]::ReadAllText((Get-TaskExePath)) -eq 'version 2')
        } finally { $env:CLEANC_SELF = $old }
    }
    Check 'no File.Replace call passes $null as the backup name' ($src -notmatch 'File\]::Replace\([^\r\n]*,\s*\$null\)')
    # ============ 18. 一键清理只删不搬；聊天记录单独一张卡片；有搬家记录就能看到搬家管理（3.6 体验评审） ============
    $cat = @(Get-Catalog)
    $oc = @($cat | ForEach-Object { @{ It = $_; A = (Get-OneClickAction $_) } })
    Check 'UX-3 one-click never moves anything (chat records included)' (@($oc | Where-Object { $_.A -eq (T '搬到其他盘') }).Count -eq 0 -and @($oc | Where-Object { $_.It.Kind -eq 'move' -and $_.A -ne (T '跳过') }).Count -eq 0)
    Check 'UX-3 one-click still deletes the safe caches (so the rule is not "skip everything")' (@($oc | Where-Object { $_.A -eq (T '删除') }).Count -ge 10)
    $br = [regex]::Match($src, '(?s)function Build-Rows\(.*?\r?\n\}').Value
    Check 'UX-3 the cleanup page shows a separate chat-records card with its own move button' ($br -match 'Update-ChatCard' -and $src -match 'x:Name="ChatCard"' -and $src -match '(?s)\$ctl\.BtnChatMove\.Add_Click\(\{.*?Invoke-RunSelected .*?-OnlyMove')
    Check 'UX-3 the move manager is listed in every mode once something has been moved, and broken links are reported at startup' ([regex]::Match($src, '(?s)function Apply-Display.*?\r?\n\}').Value -match '\$script:hasMoves' -and $src -match 'Show-HalfMoves; Show-LooseMoves; Show-BrokenMoves; return' -and $src -match "(?s)function Show-BrokenMoves.*?State -eq 'broken'")
    # ============ 19. 系统文件夹从系统接口取，不信环境变量（3.6 安全评审） ============
    $top = $src.Substring(0, $src.IndexOf('$rowCode = @"'))
    $first = $src.IndexOf('$env:SystemRoot'); $fix = $src.IndexOf('Use-SystemPaths')
    Check 'SEC-5 the system folder comes from the Windows API before anything uses $env:SystemRoot (also in the engine for background work)' ($fix -gt 0 -and $fix -lt $first -and $top -match "GetFolderPath\('Windows'\)" -and $engineText -match '(?m)^Use-SystemPaths' -and $engineText -match '\$sys32 = \[Environment\]::SystemDirectory')
    if ($win) {
        $keepRoot = $env:SystemRoot; $keepDrive = $env:SystemDrive
        try {
            $env:SystemRoot = 'C:\Users\Public\FakeWindows'; $env:SystemDrive = 'Q:'
            Use-SystemPaths
            Check 'SEC-5 a changed SystemRoot / SystemDrive in the environment is replaced with the real ones' ($env:SystemRoot -eq [Environment]::GetFolderPath('Windows') -and $env:SystemDrive -eq ([Environment]::GetFolderPath('Windows')).Substring(0, 2))
        } finally { $env:SystemRoot = $keepRoot; $env:SystemDrive = $keepDrive }
    } else { Skip 'SEC-5 replacing a changed SystemRoot' }
    # ============ 20. 网页、记事本、报告都经资源管理器打开，不以管理员身份运行（3.6 安全评审） ============
    $oa = [regex]::Match($engineText, '(?s)function Open-AsUser\(.*?\r?\n\}').Value
    Check 'SEC-6 links, logs and reports open through Explorer (as the signed-in user), never as administrator' ($oa -match 'explorer\.exe' -and $src -notmatch '(?i)notepad\.exe' -and $src -notmatch "Start-Process (-FilePath )?(\`$url|\`$file|\`$s\.Uri|\`$dlg\.FileName|'ms-settings|'https?:)" -and ([regex]::Matches($src, 'Open-AsUser ')).Count -ge 8)
    # ============ 21. 存密码、证书、密钥的文件夹：这台电脑上所有账户的都不删（3.6 安全评审） ============
    $db = [regex]::Match($engineText, '(?s)function Get-DeleteBlock\(.*?\r?\n\}').Value
    Check 'SEC-7 the key and certificate folders are blocked for every account, not only the current one' ($db -match 'AppData\\\\\(Roaming\|Local\|LocalLow\)\\\\Microsoft\\\\\(Protect\|Credentials\|Crypto\|SystemCertificates\|Vault')
    if ($win) {
        $ub = Split-Path $env:USERPROFILE -Parent
        $kp = @('Other\AppData\Roaming\Microsoft\Protect\S-1-5-21-1\key', 'Other\AppData\Local\Microsoft\Credentials\abc', 'Other\AppData\Roaming\Microsoft\SystemCertificates\My', 'Other\AppData\Local\Microsoft\Vault', 'Other\AppData\Roaming\Microsoft\Crypto\RSA')
        $open = @($kp | Where-Object { -not (Get-DeleteBlock (Join-Path $ub $_)) })
        Check ("SEC-7 another account's key folders can not be deleted ({0})" -f ($open -join ', ')) ($open.Count -eq 0 -and -not (Get-DeleteBlock (Join-Path $ub 'Other\AppData\Local\Temp\x.tmp')))
    } else { Skip 'SEC-7 key folders of other accounts' }
    # ============ 22. C 盘加密、目标盘没加密：搬家前写明（3.6 安全评审） ============
    Check 'SEC-4 moving from an encrypted C: to an unencrypted drive is spelled out before the move' ([bool](Get-EncryptionWarning 'D:\CDriveMoved' $true $false))
    Check 'SEC-4 no warning when both are encrypted, C: is not, or it can not be told' (-not (Get-EncryptionWarning 'D:\x' $true $true) -and -not (Get-EncryptionWarning 'D:\x' $false $false) -and -not (Get-EncryptionWarning 'D:\x' $true 'unknown'))
    Check 'SEC-4 not being able to read the encryption state is not an error' ($null -eq (Get-DriveEncrypted 'Q:') -or (Get-DriveEncrypted 'Q:') -eq $false)
    $rs = [regex]::Match($src, '(?s)function Invoke-RunSelected\(.*?\r?\n\}').Value
    Check 'SEC-4 the cleanup page, the move manager and app moves all add the warning to their confirmation' ($rs -match 'Get-EncryptionWarning \$dest' -and ([regex]::Matches($src, 'Get-EncryptionWarning \$')).Count -ge 3)
    # ============ 23. C 盘满了、自己的记录写不进去时要说（3.6 运维评审） ============
    $keepLog = $script:opLogDir
    try {
        $blocker = Join-Path $T 'not-a-folder'; [IO.File]::WriteAllText($blocker, 'x')
        $script:opLogDir = Join-Path $blocker 'log'; $script:opLogFailed = 0; $sync.OpLogFail = $null
        OpLog '删除' 'OPS-3 test' 'x' ''
        Check 'OPS-3 an activity-log line that can not be written is counted and reported, not silently dropped' ($script:opLogFailed -eq 1 -and $sync.OpLogFail)
        Check 'OPS-3 the app folder is checked for writing at startup' (-not (Test-AppDirWritable (Join-Path $blocker 'app')) -and (Test-AppDirWritable (Join-Path $T 'appdir-ok')))
    } finally { $script:opLogDir = $keepLog; $script:opLogFailed = 0; $sync.OpLogFail = $null }
    Check 'OPS-3 the window tells the user when the log or its own files could not be written' ($src -match '(?s)function Show-WriteTrouble.*?OpLogFail' -and ([regex]::Matches($src, 'Show-WriteTrouble')).Count -ge 3)
    # ============ 24. 删除、搬家期间不让电脑睡着；用电池搬大文件夹先提醒（3.6 运维评审） ============
    Check 'OPS-4 on battery, moving a big folder or a low battery adds a note to the confirmation' ([bool](Get-PowerNote 10GB @{ Battery = $true; Percent = 0.8 }) -and [bool](Get-PowerNote 100MB @{ Battery = $true; Percent = 0.2 }))
    Check 'OPS-4 no note on mains power, or for a small move with enough battery' (-not (Get-PowerNote 50GB @{ Battery = $false; Percent = 0.1 }) -and -not (Get-PowerNote 100MB @{ Battery = $true; Percent = 0.8 }))
    $sw = [regex]::Match($src, '(?s)function Start-Worker\(.*?\r?\n\}').Value
    $ac = [regex]::Match($src, "(?s)if \(\`$script:mode -match '\(\?i\)/autoclean'\) \{.*?\r?\n\}").Value
    Check 'OPS-4 the PC is kept awake while something is being changed, and allowed to sleep again afterwards' ($sw -match '\[FsTools\]::KeepAwake\(\$true\)' -and $src -match 'Exit-BusyLock; \[void\]\[FsTools\]::KeepAwake\(\$false\)' -and $ac -match 'KeepAwake\(\$true\)' -and $dupCode -match 'SetThreadExecutionState')
    Check 'OPS-4 the cleanup page, the move manager and app moves add the battery note' (([regex]::Matches($src, 'Get-PowerNote [$(]')).Count -ge 3)
    # ============ 25. 用另一个管理员账户的密码打开时说清楚（3.6 运维评审） ============
    Check 'OPS-5 running as another administrator than the one at the desktop is spelled out' ([bool](Get-AccountMismatch 'PC\admin' 'PC\leon') -and -not (Get-AccountMismatch 'PC\Leon' 'pc\leon') -and -not (Get-AccountMismatch 'PC\leon' ''))
    Check 'OPS-5 the check runs when the window opens' ($src -match '(?s)function Show-AccountMismatch.*?Get-DesktopUser' -and $src -match 'Show-AccountMismatch; Show-WriteTrouble -Startup')
} } finally {
    $env:USERPROFILE = $savedProfile
    Remove-Item -LiteralPath $T -Recurse -Force -ErrorAction SilentlyContinue
}
""
if ($fails) { "$fails safety test(s) failed" } else { 'all safety tests passed' }
exit $fails
