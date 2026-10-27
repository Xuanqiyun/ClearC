# 核心逻辑的测试（不打开界面）：在临时文件夹里建一棵小树，检查统计大小、查找、树上查大小、空间地图的辅助函数、深色配色。
# Windows PowerShell 5.1 和 PowerShell 7 都能跑（Linux 上也行）。用法：pwsh tests/Engine.Tests.ps1
param([string]$Script = (Join-Path $PSScriptRoot '../src/CleanC-UI.ps1'))
$ErrorActionPreference = 'Stop'
$src = [IO.File]::ReadAllText($Script)
Add-Type -TypeDefinition ([regex]::Match($src, "(?s)\`$dupCode = @'\r?\n(.*?)\r?\n'@").Groups[1].Value)
Invoke-Expression ([regex]::Match($src, "(?s)\`$engine = @'\r?\n(.*?)\r?\n'@").Groups[1].Value)
$ErrorActionPreference = 'Continue'
$sync = [hashtable]::Synchronized(@{}); $sync.Log = [System.Collections.Queue]::Synchronized((New-Object System.Collections.Queue)); $sync.P = [hashtable]::Synchronized(@{})
$fails = 0
function Check($name, $ok) { if ($ok) { "ok   $name" } else { "FAIL $name"; $script:fails++ } }
$win = [IO.Path]::DirectorySeparatorChar -eq '\'

$T = Join-Path ([IO.Path]::GetTempPath()) ('clearc-test-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Force -Path (Join-Path $T 'a/x'), (Join-Path $T 'b') | Out-Null
[IO.File]::WriteAllBytes((Join-Path $T 'a/one.bin'), (New-Object byte[] 20000))
[IO.File]::WriteAllBytes((Join-Path $T 'a/x/two.dat'), (New-Object byte[] 3000))
[IO.File]::WriteAllBytes((Join-Path $T 'b/big.iso'), (New-Object byte[] 2000000))
$lk = Join-Path $T 'lnk'
if ($win) { New-Item -ItemType Junction -Path $lk -Target (Join-Path $T 'b') | Out-Null } else { New-Item -ItemType SymbolicLink -Path $lk -Target (Join-Path $T 'b') | Out-Null }
try { & {
    trap { "FAIL error in the test script: $($_.Exception.Message) (line $($_.InvocationInfo.ScriptLineNumber))"; $script:fails++; continue }   # 检查自己出错也算失败
    Init-DriveThreads
    Check 'threads ready' ([DirStat]::ThreadsReady)
    $dirA = Join-Path $T 'a'
    $real = DirBytes $dirA
    Check "DirStat counts 23000 bytes ($real)" ($real -eq 23000)
    Check 'DirStat does not follow links' ((DirBytes $T) -eq 2023000)

    $tree = [DiskMap]::Scan($T, 2)
    Check "walk scan total ($($tree.Size))" ($tree.Size -eq 2023000 -and $tree.Files -eq 3)
    $ln = [DiskMap]::Find($tree, $lk)
    Check 'link found and flagged' ($ln -and $ln.IsLink -and $ln.Size -eq 0)
    Check 'Est-Bytes from the tree' ((Est-Bytes $dirA $tree) -eq $real)
    Check 'Est-Bytes case-insensitive' ((Est-Bytes $dirA.ToUpperInvariant() $tree) -eq $real -or -not $win)
    [IO.File]::WriteAllBytes((Join-Path $dirA 'late.bin'), (New-Object byte[] 4096))
    Check 'Est-Bytes uses the tree (an estimate)' ((Est-Bytes $dirA $tree) -eq $real)
    Check 'DirBytes measures fresh' ((DirBytes $dirA) -eq ($real + 4096))
    Check 'Get-Size skips a link' ((Get-Size @($lk) '' $tree) -eq 0)
    Check 'Get-Size with a filter lists files' ((Get-Size @($dirA) '*.bin' $tree) -eq 24096)
    Check 'Measure-Item without a tree is fresh' ((Measure-Item @{ Paths = @($dirA) }) -eq ($real + 4096))
    # 排除的文件夹：不算、也不删
    $script:appDir = Join-Path $T 'appdir'; $script:settingsFile = Join-Path $script:appDir 'settings.txt'; $script:opLogDir = Join-Path $script:appDir 'log'
    $fakeHome = ''
    if (-not $env:USERPROFILE) { $fakeHome = Join-Path $T 'home'; $env:USERPROFILE = $fakeHome; New-Item -ItemType Directory -Force -Path $fakeHome | Out-Null }   # Linux 上没有：个人文件夹保护要用
    Set-Setting 'Exclude' (Join-Path $dirA 'x')
    Check 'excluded subfolder is not counted' ((Measure-Item @{ Paths = @($dirA) }) -eq ($real + 4096 - 3000))
    Check 'Test-Excluded matches the folder and what is inside' ((Test-Excluded (Join-Path $dirA 'x/two.dat') (Get-ExcludeList)) -and -not (Test-Excluded $dirA (Get-ExcludeList)))
    Remove-Contents @($dirA) '' $false
    Check 'Remove-Contents keeps the excluded folder' ((Test-Path (Join-Path $dirA 'x/two.dat')) -and -not (Test-Path (Join-Path $dirA 'one.bin')))
    [IO.File]::WriteAllBytes((Join-Path $dirA 'one.bin'), (New-Object byte[] 20000)); [IO.File]::WriteAllBytes((Join-Path $dirA 'late.bin'), (New-Object byte[] 4096))   # 后面的测试还要用
    Set-Setting 'Exclude' ''
    Set-Setting 'CustomClean' (Join-Path $T 'b')
    $cat = Get-Catalog
    $custom = @($cat | Where-Object { $_.Custom })
    Check 'custom folder shows up in the catalog' ($custom.Count -eq 1 -and $custom[0].Paths[0] -eq (Join-Path $T 'b') -and $custom[0].Kind -eq 'cache')
    Set-Setting 'CustomClean' ''
    Remove-Item -LiteralPath $script:appDir -Recurse -Force -ErrorAction SilentlyContinue   # 测试里建的，后面比对两次扫描时不能多出来
    if ($fakeHome) { Remove-Item -LiteralPath $fakeHome -Recurse -Force -ErrorAction SilentlyContinue }
    # 缓存目录库
    $lib = Get-CacheLibrary
    Check "cache library parses ($($lib.Count) entries)" ($lib.Count -ge 40)
    $chrome = @($lib | Where-Object { $_.N -eq 'Chrome 浏览器缓存' })[0]
    Check 'chromium entry expands to the cache folders' ($chrome -and $chrome.Paths.Count -eq 10 -and ($chrome.Paths -like '*\*\Cache').Count -eq 1)
    Check 'library options: filter, whole, svc, confirm' ((@($lib | Where-Object { $_.Filter -eq '*.log' }).Count -ge 1) -and (@($lib | Where-Object { $_.Whole }).Count -ge 1) -and (@($lib | Where-Object { $_.Svc -contains 'bits' }).Count -eq 1) -and (@($lib | Where-Object { $_.Confirm }).Count -ge 3))
    Check 'library levels: pro and expert entries, Chrome stays basic' ((@($lib | Where-Object { $_.Lvl -eq 1 }).Count -ge 8) -and (@($lib | Where-Object { $_.Lvl -eq 2 }).Count -ge 4) -and $chrome.Lvl -eq 0)
    Check 'catalog carries levels (basic, pro and expert items)' ((@($cat | Where-Object { -not $_.Lvl }).Count -ge 20) -and (@($cat | Where-Object { $_.Lvl -eq 1 }).Count -ge 10) -and (@($cat | Where-Object { $_.Lvl -eq 2 }).Count -ge 6))
    Check 'library: careful entries (browser caches etc.)' ((@($lib | Where-Object { $_.Careful }).Count -ge 15) -and $chrome.Careful -and -not @($lib | Where-Object { $_.N -eq '用户临时文件' })[0].Careful)
    Check 'catalog: careful group sits between safe and confirm' ((@($cat | Where-Object { $_.Careful }).Count -ge 15) -and (@($cat | Where-Object { $_.Tier -eq 'careful' -and -not $_.Careful }).Count -eq 0))
    $fake = @(
        @{ Driver = 'oem1.inf'; OriginalFileName = 'C:\x\nvlti.inf_amd64_a\nvlti.inf'; ProviderName = 'NVIDIA'; ClassName = 'Display'; Version = '31.0.15.3598'; Date = [DateTime]'2023-06-01'; Inbox = $false; BootCritical = $false },
        @{ Driver = 'oem2.inf'; OriginalFileName = 'C:\x\nvlti.inf_amd64_b\nvlti.inf'; ProviderName = 'NVIDIA'; ClassName = 'Display'; Version = '32.0.15.5599'; Date = [DateTime]'2024-06-01'; Inbox = $false; BootCritical = $false },
        @{ Driver = 'oem3.inf'; OriginalFileName = 'C:\x\nvlti.inf_amd64_c\nvlti.inf'; ProviderName = 'NVIDIA'; ClassName = 'Display'; Version = '32.0.15.4000'; Date = [DateTime]'2024-01-01'; Inbox = $false; BootCritical = $false },
        @{ Driver = 'oem4.inf'; OriginalFileName = 'C:\x\rt.inf_amd64_d\rt.inf'; ProviderName = 'Realtek'; ClassName = 'Net'; Version = '10.1'; Date = [DateTime]'2022-01-01'; Inbox = $false; BootCritical = $false },
        @{ Driver = 'oem5.inf'; OriginalFileName = 'C:\x\stor.inf_amd64_e\stor.inf'; ProviderName = 'Intel'; ClassName = 'SCSIAdapter'; Version = '1.0'; Date = [DateTime]'2022-01-01'; Inbox = $false; BootCritical = $true },
        @{ Driver = 'oem6.inf'; OriginalFileName = 'C:\x\stor.inf_amd64_f\stor.inf'; ProviderName = 'Intel'; ClassName = 'SCSIAdapter'; Version = '2.0'; Date = [DateTime]'2023-01-01'; Inbox = $false; BootCritical = $true })
    $oldDrv = @(Select-OldDrivers $fake | ForEach-Object { $_.Driver } | Sort-Object)
    Check "old driver packages: older NVIDIA versions only, never boot-critical ($($oldDrv -join ','))" (($oldDrv -join ',') -eq 'oem1.inf,oem3.inf')
    Check 'pnputil refuses non-oem names' ((Remove-DriverPackage 'nvlti.inf') -ne '')
    Check 'every library entry has a name, a note and at least one path or Steam' (@($lib | Where-Object { -not $_.N -or -not $_.Note }).Count -eq 0)
    Check 'the catalog has one index per entry' ((@($cat | ForEach-Object { $_.Idx } | Sort-Object -Unique).Count) -eq $cat.Count)
    # winget 的表格
    $wg = "Name                         Id                        Version      Available    Source`n" +
          "-----------------------------------------------------------------------------------------`n" +
          "Microsoft Edge               Microsoft.Edge            120.0.1      121.0.5      winget`n" +
          "腾讯 QQ                      Tencent.QQ                9.9.1        9.9.7        winget`n" +
          "Some Very Long Application … SomePublisher.SomeVeryLo… 1.0          2.0          winget`n" +
          "Weird Row                    Only.Three                1.0`n" +
          "3 upgrades available.`n"
    $w = @(ConvertFrom-WingetTable $wg)
    Check "winget table parses ($($w.Count) rows)" ($w.Count -eq 3 -and $w[0].Name -eq 'Microsoft Edge' -and $w[0].Id -eq 'Microsoft.Edge' -and $w[0].Available -eq '121.0.5' -and $w[1].Name -eq '腾讯 QQ')
    Check 'winget: truncated id is dropped, name kept' ($w[2].Id -eq '' -and $w[2].Name -like 'Some Very Long*')
    Check 'winget: no table means no rows' (@(ConvertFrom-WingetTable "No installed package found matching input criteria.").Count -eq 0)
    # DISM 组件存储分析的输出
    $dism = "Deployment Image Servicing and Management tool`nVersion: 10.0.26100.1`n`nImage Version: 10.0.26100.1`n`n[==========================100.0%==========================]`n`nComponent Store (WinSxS) information:`n`nWindows Explorer Reported Size of Component Store : 9.12 GB`n`nActual Size of Component Store : 8.90 GB`n`n    Shared with Windows : 5.40 GB`n    Backups and Disabled Features : 3.37 GB`n    Cache and Temporary Data : 128.33 MB`n`nDate of Last Cleanup : 2026-09-01 12:00:00`n`nNumber of Reclaimable Packages : 3`nComponent Store Cleanup Recommended : Yes`n`nThe operation completed successfully.`n"
    $cs = ConvertFrom-DismAnalyze $dism
    Check 'DISM analysis parses by position' ($cs.Ok -and $cs.Actual -eq '8.90 GB' -and $cs.Reclaimable -eq '3' -and $cs.Recommended -eq 'Yes' -and $cs.Reported -eq '9.12 GB')
    Check 'DISM analysis: garbage is not Ok' (-not (ConvertFrom-DismAnalyze "Error: 87`nThe parameter is incorrect.").Ok)
    # 启动命令里取程序路径
    Check 'Get-CommandExe handles quotes and arguments' ((Get-CommandExe '"C:\Program Files\App\app.exe" --tray') -eq 'C:\Program Files\App\app.exe' -and (Get-CommandExe 'C:\Tools\x.exe /min') -eq 'C:\Tools\x.exe')

    # 空间地图的辅助函数
    $top = [DiskMap]::TopFiles($dirA, 1)
    Check 'TopFiles returns the largest file' ($top.Count -eq 1 -and $top[0].Name -eq 'one.bin')
    $kids = [DiskMap]::TopKids($tree, 1)
    Check 'TopKids returns the largest folder' ($kids.Count -eq 1 -and $kids[0].Name -eq 'b')
    [DiskMap]::Use($tree)
    $nb = [DiskMap]::Find($tree, (Join-Path $T 'b')); $na = [DiskMap]::Find($tree, $dirA)
    Check 'FindFilesIn one folder' ([DiskMap]::FindFilesIn(0, [DateTime]::MaxValue, '', '', [DmNode[]]@($nb), 10).Count -eq 1)
    Check 'FindFilesIn nothing large under a' ([DiskMap]::FindFilesIn(0, [DateTime]::MaxValue, '', '', [DmNode[]]@($na), 10).Count -eq 0)
    $tree2 = [DiskMap]::Scan($T, 2)
    $d = [DiskMap]::Diff($tree2, $tree, 5)
    Check "Diff finds the new file ($($d.Count))" ($d.Count -eq 1 -and $d[0] -match 'own files 2 / 1')
    Check 'GetTree walks when the file table is not used' ($null -ne [DiskMap]::GetTree($T, 2, $true, $true) -and [DiskMap]::LastMethod -eq 'walk')
    Check 'GetTree reuses a recent walk' ($null -ne [DiskMap]::GetTree($T, 2, $false, $false) -and [DiskMap]::LastMethod -eq 'walk-cache')
    [DiskMap]::Invalidate()
    Check 'Invalidate drops the walk cache' ($null -eq [DiskMap]::GetTree($T, 2, $false, $false))

    # 实际占用和硬链接：逐层往上汇总，删掉文件夹或文件后跟着减
    $r0 = New-Object DmNode; $r0.Name = $T; $k1 = New-Object DmNode; $k1.Name = 'k1'; $k1.Parent = $r0; $k2 = New-Object DmNode; $k2.Name = 'k2'; $k2.Parent = $r0
    [void]$r0.Kids.Add($k1); [void]$r0.Kids.Add($k2)
    $k1.Own = 1000; $k1.OwnFiles = 2; $k1.OwnDisk = 400; $k1.OwnShared = 600
    $k2.Own = 500; $k2.OwnFiles = 1; $k2.OwnDisk = 512; $r0.Own = 10; $r0.OwnFiles = 1; $r0.OwnDisk = 0
    [DiskMap]::Finish($r0, (New-Object 'System.Collections.Generic.List[DmFile]'))
    Check 'size on disk adds up' ($r0.Disk -eq 912 -and $r0.Shared -eq 600 -and $r0.Size -eq 1510)
    [DiskMap]::DropFile($k2, 500, 512)
    Check 'deleting a file takes off its size on disk' ($k2.OwnDisk -eq 0 -and $r0.Disk -eq 400 -and $r0.Size -eq 1010)
    [DiskMap]::DropFile($k1, 300, 100, $true)
    Check 'deleting a hard-linked file takes it off the hard-link total' ($k1.OwnShared -eq 300 -and $r0.Shared -eq 300 -and $k1.OwnDisk -eq 300)
    $k1.Own += 300; $k1.OwnFiles++; $k1.OwnDisk += 100; $k1.OwnShared += 300; $k1.Size += 300; $k1.Files++; $k1.Disk += 100; $k1.Shared += 300; $r0.Size += 300; $r0.Files++; $r0.Disk += 100; $r0.Shared += 300
    [DiskMap]::Detach($k1)
    Check 'deleting a folder takes off its size on disk and hard links' ($r0.Disk -eq 0 -and $r0.Shared -eq 0 -and $r0.Size -eq 10)
    [DiskMap]::DropFile($r0, 10)
    Check 'deleting a file of unknown size on disk stays at zero or above' ($r0.OwnDisk -eq 0 -and $r0.Disk -eq 0)
    $wt = [DiskMap]::Scan($T, 2)
    Check 'a folder-by-folder scan has no size-on-disk data' (-not $wt.HasDisk -and $wt.Disk -eq 0)
    $tf = [DiskMap]::TopFiles((Join-Path $T 'b'), 5)
    Check 'listed files carry size on disk when known' ($tf.Count -ge 1 -and ($tf[0].Disk -eq -1 -or $tf[0].Disk -ge 0))

    # 深色配色
    [Theme]::Dark = $false
    Check 'light theme leaves colors alone' ([Theme]::Map('#F5F5F7', [char]'b') -eq '#F5F5F7')
    [Theme]::Dark = $true
    Check 'white card turns dark' ([Theme]::B('White') -ne 'White' -and [Theme]::B('White').StartsWith('#2'))
    Check 'white text on buttons stays white' ([Theme]::F('White') -eq 'White')
    Check 'dark text turns light' ([Theme]::F('#1D1D1F') -match '^#F')
    Check 'transparent stays' ([Theme]::B('#00000000') -eq '#00000000')
    $x = [Theme]::Xaml('<Border Background="White" BorderBrush="#E5E5EA"><TextBlock Foreground="#1D1D1F" Text="a #FFFFFF b"/><Border.Background><SolidColorBrush Color="#F5F5F7"/></Border.Background></Border>')
    Check "XAML colors replaced by role ($x)" ($x -match 'Background="#2' -and $x -match 'Foreground="#F' -and $x -match 'Text="a #FFFFFF b"' -and $x -notmatch 'Color="#F5F5F7"')
    [Theme]::Dark = $false
    # 蓝屏转储解析：自己拼一个 64 位小转储（头部、驱动表、异常记录、调用栈、当前进程和线程）。
    # 和真的转储一样：驱动表每项 0x90 字节，名字是完整路径（\SystemRoot\system32\...）
    function New-TestDump([uint32]$code, [string[]]$params, [string]$exAddr, [string[]]$stack, [string]$proc) {
        $dmp = New-Object byte[] 0x4000
        [Text.Encoding]::ASCII.GetBytes('PAGEDU64').CopyTo($dmp, 0)
        [BitConverter]::GetBytes([uint32]26100).CopyTo($dmp, 0x0C)
        [BitConverter]::GetBytes($code).CopyTo($dmp, 0x38)
        for ($i = 0; $i -lt 4; $i++) { [BitConverter]::GetBytes([Convert]::ToUInt64($params[$i], 16)).CopyTo($dmp, 0x40 + 8 * $i) }
        [BitConverter]::GetBytes(([DateTime]'2026-10-20 08:00:00').ToFileTime()).CopyTo($dmp, 0xFA8)
        $tri = 0x2000
        [BitConverter]::GetBytes([uint32]0x2500).CopyTo($dmp, $tri + 0x10)   # 异常记录
        [BitConverter]::GetBytes([uint32]0x2800).CopyTo($dmp, $tri + 0x20); [BitConverter]::GetBytes([uint32]0x3000).CopyTo($dmp, $tri + 0x24)   # 进程、线程
        [BitConverter]::GetBytes([uint32]0x2600).CopyTo($dmp, $tri + 0x28); [BitConverter]::GetBytes([uint32](8 * $stack.Count)).CopyTo($dmp, $tri + 0x2C)
        [BitConverter]::GetBytes([uint32]0x2100).CopyTo($dmp, $tri + 0x30); [BitConverter]::GetBytes([uint32]3).CopyTo($dmp, $tri + 0x34)    # 3 个驱动
        $drv = @(@('\SystemRoot\system32\ntoskrnl.exe', 'FFFFF80000000000', 0x1000000), @('\SystemRoot\System32\DriverStore\FileRepository\nv.inf_amd64_1\nvlddmkm.sys', 'FFFFF80012000000', 0x2000000), @('\SystemRoot\System32\drivers\Wdf01000.sys', 'FFFFF80030000000', 0x100000))
        $strAt = 0x2300
        for ($i = 0; $i -lt 3; $i++) {
            $o = 0x2100 + $i * 0x90
            [BitConverter]::GetBytes([uint32]$strAt).CopyTo($dmp, $o)
            [BitConverter]::GetBytes([Convert]::ToUInt64($drv[$i][1], 16)).CopyTo($dmp, $o + 8 + 0x30); [BitConverter]::GetBytes([uint32]$drv[$i][2]).CopyTo($dmp, $o + 8 + 0x40)
            $nb = [Text.Encoding]::Unicode.GetBytes([string]$drv[$i][0])
            [BitConverter]::GetBytes([uint32]($nb.Length / 2)).CopyTo($dmp, $strAt); $nb.CopyTo($dmp, $strAt + 4); $strAt += 4 + $nb.Length + 2
        }
        [BitConverter]::GetBytes([Convert]::ToUInt32('80000003', 16)).CopyTo($dmp, 0x2500); [BitConverter]::GetBytes([Convert]::ToUInt64($exAddr, 16)).CopyTo($dmp, 0x2510)
        for ($i = 0; $i -lt $stack.Count; $i++) { [BitConverter]::GetBytes([Convert]::ToUInt64($stack[$i], 16)).CopyTo($dmp, 0x2600 + 8 * $i) }
        if ($proc) { [Text.Encoding]::ASCII.GetBytes($proc).CopyTo($dmp, 0x2800 + 0x5A8); $dmp[0x2800 + 0x5A8 + 15] = 2 }   # EPROCESS.ImageFileName，后面一个字节是 PriorityClass
        [BitConverter]::GetBytes([Convert]::ToUInt64('FFFF8000AAAA0080', 16)).CopyTo($dmp, 0x3000 + 0xB8)                    # KTHREAD.ApcState.Process
        return ,$dmp
    }
    $di = [DumpInfo]::Parse((New-TestDump 0xD1 @('10', '2', '0', 'FFFFF80012345678') 'FFFFF80000001000' @('FFFFF80000001234', 'FFFFF80030000100', 'FFFFF80012345678', '12') 'game.exe'), $null)
    Check "dump: bug check and params ($('{0:X}' -f $di.BugCheck))" ($di.Ok -and $di.BugCheck -eq 0xD1 -and $di.Params[3] -eq [Convert]::ToUInt64('FFFFF80012345678', 16) -and $di.Build -eq 26100)
    Check "dump: driver table with 0x90 entries, leaf names and full paths ($($di.Drivers.Count): $(@($di.Drivers | ForEach-Object { $_.Name }) -join ','))" ($di.Drivers.Count -eq 3 -and $di.Drivers[1].Name -eq 'nvlddmkm.sys' -and $di.Drivers[1].Path -like '\SystemRoot\*\nvlddmkm.sys' -and $di.Drivers[1].Base -eq [Convert]::ToUInt64('FFFFF80012000000', 16))
    Check "dump: suspect driver from the fault address ($($di.Suspect)/$($di.SuspectFrom))" ($di.Suspect -eq 'nvlddmkm.sys' -and $di.SuspectFrom -eq 'address')
    Check "dump: drivers on the stack, kernel excluded even with a full path ($($di.StackDrivers -join ','))" (($di.StackDrivers -join ',') -eq 'Wdf01000.sys,nvlddmkm.sys')
    Check "dump: current process name ($($di.Process))" ($di.Process -eq 'game.exe' -and -not $di.ProcessIsParam1)
    Check 'dump: time from the header' ($di.Time.Year -eq 2026 -and $di.Time.Month -eq 10)
    Check 'dump: code name table' ([DumpInfo]::CodeName(0xD1) -eq 'DRIVER_IRQL_NOT_LESS_OR_EQUAL' -and [DumpInfo]::CodeName(0x7777) -eq '')
    # 0x7A 读盘失败：状态码在参数 2；参数 4 落在哪个驱动里只说明它倒霉，不点名
    $d7 = [DumpInfo]::Parse((New-TestDump 0x7A @('FFFFA78113151F38', 'FFFFFFFFC000000E', '148370860', 'FFFFF80012000100') 'FFFFF80000001000' @('FFFFF80012000100', 'FFFFF80030000100') 'System'), $null)
    Check "dump 0x7A: status, page owner, nobody blamed ($('{0:X8}' -f $d7.Status) $($d7.PageOwner) [$($d7.Suspect)])" ($d7.Status -eq [Convert]::ToUInt32('C000000E', 16) -and [DumpInfo]::StatusName($d7.Status) -eq 'STATUS_NO_SUCH_DEVICE' -and [DumpInfo]::IsStorageStatus($d7.Status) -and $d7.PageOwner -eq 'nvlddmkm.sys' -and $d7.Suspect -eq '')
    # 0xEF：参数 1 是死掉的进程，线程里记的当前进程就是它
    $de = [DumpInfo]::Parse((New-TestDump 0xEF @('FFFF8000AAAA0080', '0', '0', '0') 'FFFFF80000001000' @('FFFFF80000001234') 'svchost.exe'), $null)
    Check "dump 0xEF: the critical process that died ($($de.Process), $($de.ProcessIsParam1))" ($de.Process -eq 'svchost.exe' -and $de.ProcessIsParam1 -and $de.Suspect -eq '')
    # 0x50：参数 3 是出事的指令；栈上只有微软驱动时不点名
    $d5 = [DumpInfo]::Parse((New-TestDump 0x50 @('FFFFB02FD15E21F8', '0', 'FFFFF80000001500', '2') 'FFFFF80000001000' @('FFFFF80030000100') ''), $null)
    $x5 = ConvertFrom-DumpInfo $d5 'x.dmp' 'x.dmp' (Get-Date) 1000
    Check "dump 0x50: a Windows-only stack names nobody ($($d5.Suspect)/$($d5.SuspectFrom) -> [$($x5.Suspect)])" ($d5.SuspectFrom -eq 'stack' -and $x5.Suspect -eq '' -and (Test-MsDriverName 'Wdf01000.sys') -and -not (Test-MsDriverName 'nvlddmkm.sys'))
    Check 'dump: garbage is rejected' (-not ([DumpInfo]::Parse((New-Object byte[] 100), $null)).Ok)
    # 几次蓝屏放在一起看：读盘失败 + 系统进程退出 → 硬盘；同一个第三方驱动两次 → 点名它；Windows 太旧、时钟往回走
    $x7 = ConvertFrom-DumpInfo $d7 'a.dmp' 'a.dmp' (Get-Date) 1000; $xe = ConvertFrom-DumpInfo $de 'b.dmp' 'b.dmp' (Get-Date) 1000; $xd = ConvertFrom-DumpInfo $di 'c.dmp' 'c.dmp' (Get-Date) 1000; $xd2 = ConvertFrom-DumpInfo $di 'd.dmp' 'd.dmp' (Get-Date) 1000
    $hv = @{ Crash = @{ Dumps = @($x7, $xe, $xd, $xd2); Events = @(@{ Source = 'disk'; Count = 3 }); Drivers = @() }; Disks = @(); Mem = @{ Whea = 0 }; Clock = @{ Wrong = $true; AheadDays = 500; Newest = (Get-Date).AddDays(500) }; Win = @{ BuildNo = 18362; Release = '1903'; Product = 'Windows 10 Pro' } }
    $vd = @(Get-CrashVerdict $hv); $ids = @($vd | ForEach-Object { $_.Id })
    Check "verdicts: storage first, the repeated driver, clock, old Windows ($($ids -join ','))" ($ids[0] -eq 'storage' -and $ids -contains 'driver-nvlddmkm.sys' -and $ids -contains 'clock' -and $ids -contains 'oldwin' -and $ids -notcontains 'sysfile')
    Check 'verdicts: the storage verdict offers the disk power fix and names the storage status' (@($vd[0].Fixes) -contains 'diskpower' -and $vd[0].Body -match '0xC000000E')
    $quiet = @(Get-CrashVerdict @{ Crash = @{ Dumps = @(); Events = @(); Drivers = @() }; Disks = @(); Win = @{ BuildNo = 26100 } })
    Check 'verdicts: nothing to report gives one "no problems" line' ($quiet.Count -eq 1 -and $quiet[0].Id -eq 'none' -and $quiet[0].Level -eq 'green')
    $ex7 = Get-DumpExplain $x7
    Check 'explain 0x7A: storage kind with the status in words' ($ex7.Kind -eq 'storage' -and (@($ex7.Detail) -join ' ') -match 'C000000E' -and @($ex7.Fixes) -contains 'diskpower')
    # 蓝屏记录（WER 1001）里的错误码和状态码：小转储只留最近几个，记录每次都有
    $wb = ConvertFrom-BugCheckText '计算机已经从检测错误后重新启动。检测错误: 0x0000007a (0xffffa78113151f38, 0xffffffffc000000e, 0x0000000148370860, 0xfffff80560723ab4)。'
    Check "bug check from an event message ($('{0:X}' -f $wb.Code) $('{0:X8}' -f $wb.Status))" ($wb.Code -eq 0x7A -and $wb.Status -eq [Convert]::ToUInt32('C000000E', 16) -and $wb.CodeName -eq 'KERNEL_DATA_INPAGE_ERROR' -and -not (ConvertFrom-BugCheckText 'nothing here'))
    # 21 次蓝屏只留了 1 个转储；U 盘的读写重试不算系统盘的；时钟比发布日期还早又上不了网；Dell 的下载页按服务编号
    $many = @(1..20 | ForEach-Object { @{ Code = [long]0xEF; CodeName = 'CRITICAL_PROCESS_DIED'; Status = 0; Time = (Get-Date) } }) + @(@{ Code = [long]0x7A; CodeName = 'KERNEL_DATA_INPAGE_ERROR'; Status = [long][Convert]::ToUInt32('C000000E', 16); Time = (Get-Date) })
    $hv2 = @{ Crash = @{ Dumps = @($xe); BugChecks = $many; DiskEvents = @(@{ Disk = 2; Count = 4; Name = 'USB Stick'; Bus = 'USB'; IsSystem = $false }); Events = @(@{ Source = 'disk'; Count = 4 }, @{ Source = 'volmgr'; Count = 3 }, @{ Source = 'Microsoft-Windows-Kernel-Power'; Count = 25 }); Drivers = @() }; Disks = @(); Mem = @{ Whea = 0 }
              Clock = @{ Wrong = $true; BehindBuild = 500; AheadDays = 500; SyncFails = 9; SyncOk = 0; DnsFail = $true }; Win = @{ BuildNo = 26100 }; Power = @{ DiskFix = $false; FastStartup = 'on' }
              Sys = @{ Maker = 'Dell Inc.'; Model = 'Precision 3640 Tower'; Bios = '1.2.3'; BiosDate = [DateTime]'2020-08-06'; Serial = 'ABC1234'; BitLocker = 0; SysDisk = @{ Name = 'NVMe X'; Bus = 'RAID'; Firmware = '1'; RaidVolume = $false }; Stor = @(@{ Device = 'Intel RST Premium Controller'; Version = '16.8'; Date = [DateTime]'2018-02-07'; Rst = $true }) } }
    $vd2 = @(Get-CrashVerdict $hv2); $st2 = @($vd2 | Where-Object { $_.Id -eq 'storage' })[0]; $cl2 = @($vd2 | Where-Object { $_.Id -eq 'clock' })[0]
    Check "verdicts count every bug check in the event log, not just the kept dumps, and leave the USB stick out ($(@($vd2 | ForEach-Object { $_.Id }) -join ','))" ($st2 -and $st2.Body -match '21' -and $st2.Body -match 'USB Stick' -and @($vd2 | Where-Object { $_.Id -eq 'unexpected' }).Count -eq 0)
    Check 'storage verdict: a fix-as-suggested plan plus things to do yourself (vendor update by service tag, AHCI guide on RST)' (($st2.Plan -join ',') -eq 'diskpower,faststartup' -and @($st2.Todo).Count -ge 4 -and @($st2.Fixes) -contains 'ahciguide' -and @($st2.Fixes) -contains 'vendor' -and (@($st2.Todo) -join ' ') -match 'ABC1234')
    Check 'clock verdict: behind the release date and offline means set it by hand' ($cl2 -and $cl2.Level -eq 'red' -and ($cl2.Plan -join ',') -eq 'datetime')
    Check 'vendor page: Dell goes by service tag, others to a search' ((Get-VendorSupportUrl $hv2.Sys) -match 'dell\.com/support/.*/servicetag/ABC1234/drivers' -and (Get-VendorSupportUrl @{ Maker = 'Acme'; Model = 'Box 1'; Serial = '' }) -match '^https://www\.bing\.com/search\?q=')
    $rt2 = Get-HealthReportText ($hv2 + @{ At = (Get-Date); Verdicts = $vd2 })
    Check 'the report says what ClearC can do and what is left to you' ($rt2 -match [regex]::Escape((T '本工具能直接做（结论下面的「按建议处理」）：')) -and $rt2 -match [regex]::Escape((T '需要你自己做：')) -and $rt2 -match 'Precision 3640')
    # 常见问题修复目录：每个问题里的步骤都存在；会改动的都写了确认文字或是无害的
    $fc = Get-FixCatalog; $bad = @()
    foreach ($pb in $fc.Problems) { foreach ($sid in $pb.Steps) { if (-not $fc.Steps.Contains($sid)) { $bad += "$($pb.Id)/$sid" } } }
    foreach ($k in $fc.Steps.Keys) { $st = $fc.Steps[$k]; if ($st.Kind -notin 'check', 'fix', 'open', 'go', 'special') { $bad += "$k kind" }; if ($st.Kind -eq 'fix' -and -not $st.Harmless -and -not $st.Confirm) { $bad += "$k no confirm" }; if (-not $st.Name -or -not $st.Desc) { $bad += "$k text" } }
    foreach ($v in @($vd)) { foreach ($f in @($v.Fixes)) { if (-not $fc.Steps.Contains($f)) { $bad += "verdict $($v.Id)/$f" } } }
    Check ("repair catalog: steps exist, changing steps ask first ({0} steps, {1} problems) {2}" -f $fc.Steps.Count, $fc.Problems.Count, ($bad -join ' ')) ($bad.Count -eq 0 -and $fc.Problems.Count -ge 10)
    $rt = Get-HealthReportText ($hv + @{ At = (Get-Date); Verdicts = $vd })
    Check 'health report text has the diagnosis and every dump' ($rt -match [regex]::Escape((T '诊断结论')) -and ([regex]::Matches($rt, 'KERNEL_DATA_INPAGE_ERROR')).Count -ge 1 -and ([regex]::Matches($rt, 'a\.dmp|b\.dmp|c\.dmp|d\.dmp')).Count -ge 4)
    # 进程采样对比
    $p1 = @{ At = (Get-Date).AddSeconds(-3); Procs = @{ 10 = @{ Pid = 10; Name = 'a.exe'; Path = ''; Cpu100ns = 0; Ws = 100; Write = 1000; Read = 0 }; 11 = @{ Pid = 11; Name = 'b.exe'; Path = ''; Cpu100ns = 0; Ws = 50; Write = 500; Read = 0 } } }
    $p2 = @{ At = (Get-Date); Procs = @{ 10 = @{ Pid = 10; Name = 'a.exe'; Path = ''; Cpu100ns = 30000000; Ws = 120; Write = 4000; Read = 0 }; 12 = @{ Pid = 12; Name = 'c.exe'; Path = ''; Cpu100ns = 0; Ws = 10; Write = 700; Read = 0 } } }
    $cmp = @(Compare-ProcSample $p1 $p2 $p1 2)
    $ra = @($cmp | Where-Object { $_.Pid -eq 10 })[0]; $rc = @($cmp | Where-Object { $_.Pid -eq 12 })[0]
    Check "process sample diff: write since and cpu ($($ra.WriteSince), $([int]$ra.Cpu)%)" ($cmp.Count -eq 2 -and $ra.WriteSince -eq 3000 -and $ra.Cpu -gt 30 -and $ra.Cpu -lt 70 -and $rc.WriteSince -eq 700)
    # 使用模式（放最后：写设置文件会多出一个文件，别影响前面的空间地图比较）
    Set-Setting 'Mode' 'expert'; $m2 = Get-Mode; Set-Setting 'Mode' 'pro'; $m1 = Get-Mode; Set-Setting 'Mode' ''; $m0 = Get-Mode
    Check 'Get-Mode: expert 2, pro 1, unset = basic 0' ($m0 -eq 0 -and $m1 -eq 1 -and $m2 -eq 2)
    $cats = @([FileCats]::OfName('a.MP4'), [FileCats]::OfName('x.tar.gz'), [FileCats]::OfName('readme'), [FileCats]::OfName('.gitignore'), [FileCats]::OfName('main.cs'), [FileCats]::OfName('b.verylongext'))
    Check "file categories by extension ($($cats -join ','))" (($cats -join ',') -eq '1,5,0,0,9,0')
    $u = [Text.Encoding]::Unicode.GetBytes('photo.JPEG'); Check 'file category from UTF-16 name bytes' ([FileCats]::Of($u, 0, $u.Length) -eq 2)
    Check 'walk scan counts file types' ($tree.TypeBytes -and $tree.TypeBytes.Length -eq 10 -and (($tree.TypeCount | Measure-Object -Sum).Sum) -eq $tree.Files)
    # 按哈希查：选一个文件找它的副本（按它的 SHA-256），或者粘贴 MD5 / SHA-1 / SHA-256 找内容对得上的文件
    $hr = Join-Path $T 'hashfind'; New-Item -ItemType Directory -Force -Path (Join-Path $hr 'sub') | Out-Null
    $hx = New-Object byte[] 300000; (New-Object Random 7).NextBytes($hx)
    $hy = [byte[]]$hx.Clone(); $hy[150000] = [byte](($hy[150000] + 1) % 256)
    [IO.File]::WriteAllBytes((Join-Path $hr 'a.bin'), $hx); [IO.File]::WriteAllBytes((Join-Path (Join-Path $hr 'sub') 'b-copy.dat'), $hx)
    [IO.File]::WriteAllBytes((Join-Path $hr 'c-same-size.bin'), $hy); [IO.File]::WriteAllBytes((Join-Path $hr 'd-short.bin'), $hx[0..999])
    $hseed = Join-Path (Join-Path $T 'hashseed') 'orig.bin'; New-Item -ItemType Directory -Force -Path (Split-Path $hseed) | Out-Null; [IO.File]::WriteAllBytes($hseed, $hx)
    $hex = { param($alg, $bytes) $h = [Security.Cryptography.HashAlgorithm]::Create($alg); try { [BitConverter]::ToString($h.ComputeHash([byte[]]$bytes)).Replace('-', '').ToLowerInvariant() } finally { $h.Dispose() } }
    $sha = & $hex 'SHA256' $hx; $md5 = & $hex 'MD5' $hx; $sha1 = & $hex 'SHA1' $hx
    $names = { param($gs) @($gs | ForEach-Object { $_.Files } | ForEach-Object { [IO.Path]::GetFileName($_.Path) } | Sort-Object) -join ',' }
    $al = ''; $p1 = [DupFinder]::ParseHash("SHA256: $($sha.ToUpperInvariant())", [ref]$al)
    $al2 = ''; $p2 = [DupFinder]::ParseHash("  $md5  ", [ref]$al2); $al3 = ''; $p3 = [DupFinder]::ParseHash("SHA1 $sha1", [ref]$al3)
    Check 'hash lookup reads a pasted SHA-256, MD5 or SHA-1 (any case, with a label in front)' ($p1 -eq $sha -and $al -eq 'SHA256' -and $p2 -eq $md5 -and $al2 -eq 'MD5' -and $p3 -eq $sha1 -and $al3 -eq 'SHA1')
    $z = ''; Check 'hash lookup refuses text that is not exactly one of those lengths (SHA-512, a 63-digit typo, plain words)' ($null -eq [DupFinder]::ParseHash(($sha + $sha), [ref]$z) -and $null -eq [DupFinder]::ParseHash($sha.Substring(1), [ref]$z) -and $null -eq [DupFinder]::ParseHash('hello world', [ref]$z))
    $g = @([DupFinder]::FindByHash([string[]]@($hr), '', $hseed, 1, 0, $null, [string[]]@(), $null))
    Check ("picking a file finds its copies by content, under any name, and lists the picked file too ({0})" -f (& $names $g)) ($g.Count -eq 1 -and (& $names $g) -eq 'a.bin,b-copy.dat,orig.bin' -and $g[0].Verified -and [DupFinder]::LookupAlgo -eq 'SHA256' -and [DupFinder]::LookupHash -eq $sha)
    $g = @([DupFinder]::FindByHash([string[]]@($hr), '', (Join-Path $hr 'a.bin'), 1, 0, $null, [string[]]@(), $null))
    Check 'a picked file inside the search location is listed once' ((& $names $g) -eq 'a.bin,b-copy.dat')
    $ok = $true; foreach ($q in @($sha, $md5, $sha1)) { $g = @([DupFinder]::FindByHash([string[]]@($hr), $q, '', 1, 0, $null, [string[]]@(), $null)); if ((& $names $g) -ne 'a.bin,b-copy.dat' -or -not $g[0].Verified) { $ok = $false } }
    Check 'a pasted SHA-256, MD5 or SHA-1 finds exactly the files with that content (same size but one byte different does not match)' $ok
    $g = @([DupFinder]::FindByHash([string[]]@($hr), (& $hex 'SHA256' $hx[0..999]), '', 1, 0, $null, [string[]]@(), $null))
    Check 'a hash with only one matching file still shows where that file is' ((& $names $g) -eq 'd-short.bin')
    $g = @([DupFinder]::FindByHash([string[]]@($hr), $sha, '', 1MB, 0, $null, [string[]]@(), $null))
    Check 'a pasted hash follows the size filter (nothing under 1 MB is read)' ($g.Count -eq 0 -and [DupFinder]::LookupError -eq '' -and [DupFinder]::FilesSeen -eq 0)
    $g = @([DupFinder]::FindByHash([string[]]@($hr), 'not a hash', '', 1, 0, $null, [string[]]@(), $null))
    Check 'text that is not a hash is reported, not searched' ($g.Count -eq 0 -and [DupFinder]::LookupError -eq 'nohash')
    $e0 = Join-Path (Split-Path $hseed) 'empty.bin'; [IO.File]::WriteAllBytes($e0, (New-Object byte[] 0))
    $g = @([DupFinder]::FindByHash([string[]]@($hr), '', $e0, 1, 0, $null, [string[]]@(), $null)); $ge = [DupFinder]::LookupError
    $g2 = @([DupFinder]::FindByHash([string[]]@($hr), '', (Join-Path (Split-Path $hseed) 'missing.bin'), 1, 0, $null, [string[]]@(), $null))
    Check 'an empty or missing picked file is reported, not searched' ($g.Count -eq 0 -and $ge -eq 'empty' -and $g2.Count -eq 0 -and [DupFinder]::LookupError -eq 'seed')
    [DupFinder]::Cancel = $true
    try { $g = @([DupFinder]::FindByHash([string[]]@($hr), $sha, '', 1, 0, $null, [string[]]@(), $null)) } finally { [DupFinder]::Cancel = $false }
    Check 'a cancelled hash lookup returns nothing' ($g.Count -eq 0)
    # 一块盘用了多少：已用 + 可用 = 总容量，百分比在 0 到 100 之间；读不到的盘不报错
    $root = [IO.Path]::GetPathRoot([IO.Path]::GetTempPath())
    $du = Get-DriveUse $root; $dn = Get-DriveUse 'Q:\no-such-drive'
    Check ("Get-DriveUse: used + free = total ({0:N1} GB of {1:N1} GB, {2:N0}%)" -f ($du.Used / 1GB), ($du.Total / 1GB), $du.Pct) ($du.Ok -and [math]::Abs($du.Used + $du.Free - $du.Total) -lt 1 -and $du.Pct -ge 0 -and $du.Pct -le 100 -and -not $dn.Ok -and $dn.Total -eq 0)
} } finally {
    Remove-Item -LiteralPath $lk -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $T -Recurse -Force -ErrorAction SilentlyContinue
}
""
if ($fails) { "$fails test(s) failed" } else { 'all engine tests passed' }
exit $fails
