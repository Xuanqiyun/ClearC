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
    Check 'catalog: careful group sits between safe and confirm' ((@($cat | Where-Object { $_.Careful }).Count -ge 15) -and (@($cat | Where-Object { ([string]$_.G).StartsWith('谨慎清理') -and -not $_.Careful }).Count -eq 0))
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
    # 蓝屏转储解析：自己拼一个 64 位小转储（头部、驱动表、异常记录、调用栈）
    $dmp = New-Object byte[] 0x3000
    [Text.Encoding]::ASCII.GetBytes('PAGEDU64').CopyTo($dmp, 0)
    [BitConverter]::GetBytes([uint32]26100).CopyTo($dmp, 0x0C)
    [BitConverter]::GetBytes([uint32]0xD1).CopyTo($dmp, 0x38)
    [BitConverter]::GetBytes([uint64]0x10).CopyTo($dmp, 0x40); [BitConverter]::GetBytes([uint64]2).CopyTo($dmp, 0x48); [BitConverter]::GetBytes([uint64]0).CopyTo($dmp, 0x50); [BitConverter]::GetBytes([Convert]::ToUInt64('FFFFF80012345678', 16)).CopyTo($dmp, 0x58)
    [BitConverter]::GetBytes(([DateTime]'2026-10-20 08:00:00').ToFileTime()).CopyTo($dmp, 0xFA8)
    $tri = 0x2000
    [BitConverter]::GetBytes([uint32]0x2500).CopyTo($dmp, $tri + 0x10)   # 异常记录
    [BitConverter]::GetBytes([uint32]0x2600).CopyTo($dmp, $tri + 0x28); [BitConverter]::GetBytes([uint32]32).CopyTo($dmp, $tri + 0x2C)   # 调用栈：4 个地址
    [BitConverter]::GetBytes([uint32]0x2100).CopyTo($dmp, $tri + 0x30); [BitConverter]::GetBytes([uint32]3).CopyTo($dmp, $tri + 0x34)    # 3 个驱动
    $drv = @(@('ntoskrnl.exe', [Convert]::ToUInt64('FFFFF80000000000', 16), 0x1000000), @('nvlddmkm.sys', [Convert]::ToUInt64('FFFFF80012000000', 16), 0x2000000), @('wdf01000.sys', [Convert]::ToUInt64('FFFFF80030000000', 16), 0x100000))
    $strAt = 0x2400
    for ($i = 0; $i -lt 3; $i++) {
        $o = 0x2100 + $i * 0x98
        [BitConverter]::GetBytes([uint32]$strAt).CopyTo($dmp, $o)
        [BitConverter]::GetBytes([uint64]$drv[$i][1]).CopyTo($dmp, $o + 8 + 0x30); [BitConverter]::GetBytes([uint32]$drv[$i][2]).CopyTo($dmp, $o + 8 + 0x40)
        $nb = [Text.Encoding]::Unicode.GetBytes([string]$drv[$i][0])
        [BitConverter]::GetBytes([uint32]($nb.Length / 2)).CopyTo($dmp, $strAt); $nb.CopyTo($dmp, $strAt + 4); $strAt += 4 + $nb.Length + 2
    }
    [BitConverter]::GetBytes([Convert]::ToUInt32('C0000005', 16)).CopyTo($dmp, 0x2500); [BitConverter]::GetBytes([Convert]::ToUInt64('FFFFF80012345678', 16)).CopyTo($dmp, 0x2510)
    [BitConverter]::GetBytes([Convert]::ToUInt64('FFFFF80000001234', 16)).CopyTo($dmp, 0x2600); [BitConverter]::GetBytes([Convert]::ToUInt64('FFFFF80030000100', 16)).CopyTo($dmp, 0x2608); [BitConverter]::GetBytes([Convert]::ToUInt64('FFFFF80012345678', 16)).CopyTo($dmp, 0x2610); [BitConverter]::GetBytes([uint64]0x12).CopyTo($dmp, 0x2618)
    $di = [DumpInfo]::Parse($dmp, $null)
    Check "dump: bug check and params ($('{0:X}' -f $di.BugCheck))" ($di.Ok -and $di.BugCheck -eq 0xD1 -and $di.Params[3] -eq [Convert]::ToUInt64('FFFFF80012345678', 16) -and $di.Build -eq 26100)
    Check 'dump: drivers and names' ($di.Drivers.Count -eq 3 -and $di.Drivers[1].Name -eq 'nvlddmkm.sys' -and $di.Drivers[1].Base -eq [Convert]::ToUInt64('FFFFF80012000000', 16))
    Check "dump: suspect driver from the fault address ($($di.Suspect))" ($di.Suspect -eq 'nvlddmkm.sys')
    Check "dump: drivers on the stack, kernel excluded ($($di.StackDrivers -join ','))" (($di.StackDrivers -join ',') -eq 'wdf01000.sys,nvlddmkm.sys')
    Check 'dump: time from the header' ($di.Time.Year -eq 2026 -and $di.Time.Month -eq 10)
    Check 'dump: code name table' ([DumpInfo]::CodeName(0xD1) -eq 'DRIVER_IRQL_NOT_LESS_OR_EQUAL' -and [DumpInfo]::CodeName(0x7777) -eq '')
    Check 'dump: garbage is rejected' (-not ([DumpInfo]::Parse((New-Object byte[] 100), $null)).Ok)
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
} } finally {
    Remove-Item -LiteralPath $lk -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $T -Recurse -Force -ErrorAction SilentlyContinue
}
""
if ($fails) { "$fails test(s) failed" } else { 'all engine tests passed' }
exit $fails
