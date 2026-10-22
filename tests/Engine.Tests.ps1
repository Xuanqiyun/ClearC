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
try {
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
} finally {
    Remove-Item -LiteralPath $lk -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $T -Recurse -Force -ErrorAction SilentlyContinue
}
""
if ($fails) { "$fails test(s) failed" } else { 'all engine tests passed' }
exit $fails
