# 界面文字翻译：中文是原文；英文界面时查表，查不到就原样显示中文。后台任务通过 $sync.L10n 拿到同一张表
function T([string]$s) {
    $d = $script:L10n
    if ($null -eq $d -and $sync) { $d = $sync.L10n }
    if ($null -eq $d) { try { $d = [L10n]::Map } catch {} }   # 后台线程（Start-BgEngine）没有 $sync：用界面启动时填好的那份
    if ($null -ne $d) { $v = $null; if ($d.TryGetValue($s, [ref]$v)) { return $v } }
    return $s
}
$ErrorActionPreference = 'SilentlyContinue'
function Log($m) { if ($sync -and $sync.Log) { $sync.Log.Enqueue($m) } else { Write-Host $m } }
# 向界面报告进度（界面每 0.3 秒读一次）
function SetP([hashtable]$h) { if ($sync -and $sync.P) { foreach ($k in $h.Keys) { $sync.P[$k] = $h[$k] } } }
# 系统文件夹从系统接口取，不信环境变量：环境变量是启动本工具的那个程序给的，普通权限就能改，
# 而本工具以管理员身份运行 cmd、robocopy、icacls 这些系统程序。之后用到的 SystemRoot、SystemDrive 环境变量都是这里的值
function Use-SystemPaths {
    $w = ''; try { $w = [Environment]::GetFolderPath('Windows') } catch {}
    if ($w -and $w.Length -ge 3 -and $w[1] -eq ':') { $env:SystemRoot = $w; $env:windir = $w; $env:SystemDrive = $w.Substring(0, 2) }
}
Use-SystemPaths
$sys32 = [Environment]::SystemDirectory
if (-not $sys32) { $sys32 = "$env:SystemRoot\System32" }
$script:AppBuilt = [DateTime]'2026-10-24'   # 这一版的发布日期（发版时改）：系统时间比它还早，时钟肯定不对
function GB($b) { "{0:N2} GB" -f ([double]$b / 1GB) }
function FreeC { (Get-PSDrive C).Free }
function DirBytes($p) { [double][DirStat]::Measure([string]$p) }
# 统计一个文件夹：返回这一次自己的结果（.Files、.Bytes、.Reparse、.ReparseSample、.Cancelled），做判断都用它
function DirCount($p) { [DirStat]::Count([string]$p) }
# 向界面报告某一行的状态：kind = wait / run / ok / warn / fail / skip
function SetStatus($idx, [string]$text, [string]$kind) { if ($sync -and $sync.Status) { $sync.Status[$idx] = @($text, $kind); $sync.StatusVer = [int]$sync.StatusVer + 1 } }

# ---------- 中途取消 ----------
# 用户点了「取消」后，后台只在安全的地方检查这个标记、停下来；返回 $true 时顺便记下「确实有没做完的」。
# 换链接、删备份这类停在一半会出问题的步骤，执行期间把 CanCancel 设成 $false（界面上的取消按钮变灰），做完才停。
function Stopping { if ($sync -and $sync.Cancel) { $sync.WasCancelled = $true; return $true }; return $false }
# ---------- 几件互不相干、各自要等一会儿的事一起做 ----------
# 每件在自己的后台里跑（各带一份引擎，读引擎只要零点几秒）。$jobs：键 → 一段代码。返回句柄，Wait-Parallel 等它们做完。
# 只用来读东西、统计大小（不删、不改）；开不了后台就什么都不开，调用的地方照旧一件一件做
function Start-Parallel($jobs, [int]$max = 4) {
    $h = @{ Pool = $null; Run = @{} }
    $src = if ($engineText) { $engineText } elseif ($engine) { $engine } else { '' }
    if (-not $jobs -or $jobs.Count -eq 0 -or -not $src) { return $h }
    try {
        $pool = [runspacefactory]::CreateRunspacePool(1, [math]::Max(1, [math]::Min($max, $jobs.Count)))
        $pool.ApartmentState = 'STA'; $pool.Open(); $h.Pool = $pool
        foreach ($k in @($jobs.Keys)) {
            $ps = [powershell]::Create(); $ps.RunspacePool = $pool
            [void]$ps.AddScript("param(`$sync, `$engineText, `$code)`nInvoke-Expression `$engineText`n`$t0 = [Environment]::TickCount`n`$v = & ([scriptblock]::Create(`$code))`n@{ V = `$v; Ms = [Environment]::TickCount - `$t0 }").AddArgument($sync).AddArgument($src).AddArgument([string]$jobs[$k])
            $h.Run[[string]$k] = @{ PS = $ps; AR = $ps.BeginInvoke() }
        }
    } catch {
        Log ((T "  没能同时做几件事，改成一件一件做（{0}）") -f $_.Exception.Message)
        foreach ($j in @($h.Run.Values)) { try { $j.PS.Dispose() } catch {} }
        $h.Run = @{}; if ($h.Pool) { try { $h.Pool.Dispose() } catch {} }; $h.Pool = $null
    }
    return $h
}
# 等一起做的那几件做完：返回 键 → @{ V = 结果; Ms = 用了多少毫秒 }。出错的、没开成的不在里面（调用的地方自己再做一遍）。
# 点了取消就停下不等；超过 $limitSec 秒还没回答的（系统那边卡住了）也不等了，放进 $h.Late，调用的地方当作没问到
function Wait-Parallel($h, [int]$limitSec = 120) {
    $res = @{}
    if (-not $h -or -not $h.Run) { return $res }
    $h.Late = @()
    $until = (Get-Date).AddSeconds($limitSec)
    $hung = $false
    try {
        foreach ($k in @($h.Run.Keys)) {
            $j = $h.Run[$k]
            $late = $false
            while (-not $j.AR.AsyncWaitHandle.WaitOne(200)) {
                if (Stopping) { break }
                if ((Get-Date) -gt $until) { $late = $true; break }
            }
            if (Stopping) { break }
            if ($late) { $h.Late += $k; $hung = $true; try { [void]$j.PS.BeginStop($null, $null) } catch {}; continue }
            try { $out = $j.PS.EndInvoke($j.AR); if ($out.Count -gt 0 -and $out[$out.Count - 1] -is [hashtable]) { $res[$k] = $out[$out.Count - 1] } } catch {}
            try { $j.PS.Dispose() } catch {}; $j.Done = $true
        }
        if (Stopping) { foreach ($x in @($h.Run.Values)) { if (-not $x.Done) { $hung = $true; try { [void]$x.PS.BeginStop($null, $null) } catch {} } } }
    } finally {
        # 卡住的那个不等它（关掉它的后台会一直等下去）：留着让它自己结束
        if ($h.Pool -and -not $hung) { try { $h.Pool.Close(); $h.Pool.Dispose() } catch {} }
        $h.Run = @{}; $h.Pool = $null
    }
    return $res
}
# 记下后台里每一段用了多久（扫描为什么慢一看就知道；写进日志）
function Start-Phases { $script:phSw = [Diagnostics.Stopwatch]::StartNew(); $script:phLast = [long]0; $script:phList = New-Object System.Collections.ArrayList }
function Mark-Phase([string]$n) { if ($script:phSw) { $now = $script:phSw.ElapsedMilliseconds; [void]$script:phList.Add(@{ N = $n; Ms = $now - $script:phLast }); $script:phLast = $now } }
function End-Phases { if ($script:phSw) { if ($sync) { $sync.PhaseTimes = $script:phList }; $script:phSw = $null } }
function Set-CanCancel([bool]$b) { if ($sync -and $sync.P) { $sync.P.CanCancel = $b } }
function Quote-Arg([string]$a) {
    if ($a -eq '') { return '""' }
    if ($a -notmatch '[\s"]') { return $a }
    return '"' + (($a -replace '(\\*)"', '$1$1\"') -replace '(\\+)$', '$1$1') + '"'
}
# 运行 robocopy、compact 这类外部程序，返回 @{ Code; Cancelled }。
# 用户取消时，只结束这一个由本工具自己启动的进程（不碰任何别的程序），Code 为 -1。
# CopyBase >= 0 时，把 robocopy 每复制完一个文件输出的「大小<Tab>文件名」累加起来，报给进度条。
function Invoke-Tool([string]$exe, [string[]]$argv, [string]$cwd = '', [double]$copyBase = -1) {
    $r = @{ Code = -1; Cancelled = $false; Error = '' }
    $si = New-Object System.Diagnostics.ProcessStartInfo
    $si.FileName = $exe
    $si.Arguments = (@($argv | ForEach-Object { Quote-Arg $_ }) -join ' ')
    $si.UseShellExecute = $false; $si.CreateNoWindow = $true
    $si.RedirectStandardOutput = $true; $si.RedirectStandardError = $true
    if ($cwd) { $si.WorkingDirectory = $cwd }
    $p = $null
    try { $p = [System.Diagnostics.Process]::Start($si) } catch { $r.Error = $_.Exception.Message; return $r }
    try {
        $null = $p.StandardError.ReadToEndAsync()
        $copied = [double]0
        $task = $p.StandardOutput.ReadLineAsync()
        $readOk = $true
        while ($true) {
            $got = $false
            try { $got = $task.Wait(250) } catch { $readOk = $false; break }
            if ($got) {
                $line = $task.Result
                if ($null -eq $line) { break }
                if ($copyBase -ge 0) {
                    $m = [regex]::Match($line, '(\d+)\t[^\t]*$')
                    if ($m.Success) { $copied += [double]$m.Groups[1].Value; if ($sync -and $sync.P) { $sync.P.SubDone = $copyBase + $copied } }
                }
                $task = $p.StandardOutput.ReadLineAsync()
            }
            if (Stopping) { $r.Cancelled = $true; try { $p.Kill() } catch {}; break }
        }
        if (-not $readOk) {
            # 读输出出错：不再统计进度，把输出倒掉免得程序卡住，只等它做完；期间仍然可以取消
            try { $null = $p.StandardOutput.BaseStream.CopyToAsync([IO.Stream]::Null) } catch {}
            while (-not $p.WaitForExit(250)) { if (Stopping) { $r.Cancelled = $true; try { $p.Kill() } catch {}; break } }
        }
        if ($r.Cancelled) { [void]$p.WaitForExit(10000); $r.Code = -1 }
        else { $p.WaitForExit(); $r.Code = $p.ExitCode }
    } finally { $p.Dispose() }
    return $r
}
function IsLink($p) { $i = Get-Item -LiteralPath $p -Force -ErrorAction SilentlyContinue; return [bool]($i -and ($i.Attributes -band [IO.FileAttributes]::ReparsePoint)) }

# 用户在设置里排除的文件夹：清理时一律不碰，估算大小时也不算
function Get-ExcludeList { @((Get-Setting 'Exclude' '') -split '\|' | ForEach-Object { $_.Trim().TrimEnd('\', '/') } | Where-Object { $_ }) }
function Get-CustomClean { @((Get-Setting 'CustomClean' '') -split '\|' | ForEach-Object { $_.Trim().TrimEnd('\', '/') } | Where-Object { $_ }) }
function Test-Excluded([string]$path, $ex) {
    if (-not $ex) { return $false }
    $p = $path.TrimEnd('\', '/'); $sep = [IO.Path]::DirectorySeparatorChar
    foreach ($x in $ex) { if ($p -ieq $x -or $p.StartsWith($x + $sep, [StringComparison]::OrdinalIgnoreCase)) { return $true } }
    return $false
}
# 这个文件夹里面有没有被排除的位置（有的话不能整个删）
function Test-HasExcluded([string]$dir, $ex) {
    if (-not $ex) { return $false }
    $d = $dir.TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
    foreach ($x in $ex) { if ($x.StartsWith($d, [StringComparison]::OrdinalIgnoreCase)) { return $true } }
    return $false
}
# $tree：Get-SysTree 读出的 C 盘文件夹树，有的话文件夹大小直接从树上查（只用于显示和估算）
function Get-Size([string[]]$paths, [string]$filter, $tree = $null, $ex = $null) {
    $sum = [double]0
    foreach ($p in $paths) {
        foreach ($it in (Get-PathItems $p)) {
            if ($ex -and (Test-Excluded $it.FullName $ex)) { continue }
            if (Get-LinkedAncestor $it.FullName) { continue }   # 经过链接（上级被搬走了）：清理时不碰，也不算
            if ($it.PSIsContainer) {
                if (IsLink $it.FullName) { continue }
                if ($filter) {
                    $s = (Get-ChildItem -LiteralPath $it.FullName -Filter $filter -File -Force -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum
                    if ($s) { $sum += $s }
                } else {
                    $sum += (Est-Bytes $it.FullName $tree)
                    if ($ex) { $d = $it.FullName.TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar; foreach ($x in $ex) { if ($x.StartsWith($d, [StringComparison]::OrdinalIgnoreCase)) { $sum -= (Est-Bytes $x $tree) } } }
                }
            } else { $sum += $it.Length }
        }
    }
    return [math]::Max([double]0, $sum)
}

# ---------- 统计得更快 ----------
# 每块盘用几个线程一起统计：固态硬盘多一些，机械硬盘少一些（来回寻道反而更慢）。每次打开程序只查一次
function Init-DriveThreads {
    if ([DirStat]::ThreadsReady) { return }
    $cores = [Environment]::ProcessorCount
    try {
        $media = @{}
        foreach ($pd in @(Get-PhysicalDisk -ErrorAction Stop)) { $media[[string]$pd.DeviceId] = [string]$pd.MediaType }
        foreach ($part in @(Get-Partition -ErrorAction Stop)) {
            $c = [int][char]$part.DriveLetter
            if ($c -lt 65) { continue }
            $mt = $media[[string]$part.DiskNumber]
            $n = if ($mt -eq 'SSD' -or $mt -eq 'SCM') { [math]::Min(8, [math]::Max(4, $cores)) } elseif ($mt -eq 'HDD') { 2 } else { 4 }
            [DirStat]::SetThreads([string][char]$c, $n)
        }
    } catch {}
    [DirStat]::ThreadsReady = $true
}
# C 盘的文件夹树，各页面共用：能直接读 NTFS 的文件表（MFT）就读，几秒钟读完；同一次打开程序里再用时，按变更日志只更新改过的部分。
# 读不了（不是 NTFS、没有权限、和直接列目录核对对不上）就返回空，调用的地方照旧逐个文件夹统计。
# 这棵树只用来显示和估算大小；真正删除、搬家时，各自重新统计、重新检查
function Get-SysTree {
    if (Stopping) { return $null }
    SetP @{ SubKind = 'mft'; SubStart = (Get-Date); Detail = (T '读取 C 盘的文件表（MFT）') }
    $t = $null
    try { $t = [DiskMap]::GetTree("$env:SystemDrive", [DirStat]::ThreadsFor($env:SystemDrive), $false, $false) } catch { $t = $null }
    if (-not $t) {
        $why = [string][DiskMap]::LastNote
        if ($why -and -not $sync.MftNoted) { $sync.MftNoted = $true; Log ((T "没能直接读取 C 盘的文件表，改为逐个文件夹统计（{0}）") -f $why) }
        return $null
    }
    $m = [string][DiskMap]::LastMethod
    if ($m -eq 'mft-partial' -or (Stopping)) { return $null }
    if ($m -eq 'mft') { Log ((T "读取 C 盘的文件表：{0:N0} 个文件，用时 {1:N1} 秒") -f $t.Files, ([double][DiskMap]::LastMs / 1000)) }
    elseif ($m -eq 'mft-usn') { Log ((T "按变更日志更新了 C 盘的文件表（{0:N0} 处改动），用时 {1:N1} 秒") -f [DiskMap]::LastChanged, ([double][DiskMap]::LastMs / 1000)) }
    if ([DiskMap]::LastFailed -gt 0) { Log ((T "文件表里有 {0} 条记录这次没读到，下次扫描时再补") -f [DiskMap]::LastFailed) }
    return $t
}
# 别的盘（D 盘这些）的文件夹树：读那块盘的文件表，同一个后台里只读一次；不是 NTFS、读不了就是空（调用的地方照旧逐个统计）。只用于显示和估算
$script:driveTrees = @{}
function Get-DriveTree([string]$path) {
    if (-not $path -or $path.Length -lt 2 -or $path[1] -ne ':') { return $null }
    $k = $path.Substring(0, 1).ToUpperInvariant()
    if ($script:driveTrees.ContainsKey($k)) { return $script:driveTrees[$k] }
    $t = $null
    if ($env:SystemDrive -and $k -eq $env:SystemDrive.Substring(0, 1).ToUpperInvariant()) { $t = Get-SysTree }
    else {
        try {
            $t = [DiskMap]::GetTree("$($k):", [DirStat]::ThreadsFor("$($k):"), $false, $false)
            if ([string][DiskMap]::LastMethod -eq 'mft-partial') { $t = $null }
            if ($t) { Log ((T "读取 {0} 盘的文件表：{1:N0} 个文件，用时 {2:N1} 秒") -f $k, $t.Files, ([double][DiskMap]::LastMs / 1000)) }
        } catch { $t = $null }
    }
    $script:driveTrees[$k] = $t
    return $t
}
# 估计一个文件夹的大小：树上有就直接查，查不到（不在 C 盘、路径里有链接、短文件名等）再逐个统计
function Est-Bytes([string]$p, $tree) {
    if ($tree) {
        try { $n = [DiskMap]::Find($tree, $p); if ($n -and -not $n.IsLink) { return [double]$n.Size } } catch {}
        # 短文件名（%TEMP% 常常是 C:\Users\ADMINI~1\...）：换成长路径再查一次，不用逐个文件夹统计
        if ($p.IndexOf('~') -ge 0) { try { $lp = [FsTools]::LongPath($p); if ($lp -and $lp -ne $p) { $n = [DiskMap]::Find($tree, $lp); if ($n -and -not $n.IsLink) { return [double]$n.Size } } } catch {} }
    }
    $t0 = [Environment]::TickCount
    $b = DirBytes $p
    if ($null -ne $script:walkLog) { [void]$script:walkLog.Add(@{ Path = $p; Ms = [Environment]::TickCount - $t0 }) }   # 记下哪些是逐个文件夹统计的（排查扫描为什么慢）
    return $b
}
# ---------- 个人文件夹保护 ----------
# C 盘上的个人文件夹（桌面、文档、下载、图片、视频、音乐、收藏夹、OneDrive 等）以及用户目录本身，清理时一律不删
function Get-PersonalFolders {
    $list = New-Object System.Collections.Generic.List[string]
    foreach ($f in 'Desktop','MyDocuments','MyPictures','MyVideos','MyMusic','Favorites') {
        try { $x = [Environment]::GetFolderPath($f); if ($x) { $list.Add($x) } } catch {}
    }
    $usf = Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders' -ErrorAction SilentlyContinue
    if ($usf) { foreach ($k in '{374DE290-123F-4565-9164-39C4925E467B}','{56784854-C6CB-462B-8169-88E350ACB882}','{BFB9D5E0-C6A9-404C-B2B2-AE6DB6AF4968}','{4C5C32FF-BB9D-43B0-B5B4-2D72E54EAAA4}') {
        $v = $usf.$k; if ($v) { $list.Add([Environment]::ExpandEnvironmentVariables([string]$v)) } } }
    $list.Add("$env:USERPROFILE\Downloads")
    foreach ($n in 'Contacts','Links','Saved Games','Searches','3D Objects') { $list.Add("$env:USERPROFILE\$n") }
    foreach ($d in @(Get-ChildItem -LiteralPath $env:USERPROFILE -Directory -Filter 'OneDrive*' -Force -ErrorAction SilentlyContinue)) { $list.Add($d.FullName) }
    return ,@($list | Where-Object { $_ -and $_.Length -gt 3 -and $_.Substring(0, 2) -ieq $env:SystemDrive } | ForEach-Object { $_.TrimEnd('\') } | Select-Object -Unique)
}
$script:personalDirs = $null
$script:personalLeaves = @('Desktop','Documents','Downloads','Pictures','Videos','Music','Favorites','Contacts','Links','Saved Games','Searches','3D Objects')
# 路径在 C 盘个人文件夹里（或者就是用户目录、C:\Users、盘符根目录本身）就返回 $true
function Test-Personal([string]$path) {
    if (-not $path) { return $false }
    $full = $path
    try { $full = [IO.Path]::GetFullPath($path) } catch {}
    $full = $full.TrimEnd('\')
    if ($full.Length -le 3) { return $true }
    if ($full -ieq $env:USERPROFILE.TrimEnd('\') -or $full -ieq (Split-Path $env:USERPROFILE -Parent)) { return $true }
    # 这台电脑上其他账户的个人文件夹、公用文件夹，也一样不动
    $users = (Split-Path $env:USERPROFILE -Parent).TrimEnd('\')
    if ($full.StartsWith($users + '\', [StringComparison]::OrdinalIgnoreCase)) {
        $rest = $full.Substring($users.Length + 1).Split('\')
        if ($rest[0] -ieq 'Public') { return $true }
        if ($rest.Count -ge 2 -and ($script:personalLeaves -contains $rest[1] -or $rest[1] -like 'OneDrive*')) { return $true }
    }
    if (-not $script:personalDirs) { $script:personalDirs = Get-PersonalFolders }
    foreach ($d in $script:personalDirs) {
        if ($full -ieq $d -or $full.StartsWith($d + '\', [StringComparison]::OrdinalIgnoreCase)) { return $true }
    }
    return $false
}

# cmd 会把命令行里的 %名字%（比如 %USERNAME%）换成变量的值，路径里带 % 时删的就是另一个地方：这种路径不交给 cmd
function Test-CmdPathOk([string]$p) { return -not ($p.Contains('%') -or $p.Contains('"')) }
# 「放进回收站」会不会真的进回收站。网络位置、U 盘、光盘没有回收站；组策略关了回收站；这块盘的回收站设成了
# 「直接删除」；这一项比这块盘的回收站还大。这几种情况系统会改成永久删除，弹不弹提示要看调用方式（后台批量调用时不一定弹），
# 所以先在这里判断：判断不行就不删，绝不让「放进回收站」悄悄变成永久删除。返回空表示可以
function Get-RecycleVerdict([double]$bytes, [string]$driveType, [bool]$policyOff, [int]$nuke, [double]$maxMB, [double]$volBytes) {
    if ($driveType -ne 'Fixed') { return (T '这个位置没有回收站（网络位置、U 盘或光盘），放进回收站会变成永久删除') }
    if ($policyOff) { return (T '组策略关掉了回收站，放进回收站会变成永久删除') }
    if ($nuke -eq 1) { return (T '这块盘的回收站设成了「不移到回收站，直接删除」') }
    $cap = if ($maxMB -ge 0) { $maxMB * 1MB } elseif ($volBytes -gt 0) { $volBytes * 0.05 } else { [double]-1 }   # 没设过时 Windows 默认大约是盘的 5%
    if ($cap -ge 0 -and $bytes -gt $cap * 0.9) { return ((T '比这块盘的回收站容量（{0}）还大，放进回收站会变成永久删除') -f (GB $cap)) }
    return ''
}
$script:recycleInfo = @{}
function Test-RecycleOk([string]$path, [double]$bytes) {
    if (-not $path) { return (T '路径为空') }
    $p = $path
    if ($p.StartsWith('\\?\UNC\', [StringComparison]::OrdinalIgnoreCase) -or ($p.StartsWith('\\') -and -not $p.StartsWith('\\?\'))) { return (T '这个位置没有回收站（网络位置、U 盘或光盘），放进回收站会变成永久删除') }
    if ($p.StartsWith('\\?\')) { $p = $p.Substring(4) }
    if ($p.Length -lt 3 -or $p[1] -ne ':') { return (T '这个位置没有回收站（网络位置、U 盘或光盘），放进回收站会变成永久删除') }
    $root = $p.Substring(0, 3); $k = $root.ToUpperInvariant()
    if (-not $script:recycleInfo.ContainsKey($k)) {
        $dt = 'Unknown'; $vb = [double]0
        try { $di = New-Object System.IO.DriveInfo $root; $dt = [string]$di.DriveType; $vb = [double]$di.TotalSize } catch {}
        $pol = $false
        foreach ($h in 'HKCU:', 'HKLM:') { try { if ([int](Get-ItemProperty "$h\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer" -ErrorAction Stop).NoRecycleFiles -eq 1) { $pol = $true } } catch {} }
        $nuke = 0; $max = [double]-1
        $g = [FsTools]::VolumeGuid($root)
        if ($g) {
            try {
                $v = Get-ItemProperty "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\BitBucket\Volume\$g" -ErrorAction Stop
                if ($null -ne $v.NukeOnDelete) { $nuke = [int]$v.NukeOnDelete }
                if ($null -ne $v.MaxCapacity) { $max = [double]$v.MaxCapacity }
            } catch {}
        }
        $script:recycleInfo[$k] = @{ Type = $dt; Vol = $vb; Pol = $pol; Nuke = $nuke; Max = $max }
    }
    $x = $script:recycleInfo[$k]
    return Get-RecycleVerdict $bytes $x.Type $x.Pol $x.Nuke $x.Max $x.Vol
}
function Get-ItemBytes($it) { if ($it.PSIsContainer) { try { [double][FsTools]::OnDiskTree($it.FullName) } catch { [double]0 } } else { [double]$it.Length } }
# 可恢复删除（设置里打开）：手动清理时先放进回收站，而不是直接删掉；攒成一批交给系统，比一个个放快
$script:recycleNow = $false
$script:recycleRefused = 0
$script:recycleBatch = $null
function Recycle-Flush {
    if (-not $script:recycleBatch -or $script:recycleBatch.Count -eq 0) { return }
    $arr = $script:recycleBatch.ToArray(); $script:recycleBatch.Clear()
    $r = [FsTools]::RecycleMany($arr)
    $left = @($arr | Where-Object { Test-Path -LiteralPath $_ }).Count
    if ($r -ne 0 -or $left -gt 0) { Log ((T "  有 {0} 项没能放进回收站（错误 {1}），这些没有删") -f $left, $r) }
}
# ---------- 删除的唯一入口 ----------
# 删用户看得到的文件和文件夹都走这里：清理列表、空间地图、重复文件、软件残留、失效的快捷方式、Installer 孤儿包……
# 安全测试用语法树数着：别的地方不能删（本工具自己的临时文件、日志和搬家的步骤除外，测试里一条条写着）。
# 先查能不能删，再放进回收站或永久删除，删完核对还在不在，最后写操作日志。
#   -Scope pick      用户在列表里点的：过 Get-DeleteBlock（个人文件夹、系统、软件安装文件夹、搬家后的数据、聊天记录）
#          leftover  软件残留：同上，但已卸载软件留在安装文件夹里的可以删（Get-DeleteBlock -Leftover）
#          dup       重复文件：过 Get-DupBlock；-AllowPersonal 对应重复文件页的开关（聊天记录不管开关都不删）
#          list      清理列表里写死的缓存位置（本来就在系统文件夹里，所以不过 Get-DeleteBlock）：一样不碰个人文件夹
#   不管哪种：本身是链接的，list 只拆链接本身，其他直接不删；上级文件夹是链接的不删（调用方查过上级时给 -ParentChecked）
#   -How recycle：先过 Test-RecycleOk，放不进回收站就不删，绝不悄悄变成永久删除；-Batch 攒成一批再交给系统（Recycle-Flush）
# 返回 @{ Ok; Why; Stage }：Ok 是删掉了（或者本来就不在）；没删时 Stage 是 block（不让删）、recycle（放不进回收站）或 fail（删的时候失败）
function Invoke-SafeRemove {
    param([string]$Path, $Item = $null, [string]$How = 'delete', [string]$Scope = 'pick', [double]$Bytes = -1,
          [string]$What = '', [string]$Detail = '', [switch]$NoLog, [switch]$Batch, [switch]$AllowPersonal, [switch]$ParentChecked)
    if ($How -ne 'recycle' -and $How -ne 'delete') { throw "Invoke-SafeRemove: How = $How" }
    if (@('pick', 'leftover', 'dup', 'list') -notcontains $Scope) { throw "Invoke-SafeRemove: Scope = $Scope" }
    if ($Item) { $Path = $Item.FullName }
    $res = @{ Ok = $false; Why = ''; Stage = 'block' }
    $finish = {
        if (-not $NoLog -and $What) {
            $d = if ($res.Ok) { if ($Detail) { $Detail } elseif ($Bytes -ge 0) { GB $Bytes } else { '' } } else { (T '没删：') + $res.Why }
            OpLog '删除' $What $Path $d
        }
        return $res
    }
    if (-not $Path) { $res.Why = (T '路径为空'); return (& $finish) }
    if ($Path.Length -gt 3) { $Path = $Path.TrimEnd('\') }
    # 检查用规范化后的路径；真正删的时候用原来的路径（规范化会去掉名字末尾的点和空格，那就成了另一个文件）
    $full = $Path; try { $full = [IO.Path]::GetFullPath($Path).TrimEnd('\') } catch {}
    if ($full.Length -le 3) { $res.Why = (T '整块磁盘不能删'); return (& $finish) }
    if (-not $Item) { $Item = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue }
    if (-not $Item) { $res.Ok = $true; $res.Stage = ''; return $res }   # 已经不在了
    $isDir = [bool]$Item.PSIsContainer
    $isLink = [bool]($Item.Attributes -band [IO.FileAttributes]::ReparsePoint)
    $why = switch ($Scope) {
        'pick'     { Get-DeleteBlock $full }
        'leftover' { Get-DeleteBlock $full -Leftover }
        'dup'      { Get-DupBlock $full ($AllowPersonal -and (Test-Personal $full)) }
        'list'     { if (Test-Personal $full) { (T 'C 盘个人文件夹（桌面、文档、下载、图片、视频、音乐等）里的东西不删') } else { '' } }
    }
    if (-not $why -and $isLink -and $Scope -ne 'list') { $why = (T '这是一个链接（多半是搬家后留下的），删了软件会找不到数据。要处理请到「搬家管理」') }
    if (-not $why -and -not $ParentChecked) { $la = Get-LinkedAncestor $full; if ($la) { $why = ((T "所在的 {0} 是链接（多半是搬家留下的），这里看到的是另一个位置的文件") -f $la) } }
    if (-not $why -and $isDir -and -not (Test-CmdPathOk $Path)) { $why = (T '路径里有 % 或引号，为了不删错地方不交给系统命令') }
    if ($why) { $res.Why = [string]$why; return (& $finish) }
    if ($How -eq 'recycle') {
        $res.Stage = 'recycle'
        if ($Bytes -lt 0) { $Bytes = Get-ItemBytes $Item }
        $why = Test-RecycleOk $full $Bytes
        if ($why) { $res.Why = $why; return (& $finish) }
        if ($Batch) {
            if (-not $script:recycleBatch) { $script:recycleBatch = New-Object System.Collections.Generic.List[string] }
            $script:recycleBatch.Add($Path)
            if ($script:recycleBatch.Count -ge 500) { Recycle-Flush }
            $res.Ok = $true; $res.Stage = ''; return $res
        }
        $res.Stage = 'fail'
        $h = [long]0; try { if ($null -ne $sync -and $sync.Hwnd) { $h = [long]$sync.Hwnd } } catch {}
        $rc = [FsTools]::Recycle($Path, $h)
        if (Test-Path -LiteralPath $Path) { $res.Why = ((T "没能放进回收站（代码 {0}）：可能文件正被占用、回收站放不下，或者在提示里选了取消。没有删") -f $rc); return (& $finish) }
    } else {
        $res.Stage = 'fail'
        if ($isDir) {
            # 链接只拆链接本身；rd /s 遇到里面的链接也只拆不跟，而且比 Remove-Item 快很多
            if ($isLink) { & "$sys32\cmd.exe" /c rmdir "$Path" 2>$null | Out-Null }
            else { & "$sys32\cmd.exe" /c rd /s /q "\\?\$Path" 2>$null | Out-Null }
        } else {
            try {
                if ($Item.Attributes -band [IO.FileAttributes]::ReadOnly) { $Item.Attributes = $Item.Attributes -bxor [IO.FileAttributes]::ReadOnly }
                [IO.File]::Delete($Path)
            } catch { $res.Why = $_.Exception.Message; return (& $finish) }
        }
        if ([IO.File]::Exists($Path) -or [IO.Directory]::Exists($Path)) { $res.Why = (T '没删干净，可能有文件正被占用'); return (& $finish) }
    }
    $res.Ok = $true; $res.Stage = ''
    return (& $finish)
}
# 清理列表里的一项：自动清理时一天内写过的不碰；其余交给 Invoke-SafeRemove（调用前已经查过它和它的上级都不是链接）
function Remove-Path($it) {
    if ($script:autoMinAge) {
        # 文件夹的修改时间只看它自己这一层：里面深处正在写的文件不会让它变新，所以看整棵树里最近的一次
        $w = $it.LastWriteTime
        if ($it.PSIsContainer) { try { $nw = [FsTools]::NewestWrite($it.FullName); if ($nw -gt $w) { $w = $nw } } catch {} }
        if ($w -gt $script:autoMinAge) { return }
    }
    $how = if ($script:recycleNow) { 'recycle' } else { 'delete' }
    $r = Invoke-SafeRemove -Item $it -Scope list -How $how -Batch -NoLog -ParentChecked
    if ($r.Ok -or $r.Stage -eq 'fail') { return }   # 删不掉的多半是正被占用的临时文件，不一条条报
    if ($r.Stage -eq 'recycle') { $script:recycleRefused++; if ($script:recycleRefused -gt 20) { return } }
    Log ((T "  没删（{0}）：{1}") -f $r.Why, $it.FullName)
}
function Remove-Contents([string[]]$paths, [string]$filter, [bool]$wholeDir) {
    try { Remove-Contents2 $paths $filter $wholeDir } finally { Recycle-Flush }
}
# 一个文件夹里面的所有链接（目录联接、符号链接）只拆链接本身，不跟进去：自己一层层走，碰到重解析点就 rmdir 掉它
function Remove-LinksInside([string]$dir) {
    $n = 0
    $st = New-Object System.Collections.Generic.Stack[string]; $st.Push($dir)
    while ($st.Count -gt 0) {
        $d = $st.Pop()
        $subs = $null; try { $subs = [IO.Directory]::GetDirectories($d) } catch { continue }
        foreach ($s in $subs) {
            $a = $null; try { $a = [IO.File]::GetAttributes($s) } catch { continue }
            if (($a -band [IO.FileAttributes]::ReparsePoint) -ne 0) { if (Test-CmdPathOk $s) { & "$sys32\cmd.exe" /c rmdir "\\?\$s" 2>$null | Out-Null; $n++ } else { try { [IO.Directory]::Delete($s, $false); $n++ } catch {} } }
            else { $st.Push($s) }
        }
    }
    return $n
}
# 系统命令（takeown、chkdsk）问「是/否」时，「是」的字母随系统语言变（英文、中文是 Y，德文 J，法文 O……）。
# 从 takeown /? 里 /D 那一项的说明读：第一个用引号括起来的单个字母就是「是」。读不到用 Y
function Get-YesFromHelp([string]$txt) {
    if (-not $txt) { return '' }
    $seg = [regex]::Match($txt, '(?ms)^\s*/D\s.*?(?=^\s*/[A-Za-z?]|\z)').Value
    $m = [regex]::Matches($seg, '["\u201C\u201D\u201E\u00AB\u00BB\u2018\u2019'']\s*(\w)\s*["\u201C\u201D\u201E\u00AB\u00BB\u2018\u2019'']')
    if ($m.Count -ge 2) { return $m[0].Groups[1].Value.ToUpperInvariant() }
    return ''
}
$script:yesLetter = $null
function Get-YesLetter {
    if ($script:yesLetter) { return $script:yesLetter }
    $y = ''
    try { $y = Get-YesFromHelp ((& "$sys32\takeown.exe" /? 2>$null) -join "`n") } catch {}
    if (-not $y) { $y = 'Y' }
    $script:yesLetter = $y
    return $y
}
# Windows.old：里面 Users\<user>\Application Data 这类是指向当前系统活目录的绝对路径链接，Remove-Item -Recurse（PowerShell 5.1）和 icacls /T 会跟进去。
# 所以先把里面的链接全部拆掉，再夺权、再 rd（rd 对剩下的链接也只拆不跟）
function Remove-WindowsOld {
    $p = 'C:\Windows.old'
    if (-not (Test-Path -LiteralPath $p)) { return }
    if (IsLink $p) { Log (T '  C:\Windows.old 本身是链接，不删'); return }
    $links = Remove-LinksInside $p
    if ($links -gt 0) { Log ((T "  先拆掉了 Windows.old 里的 {0} 个链接（它们指向现在系统的文件夹，不能跟进去删）") -f $links) }
    & "$env:SystemRoot\System32\takeown.exe" /F $p /R /A /D (Get-YesLetter) /SKIPSL 2>$null | Out-Null
    $more = Remove-LinksInside $p
    if ($more -gt 0) { Log ((T "  夺权后又拆掉了 {0} 个链接") -f $more) }
    & "$env:SystemRoot\System32\icacls.exe" $p /grant *S-1-5-32-544:F /T /C /L /Q 2>$null | Out-Null   # 管理员组按 SID 写：组名随系统语言变
    [void](Remove-LinksInside $p)
    $r = Invoke-SafeRemove -Path $p -Scope list -How delete -What (T '旧系统 Windows.old')
    if (-not $r.Ok) { Log ((T "  Windows.old 没删干净：{0}") -f $r.Why) }
}
function Remove-Contents2([string[]]$paths, [string]$filter, [bool]$wholeDir) {
    $script:settingsBad = $false
    $ex = Get-ExcludeList
    if ($script:settingsBad) { Log ((T "  跳过（设置文件读不出来，不知道你排除了哪些文件夹）：{0}") -f ($paths -join (T '；'))); OpLog '删除' (T '跳过：设置文件读不出来') ($paths -join (T '；')) ''; return }
    $skipEx = { param($x) Log ((T "  跳过（在设置里排除了）：{0}") -f $x); OpLog '删除' (T '跳过：在设置里排除了') $x '' }
    foreach ($p in $paths) {
        if (Stopping) { return }
        foreach ($it in (Get-PathItems $p)) {
            if (Stopping) { return }
            if (Test-Personal $it.FullName) { Log ((T "  跳过（在个人文件夹里，不删）：{0}") -f $($it.FullName)); OpLog '删除' (T '跳过：在个人文件夹里，不删') $it.FullName ''; continue }
            if ($it.PSIsContainer -and ($it.Attributes -band [IO.FileAttributes]::ReparsePoint)) { Log ((T "  跳过（是链接，不跟进去删）：{0}") -f $($it.FullName)); continue }
            $la = Get-LinkedAncestor $it.FullName
            if ($la) { Log ((T "  跳过（上级文件夹 {0} 是链接，多半已经搬到其他盘，不跟进去删）：{1}") -f $la, $it.FullName); continue }
            if (Test-Excluded $it.FullName $ex) { & $skipEx $it.FullName; continue }
            if ($it.PSIsContainer) {
                if ($wholeDir) { if (Test-HasExcluded $it.FullName $ex) { & $skipEx $it.FullName } else { Remove-Path $it } }
                else {
                    $f = if ($filter) { $filter } else { '*' }
                    foreach ($c in @(Get-ChildItem -LiteralPath $it.FullName -Filter $f -Force -ErrorAction SilentlyContinue)) {
                        if (Stopping) { return }
                        if (Test-Personal $c.FullName) { continue }
                        if ((Test-Excluded $c.FullName $ex) -or ($c.PSIsContainer -and (Test-HasExcluded $c.FullName $ex))) { & $skipEx $c.FullName; continue }
                        Remove-Path $c
                    }
                }
            } else { Remove-Path $it }
        }
    }
}

# 聊天软件：P = 进程名（可带 *），K = 只在搬家时顺带关掉的后台进程，Dirs = 程序所在文件夹的特征（进程名对不上时按路径认）
function Get-ChatApps {
    @{
        '微信'     = @{ P = @('WeChat','Weixin','WeChatAppEx','WeChatOCR','WeChatPlayer','WeChatUtility','WeChatBrowser','wechatweb'); Dirs = @('\Tencent\WeChat\','\Tencent\Weixin\','\Tencent\xwechat\') }
        'QQ'       = @{ P = @('QQ','TIM'); K = @('QQProtect','TXPlatform'); Dirs = @('\Tencent\QQNT\','\Tencent\TIM\') }
        '企业微信' = @{ P = @('WXWork','WXWorkWeb','WXDrive'); Dirs = @('\WXWork\') }
        '腾讯会议' = @{ P = @('wemeetapp','WeMeet*'); Dirs = @('\WeMeet\') }
        '飞书'     = @{ P = @('Feishu*','Lark'); Dirs = @('\Feishu\','\LarkShell\','\Lark\') }
        '钉钉'     = @{ P = @('DingTalk*','DingDing*'); Dirs = @('\DingDing\','\DingTalk\') }
        'Telegram' = @{ P = @('Telegram'); Dirs = @('\Telegram Desktop\') }
        'Discord'  = @{ P = @('Discord','DiscordPTB','DiscordCanary'); Dirs = @("$env:LOCALAPPDATA\Discord\", "$env:LOCALAPPDATA\DiscordPTB\", "$env:LOCALAPPDATA\DiscordCanary\") }
        'Slack'    = @{ P = @('slack'); Dirs = @("$env:LOCALAPPDATA\slack\") }
        'Signal'   = @{ P = @('Signal'); Dirs = @("$env:LOCALAPPDATA\Programs\signal-desktop\") }
        'LINE'     = @{ P = @('LINE','LineLauncher','LineUpdater','LineMediaPlayer'); Dirs = @("$env:LOCALAPPDATA\LINE\bin\") }
        'Viber'    = @{ P = @('Viber'); Dirs = @("$env:LOCALAPPDATA\Viber\") }
        'KakaoTalk' = @{ P = @('KakaoTalk'); Dirs = @("${env:ProgramFiles(x86)}\Kakao\KakaoTalk\", "$env:ProgramFiles\Kakao\KakaoTalk\") }
        'Zoom'     = @{ P = @('Zoom','ZoomWebHost','zWebview2Agent','CptHost','Zoom_launcher'); Dirs = @("$env:APPDATA\Zoom\bin\", "$env:ProgramFiles\Zoom\bin\") }
        'Docker Desktop' = @{ P = @('Docker Desktop','com.docker.backend','com.docker.build','com.docker.dev-envs'); Dirs = @('\Docker\Docker\') }
        'VirtualBox' = @{ P = @('VirtualBox','VirtualBoxVM','VBoxHeadless','VBoxSVC'); Dirs = @('\Oracle\VirtualBox\') }
        'VMware'     = @{ P = @('vmware','vmware-vmx','vmplayer'); Dirs = @('\VMware Workstation\','\VMware Player\') }
        'Android 模拟器' = @{ P = @('qemu-system-*','emulator','emulator64-*'); Dirs = @('\Android\Sdk\emulator\') }
    }
}
# 某个进程的程序路径是否落在这些特征文件夹里
function PathHasAny([string]$path, $frags) {
    if (-not $path) { return $false }
    foreach ($f in $frags) { if ($path.IndexOf([string]$f, [StringComparison]::OrdinalIgnoreCase) -ge 0) { return $true } }
    return $false
}

# ---------- 缓存目录库 ----------
# 一行一条，字段用 | 隔开：名称 | 路径 | 说明 | 选项。加新条目只要在这里加一行，不用改代码。
#   路径：多个用 ; 隔开；可以用 %LOCALAPPDATA%、%APPDATA%、%PROGRAMDATA%、%TEMP%、%USERPROFILE%、%SYSTEMROOT%、%SYSTEMDRIVE% 这类变量，
#         以及 %STEAM%（Steam 的安装目录，从注册表查）；可以用 * 通配一层文件夹；@chromium:<User Data 目录> 展开成 Chromium 系浏览器的各个缓存目录
#   选项：filter=*.log（只删匹配的文件）  whole（整个文件夹删掉，不只是里面的东西）  confirm（放进「需确认」，默认跳过）  svc=服务,服务（删之前停掉、删完再启动）
#         pro / expert（只在「工程师」/「开发者和 IT」模式下显示；不写的普通用户也看得到）
#         careful（放进「清后要重建」：删了要重新下载或重新生成，默认也清，但单独成组、执行前单独列出来）
# 只删缓存：不碰 Cookie、历史记录、密码、设置和用户保存的数据。每一条的名称和说明都在翻译表里有英文
$script:cacheLib = @(
    '用户临时文件 | %TEMP% | 各软件运行时的临时文件，关掉软件就没用了'
    '系统临时文件 | %SYSTEMROOT%\Temp | 系统和安装程序的临时文件'
    'Windows 更新下载缓存 | %SYSTEMROOT%\SoftwareDistribution\Download | 已装完的更新安装包，下次更新会重新下载需要的部分 | svc=wuauserv,bits careful'
    '系统升级残留目录 | %SYSTEMDRIVE%\$WINDOWS.~BT;%SYSTEMDRIVE%\$WINDOWS.~WS;%SYSTEMDRIVE%\$GetCurrent | 大版本升级留下的临时目录 | whole'
    '磁盘检查残留 (found.000) | %SYSTEMDRIVE%\found.??? | 磁盘检查（chkdsk）修复时从损坏的文件里抢救出来的碎片，一般都没用；偶尔能从里面找回丢失的文件，删之前可以先打开看看 | whole confirm'
    '崩溃转储与错误报告 | %SYSTEMROOT%\Minidump;%SYSTEMROOT%\MEMORY.DMP;%SYSTEMROOT%\LiveKernelReports;%PROGRAMDATA%\Microsoft\Windows\WER;%LOCALAPPDATA%\Microsoft\Windows\WER;%LOCALAPPDATA%\CrashDumps | 蓝屏、驱动出错（显卡驱动重置等）和程序崩溃时留下的调试文件，只对排查问题的工程师有用'
    '系统组件日志 | %SYSTEMROOT%\Logs\CBS | Windows 更新的安装日志 | filter=*.log'
    'Windows 更新日志 | %SYSTEMROOT%\Logs\WindowsUpdate;%PROGRAMDATA%\USOShared\Logs | Windows 更新的跟踪日志（.etl）'
    '缩略图缓存 | %LOCALAPPDATA%\Microsoft\Windows\Explorer | 文件夹里图片的小预览图，打开文件夹时会重新生成 | filter=thumbcache_*.db careful'
    '系统网页缓存 (INetCache) | %LOCALAPPDATA%\Microsoft\Windows\INetCache\IE | Windows 组件和一些软件内嵌的网页浏览留下的缓存'
    '应用商店软件的临时文件 | %LOCALAPPDATA%\Packages\*\TempState;%LOCALAPPDATA%\Packages\*\AC\INetCache;%LOCALAPPDATA%\Packages\*\AC\Temp | 从应用商店装的软件的临时文件和网页缓存。不碰它们保存的数据和设置'
    '远程桌面位图缓存 | %LOCALAPPDATA%\Microsoft\Terminal Server Client\Cache | 远程桌面连接时缓存的画面碎片'
    'DirectX 着色器缓存 | %LOCALAPPDATA%\D3DSCache | Windows 给游戏和软件编译好的着色器，下次用到时会重新生成 | careful'
    'NVIDIA 安装包与着色器缓存 | %PROGRAMDATA%\NVIDIA Corporation\Downloader;%PROGRAMDATA%\NVIDIA Corporation\NV_Cache;%LOCALAPPDATA%\NVIDIA Corporation\NV_Cache;%LOCALAPPDATA%\NVIDIA\DXCache;%LOCALAPPDATA%\NVIDIA\GLCache;%LOCALAPPDATA%\NVIDIA\VkCache;%LOCALAPPDATA%\NVIDIA\OptixCache | 显卡驱动安装包和游戏着色器缓存，游戏首次启动会重建 | careful'
    'AMD 显卡着色器缓存 | %LOCALAPPDATA%\AMD\DxCache;%LOCALAPPDATA%\AMD\DxcCache;%LOCALAPPDATA%\AMD\GLCache;%LOCALAPPDATA%\AMD\VkCache | AMD 显卡给游戏编译的着色器缓存，游戏首次启动会重建 | careful'
    'Intel 显卡着色器缓存 | %LOCALAPPDATA%\Intel\ShaderCache;%PROGRAMDATA%\Intel\ShaderCache | 核显着色器缓存 | careful'
    'Chrome 浏览器缓存 | @chromium:%LOCALAPPDATA%\Google\Chrome\User Data | 网页缓存。请先关闭浏览器。不影响密码、书签、历史记录 | careful'
    'Edge 浏览器缓存 | @chromium:%LOCALAPPDATA%\Microsoft\Edge\User Data | 网页缓存。请先关闭浏览器。不影响密码、书签、历史记录 | careful'
    'Firefox 浏览器缓存 | %LOCALAPPDATA%\Mozilla\Firefox\Profiles\*\cache2;%LOCALAPPDATA%\Mozilla\Firefox\Profiles\*\startupCache;%LOCALAPPDATA%\Mozilla\Firefox\Profiles\*\shader-cache;%LOCALAPPDATA%\Mozilla\Firefox\Profiles\*\jumpListCache;%LOCALAPPDATA%\Mozilla\Firefox\Profiles\*\OfflineCache | 网页缓存。请先关闭浏览器。不影响密码、书签、历史记录 | careful'
    'Brave 浏览器缓存 | @chromium:%LOCALAPPDATA%\BraveSoftware\Brave-Browser\User Data | 网页缓存。请先关闭浏览器。不影响密码、书签、历史记录 | careful'
    'Vivaldi 浏览器缓存 | @chromium:%LOCALAPPDATA%\Vivaldi\User Data | 网页缓存。请先关闭浏览器。不影响密码、书签、历史记录 | careful'
    'Opera 浏览器缓存 | %LOCALAPPDATA%\Opera Software\Opera*Stable\Cache;%LOCALAPPDATA%\Opera Software\Opera*Stable\Code Cache;%LOCALAPPDATA%\Opera Software\Opera*Stable\GPUCache;%LOCALAPPDATA%\Opera Software\Opera*Stable\Service Worker\CacheStorage | 网页缓存（含 Opera GX）。请先关闭浏览器。不影响密码、书签、历史记录 | careful'
    'Chrome 测试版 / Chromium 缓存 | @chromium:%LOCALAPPDATA%\Google\Chrome Beta\User Data;@chromium:%LOCALAPPDATA%\Google\Chrome Dev\User Data;@chromium:%LOCALAPPDATA%\Google\Chrome SxS\User Data;@chromium:%LOCALAPPDATA%\Chromium\User Data | Chrome Beta、Dev、Canary 和 Chromium 的网页缓存。请先关闭浏览器 | careful'
    '360 浏览器缓存 | @chromium:%APPDATA%\360se6\User Data;@chromium:%LOCALAPPDATA%\360Chrome\Chrome\User Data;@chromium:%LOCALAPPDATA%\360ChromeX\Chrome\User Data | 360 安全浏览器和 360 极速浏览器的网页缓存。请先关闭浏览器。不影响密码、书签、历史记录 | careful'
    'QQ 浏览器缓存 | @chromium:%LOCALAPPDATA%\Tencent\QQBrowser\User Data | 网页缓存。请先关闭浏览器。不影响密码、书签、历史记录 | careful'
    'Steam 着色器与网页缓存 | %STEAM%\steamapps\shadercache;%STEAM%\appcache\httpcache;%STEAM%\dumps;%STEAM%\logs | 游戏的着色器缓存（首次启动会重建）、Steam 商店页面的缓存、崩溃转储和日志。请先退出 Steam。游戏本身不动 | careful'
    'Epic Games 启动器缓存 | %LOCALAPPDATA%\EpicGamesLauncher\Saved\webcache*;%LOCALAPPDATA%\EpicGamesLauncher\Saved\Logs | 启动器的网页缓存和日志。请先退出 Epic Games 启动器。游戏本身不动'
    'Unity 缓存 | %LOCALAPPDATA%\Unity\cache | Unity 编辑器的资源商店下载和全局光照缓存，需要时会重新下载或生成 | pro'
    'Adobe 媒体缓存 | %APPDATA%\Adobe\Common\Media Cache Files;%APPDATA%\Adobe\Common\Media Cache;%APPDATA%\Adobe\Common\Peak Files | Premiere、After Effects、Audition 导入素材时生成的缓存，打开项目会重新生成。请先关闭 Adobe 软件'
    'Microsoft Teams (旧版) 缓存 | %APPDATA%\Microsoft\Teams\Cache;%APPDATA%\Microsoft\Teams\Code Cache;%APPDATA%\Microsoft\Teams\GPUCache;%APPDATA%\Microsoft\Teams\Service Worker\CacheStorage;%APPDATA%\Microsoft\Teams\tmp | 旧版 Teams 的网页缓存。请先退出 Teams。不影响登录和聊天记录'
    'Discord 缓存 | %APPDATA%\discord\Cache;%APPDATA%\discord\Code Cache;%APPDATA%\discord\GPUCache | 看过的图片和视频的缓存。请先退出 Discord（包括托盘图标）。不影响登录'
    'Slack 缓存 | %APPDATA%\Slack\Cache;%APPDATA%\Slack\Code Cache;%APPDATA%\Slack\GPUCache;%APPDATA%\Slack\Service Worker\CacheStorage | 网页缓存和文件预览。请先退出 Slack。不影响登录'
    'VS Code 缓存 | %APPDATA%\Code\Cache;%APPDATA%\Code\CachedData;%APPDATA%\Code\Code Cache;%APPDATA%\Code\GPUCache;%APPDATA%\Code\CachedExtensionVSIXs;%APPDATA%\Code\logs | 编辑器的缓存、下载过的扩展安装包和日志。请先关闭 VS Code。不影响设置和扩展 | pro'
    'Cursor 缓存 | %APPDATA%\Cursor\Cache;%APPDATA%\Cursor\CachedData;%APPDATA%\Cursor\Code Cache;%APPDATA%\Cursor\GPUCache;%APPDATA%\Cursor\logs | 编辑器的缓存和日志。请先关闭 Cursor。不影响设置和扩展 | pro'
    'Cursor 状态库备份 | %APPDATA%\Cursor\User\globalStorage\state.vscdb.backup | Cursor 编辑器状态库的备份副本，主文件保留 | pro'
    'Spotify 缓存 | %LOCALAPPDATA%\Spotify\Data;%LOCALAPPDATA%\Spotify\Browser\Cache | 播放过的歌曲的缓存。下载供离线听的歌不在这里。请先退出 Spotify | careful'
    '网易云音乐缓存 | %LOCALAPPDATA%\NetEase\CloudMusic\Cache | 听过的歌的缓存。下载的歌不在这里。请先退出网易云音乐 | careful'
    'pip 缓存 | %LOCALAPPDATA%\pip\cache | Python 装包时下载的安装包副本，再装时会重新下载 | pro careful'
    'uv 缓存 | %LOCALAPPDATA%\uv\cache | uv 装 Python 包时的下载缓存，再装时会重新下载 | pro careful'
    'npm 缓存 | %LOCALAPPDATA%\npm-cache | Node.js 装包时的下载缓存 | pro careful'
    'Yarn 缓存 | %LOCALAPPDATA%\Yarn\Cache | Yarn 装包时的下载缓存 | pro careful'
    'NuGet 下载缓存 | %LOCALAPPDATA%\NuGet\v3-cache;%LOCALAPPDATA%\NuGet\http-cache;%LOCALAPPDATA%\NuGet\plugins-cache | .NET 装包时的下载缓存。项目用的包在全局包目录里，不在这里 | pro careful'
    'Go 编译缓存 | %LOCALAPPDATA%\go-build | Go 的编译结果缓存，下次编译会重新生成 | pro'
    'Rust crate 下载缓存 | %USERPROFILE%\.cargo\registry\cache | cargo 下载过的 crate 压缩包，需要时会重新下载 | pro careful'
    'Clash Verge 代理日志 | %APPDATA%\io.github.clash-verge-rev.clash-verge-rev\logs;%APPDATA%\clash-verge\logs;%LOCALAPPDATA%\io.github.clash-verge-rev.clash-verge-rev\logs | 代理软件的运行日志，会无限增长。建议在它设置里把日志等级改成 warn | pro'
    'Intel XTU 超频日志 | %PROGRAMDATA%\Intel\Intel Extreme Tuning Utility\Logs | Intel 超频组件的日志，会无限增长 | pro'
    'Apple 设备系统更新包 | %PROGRAMDATA%\Apple\AMPDevicesAgent\*-Temporary-Files;%APPDATA%\Apple Computer\iTunes\*Software Updates | 给 iPhone/iPad 升级时下载的固件，装完就没用了'
    'Dell 更新程序缓存 | %PROGRAMDATA%\Dell\DTP;%PROGRAMDATA%\Dell\SupportAssist | 戴尔驱动更新工具下载的安装包'
    '罗技 Options+ 缓存 | %PROGRAMDATA%\LogiOptionsPlus\cache;%PROGRAMDATA%\LogiOptionsPlus\depots | 罗技驱动的更新包缓存'
    '驱动安装包解压残留 | %SYSTEMDRIVE%\NVIDIA;%SYSTEMDRIVE%\AMD;%SYSTEMDRIVE%\Intel;%SYSTEMDRIVE%\SWSetup;%SYSTEMDRIVE%\Drivers;%SYSTEMDRIVE%\Dell\Drivers | 显卡驱动和品牌机驱动安装时解压到 C 盘根目录的文件，装完就没用了。以后要重装驱动再下载一次即可 | confirm pro'
    'NI 安装包缓存 | %PROGRAMDATA%\National Instruments\MDF\ProductCache;%PROGRAMDATA%\National Instruments\NI Package Manager\packages | LabVIEW 等 NI 软件的安装媒体缓存。软件本身不受影响；以后修复或重装时需重新下载 | confirm expert'
    'NuGet 全局包目录 | %USERPROFILE%\.nuget\packages | .NET 项目引用的包都放在这里。删了以后打开项目要联网重新还原（Visual Studio 会自动做，但要等一会儿） | confirm expert'
    'Gradle 依赖缓存 | %USERPROFILE%\.gradle\caches | Android Studio 和 Gradle 项目下载的依赖。删了下次构建要重新下载，国内网络可能很慢 | confirm expert'
    'Maven 本地仓库 | %USERPROFILE%\.m2\repository | Maven 项目下载的依赖。删了下次构建要重新下载 | confirm expert'
    'JetBrains IDE 缓存和索引 | %LOCALAPPDATA%\JetBrains\*\caches;%LOCALAPPDATA%\JetBrains\*\index | IntelliJ IDEA、PyCharm 等的缓存和代码索引。删了打开项目要重新索引（几分钟）。请先关闭这些 IDE | confirm expert'
    '虚幻引擎派生数据缓存 | %LOCALAPPDATA%\UnrealEngine\Common\DerivedDataCache | Unreal Engine 给项目生成的派生数据，常有几十 GB。删了打开项目要重新生成，很慢 | confirm expert'
)
function Get-SteamPath {
    try { $p = [string](Get-ItemProperty 'HKCU:\Software\Valve\Steam' -EA SilentlyContinue).SteamPath; if ($p) { return $p.Replace('/', '\').TrimEnd('\') } } catch {}
    return ''
}
# 按路径拿到文件或文件夹。只有路径里有 * 或 ? 才当通配符；[ ] 和 ` 都当普通字符（PowerShell 默认把 [ ] 当字符集，
# 用户名是 a[1] 时 C:\Users\a[1]\... 会匹配到 C:\Users\a1\...，也就是别的账户的文件）
function Get-PathItems([string]$p) {
    if (-not $p) { return @() }
    if ($p.IndexOfAny([char[]]'*?') -lt 0) { return @(Get-Item -LiteralPath $p -Force -ErrorAction SilentlyContinue) }
    return @(Get-Item -Path ($p -replace '([\[\]`])', '`$1') -Force -ErrorAction SilentlyContinue)
}
# %TEMP% 指的地方能不能当临时文件夹清：Windows 默认的（用户目录里的 AppData\Local\Temp，远程桌面会话下面还有一层编号）、
# 系统的 Windows\Temp，或者本工具建的（里面有 .cleanc-temp 标记）。别的（比如被改到 D:\Temp、D:\Work）一律不清：那可能是用户自己的文件夹
function Test-TempOk([string]$x) {
    $t = $x.TrimEnd('\', '/')
    if (-not $t) { return $false }
    $sep = [IO.Path]::DirectorySeparatorChar
    $t = [FsTools]::LongPath($t)   # %TEMP% 常常是 8.3 短路径（C:\Users\RUNNER~1\...），先换成长路径再比
    foreach ($base in @($(if ($env:USERPROFILE) { Join-Path $env:USERPROFILE ('AppData' + $sep + 'Local' + $sep + 'Temp') }), $(if ($env:SystemRoot) { Join-Path $env:SystemRoot 'Temp' }))) {
        if (-not $base) { continue }
        $b = ([FsTools]::LongPath($base)).TrimEnd('\', '/')
        if ($t -ieq $b -or $t.StartsWith($b + $sep, [StringComparison]::OrdinalIgnoreCase)) { return $true }
    }
    return (Test-Path -LiteralPath (Join-Path $t '.cleanc-temp'))
}
function Expand-LibPath([string]$p) {
    $p = $p.Trim()
    if ($p.StartsWith('@chromium:')) {
        $out = @()
        foreach ($base in (Expand-LibPath $p.Substring(10))) {
            $out += @("$base\*\Cache", "$base\*\Code Cache", "$base\*\GPUCache", "$base\*\Service Worker\CacheStorage", "$base\*\Service Worker\ScriptCache", "$base\GrShaderCache", "$base\ShaderCache", "$base\DawnCache", "$base\DawnGraphiteCache", "$base\DawnWebGPUCache")
        }
        return ,$out
    }
    $i = $p.IndexOf('%STEAM%', [StringComparison]::OrdinalIgnoreCase)
    if ($i -ge 0) { $s = Get-SteamPath; if (-not $s) { return ,@() }; $p = $p.Substring(0, $i) + $s + $p.Substring($i + 7) }
    $x = [Environment]::ExpandEnvironmentVariables($p)
    if ($p -match '(?i)%TE?MP%' -and $x -notmatch '%' -and -not (Test-TempOk $x)) { return ,@() }
    return ,@($x)
}
function Get-CacheLibrary {
    $out = @()
    foreach ($line in $script:cacheLib) {
        $l = $line.Trim()
        if (-not $l -or $l.StartsWith('#')) { continue }
        $f = $l.Split('|')
        if ($f.Count -lt 3) { continue }
        $paths = @()
        foreach ($p in $f[1].Split(';')) { if ($p.Trim()) { $paths += Expand-LibPath $p } }
        $x = @{ N = (T $f[0].Trim()); Note = (T $f[2].Trim()); Paths = $paths; Confirm = $false; Whole = $false; Filter = ''; Svc = $null; Lvl = 0; Careful = $false }
        if ($f.Count -gt 3) {
            foreach ($o in $f[3].Trim().Split(' ')) {
                $o = $o.Trim(); if (-not $o) { continue }
                if ($o -eq 'whole') { $x.Whole = $true }
                elseif ($o -eq 'confirm') { $x.Confirm = $true }
                elseif ($o.StartsWith('filter=')) { $x.Filter = $o.Substring(7) }
                elseif ($o.StartsWith('svc=')) { $x.Svc = @($o.Substring(4).Split(',') | Where-Object { $_ }) }
                elseif ($o -eq 'pro') { $x.Lvl = 1 }
                elseif ($o -eq 'careful') { $x.Careful = $true }
                elseif ($o -eq 'expert') { $x.Lvl = 2 }
            }
        }
        $out += $x
    }
    return ,$out
}
# Windows Installer 留下的孤儿安装包：C:\Windows\Installer 里没有任何已装软件、补丁再引用的 .msi / .msp
# 判断标准和 PatchCleaner 一样：注册表里每个产品、每个补丁登记的 LocalPackage，再用 Windows Installer 自己的接口问一遍。一个引用都没读到就不敢判断，返回空
# 驱动存储里的旧版驱动包：同一个 inf（原始名）、同一厂商、同一类别有更新版本的那些；启动必需的、系统自带的不算
function Select-OldDrivers($drivers) {
    $groups = @{}
    foreach ($d in $drivers) {
        if (-not $d.Driver -or $d.Inbox -or $d.BootCritical) { continue }
        $orig = ([string]$d.OriginalFileName) -replace '^.*[\\/]', ''
        if (-not $orig) { continue }
        $k = ($orig + '|' + [string]$d.ProviderName + '|' + [string]$d.ClassName).ToLowerInvariant()
        if (-not $groups.ContainsKey($k)) { $groups[$k] = New-Object System.Collections.ArrayList }
        [void]$groups[$k].Add($d)
    }
    $old = @()
    foreach ($g in $groups.Values) {
        if ($g.Count -lt 2) { continue }
        $ver = { param($x) $v = $null; if ([version]::TryParse([string]$x.Version, [ref]$v)) { $v } else { [version]'0.0' } }
        $sorted = @($g | Sort-Object { & $ver $_ }, { $_.Date } -Descending)
        foreach ($d in @($sorted | Select-Object -Skip 1)) { $old += $d }
    }
    return $old
}
function Get-OldDriverPackages([switch]$Fresh) {
    # 问 DISM 要好几秒：同一次打开程序里，驱动包没变（C:\Windows\INF 里的 oem*.inf 一个没多、没少、没改）就用上次问到的，半小时内有效。删除时（-Fresh）每次现问
    $sig = ''
    try { $sig = ((@([IO.Directory]::GetFiles((Join-Path $env:SystemRoot 'INF'), 'oem*.inf')) | Sort-Object | ForEach-Object { $_ + '=' + [IO.File]::GetLastWriteTimeUtc($_).Ticks }) -join '|') } catch { $sig = '' }
    if (-not $Fresh -and $sig) {
        $c = [AppDomain]::CurrentDomain.GetData('ClearC.OldDrivers')
        if ($c -and $c.Sig -eq $sig -and ((Get-Date) - $c.At).TotalMinutes -lt 30) { return @($c.List) }
    }
    $drivers = $null
    try { Import-Module Dism -ErrorAction Stop; $drivers = @(Get-WindowsDriver -Online -ErrorAction Stop) } catch { return @() }
    $out = @()
    foreach ($d in (Select-OldDrivers $drivers)) {
        $dir = Split-Path ([string]$d.OriginalFileName) -Parent
        $bytes = [double]0
        if ($dir -and (Test-Path -LiteralPath $dir)) { try { $bytes = [double][FsTools]::OnDiskTree($dir) } catch { $bytes = 0 } }
        $out += @{ Published = [string]$d.Driver; Original = (([string]$d.OriginalFileName) -replace '^.*[\\/]', ''); Provider = [string]$d.ProviderName; Class = [string]$d.ClassName; Version = [string]$d.Version; Dir = $dir; Bytes = $bytes }
    }
    if ($sig) { [AppDomain]::CurrentDomain.SetData('ClearC.OldDrivers', @{ Sig = $sig; At = (Get-Date); List = @($out) }) }
    return $out
}
# 用 pnputil 删一个驱动包（不加 /force：正在用的删不掉）。返回空表示成功
function Remove-DriverPackage([string]$published) {
    if ($published -notmatch '^oem\d+\.inf$') { return (T '不是 oem 驱动包') }
    try {
        $o = & "$env:SystemRoot\System32\pnputil.exe" /delete-driver $published 2>&1 | Out-String
        if ($LASTEXITCODE -eq 0) { return '' }
        return ($o -replace '\s+', ' ').Trim()
    } catch { return $_.Exception.Message }
}
function Get-InstallerOrphans {
    $dir = Join-Path $env:SystemRoot 'Installer'
    $files = @(Get-ChildItem -LiteralPath $dir -File -Force -ErrorAction SilentlyContinue | Where-Object { $_.Extension -match '^\.(msi|msp)$' })
    if ($files.Count -eq 0) { return @() }
    $used = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    # 注册表里每个产品、每个补丁登记的 LocalPackage，再用 Windows Installer 自己的接口问一遍（都在 InstallerRefs 里一次问完）
    foreach ($v in @([InstallerRefs]::FromRegistry())) { if ($v) { [void]$used.Add([string]$v) } }
    $fromReg = $used.Count
    if ($fromReg -eq 0) { return @() }
    $viaApi = [InstallerRefs]::FromInstaller()
    if ($null -eq $viaApi) { return @() }   # 接口读不了：只靠注册表可能漏掉还在用的安装包，宁可不判断
    foreach ($v in @($viaApi)) { if ($v) { [void]$used.Add([string]$v) } }
    if ($used.Count -eq 0) { return @() }
    $out = @()
    $recent = (Get-Date).AddDays(-1)
    foreach ($f in $files) {
        if ($used.Contains($f.Name)) { continue }
        if ($f.LastWriteTime -gt $recent) { continue }   # 刚装的软件，登记可能还没写完
        $out += $f
    }
    return $out
}

# ---------- 开始菜单里失效的快捷方式（只看公共和当前用户的开始菜单，不碰桌面）----------
function Get-BrokenShortcuts {
    $out = @()
    $sh = $null
    try { $sh = New-Object -ComObject WScript.Shell } catch { return @() }
    foreach ($base in @("$env:ProgramData\Microsoft\Windows\Start Menu", "$env:APPDATA\Microsoft\Windows\Start Menu")) {
        foreach ($f in @(Get-ChildItem -LiteralPath $base -Filter '*.lnk' -File -Recurse -Force -ErrorAction SilentlyContinue)) {
            try {
                $lnk = $sh.CreateShortcut($f.FullName)
                $t = [string]$lnk.TargetPath
                if (-not $t) { continue }                                   # 应用商店、MSI 广告式快捷方式没有普通目标，不判断
                $t = [Environment]::ExpandEnvironmentVariables($t)
                if ($t -notmatch '^[A-Za-z]:\\') { continue }               # 网络路径、特殊目标不判断
                $drv = $t.Substring(0, 3)
                if (-not (Test-Path -LiteralPath $drv)) { continue }       # 盘没插着，不算失效
                if (Test-Path -LiteralPath $t) { continue }
                if (Get-LinkedAncestor $t) { continue }                     # 在搬走了的文件夹里（链接指的那块盘可能没插着），不算失效
                $out += $f
            } catch {}
        }
    }
    return $out
}
# ---------- OneDrive：本地留着副本的文件改成「仅在线」，文件还在云端，本地不占空间 ----------
function Get-OneDriveFolders {
    $out = @()
    foreach ($k in @(Get-ChildItem 'HKCU:\Software\Microsoft\OneDrive\Accounts' -ErrorAction SilentlyContinue)) {
        $p = [string](Get-ItemProperty -LiteralPath $k.PSPath -ErrorAction SilentlyContinue).UserFolder
        if ($p -and (Test-Path -LiteralPath $p) -and ($out -notcontains $p.TrimEnd('\'))) { $out += $p.TrimEnd('\') }
    }
    if ($env:OneDrive -and (Test-Path -LiteralPath $env:OneDrive) -and ($out -notcontains $env:OneDrive.TrimEnd('\'))) { $out += $env:OneDrive.TrimEnd('\') }
    return $out
}
# 本地有副本 = 没有「访问时下载」属性（0x400000）；pinned（0x80000）= 用户设了「始终保留在此设备」，不动
function Get-OneDriveInfo {
    $r = @{ Folders = @(Get-OneDriveFolders); Files = 0; Local = [double]0; Pinned = [double]0; Online = [double]0; Running = $false }
    try { $r.Running = @(Get-Process -Name OneDrive -ErrorAction SilentlyContinue).Count -gt 0 } catch {}
    foreach ($d in $r.Folders) {
        foreach ($f in @([IO.Directory]::EnumerateFiles($d, '*', [IO.SearchOption]::AllDirectories))) {
            if (Stopping) { break }
            try {
                $fi = New-Object IO.FileInfo $f
                $a = [int]$fi.Attributes
                # 链接不算；OneDrive「按需下载」的文件也带重解析点（云端类型），那些要算
                if (($a -band 0x400) -and -not [FsTools]::IsCloudTag([FsTools]::ReparseTag($f))) { continue }
                $r.Files++
                if ($a -band 0x400000) { $r.Online += $fi.Length }
                elseif ($a -band 0x80000) { $r.Pinned += $fi.Length }
                else { $r.Local += $fi.Length }
            } catch {}
        }
    }
    return $r
}
function Invoke-OneDriveFree($res) {
    $res.Done = 0; $res.Bytes = [double]0; $res.Fail = 0
    foreach ($d in (Get-OneDriveFolders)) {
        foreach ($f in @([IO.Directory]::EnumerateFiles($d, '*', [IO.SearchOption]::AllDirectories))) {
            if (Stopping) { return }
            try {
                $fi = New-Object IO.FileInfo $f
                $a = [int]$fi.Attributes
                if (($a -band 0x400000) -or ($a -band 0x80000)) { continue }   # 已经只在云端，或者设了「始终保留在此设备」
                if (($a -band 0x400) -and -not [FsTools]::IsCloudTag([FsTools]::ReparseTag($f))) { continue }   # 链接不动；云端类型的重解析点是 OneDrive 自己的文件
                [IO.File]::SetAttributes($f, [IO.FileAttributes]($a -bor 0x100000))   # +U：告诉 OneDrive 这个文件只要留在云端
                $res.Done++; $res.Bytes += $fi.Length
            } catch { $res.Fail++ }
        }
    }
}
# ---------- Windows 保留的存储（给更新预留的几个 GB）----------
function Get-ReservedStorageState {
    try { $s = Get-WindowsReservedStorageState -ErrorAction Stop; return [string]$s.ReservedStorageState } catch {}
    try {
        $o = (& "$sys32\Dism.exe" /Online /Get-ReservedStorageState 2>&1 | Out-String)
        if ($o -match '(?i)disabled|已禁用|未启用') { return 'Disabled' }
        if ($o -match '(?i)enabled|已启用') { return 'Enabled' }
    } catch {}
    return ''
}
function Set-ReservedStorage([bool]$on) {
    try { Set-WindowsReservedStorageState -State $(if ($on) { 'Enabled' } else { 'Disabled' }) -ErrorAction Stop | Out-Null; return '' }
    catch { $m = $_.Exception.Message }
    $o = (& "$sys32\Dism.exe" /Online /Set-ReservedStorageState /State:$(if ($on) { 'Enabled' } else { 'Disabled' }) 2>&1 | Out-String)
    if ($LASTEXITCODE -eq 0) { return '' }
    return ($m + "`n" + $o).Trim()
}
# ---------- 组件存储（WinSxS）分析：DISM 报告实际大小、可回收多少、建不建议清理。各行的顺序固定，按顺序取值，不依赖语言 ----------
function Get-ComponentStoreInfo {
    $o = (& "$sys32\Dism.exe" /Online /Cleanup-Image /AnalyzeComponentStore 2>&1 | Out-String)
    return (ConvertFrom-DismAnalyze $o)
}
function ConvertFrom-DismAnalyze([string]$o) {
    $vals = @()
    foreach ($l in ($o -split "`r?`n")) {
        $i = $l.IndexOf(':')
        if ($i -gt 0 -and $l.Trim() -notmatch '^(Deployment|Version|Image Version|映像版本|部署映像)' -and $l -notmatch '^\s*$') { $vals += $l.Substring($i + 1).Trim() }
    }
    # 顺序：资源管理器报告的大小、实际大小、与 Windows 共享、备份和已禁用的功能、缓存和临时数据、上次清理日期、可回收的包、是否建议清理
    if ($vals.Count -lt 8) { return @{ Ok = $false; Out = $o } }
    $n = $vals.Count
    return @{ Ok = $true; Reported = $vals[$n - 8]; Actual = $vals[$n - 7]; Shared = $vals[$n - 6]; Backups = $vals[$n - 5]; Cache = $vals[$n - 4]; LastCleanup = $vals[$n - 3]; Reclaimable = $vals[$n - 2]; Recommended = $vals[$n - 1]; Out = $o }
}
# ---------- 蓝屏转储的类型：0 不保存  1 完整内存  2 内核  3 小转储(256 KB)  7 自动 ----------
function Get-CrashDumpMode { try { return [int](Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\CrashControl' -ErrorAction Stop).CrashDumpEnabled } catch { return -1 } }
function Set-CrashDumpMode([int]$mode) { Set-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\CrashControl' -Name CrashDumpEnabled -Value $mode -Type DWord -ErrorAction Stop }
# ---------- 当前用户的临时文件夹位置（TEMP / TMP 环境变量）----------
function Get-UserTemp { try { return [string](Get-ItemProperty 'HKCU:\Environment' -ErrorAction Stop).TEMP } catch { return '' } }
function Set-UserTemp([string]$path) {
    $v = if ($path) { $path } else { '%USERPROFILE%\AppData\Local\Temp' }
    foreach ($n in 'TEMP', 'TMP') { Set-ItemProperty 'HKCU:\Environment' -Name $n -Value $v -Type ExpandString -ErrorAction Stop }
    # 通知正在运行的程序环境变量变了（新开的程序才会用新位置）
    try {
        if (-not ('EnvNotify' -as [type])) { Add-Type -Namespace Win32 -Name EnvNotify -MemberDefinition '[DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Auto)] public static extern IntPtr SendMessageTimeout(IntPtr hWnd, uint Msg, UIntPtr wParam, string lParam, uint fuFlags, uint uTimeout, out UIntPtr lpdwResult);' }
        $r = [UIntPtr]::Zero; [void][Win32.EnvNotify]::SendMessageTimeout([IntPtr]0xffff, 0x1A, [UIntPtr]::Zero, 'Environment', 2, 2000, [ref]$r)
    } catch {}
}
# ---------- 磁盘健康：SSD 的磨损、温度、通电时间（只读）----------
# 返回 @{ Ok; Model; Media; Health（Healthy / Warning / …）; Wear（-1 = 不知道）; Temp（0 = 不知道）; Hours; ReadErrors }
function Get-DiskHealthInfo([string]$drive) {
    $r = @{ Ok = $false; Model = ''; Media = ''; Health = ''; Wear = -1; Temp = 0; Hours = [long]0; ReadErrors = [long]0 }
    try {
        $letter = $drive.Substring(0, 1)
        $part = @(Get-Partition -DriveLetter $letter -ErrorAction Stop)[0]
        if ($part) {
            $pd = @(Get-PhysicalDisk -ErrorAction Stop | Where-Object { [string]$_.DeviceId -eq [string]$part.DiskNumber })[0]
            if ($pd) {
                $r.Ok = $true
                $r.Model = ([string]$pd.FriendlyName).Trim()
                $mt = [string]$pd.MediaType; if ($mt -and $mt -ne 'Unspecified') { $r.Media = $mt }
                $r.Health = [string]$pd.HealthStatus
                try {
                    $rc = $pd | Get-StorageReliabilityCounter -ErrorAction Stop
                    if ($rc) {
                        if ($rc.Wear -ne $null -and [int]$rc.Wear -ge 0) { $r.Wear = [int]$rc.Wear }
                        if ($rc.Temperature -and [int]$rc.Temperature -ge 5) { $r.Temp = [int]$rc.Temperature }   # RST 这类控制器会报 0、1，不当真
                        if ($rc.PowerOnHours -and [long]$rc.PowerOnHours -gt 0) { $r.Hours = [long]$rc.PowerOnHours }
                        if ($rc.ReadErrorsTotal -and [long]$rc.ReadErrorsTotal -gt 0) { $r.ReadErrors = [long]$rc.ReadErrorsTotal }
                    }
                } catch {}
                return $r
            }
        }
    } catch {}
    # 存储模块不可用时退回 WMI：只有型号和状态
    try {
        $ld = Get-CimInstance -ClassName Win32_LogicalDisk -Filter ("DeviceID='{0}'" -f $drive.Substring(0, 2)) -ErrorAction Stop
        foreach ($pt in @(Get-CimAssociatedInstance -InputObject $ld -ResultClassName Win32_DiskPartition -ErrorAction Stop)) {
            foreach ($dd in @(Get-CimAssociatedInstance -InputObject $pt -ResultClassName Win32_DiskDrive -ErrorAction Stop)) {
                $r.Ok = $true; $r.Model = ([string]$dd.Model).Trim(); $r.Health = $(if ([string]$dd.Status -eq 'OK') { 'Healthy' } else { [string]$dd.Status })
                return $r
            }
        }
    } catch {}
    return $r
}
function Get-DiskHealth([string]$drive) {
    $h = Get-DiskHealthInfo $drive
    if (-not $h.Ok) { return '' }
    $parts = @()
    if ($h.Model) { $parts += $h.Model }
    if ($h.Media) { $parts += $h.Media }
    if ($h.Health) { $parts += $(if ($h.Health -eq 'Healthy') { (T '健康状态正常') } else { ((T "健康状态：{0}") -f $h.Health) }) }
    if ($h.Wear -ge 0) { $parts += ((T "已磨损 {0}%") -f $h.Wear) }
    if ($h.Temp -gt 0) { $parts += ((T "{0} °C") -f $h.Temp) }
    if ($h.Hours -gt 0) { $parts += ((T "通电 {0:N0} 小时") -f $h.Hours) }
    if ($h.ReadErrors -gt 0) { $parts += ((T "读错误 {0:N0} 次") -f $h.ReadErrors) }
    return ($parts -join ' · ')
}
# ---------- Windows 自带的「存储感知」开没开 ----------
function Get-StorageSenseOn { try { return ([int](Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\StorageSense\Parameters\StoragePolicy' -ErrorAction Stop).'01' -eq 1) } catch { return $false } }
# ---------- 已卸载软件可能留下的文件夹：名字对不上任何已装软件、没有程序在用、很久没动过 ----------
function Get-OrphanFolders($apps, $tree = $null) {
    $norm = { param($x) (([string]$x).ToLowerInvariant() -replace '[^\p{L}\p{N}]', '') }
    $tokens = New-Object System.Collections.Generic.List[string]
    $locs = @()
    foreach ($a in @($apps)) {
        foreach ($n in @($a.Name, $a.Publisher)) { $t = & $norm $n; if ($t.Length -ge 3) { $tokens.Add($t) } }
        $l = ([string]$a.Location).TrimEnd('\'); if ($l -and $l.Length -gt 3) { $locs += $l }
    }
    $procDirs = @()
    foreach ($p in @(Get-Process -ErrorAction SilentlyContinue)) { try { if ($p.Path) { $procDirs += (Split-Path $p.Path -Parent) } } catch {} }
    $procDirs = @($procDirs | Select-Object -Unique)
    # Windows 和常见组件自己的文件夹，以及发行商的总文件夹：不当残留
    $known = @('Microsoft','Packages','Temp','Comms','ConnectedDevicesPlatform','D3DSCache','PeerDistRepub','Publishers','VirtualStore','PlaceholderTileLogoFolder','TileDataLayer','CrashDumps','IconCache','OneDrive','Programs','Apps',
        'Application Data','History','Temporary Internet Files','Microsoft Help','Intel','NVIDIA','AMD','NVIDIA Corporation','Package Cache','ssh','USOPrivate','USOShared','SoftwareDistribution','Windows','WindowsHolographicDevices',
        'Diagnostics','Desktop','Start Menu','Templates','Documents','Favorites','DSS','dotnet','Common Files','WindowsApps','ModifiableWindowsApps','Windows Defender','Windows Defender Advanced Threat Protection','Windows Mail',
        'Windows Media Player','Windows Multimedia Platform','Windows NT','Windows Photo Viewer','Windows Portable Devices','Windows Security','Windows Sidebar','Internet Explorer','MSBuild','Reference Assemblies','Uninstall Information',
        'regid.1991-06.com.microsoft','Tencent','Google','Adobe','Apple','Mozilla','Oracle','Java','Python','Steam','Autodesk','Realtek','Logitech','Razer','Samsung','Lenovo','Dell','HP','ASUS','Acer','Huawei','Xiaomi','JetBrains','Unity','Epic Games',
        'CleanC','cache','Cache','Logs','log','logs','Local','LocalLow','Roaming','Default','Public','All Users','Default User','.cache','.config','.local','go-build','npm-cache','pip','uv','Yarn','NuGet','pnpm','Docker','docker','WSL','Lxss',
        'Spotify','Discord','slack','Code','Cursor','Zoom','Notion','Figma','Postman','Obsidian','Typora','Telegram Desktop','ViberPC','Signal','LINE','Kakao','DingTalk','DingDing','Feishu','LarkShell','WXWork','WeMeet','xwechat_files','WeChat Files','Tencent Files','CDriveMoved')
    $bases = @($env:LOCALAPPDATA, $env:APPDATA, "$env:USERPROFILE\AppData\LocalLow", "$env:SystemDrive\ProgramData", "$env:SystemDrive\Program Files", "$env:SystemDrive\Program Files (x86)", "$env:LOCALAPPDATA\Programs")
    $cut = (Get-Date).AddDays(-30)
    $out = @()
    foreach ($b in $bases) {
        foreach ($d in @(Get-ChildItem -LiteralPath $b -Directory -Force -ErrorAction SilentlyContinue)) {
            if (Stopping) { return $out }
            $name = $d.Name
            if ($known -contains $name -or $name.StartsWith('.') -or $name -like 'Microsoft*' -or $name -like 'Windows*' -or $name -like '{*}') { continue }
            if (IsLink $d.FullName) { continue }
            if ($d.LastWriteTime -gt $cut) { continue }
            $nn = & $norm $name
            if ($nn.Length -lt 3) { continue }
            $hit = $false
            foreach ($t in $tokens) { if ($nn -eq $t -or ($nn.Length -ge 4 -and $t.Contains($nn)) -or ($t.Length -ge 4 -and $nn.Contains($t))) { $hit = $true; break } }
            if ($hit) { continue }
            $full = $d.FullName.TrimEnd('\')
            foreach ($l in $locs) { if ($l -ieq $full -or $l.StartsWith("$full\", [StringComparison]::OrdinalIgnoreCase) -or $full.StartsWith("$l\", [StringComparison]::OrdinalIgnoreCase)) { $hit = $true; break } }
            if ($hit) { continue }
            foreach ($pdir in $procDirs) { if ($pdir -ieq $full -or $pdir.StartsWith("$full\", [StringComparison]::OrdinalIgnoreCase)) { $hit = $true; break } }
            if ($hit) { continue }
            if (Get-DeleteBlock $full -Leftover) { continue }
            # 里面最近改过的文件也算在用（LastWriteTime 只看文件夹本身）。C 盘的文件表在手上就直接查（里面每个文件都看到了，也不用再逐个统计大小）
            $newest = $d.LastWriteTime
            $node = $null; if ($tree) { try { $node = [DiskMap]::Find($tree, $full) } catch { $node = $null } }
            if ($node -and -not $node.IsLink) {
                if ($node.LastWrite -gt 0) { try { $nw = [DateTime]::FromFileTime([long]$node.LastWrite); if ($nw -gt $newest) { $newest = $nw } } catch {} }
                if ($newest -gt $cut) { continue }
                $bytes = [double]$node.Size
            } else {
                try { foreach ($f in @(Get-ChildItem -LiteralPath $full -Recurse -File -Force -ErrorAction SilentlyContinue | Select-Object -First 400)) { if ($f.LastWriteTime -gt $newest) { $newest = $f.LastWriteTime } } } catch {}
                if ($newest -gt $cut) { continue }
                $bytes = [double](DirBytes $full)
            }
            if ($bytes -lt 1MB) { continue }
            $out += @{ Path = $full; Bytes = $bytes; Modified = $newest }
        }
    }
    return $out
}

# 使用模式：0 普通用户  1 工程师  2 开发者和 IT。目录项的 Lvl 比当前模式高就不在清理页列出（自动清理不受影响）
function Get-Mode { switch ((Get-Setting 'Mode' 'basic')) { 'pro' { 1 } 'expert' { 2 } default { 0 } } }
# ==================== 系统健康：硬件、启动、蓝屏、事件 ====================
# 原则：读不到的就明说「读不到」，不拿估算冒充实测。每一项都是 @{ ... Ok = $true/$false; Why = '为什么读不到' }
function Try-Cim([string]$class, [string]$ns = 'root\cimv2', [string]$filter = '') {
    try {
        if ($filter) { return @(Get-CimInstance -ClassName $class -Namespace $ns -Filter $filter -ErrorAction Stop -OperationTimeoutSec 20) }
        return @(Get-CimInstance -ClassName $class -Namespace $ns -ErrorAction Stop -OperationTimeoutSec 20)
    } catch { return @() }
}
function Try-Counter([string[]]$paths, [int]$samples = 1) {
    try { return (Get-Counter -Counter $paths -SampleInterval 1 -MaxSamples $samples -ErrorAction Stop).CounterSamples } catch { return @() }
}
# CPU：型号、核心数、负载、当前频率和最高频率（降频看得出来）、温度（主板不报就读不到）
function Get-CpuHealth {
    $r = @{ Ok = $false; Name = ''; Cores = 0; Threads = 0; Load = -1; MHz = 0; MaxMHz = 0; Perf = -1; Temp = $null; TempWhy = ''; Throttle = $false }
    $cpu = @(Try-Cim 'Win32_Processor')
    if ($cpu.Count -eq 0) { $r.Why = (T '读不到处理器信息（WMI）'); return $r }
    $c = $cpu[0]
    $r.Name = ([string]$c.Name).Trim(); $r.Cores = [int]$c.NumberOfCores; $r.Threads = [int]$c.NumberOfLogicalProcessors
    $r.MHz = [int]$c.CurrentClockSpeed; $r.MaxMHz = [int]$c.MaxClockSpeed; $r.Load = [int]$c.LoadPercentage
    # 「处理器性能」计数器：100% 是标称频率；持续明显低于 100% 又不是空闲，就是被限制了（散热、电源）
    $s = @(Try-Counter @('\Processor Information(_Total)\% Processor Performance', '\Processor Information(_Total)\% Processor Utility') 2)
    $perf = @($s | Where-Object { $_.Path -like '*Processor Performance*' } | Select-Object -Last 1)
    $util = @($s | Where-Object { $_.Path -like '*Processor Utility*' } | Select-Object -Last 1)
    if ($perf.Count -gt 0) { $r.Perf = [int][math]::Round($perf[0].CookedValue); if ($util.Count -gt 0 -and $util[0].CookedValue -gt 40 -and $r.Perf -lt 75) { $r.Throttle = $true } }
    if ($util.Count -gt 0 -and $r.Load -lt 0) { $r.Load = [int][math]::Round([math]::Min(100, $util[0].CookedValue)) }
    # 温度：ACPI 热区（很多主板不报，或者报的是机箱 / 主板温度）
    $tz = @(Try-Cim 'MSAcpi_ThermalZoneTemperature' 'root\wmi')
    $temps = @($tz | ForEach-Object { try { ([double]$_.CurrentTemperature - 2732) / 10 } catch { $null } } | Where-Object { $_ -ne $null -and $_ -gt 0 -and $_ -lt 130 })
    if ($temps.Count -gt 0) { $r.Temp = [int][math]::Round(($temps | Measure-Object -Maximum).Maximum); $r.TempNote = (T '来自 ACPI 热区，可能是主板而不是 CPU 内核的温度') }
    else { $r.TempWhy = (T '主板没有通过 ACPI 报告温度；要看 CPU 内核温度需要厂商工具（HWiNFO 等）') }
    $r.Ok = $true
    return $r
}
# 内存：总量、可用、提交量和上限、硬错误（从页面文件读回来的次数）、WHEA 报告过的内存错误
function Get-MemHealth {
    $r = @{ Ok = $false; Total = 0; Free = 0; Commit = 0; CommitLimit = 0; HardFaults = -1; Whea = 0; Pressure = '' }
    $os = @(Try-Cim 'Win32_OperatingSystem')
    if ($os.Count -eq 0) { $r.Why = (T '读不到内存信息（WMI）'); return $r }
    $o = $os[0]
    $r.Total = [double]$o.TotalVisibleMemorySize * 1KB; $r.Free = [double]$o.FreePhysicalMemory * 1KB
    $r.CommitLimit = [double]$o.TotalVirtualMemorySize * 1KB; $r.Commit = $r.CommitLimit - [double]$o.FreeVirtualMemory * 1KB
    $s = @(Try-Counter @('\Memory\Page Reads/sec') 3)
    if ($s.Count -gt 0) { $r.HardFaults = [int][math]::Round((($s | Measure-Object -Property CookedValue -Average).Average)) }
    try { $r.Whea = @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-WHEA-Logger'; StartTime = (Get-Date).AddDays(-30) } -MaxEvents 200 -ErrorAction Stop | Where-Object { $_.Message -match (T '内存|Memory') }).Count } catch { $r.Whea = 0 }
    $usedPct = if ($r.Total -gt 0) { 100 * ($r.Total - $r.Free) / $r.Total } else { 0 }
    $commitPct = if ($r.CommitLimit -gt 0) { 100 * $r.Commit / $r.CommitLimit } else { 0 }
    $r.UsedPct = [int][math]::Round($usedPct); $r.CommitPct = [int][math]::Round($commitPct)
    $r.Pressure = if ($usedPct -ge 92 -or $commitPct -ge 90 -or $r.HardFaults -ge 100) { 'high' } elseif ($usedPct -ge 80 -or $commitPct -ge 75 -or $r.HardFaults -ge 20) { 'mid' } else { 'low' }
    $r.Ok = $true
    return $r
}
# 电池：设计容量、现在充满能到多少、循环次数（台式机没有电池）
function Get-BatteryHealth {
    $r = @{ Ok = $false; Present = $false; Design = 0; Full = 0; Cycles = -1; Charge = -1; Status = '' }
    $b = @(Try-Cim 'Win32_Battery')
    if ($b.Count -eq 0) { $r.Why = (T '没有电池（台式机）'); $r.Ok = $true; return $r }
    $r.Present = $true; $r.Charge = [int]$b[0].EstimatedChargeRemaining
    $r.Status = switch ([int]$b[0].BatteryStatus) { 1 { (T '放电中') } 2 { (T '接着电源') } 3 { (T '已充满') } 4 { (T '电量低') } 5 { (T '电量极低') } 6 { (T '充电中') } 7 { (T '充电中') } 8 { (T '充电中') } 9 { (T '充电中') } default { '' } }
    $st = @(Try-Cim 'BatteryStaticData' 'root\wmi'); $fc = @(Try-Cim 'BatteryFullChargedCapacity' 'root\wmi'); $cc = @(Try-Cim 'BatteryCycleCount' 'root\wmi')
    if ($st.Count -gt 0) { $r.Design = [double]$st[0].DesignedCapacity }
    if ($fc.Count -gt 0) { $r.Full = [double]$fc[0].FullChargedCapacity }
    if ($cc.Count -gt 0) { $r.Cycles = [int]$cc[0].CycleCount }
    if ($r.Design -le 0 -or $r.Full -le 0) { $r.Why = (T '电池没有报告设计容量和实际满充容量') }
    $r.Ok = $true
    return $r
}
# 显卡：型号、驱动版本和日期、显存大小、现在的占用（Windows 的 GPU 计数器）；温度要厂商工具
function Get-GpuHealth {
    $out = @()
    foreach ($v in @(Try-Cim 'Win32_VideoController')) {
        $g = @{ Ok = $true; Name = ([string]$v.Name).Trim(); Driver = [string]$v.DriverVersion; DriverDate = $null; Vram = 0; Util = -1; VramUsed = -1; TempWhy = (T '温度要厂商工具（NVIDIA、AMD、Intel 的控制面板）才能读') }
        try { if ($v.DriverDate) { $g.DriverDate = [DateTime]$v.DriverDate } } catch {}
        # AdapterRAM 是 32 位，超过 4 GB 的显卡报不准：从注册表读 qwMemorySize
        $g.Vram = [double]$v.AdapterRAM
        try {
            foreach ($k in @(Get-ChildItem 'HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}' -ErrorAction Stop | Where-Object { $_.PSChildName -match '^\d{4}$' })) {
                $p = Get-ItemProperty $k.PSPath -ErrorAction SilentlyContinue
                if ($p -and $p.DriverDesc -eq $v.Name -and $p.'HardwareInformation.qwMemorySize') { $g.Vram = [double]$p.'HardwareInformation.qwMemorySize'; break }
            }
        } catch {}
        $out += $g
    }
    if ($out.Count -eq 0) { return @(@{ Ok = $false; Why = (T '读不到显卡信息（WMI）') }) }
    # 占用：GPU Engine 计数器按进程分，这里把 3D 引擎的加起来；显存按适配器的专用显存占用
    $s = @(Try-Counter @('\GPU Engine(*engtype_3D)\Utilization Percentage', '\GPU Adapter Memory(*)\Dedicated Usage') 1)
    if ($s.Count -gt 0) {
        $u = [double]0; foreach ($x in @($s | Where-Object { $_.Path -like '*Utilization*' })) { $u += [double]$x.CookedValue }
        $m = [double]0; foreach ($x in @($s | Where-Object { $_.Path -like '*Dedicated Usage*' })) { $m += [double]$x.CookedValue }
        $out[0].Util = [int][math]::Min(100, [math]::Round($u)); $out[0].VramUsed = $m
    }
    return $out
}
# Windows：开机多久、挂起的重启、最近的更新、有问题的设备（设备管理器里带叹号的）、最近 7 天的严重和错误事件按来源
function Get-WinHealth {
    $r = @{ Ok = $true; Uptime = $null; LastBoot = $null; PendingReboot = $false; LastUpdate = $null; BadDevices = @(); Errors = @(); ErrorCount = 0; Build = '' }
    $os = @(Try-Cim 'Win32_OperatingSystem')
    if ($os.Count -gt 0) { try { $r.LastBoot = [DateTime]$os[0].LastBootUpTime; $r.Uptime = (Get-Date) - $r.LastBoot } catch {}; $r.Build = [string]$os[0].Version }
    try {
        $cv = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction Stop
        $r.BuildNo = [int]$cv.CurrentBuildNumber; $r.Ubr = [int]$cv.UBR
        $r.Release = if ($cv.DisplayVersion) { [string]$cv.DisplayVersion } else { [string]$cv.ReleaseId }
        $r.Product = if ($r.BuildNo -ge 22000) { ([string]$cv.ProductName) -replace 'Windows 10', 'Windows 11' } else { [string]$cv.ProductName }
    } catch {}
    foreach ($k in 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending', 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired') { if (Test-Path $k) { $r.PendingReboot = $true } }
    try { $p = Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -Name PendingFileRenameOperations -ErrorAction Stop; if ($p.PendingFileRenameOperations) { $r.PendingReboot = $true } } catch {}
    try { $h = @(Get-HotFix -ErrorAction Stop | Where-Object { $_.InstalledOn } | Sort-Object InstalledOn -Descending); if ($h.Count -gt 0) { $r.LastUpdate = [DateTime]$h[0].InstalledOn; $r.LastUpdateId = [string]$h[0].HotFixID } } catch {}
    foreach ($d in @(Try-Cim 'Win32_PnPEntity' 'root\cimv2' 'ConfigManagerErrorCode <> 0')) {
        $r.BadDevices += @{ Name = [string]$d.Name; Code = [int]$d.ConfigManagerErrorCode; Note = (Get-PnpErrorText ([int]$d.ConfigManagerErrorCode)) }
    }
    try {
        $ev = @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; Level = @(1, 2); StartTime = (Get-Date).AddDays(-7) } -MaxEvents 2000 -ErrorAction Stop)
        $r.ErrorCount = $ev.Count
        $r.Errors = @($ev | Group-Object ProviderName | Sort-Object Count -Descending | Select-Object -First 6 | ForEach-Object { @{ Source = $_.Name; Count = $_.Count; Last = ($_.Group | Sort-Object TimeCreated -Descending | Select-Object -First 1).TimeCreated; Sample = (([string]($_.Group[0].Message) -split "`n")[0]).Trim() } })
    } catch { $r.Errors = @() }
    return $r
}
function Get-PnpErrorText([int]$code) {
    switch ($code) {
        1 { (T '没有正确配置') } 3 { (T '驱动可能损坏，或内存不足') } 10 { (T '无法启动') } 12 { (T '找不到足够的可用资源') } 14 { (T '要重启电脑才能正常工作') }
        18 { (T '要重新安装驱动') } 19 { (T '注册表里的配置信息损坏') } 22 { (T '已被禁用') } 24 { (T '设备不在了，或者没有正确连接') } 28 { (T '没有安装驱动') }
        31 { (T '无法加载驱动') } 37 { (T '驱动初始化失败') } 39 { (T '驱动损坏或丢失') } 43 { (T '设备报告了问题，Windows 把它停了') } 45 { (T '已拔出') }
        default { (T "设备管理器错误代码 {0}") -f $code }
    }
}
# 启动：最近一次开机用了多久（Windows 自己记在「诊断-性能」日志里），以及它点名拖慢开机的程序
function Get-BootHealth {
    $r = @{ Ok = $false; BootMs = 0; MainMs = 0; PostMs = 0; At = $null; Slow = @(); History = @() }
    try {
        $ev = @(Get-WinEvent -FilterHashtable @{ LogName = 'Microsoft-Windows-Diagnostics-Performance/Operational'; Id = 100 } -MaxEvents 10 -ErrorAction Stop)
        foreach ($e in $ev) {
            $x = [xml]$e.ToXml(); $d = @{}
            foreach ($n in $x.Event.EventData.Data) { $d[[string]$n.Name] = [string]$n.'#text' }
            $h = @{ At = $e.TimeCreated; BootMs = [int]$d['BootTime']; MainMs = [int]$d['MainPathBootTime']; PostMs = [int]$d['BootPostBootTime'] }
            $r.History += $h
        }
        if ($r.History.Count -gt 0) { $h = $r.History[0]; $r.BootMs = $h.BootMs; $r.MainMs = $h.MainMs; $r.PostMs = $h.PostMs; $r.At = $h.At; $r.Ok = $true }
        else { $r.Why = (T 'Windows 还没有记录过开机用时（「诊断-性能」日志为空）') }
    } catch { $r.Why = (T '读不到「诊断-性能」日志') }
    try {
        $ev = @(Get-WinEvent -FilterHashtable @{ LogName = 'Microsoft-Windows-Diagnostics-Performance/Operational'; Id = 101; StartTime = (Get-Date).AddDays(-30) } -MaxEvents 60 -ErrorAction Stop)
        $byName = @{}
        foreach ($e in $ev) {
            $x = [xml]$e.ToXml(); $d = @{}
            foreach ($n in $x.Event.EventData.Data) { $d[[string]$n.Name] = [string]$n.'#text' }
            $name = $d['Name']; if (-not $name) { $name = $d['Path'] }
            if (-not $name) { continue }
            if (-not $byName.ContainsKey($name)) { $byName[$name] = @{ Name = $name; Path = $d['Path']; Times = 0; DegradeMs = 0; Last = $e.TimeCreated } }
            $byName[$name].Times++; $byName[$name].DegradeMs = [math]::Max([int]$byName[$name].DegradeMs, [int]$d['DegradationTime'])
        }
        $r.Slow = @($byName.Values | Sort-Object { $_.DegradeMs } -Descending | Select-Object -First 8)
    } catch {}
    return $r
}
# 蓝屏和崩溃：转储文件（自己解析）、相关事件（意外关机、蓝屏记录、硬件错误、磁盘错误）、最近装的驱动
function Get-CrashHealth {
    $r = @{ Ok = $true; Dumps = @(); Events = @(); Drivers = @(); DumpDir = (Join-Path $env:SystemRoot 'Minidump'); MemoryDmp = $null }
    $files = @()
    if (Test-Path -LiteralPath $r.DumpDir) { $files = @(Get-ChildItem -LiteralPath $r.DumpDir -Filter *.dmp -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 10) }
    foreach ($f in $files) {
        $d = $null; try { $d = [DumpInfo]::Parse($f.FullName) } catch { $d = $null }
        $r.Dumps += (ConvertFrom-DumpInfo $d $f.FullName $f.Name $f.LastWriteTime ([double]$f.Length))
    }
    $mem = Join-Path $env:SystemRoot 'MEMORY.DMP'
    if (Test-Path -LiteralPath $mem) { $i = Get-Item -LiteralPath $mem; $r.MemoryDmp = @{ Size = [double]$i.Length; Time = $i.LastWriteTime } }
    # 事件：Kernel-Power 41 意外关机、BugCheck 1001、WHEA 硬件错误、磁盘和 NTFS 错误
    $defs = @(
        @{ Prov = 'Microsoft-Windows-Kernel-Power'; Ids = @(41); What = (T '意外关机或重启（没有正常关机）') },
        @{ Prov = 'Microsoft-Windows-WER-SystemErrorReporting'; Ids = @(1001); What = (T '蓝屏记录') },
        @{ Prov = 'Microsoft-Windows-WHEA-Logger'; Ids = @(17, 18, 19, 20, 46, 47); What = (T '硬件错误（CPU、内存、PCIe 报告的）') },
        @{ Prov = 'disk'; Ids = @(7, 11, 51, 153); What = (T '磁盘读写错误或重试') },
        @{ Prov = 'Ntfs'; Ids = @(55, 98, 140); What = (T '文件系统损坏或需要检查') },
        @{ Prov = 'volmgr'; Ids = @(161); What = (T '没能写出转储文件') },
        @{ Prov = 'Microsoft-Windows-Kernel-General'; Ids = @(1); What = (T '系统时间被改动') }
    )
    $r.BugChecks = @(); $r.DiskEvents = @()
    foreach ($df in $defs) {
        if ($df.Prov -eq 'Microsoft-Windows-Kernel-General') { continue }
        try {
            $ev = @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; ProviderName = $df.Prov; Id = $df.Ids; StartTime = (Get-Date).AddDays(-30) } -MaxEvents 200 -ErrorAction Stop)
            if ($ev.Count -gt 0) { $r.Events += @{ Source = $df.Prov; What = $df.What; Count = $ev.Count; Last = ($ev | Sort-Object TimeCreated -Descending | Select-Object -First 1).TimeCreated; Sample = (([string]$ev[0].Message -split "`n")[0]).Trim() } }
            # 小转储只留最近几个，蓝屏记录（WER 1001）每次都有：错误码和四个参数都在里面
            if ($df.Prov -eq 'Microsoft-Windows-WER-SystemErrorReporting') { foreach ($e in $ev) { $b = ConvertFrom-BugCheckText ([string]$e.Message + ' ' + [string]$e.ToXml()); if ($b) { $b.Time = $e.TimeCreated; $r.BugChecks += $b } } }
            if ($df.Prov -eq 'disk') { $r.DiskEvents = @(Group-DiskEvents $ev) }
        } catch {}
    }
    # 最近 30 天装的驱动（设备管理器的安装记录）
    try {
        $ev = @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-UserPnp'; Id = @(20001, 20003); StartTime = (Get-Date).AddDays(-30) } -MaxEvents 100 -ErrorAction Stop)
        $seen = @{}
        foreach ($e in $ev) {
            $x = [xml]$e.ToXml(); $d = @{}
            foreach ($n in $x.Event.EventData.Data) { $d[[string]$n.Name] = [string]$n.'#text' }
            $name = $d['DriverName']; if (-not $name) { $name = $d['DeviceInstanceID'] }
            if (-not $name) { continue }
            $k = $name + '|' + $d['DriverVersion']
            if ($seen.ContainsKey($k)) { continue }; $seen[$k] = $true
            $r.Drivers += @{ When = $e.TimeCreated; Name = $name; Provider = $d['DriverProvider']; Version = $d['DriverVersion']; Device = $d['DeviceInstanceID']; Status = $d['Status'] }
        }
    } catch {}
    return $r
}
# 蓝屏记录里的「检测错误: 0x0000007a (0x…, 0x…, 0x…, 0x…)」：各种语言的系统里这一段都一样
function ConvertFrom-BugCheckText([string]$t) {
    $m = [regex]::Match($t, '0x([0-9a-fA-F]{8})\s*\((0x[0-9a-fA-F]+),\s*(0x[0-9a-fA-F]+),\s*(0x[0-9a-fA-F]+),\s*(0x[0-9a-fA-F]+)\)')
    if (-not $m.Success) { return $null }
    $code = [long][Convert]::ToUInt32($m.Groups[1].Value, 16)
    $hx = @(2..5 | ForEach-Object { $m.Groups[$_].Value.Substring(2).PadLeft(16, '0') })
    $p = @($hx | ForEach-Object { [Convert]::ToUInt64($_, 16) })
    $lo = { param($h) [long][Convert]::ToUInt32($h.Substring($h.Length - 8), 16) }   # 状态码是参数的低 32 位（0xffffffffc000000e → 0xC000000E）
    $st = 0; if ($code -eq 0x7A) { $st = & $lo $hx[1] } elseif ($code -eq 0x77) { $st = $(if ($p[0] -le 2) { & $lo $hx[1] } else { & $lo $hx[0] }) }
    return @{ Code = $code; CodeName = [DumpInfo]::CodeName([uint32]$code); Params = @($p | ForEach-Object { '0x{0:X}' -f $_ }); Status = $st; Time = $null }
}
# 磁盘事件（disk 7/11/51/153）按盘号归并：「已在磁盘 2 … 重试」是哪块盘，是不是系统盘
function Group-DiskEvents($ev) {
    $by = @{}
    foreach ($e in @($ev)) {
        $n = -1
        $x = ''; try { $x = [string]$e.ToXml() } catch {}
        $m = [regex]::Match($x, 'Harddisk(\d+)'); if (-not $m.Success) { $m = [regex]::Match([string]$e.Message, '(?:磁盘|[Dd]isk)\s*(\d+)') }
        if ($m.Success) { $n = [int]$m.Groups[1].Value }
        if (-not $by.ContainsKey($n)) { $by[$n] = @{ Disk = $n; Count = 0; Last = $e.TimeCreated; Name = ''; Bus = ''; IsSystem = $false } }
        $by[$n].Count++; if ($e.TimeCreated -gt $by[$n].Last) { $by[$n].Last = $e.TimeCreated }
    }
    $sys = -1; try { $sys = [int](@(Get-Partition -DriveLetter ([string]$env:SystemDrive).Substring(0, 1) -ErrorAction Stop)[0].DiskNumber) } catch {}
    $pds = @(); try { $pds = @(Get-PhysicalDisk -ErrorAction Stop) } catch {}
    foreach ($g in $by.Values) {
        $pd = @($pds | Where-Object { [string]$_.DeviceId -eq [string]$g.Disk })[0]
        if ($pd) { $g.Name = ([string]$pd.FriendlyName).Trim(); $g.Bus = [string]$pd.BusType }
        $g.IsSystem = ($g.Disk -ge 0 -and $g.Disk -eq $sys) -or ($g.Disk -lt 0)   # 读不出盘号的算系统盘（宁可多怀疑）
    }
    return @($by.Values)
}
# 这台电脑本身：厂商、型号、BIOS、服务编号、存储控制器驱动、系统盘、BitLocker、时间同步。给建议用（BIOS 和驱动多旧、去哪下载）
function Get-SysFacts {
    $r = @{ Maker = ''; Model = ''; Bios = ''; BiosDate = $null; Serial = ''; Stor = @(); SysDisk = $null; BitLocker = -1 }
    $cs = @(Try-Cim 'Win32_ComputerSystem'); if ($cs.Count) { $r.Maker = ([string]$cs[0].Manufacturer).Trim(); $r.Model = ([string]$cs[0].Model).Trim() }
    $b = @(Try-Cim 'Win32_BIOS')
    if ($b.Count) { $r.Bios = ([string]$b[0].SMBIOSBIOSVersion).Trim(); try { $r.BiosDate = [DateTime]$b[0].ReleaseDate } catch {}; $r.Serial = ([string]$b[0].SerialNumber).Trim() }
    # 存储控制器的驱动：版本和驱动日期（设备管理器「驱动程序」页上的那两个）
    foreach ($d in @(Try-Cim 'Win32_PnPSignedDriver' 'root\cimv2' "DeviceClass='SCSIADAPTER' OR DeviceClass='HDC'")) {
        if (-not $d.DeviceName) { continue }
        $dt = $null; try { $dt = [DateTime]$d.DriverDate } catch {}
        $r.Stor += @{ Device = ([string]$d.DeviceName).Trim(); Version = [string]$d.DriverVersion; Date = $dt; Provider = [string]$d.DriverProviderName; Inf = [string]$d.InfName; Rst = ([string]$d.DeviceName -match '(?i)RST|Rapid Storage|RAID|Optane|VMD|Chipset SATA') }
    }
    try {
        $part = @(Get-Partition -DriveLetter ([string]$env:SystemDrive).Substring(0, 1) -ErrorAction Stop)[0]
        $pd = @(Get-PhysicalDisk -ErrorAction Stop | Where-Object { [string]$_.DeviceId -eq [string]$part.DiskNumber })[0]
        if ($pd) { $r.SysDisk = @{ Number = [int]$part.DiskNumber; Name = ([string]$pd.FriendlyName).Trim(); Bus = [string]$pd.BusType; Media = [string]$pd.MediaType; Firmware = ([string]$pd.FirmwareVersion).Trim(); RaidVolume = ([string]$pd.FriendlyName -match '(?i)raid|volume') } }
    } catch {}
    $bl = @(Try-Cim 'Win32_EncryptableVolume' 'root\cimv2\Security\MicrosoftVolumeEncryption' ("DriveLetter='{0}'" -f $env:SystemDrive))
    if ($bl.Count) { $r.BitLocker = [int]$bl[0].ProtectionStatus }
    return $r
}
# 厂商的驱动下载页：Dell 按服务编号直达；别的牌子给搜索
function Get-VendorSupportUrl($f) {
    if (-not $f) { return '' }
    $tag = [string]$f.Serial
    if ($f.Maker -match '(?i)^Dell' -and $tag -match '^[A-Za-z0-9]{5,8}$') { $en = $false; try { $en = ($null -ne [L10n]::Map -and [L10n]::Map.Count -gt 0) } catch {}; return ('https://www.dell.com/support/home/{0}/product-support/servicetag/{1}/drivers' -f $(if ($en) { 'en-us' } else { 'zh-cn' }), $tag) }
    if ($f.Maker -match '(?i)^Lenovo' -and $tag) { return ('https://pcsupport.lenovo.com/products/{0}/downloads' -f $tag) }
    if ($f.Maker -match '(?i)^(HP|Hewlett)') { return 'https://support.hp.com/drivers' }
    $q = (('{0} {1} ' -f $f.Maker, $f.Model) + (T 'BIOS 驱动 下载')).Trim()
    return ('https://www.bing.com/search?q=' + [uri]::EscapeDataString($q))
}
# 转储解析结果变成健康页用的表：多带上状态码、出事的进程、栈上驱动是谁做的
function ConvertFrom-DumpInfo($d, [string]$file, [string]$name, $time, [double]$size) {
    $x = @{ File = $file; Name = $name; Time = $time; Size = $size; Ok = $false; Code = 0; CodeName = ''; Params = @(); Suspect = ''; SuspectFrom = ''; SuspectMaker = ''; SuspectMs = $false; Stack = @(); StackInfo = @(); Drivers = 0; Error = ''
            Status = 0; StatusName = ''; PageOwner = ''; Process = ''; ProcIsP1 = $false; StorageDrivers = @(); Build = 0 }
    if (-not $d) { return $x }
    $x.Ok = $d.Ok; $x.Code = [long]$d.BugCheck; $x.CodeName = [DumpInfo]::CodeName($d.BugCheck); $x.Params = @($d.Params | ForEach-Object { '0x{0:X}' -f $_ })
    $x.Drivers = $d.Drivers.Count; $x.Error = $d.Error; $x.Build = [int]$d.Build
    $x.Status = [long]$d.Status; $x.StatusName = [DumpInfo]::StatusName($d.Status); $x.PageOwner = $d.PageOwner; $x.Process = $d.Process; $x.ProcIsP1 = $d.ProcessIsParam1
    if ($d.Time -gt [DateTime]'2000-01-01') { $x.Time = $d.Time }
    $paths = @{}; foreach ($dr in $d.Drivers) { if (-not $paths.ContainsKey($dr.Name)) { $paths[$dr.Name] = $dr.Path } }
    $x.StorageDrivers = @($d.Drivers | Where-Object { (Get-DriverKind $_.Name) -eq 'storage' } | ForEach-Object { $_.Name } | Select-Object -Unique)
    foreach ($s in @($d.StackDrivers)) { $m = Get-DriverMaker $paths[$s] $s; $x.StackInfo += @{ Name = $s; Maker = $m.Maker; Ms = $m.Ms } }
    $x.Stack = @($d.StackDrivers)
    # 只是「栈上第一个」的时候，Windows 自带的驱动多半是受害者：换成栈上第一个不是微软的；一个都没有就不点名
    if ($d.SuspectFrom -eq 'stack') {
        $pick = @($x.StackInfo | Where-Object { -not $_.Ms } | Select-Object -First 1)
        if ($pick.Count -gt 0) { $x.Suspect = $pick[0].Name; $x.SuspectFrom = 'stack'; $x.SuspectMaker = $pick[0].Maker }
    } elseif ($d.Suspect) {
        $m = Get-DriverMaker $paths[$d.Suspect] $d.Suspect
        $x.Suspect = $d.Suspect; $x.SuspectFrom = 'address'; $x.SuspectMaker = $m.Maker; $x.SuspectMs = $m.Ms
    }
    return $x
}
# 驱动文件是谁做的：转储里记的路径（\SystemRoot\...、\??\C:\...）换成本机路径，读文件的版本信息；读不到就按名字认几个 Windows 自带的
function Get-DriverMaker([string]$path, [string]$name) {
    $cands = @()
    if ($path) {
        $p = $path -replace '^\\SystemRoot', ([string]$env:SystemRoot) -replace '^\\\?\?\\', ''
        if ($p -match '^[A-Za-z]:\\') { $cands += $p } elseif ($p -match '^\\Windows\\') { $cands += ($env:SystemDrive + $p) }
    }
    if ($name -and $env:SystemRoot) { $cands += (Join-Path $env:SystemRoot ('System32\drivers\' + $name)); $cands += (Join-Path $env:SystemRoot ('System32\' + $name)) }
    foreach ($c in $cands) {
        try {
            if (Test-Path -LiteralPath $c -PathType Leaf) {
                $v = [Diagnostics.FileVersionInfo]::GetVersionInfo($c)
                $co = ([string]$v.CompanyName).Trim(); $desc = ([string]$v.FileDescription).Trim()
                $maker = if ($co -and $desc -and $desc -ne $name) { '{0} · {1}' -f $co, $desc } elseif ($co) { $co } else { $desc }
                return @{ Maker = $maker; Ms = ($co -match '^Microsoft'); Found = $true }
            }
        } catch {}
    }
    return @{ Maker = ''; Ms = (Test-MsDriverName $name); Found = $false }
}
function Test-MsDriverName([string]$n) { return ($n -match '^(?i)(ntoskrnl|ntkrnl|hal|ntfs|refs|win32k\w*|dxgkrnl|dxgmms\d|tcpip|ndis|netio|fltmgr|storport|stornvme|storahci|ataport|classpnp|disk|partmgr|volmgr\w*|volsnap|mountmgr|wdf01000|wdfldr|ks|ksecdd|cng|afd|http|mup|rdbss|srv\w*|wof|fileinfo|wdfilter|wdnisdrv|usbxhci|ucx01000|usbhub3|usbport|usbccgp|hidclass|hidusb|acpi|pci|pdc|cldflt|bindflt|luafv|npfs|msfs|fastfat|exfat|cdfs|udfs|iorate|storqosflt|wcifs|bowser|mrxsmb\w*|nsiproxy|netbt|tdx|vmbus|hvsocket|bam|ahcache|condrv|clipsp|ci|tm|clfs|pshed|kd|kdcom|bootvid|werkernel|mssecflt|sgrmagent|wtd|crashdmp|dumpstorport|dumpfve|fvevol|rdyboost|spaceport|intelpep|wmilib|cea|msrpc|ksthunk|portcls|drmk|hdaudbus|hdaudio|monitor|basicdisplay|basicrender|watchdog|mouclass|kbdclass|i8042prt|serial|serenum|vdrvroot|wpprecorder)\.(sys|dll|exe)$') }
# 驱动是哪一类：存储、显卡、网卡、安全软件、反作弊、芯片组管理引擎。用来给建议，不用来定罪
function Get-DriverKind([string]$n) {
    switch -Regex ($n) {
        '^(?i)(iastor\w*|rstmw\w*|amdsata|amdxata|amdsbs|nvstor\w*|secnvme|samsungnvme\w*|nvme\w*|stornvme|storahci|rcraid|rcbottom|megasas\w*|lsi_\w+|arcsas|percsas\w*|vmd)\.sys$' { return 'storage' }
        '^(?i)(nvlddmkm|atikmdag|atikmpag|amdkmdag|amdkmpfd|amdfendr|igdkmd\w*|igdkmdn\w*|igdkmdnd\w*|igfxkmd\w*|dxgkrnl|dxgmms\d|basicdisplay)\.sys$' { return 'graphics' }
        '^(?i)(e1[a-z]\d+x64|e2f\w*|rt640x64|rt\w*x64|rtwlan\w*|rtux64w10|netwtw\d+|netwbw\d+|netwsw\d+|athw\w*|qcamain\w*|bcmwl\w*|mrvlpcie\w*|ndis|tcpip|netio|wfplwfs|vwifibus)\.sys$' { return 'network' }
        '^(?i)(klif|kl\w+|avgsp|avgsnx|aswsp|aswsnx|aswarpot|360\w*|bapidrv\w*|qmbsec\w*|tsdefensebt|taokernel\w*|qqprotect\w*|sysdiag\w*|hrwfpdrv|hrdevmon|mfe\w+|symefasi\w*|srtsp\w*|bdselfpr|avc3|gzflt|trufos|eamonm|ehdrv|epfw\w*|wdfilter|wdnisdrv)\.sys$' { return 'security' }
        '^(?i)(easyanticheat\w*|bedaisy|vgk|ace-base\w*|ace-game\w*|tessafe|xhunter1|npptnt2|gameguard\w*)\.sys$' { return 'anticheat' }
        '^(?i)(teedriver\w*|heci\w*|mei\w*|iqvw64e)\.sys$' { return 'mei' }
        '^(?i)(vmx86|vmci|vboxdrv|vboxsup|vboxnetlwf|vboxusbmon|hvservice|vmbus|vmswitch)\.sys$' { return 'virt' }
    }
    return ''
}
# 系统时钟准不准：拿不到网络时间也能看出「时钟往回走了」——系统自己写的文件里有比现在还晚的修改时间
function Get-ClockHealth {
    $r = @{ Ok = $true; Wrong = $false; AheadDays = 0; Newest = $null; Source = ''; Service = ''; Jumps = 0; MaxJumpDays = 0; SyncFails = 0; SyncOk = 0; DnsFail = $false; BehindBuild = 0 }
    $now = Get-Date
    foreach ($spec in @(@{ Dir = (Join-Path $env:SystemRoot 'Prefetch'); Filter = '*.pf' }, @{ Dir = (Join-Path $env:SystemRoot 'System32\winevt\Logs'); Filter = '*.evtx' }, @{ Dir = (Join-Path $env:SystemRoot 'Logs\CBS'); Filter = '*.log' }, @{ Dir = (Join-Path $env:SystemRoot 'SoftwareDistribution\DataStore'); Filter = '*.edb' })) {
        try {
            $f = @(Get-ChildItem -LiteralPath $spec.Dir -Filter $spec.Filter -File -Force -ErrorAction Stop | Sort-Object LastWriteTime -Descending | Select-Object -First 1)
            if ($f.Count -gt 0 -and (-not $r.Newest -or $f[0].LastWriteTime -gt $r.Newest)) { $r.Newest = $f[0].LastWriteTime; $r.Source = $f[0].FullName }
        } catch {}
    }
    if ($r.Newest -and $r.Newest -gt $now.AddDays(1)) { $r.Wrong = $true; $r.AheadDays = [int][math]::Floor(($r.Newest - $now).TotalDays) }
    # 电脑从装系统起时间就不对时，系统写的文件时间也都跟着错，比不出来；本工具的发布日期是外面带进来的
    if ($script:AppBuilt -and $now -lt $script:AppBuilt.AddDays(-1)) { $r.Wrong = $true; $r.BehindBuild = [int][math]::Floor(($script:AppBuilt - $now).TotalDays); if ($r.BehindBuild -gt $r.AheadDays) { $r.AheadDays = $r.BehindBuild; $r.Newest = $script:AppBuilt; $r.Source = 'ClearC' } }
    # 时间服务：同步失败（134 DNS 解析不了、129 连不上、36 一天没同步）和成功（35、37）
    try {
        $ev = @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-Time-Service'; StartTime = $now.AddDays(-30) } -MaxEvents 500 -ErrorAction Stop)
        foreach ($e in $ev) { if ($e.Id -in 129, 134, 36, 47) { $r.SyncFails++; if ($e.Id -eq 134 -and ([string]$e.Message -match '0x80072AF9|DNS')) { $r.DnsFail = $true } } elseif ($e.Id -in 35, 37) { $r.SyncOk++ } }
    } catch {}
    try { $s = Get-Service -Name W32Time -ErrorAction Stop; $r.Service = '{0}/{1}' -f $s.Status, $s.StartType } catch {}
    # Kernel-General 1：系统时间被改过（OldTime → NewTime），一次差一天以上的算跳变
    try {
        $ev = @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-Kernel-General'; Id = 1; StartTime = $now.AddDays(-90) } -MaxEvents 200 -ErrorAction Stop)
        foreach ($e in $ev) {
            $x = [xml]$e.ToXml(); $d = @{}
            foreach ($n in $x.Event.EventData.Data) { $d[[string]$n.Name] = [string]$n.'#text' }
            try { $days = [math]::Abs(([DateTime]$d['NewTime'] - [DateTime]$d['OldTime']).TotalDays) } catch { continue }
            if ($days -ge 1) { $r.Jumps++; if ($days -gt $r.MaxJumpDays) { $r.MaxJumpDays = [int][math]::Round($days) } }
        }
    } catch {}
    return $r
}
# 一次读完健康页要的全部（在后台线程里跑）
function Get-HealthAll {
    $t0 = Get-Date
    # 各部分互不相干，同时读（每部分要等 WMI、性能计数器、事件日志一两秒，一个一个读要十几秒）；开不了后台就一个一个读
    $parts = [ordered]@{ Crash = 'Get-CrashHealth'; Win = 'Get-WinHealth'; Cpu = 'Get-CpuHealth'; Boot = 'Get-BootHealth'; Gpu = ',@(Get-GpuHealth)'; Mem = 'Get-MemHealth'; Battery = 'Get-BatteryHealth'; Clock = 'Get-ClockHealth'; Sys = 'Get-SysFacts'
        Disks = '$o = @(); foreach ($d in @(Get-FixedDriveLetters)) { try { $h = Get-DiskHealthInfo $d; $h.Drive = $d; $o += $h } catch {} }; ,$o' }
    $got = Wait-Parallel (Start-Parallel $parts 6)
    $r = @{ At = (Get-Date); Power = (Get-PowerFixState); PartMs = @{} }
    foreach ($k in $parts.Keys) {
        if ($got.ContainsKey($k)) { $r[$k] = $got[$k].V; $r.PartMs[$k] = $got[$k].Ms }
        else { $t1 = [Environment]::TickCount; $r[$k] = & ([scriptblock]::Create($parts[$k])); $r.PartMs[$k] = [Environment]::TickCount - $t1 }
    }
    $r.Gpu = @($r.Gpu); $r.Disks = @($r.Disks)
    $r.Verdicts = @(Get-CrashVerdict $r)
    $r.Secs = ((Get-Date) - $t0).TotalSeconds
    return $r
}
function Get-FixedDriveLetters { @([IO.DriveInfo]::GetDrives() | Where-Object { $_.DriveType -eq 'Fixed' -and $_.IsReady } | ForEach-Object { $_.Name.TrimEnd('\') }) }

# ---------- 蓝屏诊断：错误码和状态码的人话解释，几次蓝屏放在一起看出来的结论 ----------
# 错误码 → 哪一类问题、一句人话、常见原因、建议先做的修复（编号对应 Get-FixCatalog 里的步骤）
function Get-BugcheckKb {
    return @(
        @{ Codes = @('7A', '77'); Kind = 'storage'; Plain = (T '系统要从硬盘读回一块数据时读失败了'); Causes = (T '硬盘或它的连接出了问题（看状态码）；少数是内存'); Fixes = @('hwtab', 'diskpower', 'chkscan', 'devmgmt') },
        @{ Codes = @('EF', 'F4', 'C000021A'); Kind = 'sysproc'; Plain = (T 'Windows 离不开的系统进程意外退出了，只能蓝屏'); Causes = (T '系统文件损坏，或者硬盘读不出系统文件（和读盘失败、磁盘错误一起出现时多半是这个）；也可能是内存问题或安全软件误杀'); Fixes = @('sfccheck', 'sfcrepair', 'chkscan', 'memtest') },
        @{ Codes = @('50'); Kind = 'memory'; Plain = (T '系统访问了一块不存在的内存'); Causes = (T '点名的驱动不是微软的时候多半是它的错；否则常见于内存条问题、硬盘读不回换出去的内存、安全软件'); Fixes = @('memtest', 'sfccheck', 'devmgmt') },
        @{ Codes = @('1A', '4E', '19', 'C2', 'C5', '13A', '139', '7F', '109', 'BE', 'FC', 'D5', 'D6'); Kind = 'memory'; Plain = (T '内存里的数据被破坏了'); Causes = (T '内存条或内存超频（XMP）不稳定，或者某个驱动写坏了内存'); Fixes = @('memtest', 'devmgmt', 'sfccheck') },
        @{ Codes = @('A', 'D1'); Kind = 'driver'; Plain = (T '有个驱动在不允许的时候访问了内存'); Causes = (T '几乎都是驱动的错：有线和无线网卡、VPN、安全软件、虚拟光驱的驱动最常见'); Fixes = @('devmgmt', 'rstrui', 'winupdate') },
        @{ Codes = @('1E', '7E', '8E', '3B', '1000007E', '1000008E'); Kind = 'driver'; Plain = (T '系统或某个驱动里出了没处理的错误'); Causes = (T '多是驱动的错（尤其显卡、安全软件），也可能是系统文件损坏'); Fixes = @('devmgmt', 'sfccheck', 'rstrui') },
        @{ Codes = @('9F', 'A0'); Kind = 'power'; Plain = (T '睡眠、唤醒或关机的时候，有个驱动迟迟不响应'); Causes = (T '芯片组、存储、无线网卡、显卡驱动太旧，或者快速启动和驱动不兼容'); Fixes = @('faststartup', 'devmgmt', 'winupdate') },
        @{ Codes = @('133', 'EA', '100000EA'); Kind = 'driver'; Plain = (T '某个驱动占着处理器太久不放'); Causes = (T '常见于硬盘控制器驱动（比如 Intel RST）、固态硬盘固件太旧、显卡驱动'); Fixes = @('devmgmt', 'diskpower', 'winupdate') },
        @{ Codes = @('124'); Kind = 'hardware'; Plain = (T 'CPU、内存或主板报告了没法纠正的硬件错误'); Causes = (T '超频或 XMP 不稳定、温度太高、电源供电不足、BIOS 太旧；少数是 CPU 或内存坏了'); Fixes = @('hwtab', 'memtest') },
        @{ Codes = @('116', '117', '119', '141', '113', '10E'); Kind = 'graphics'; Plain = (T '显卡驱动没响应，系统重置它也没恢复'); Causes = (T '显卡驱动版本有问题、显卡温度过高或超频；笔记本双显卡切换时也常见'); Fixes = @('devmgmt', 'hwtab') },
        @{ Codes = @('154'); Kind = 'storage'; Plain = (T '内存压缩存储出错'); Causes = (T '多是硬盘读写不稳，或者内存有问题'); Fixes = @('chkscan', 'memtest', 'diskpower') },
        @{ Codes = @('24', 'F5', 'DE', '23'); Kind = 'filesystem'; Plain = (T '文件系统出错'); Causes = (T '磁盘上的文件系统有损坏，或者安全软件、加密软件的过滤驱动有问题'); Fixes = @('chkscan', 'chkfix', 'devmgmt') },
        @{ Codes = @('C4'); Kind = 'driver'; Plain = (T '「驱动程序验证程序」抓到了驱动的错'); Causes = (T '只有开着 Driver Verifier（verifier.exe）时才会出现，被点名的驱动就是有问题的那个；查完记得用 verifier /reset 关掉'); Fixes = @('devmgmt') }
    )
}
# 读盘失败的状态码 → 人话
function Get-StatusPlain([long]$st) {
    switch ('{0:X8}' -f $st) {
        'C000000E' { return (T '硬盘在运行中掉线了，系统找不到它') }
        'C000009D' { return (T '硬盘在运行中断开了连接') }
        'C000009C' { return (T '硬盘读到了坏的扇区（坏道）') }
        'C000016A' { return (T '硬盘读写操作失败，多是坏道') }
        'C0000185' { return (T '硬盘读写出错，常见于数据线或接口接触不良') }
        'C0000483' { return (T '硬盘报告了自身的硬件错误') }
        'C00000B5' { return (T '硬盘很久没有响应（超时）') }
        'C000003F' { return (T '数据校验出错（CRC），多是数据线或接口的问题') }
        'C000009A' { return (T '系统资源（内存）耗尽，没法完成读盘') }
    }
    return ''
}
# 一次蓝屏的解释：哪一类、发生了什么（带上状态码、进程、点名的驱动）、建议的修复
function Get-DumpExplain($x) {
    $hex = '{0:X}' -f [long]$x.Code
    $kb = @(Get-BugcheckKb | Where-Object { $_.Codes -contains $hex } | Select-Object -First 1)
    $e = @{ Kind = 'other'; Plain = (T '这个错误码没有现成的解释'); Causes = (T '可以把转储文件交给懂的人用 WinDbg 分析'); Fixes = @('sfccheck', 'diagpack'); Detail = @() }
    if ($kb.Count -gt 0) { $e.Kind = $kb[0].Kind; $e.Plain = $kb[0].Plain; $e.Causes = $kb[0].Causes; $e.Fixes = @($kb[0].Fixes) }
    if (-not $x.Ok) { $e.Plain = (T '转储文件没解析出来'); return $e }
    if ($e.Kind -eq 'storage' -and $x.Status) {
        $sp = Get-StatusPlain $x.Status
        $e.Detail += ((T '{0}（0x{1:X8}{2}）') -f $(if ($sp) { $sp } else { (T '读盘失败') }), [long]$x.Status, $(if ($x.StatusName) { ' ' + $x.StatusName } else { '' }))
        if ($x.Status -and -not [DumpInfo]::IsStorageStatus([uint32]$x.Status)) { $e.Kind = 'memory'; $e.Fixes = @('memtest', 'chkscan', 'sfccheck') }
        if ($x.PageOwner) { $e.Detail += ((T '读不回来的那一块属于 {0}：它只是碰上了，不是原因') -f $x.PageOwner) }
    }
    if ($hex -eq 'EF' -and $x.Process) { $e.Detail += $(if ($x.ProcIsP1) { (T '退出的是 {0}') -f $x.Process } else { (T '出事时的进程是 {0}') -f $x.Process }) }
    if ($x.Suspect) {
        $who = if ($x.SuspectMaker) { (T '{0}（{1}）') -f $x.Suspect, $x.SuspectMaker } else { $x.Suspect }
        if ($x.SuspectFrom -eq 'address' -and $x.SuspectMs) { $e.Detail += ((T '出事的地址在 Windows 自带的 {0} 里：它常常是被别的驱动连累的') -f $who) }
        elseif ($x.SuspectFrom -eq 'address') { $e.Detail += ((T '出事的地址在 {0} 里：最值得怀疑') -f $who) }
        else { $e.Detail += ((T '栈上出现的第一个非微软驱动是 {0}：可以怀疑，但不确定') -f $who) }
    } elseif (@($x.Stack).Count -gt 0 -and $e.Kind -notin 'storage', 'sysproc', 'hardware') { $e.Detail += ((T '栈上只有 Windows 自带的驱动（{0}）：这种多半不是驱动的错，更像内存或硬盘的问题') -f ((@($x.Stack) | Select-Object -First 4) -join ', ')) }
    return $e
}
# 几次蓝屏、事件日志、硬盘健康、时钟、系统版本放在一起看：给出几条结论，每条带建议的修复
function Get-CrashVerdict($r) {
    $out = @()
    $cr = $r.Crash; $dumps = @($cr.Dumps | Where-Object { $_.Ok })
    $sys = $r.Sys; $ck = $r.Clock; $w = $r.Win; $pw = $r.Power
    $ex = @{}; foreach ($d in $dumps) { $ex[$d.File] = Get-DumpExplain $d }
    $ev = @{}; foreach ($x in @($cr.Events)) { $ev[[string]$x.Source] = $x }
    # 参照时间：时钟不对时用本工具的发布日期算「BIOS、驱动有多旧」
    $ref = Get-Date; if ($script:AppBuilt -and $script:AppBuilt -gt $ref) { $ref = $script:AppBuilt }
    # 蓝屏次数：蓝屏记录（WER 1001）每次都有，小转储只留最近几个；记录比转储少（日志被清过）就用转储
    $bcs = @($cr.BugChecks | Where-Object { $_ })
    if ($bcs.Count -lt $dumps.Count) { $bcs = @($dumps | ForEach-Object { @{ Code = [long]$_.Code; CodeName = $_.CodeName; Status = [long]$_.Status; Time = $_.Time } }) }
    $kindOf = { param($b) $k = 'other'; $hx = '{0:X}' -f [long]$b.Code; $kb = @(Get-BugcheckKb | Where-Object { $_.Codes -contains $hx } | Select-Object -First 1); if ($kb.Count) { $k = $kb[0].Kind }; if ($k -eq 'storage' -and $b.Status -and -not [DumpInfo]::IsStorageStatus([uint32]$b.Status)) { $k = 'memory' }; $k }
    $byKind = @{}
    foreach ($b in $bcs) { $k = & $kindOf $b; if (-not $byKind.ContainsKey($k)) { $byKind[$k] = @() }; $byKind[$k] += $b }
    $get = { param($k) if ($byKind.ContainsKey($k)) { @($byKind[$k]) } else { @() } }
    $n = { param($k) @(& $get $k).Count }
    $nameOf = { param($b) if ($b.CodeName) { $b.CodeName } else { '0x{0:X}' -f [long]$b.Code } }
    $codeList = { param($list) (@(@($list) | Group-Object { & $nameOf $_ } | Sort-Object Count -Descending | ForEach-Object { if ($_.Count -gt 1) { '{0} ×{1}' -f $_.Name, $_.Count } else { $_.Name } }) -join (T '、')) }
    $dumpFail = if ($ev.ContainsKey('volmgr')) { [int]$ev['volmgr'].Count } else { 0 }
    # 磁盘事件只算系统盘的；U 盘、移动硬盘的读写重试和蓝屏无关
    $de = @($cr.DiskEvents | Where-Object { $_ })
    $sysDiskEv = 0; $otherDisk = @()
    if ($de.Count -gt 0) { foreach ($g in $de) { if ($g.IsSystem) { $sysDiskEv += [int]$g.Count } else { $otherDisk += $g } } }
    elseif ($ev.ContainsKey('disk')) { $sysDiskEv = [int]$ev['disk'].Count }
    $fsEv = if ($ev.ContainsKey('Ntfs')) { [int]$ev['Ntfs'].Count } else { 0 }
    $badDisks = @($r.Disks | Where-Object { $_ -and $_.Ok -and (([string]$_.Health -and [string]$_.Health -notmatch 'Healthy|正常|OK') -or ($_.ReadErrors -ne $null -and [long]$_.ReadErrors -gt 0)) })
    $rstDrv = @(@($sys.Stor) | Where-Object { $_ -and $_.Rst })
    $rstNames = @($dumps | ForEach-Object { @($_.StorageDrivers) } | Where-Object { $_ -match '^(?i)iastor' } | Select-Object -Unique)
    $isDell = ([string]$sys.Maker -match '(?i)^Dell')
    $vendorTodo = {
        $old = @()
        if ($sys.BiosDate -and ($ref - $sys.BiosDate).TotalDays -gt 540) { $old += (T 'BIOS {0}（{1:yyyy-MM-dd}）') -f $sys.Bios, $sys.BiosDate }
        foreach ($s in $rstDrv) { if ($s.Date -and ($ref - $s.Date).TotalDays -gt 540) { $old += (T '{0} 驱动 {1}（{2:yyyy-MM-dd}）') -f $s.Device, $s.Version, $s.Date } }
        $t = if ($isDell) { (T '到 Dell 支持网站下载这台电脑的最新 BIOS、Intel Rapid Storage Technology（RST）驱动和固态硬盘固件（下面「厂商驱动下载页」按服务编号 {0} 直达）') -f $sys.Serial } else { (T '到电脑或主板厂商的网站下载最新的 BIOS、芯片组 / 存储驱动和固态硬盘固件（下面「厂商驱动下载页」）') }
        if ($old.Count -gt 0) { $t += (T '。现在的 {0} 都是好几年前的') -f ($old -join (T '、')) }
        if ($ck -and $ck.DnsFail) { $t += (T '。这台电脑上不了外网：在别的电脑上下载，用 U 盘拷过来装') }
        $t
    }
    # 1. 硬盘或硬盘连接
    $storBc = @(& $get 'storage' | Where-Object { [DumpInfo]::IsStorageStatus([uint32]$_.Status) })
    $sp = @(& $get 'sysproc')
    $storage = ($storBc.Count -gt 0) -or ($badDisks.Count -gt 0 -and $bcs.Count -gt 0) -or (($sysDiskEv + $fsEv) -gt 0 -and ($sp.Count + (& $n 'memory') + (& $n 'filesystem')) -gt 0)
    if ($storage) {
        $lines = @()
        if ($bcs.Count -gt 0) { $lines += ((T '• 最近 30 天蓝屏 {0} 次：{1}') -f $bcs.Count, (& $codeList $bcs)) }
        foreach ($g in @($storBc | Group-Object { [long]$_.Status })) { $st = [long]$g.Group[0].Status; $lines += ((T '• 其中 {0} 次读盘失败，状态码 0x{1:X8}：{2}') -f $g.Count, $st, $(if (Get-StatusPlain $st) { Get-StatusPlain $st } else { (T '读盘失败') })) }
        if ($sp.Count -gt 0) {
            $procs = @($dumps | Where-Object { $ex[$_.File].Kind -eq 'sysproc' } | ForEach-Object { $_.Process } | Where-Object { $_ } | Select-Object -Unique)
            $lines += ((T '• {0} 次是系统进程退出{1}：系统进程读不到自己的文件时就会这样') -f $sp.Count, $(if ($procs.Count) { (T '（{0}）') -f ($procs -join ', ') } else { '' }))
        }
        if ($dumpFail -gt 0) { $lines += ((T '• 另有 {0} 次蓝屏连转储文件都没写出来：转储要写在系统盘上，硬盘不见了就写不出来') -f $dumpFail) }
        if ($sysDiskEv + $fsEv -gt 0) { $lines += ((T '• 最近 30 天系统日志里有 {0} 条系统盘的读写或文件系统错误') -f ($sysDiskEv + $fsEv)) }
        foreach ($b in $badDisks) { $lines += ((T '• {0} {1}：健康状态「{2}」{3}') -f $b.Drive, $b.Model, $b.Health, $(if ($b.ReadErrors -gt 0) { (T '，读错误 {0} 次') -f $b.ReadErrors } else { '' })) }
        if ($sys.SysDisk) { $lines += ((T '• 系统盘是 {0}（固件 {1}，接口 {2}）') -f $sys.SysDisk.Name, $sys.SysDisk.Firmware, $sys.SysDisk.Bus) }
        foreach ($s in $rstDrv) { $lines += ((T '• 存储驱动：{0}，版本 {1}，驱动日期 {2:yyyy-MM-dd}') -f $s.Device, $s.Version, $s.Date) }
        if ($rstDrv.Count -eq 0 -and $rstNames.Count -gt 0) { $lines += ((T '• 硬盘用的是 Intel RST 存储驱动（{0}）：这类掉盘很多和它的版本或省电设置有关') -f ($rstNames -join ', ')) }
        if ($sys.BiosDate) { $lines += ((T '• BIOS：{0}（{1:yyyy-MM-dd}）') -f $sys.Bios, $sys.BiosDate) }
        foreach ($g in $otherDisk) { $lines += ((T '• 另外 {0} 条读写重试是 {1}（磁盘 {2}，{3}）的，不是系统盘，和蓝屏无关') -f $g.Count, $(if ($g.Name) { $g.Name } else { (T '另一块盘') }), $g.Disk, $g.Bus) }
        $body = ($lines -join "`n") + "`n" + (T '最可能的原因：系统盘在运行中短暂掉线（省电后唤醒失败、存储驱动或 BIOS 太旧、接触不良），或者硬盘本身在坏。硬盘报告的健康状态正常、蓝屏又都是这一类时，多半是前几种，能修好。')
        $todo = @((T '先把重要资料备份到另一块硬盘、U 盘或网盘（同一块硬盘上的 D 盘不算备份）'), (& $vendorTodo))
        $todo += $(if ($isDell) { (T '用 Dell 自带的硬件检测查一次硬盘：重启时按 F12，选 Diagnostics（ePSA）；报硬盘错误就直接换盘') } else { (T '用厂商自带的硬件检测（开机按 F12 或 F10 进诊断）或者硬盘厂商的工具查一次硬盘') })
        $todo += (T '关机断电后把固态硬盘拔下来重新插紧（M.2 的拧好固定螺丝）；SATA 盘换一根数据线、换个接口')
        if ($rstDrv.Count -gt 0 -or $rstNames.Count -gt 0 -or ($sys.SysDisk -and $sys.SysDisk.Bus -eq 'RAID')) { $todo += (T '以上都做了还掉盘：把 BIOS 里的硬盘模式从 RAID On 改成 AHCI，改用 Windows 自带的驱动（下面「改用 Windows 自带的硬盘驱动」有步骤）；还不行就是硬盘坏了，换一块') }
        else { $todo += (T '以上都做了还掉盘，就是硬盘本身坏了：换一块，把备份拷回去') }
        $plan = @('diskpower', 'faststartup')
        $fixes = @('hwtab', 'diskpower', 'faststartup', 'vendor', 'chkscan', 'devmgmt', 'diagpack')
        if ($rstDrv.Count -gt 0 -or $rstNames.Count -gt 0 -or ($sys.SysDisk -and $sys.SysDisk.Bus -eq 'RAID')) { $fixes += 'ahciguide' }
        $out += @{ Id = 'storage'; Level = 'red'; Title = (T '系统盘在运行中掉线（最可能）'); Body = $body; Fixes = $fixes; Plan = $plan; Todo = $todo }
    }
    # 2. 同一个第三方驱动反复被点名
    $sus = @($dumps | Where-Object { $_.Suspect -and -not $_.SuspectMs -and -not (Test-MsDriverName $_.Suspect) -and $ex[$_.File].Kind -notin 'storage', 'sysproc' } | Group-Object { $_.Suspect } | Sort-Object Count -Descending)
    foreach ($g in $sus) {
        if ($g.Count -lt 2 -and $dumps.Count -gt 1) { continue }
        $one = $g.Group[0]; $kind = Get-DriverKind $one.Suspect
        $who = if ($one.SuspectMaker) { (T '{0}（{1}）') -f $one.Suspect, $one.SuspectMaker } else { $one.Suspect }
        $hint = switch ($kind) { 'graphics' { (T '这是显卡驱动：到显卡厂商（NVIDIA、AMD、Intel）官网下载最新驱动重新安装；刚更新完才出现的，就回退到上一个版本。') } 'network' { (T '这是网卡驱动：到电脑或网卡厂商网站下载最新版；VPN、加速器类软件也会装网络驱动，最近装过的先卸掉试试。') } 'security' { (T '这是安全软件的驱动：先升级这款安全软件；还蓝屏就暂时卸载它（Windows 自带的 Defender 会自动接管）。') } 'anticheat' { (T '这是游戏反作弊的驱动：更新或重新安装对应的游戏；不玩了就卸载。') } 'storage' { (T '这是硬盘控制器驱动：到电脑或主板厂商网站下载最新的芯片组 / 存储驱动。') } default { (T '到这个驱动的厂商网站下载最新版本；刚装或刚更新过的，在设备管理器里「回退驱动程序」，或者卸载对应的软件。') } }
        $body = ((T '{0} 在 {1} 次蓝屏里被点名（{2}）。') -f $who, $g.Count, (& $codeList $g.Group))
        $recent = @($cr.Drivers | Where-Object { $_.Name -and ($_.Name -like ('*' + [IO.Path]::GetFileNameWithoutExtension($one.Suspect) + '*')) } | Select-Object -First 1)
        if ($recent.Count -gt 0) { $body += "`n" + ((T '最近 30 天装过相关的驱动：{0} {1}（{2:MM-dd}）') -f $recent[0].Provider, $recent[0].Version, $recent[0].When) }
        $out += @{ Id = 'driver-' + $one.Suspect; Level = 'red'; Title = ((T '驱动 {0} 嫌疑最大') -f $one.Suspect); Body = $body; Fixes = @('devmgmt', 'vendor', 'rstrui', 'winupdate'); Plan = @(); Todo = @($hint, (T '改完用几天，看还会不会蓝屏；还蓝屏就把诊断包发给懂的人看')) }
    }
    # 3. 显卡
    if ((& $n 'graphics') -gt 0 -and -not ($out | Where-Object { $_.Id -like 'driver-*' -and (Get-DriverKind ($_.Id.Substring(7))) -eq 'graphics' })) {
        $out += @{ Id = 'graphics'; Level = 'amber'; Title = (T '显卡驱动出问题'); Body = ((T '{0}：显卡驱动没响应被系统重置过。') -f (& $codeList (& $get 'graphics'))); Fixes = @('devmgmt', 'vendor', 'hwtab'); Plan = @()
                   Todo = @((T '到显卡厂商官网下载最新驱动，安装时选「清洁安装」'), (T '看看「硬件」里显卡占用和散热，清一下显卡风扇的灰'), (T '超频过的先恢复默认频率')) }
    }
    # 4. 内存
    $memB = @(& $get 'memory')
    $whea = [int]$r.Mem.Whea
    if (($memB.Count -ge 2 -and -not $storage) -or $whea -gt 0) {
        $body = if ($memB.Count -gt 0) { (T '{0}：这类蓝屏点名的驱动各不相同，或者只有 Windows 自带的驱动，内存出问题的可能性比较大。') -f (& $codeList $memB) } else { '' }
        if ($whea -gt 0) { $body += $(if ($body) { "`n" } else { '' }) + ((T '最近 30 天 Windows 记录了 {0} 次内存硬件错误（WHEA）。') -f $whea) }
        $out += @{ Id = 'memory'; Level = 'amber'; Title = (T '可能是内存不稳定'); Body = $body; Fixes = @('memtest', 'sfccheck'); Plan = @('memtest')
                   Todo = @((T '用 Windows 内存诊断查一次（重启后自动检测，大约 15 分钟），报错就换内存条'), (T '在 BIOS 里开过 XMP / 超频的先关掉'), (T '台式机可以把内存条拔下来擦一下金手指重新插，或者一根一根地试')) }
    }
    # 5. 硬件错误
    if ((& $n 'hardware') -gt 0 -or $ev.ContainsKey('Microsoft-Windows-WHEA-Logger')) {
        $cnt = if ($ev.ContainsKey('Microsoft-Windows-WHEA-Logger')) { [int]$ev['Microsoft-Windows-WHEA-Logger'].Count } else { 0 }
        $out += @{ Id = 'hardware'; Level = 'red'; Title = (T 'CPU、内存或主板报告了硬件错误'); Body = ((T '硬件错误蓝屏 {0} 次，系统日志里的硬件错误 {1} 条。') -f (& $n 'hardware'), $cnt); Fixes = @('hwtab', 'memtest', 'vendor'); Plan = @()
                   Todo = @((T '先恢复 BIOS 默认设置（取消超频和 XMP）'), (T '看「硬件」里 CPU 温度，清一下散热器的灰'), (T '台式机检查电源功率是否够'), (T '到电脑或主板厂商网站更新 BIOS')) }
    }
    # 6. 睡眠唤醒、意外关机
    if ((& $n 'power') -gt 0) { $out += @{ Id = 'power'; Level = 'amber'; Title = (T '睡眠、唤醒或关机时驱动没响应'); Body = ((T '{0}。') -f (& $codeList (& $get 'power'))); Fixes = @('faststartup', 'powerreq', 'devmgmt'); Plan = @('faststartup'); Todo = @((T '更新芯片组、无线网卡、显卡驱动')) } }
    $kp = if ($ev.ContainsKey('Microsoft-Windows-Kernel-Power')) { [int]$ev['Microsoft-Windows-Kernel-Power'].Count } else { 0 }
    $unexplained = $kp - [math]::Max($bcs.Count, $dumps.Count) - $dumpFail
    if ($kp -ge 3 -and $unexplained -ge 3) {
        $out += @{ Id = 'unexpected'; Level = 'amber'; Title = (T '多次没有正常关机'); Body = ((T '最近 30 天有 {0} 次意外关机或重启，其中 {1} 次找不到蓝屏记录。') -f $kp, $unexplained) + "`n" + (T '这些多半是直接断电、死机后按了电源键，或者蓝屏时没能写出记录。'); Fixes = @('memtest', 'chkscan', 'reliability'); Plan = @()
                   Todo = @((T '台式机检查电源和插线板；笔记本检查电池'), (T '死机时屏幕定住不动的，多半是显卡、内存或硬盘的问题')) }
    }
    # 7. 系统文件
    if ($sp.Count -gt 0 -and -not $storage) {
        $out += @{ Id = 'sysfile'; Level = 'amber'; Title = (T '系统进程意外退出'); Body = ((T '{0}。') -f (& $codeList $sp)); Fixes = @('sfccheck', 'sfcrepair', 'rstrui'); Plan = @('sfcrepair')
                   Todo = @((T '修复系统文件后用几天看还会不会出现'), (T '最近装过更新、驱动或软件之后才开始的，可以用系统还原回到之前')) }
    }
    # 8. 时钟
    if ($ck -and ($ck.Wrong -or ($ck.SyncFails -gt 0 -and $ck.SyncOk -eq 0))) {
        $lines = @()
        if ($ck.BehindBuild -gt 0) { $lines += (T '系统时间比本工具的发布日期（{0:yyyy-MM-dd}）还早 {1} 天，肯定不对。') -f $script:AppBuilt, $ck.BehindBuild }
        elseif ($ck.Wrong) { $lines += (T '系统自己写的文件里有比「现在」还晚 {0} 天的（{1:yyyy-MM-dd}）：时钟被往回调过，或者主板电池没电后时间重置了。') -f $ck.AheadDays, $ck.Newest }
        if ($ck.DnsFail) { $lines += (T '时间服务连不上 time.windows.com（域名解析不了）：这台电脑上不了外网，时间没法自动校准，只能手动改。') }
        elseif ($ck.SyncFails -gt 0) { $lines += (T '最近 30 天时间服务同步失败 {0} 次，一次也没成功。') -f $ck.SyncFails }
        $lines += (T '时间不对会让网页提示证书错误、Windows 激活和更新失败，蓝屏和日志记下的时间也跟着不准。')
        $todo = @((T '把时间改对：点「日期和时间」，在「日期和时间」选项卡点「更改日期和时间」'), (T '台式机每次断电后时间都变回去，就是主板上的纽扣电池（CR2032）没电了，换一颗'))
        if (-not $ck.DnsFail) { $todo = @((T '点「同步系统时间」；同步不了再手动改')) + $todo }
        $out += @{ Id = 'clock'; Level = $(if ($ck.Wrong) { 'red' } else { 'amber' }); Title = $(if ($ck.Wrong) { (T '系统时间不准') } else { (T '系统时间一直同步不了') }); Body = ($lines -join "`n"); Fixes = @('datetime', 'timesync', 'timecheck'); Plan = $(if ($ck.DnsFail) { @('datetime') } else { @('timesync') }); Todo = $todo }
    }
    # 9. 系统版本太旧
    if ($w -and $w.BuildNo -gt 0 -and $w.BuildNo -lt 19045 -and [string]$w.Product -notmatch 'Server|LTSC|LTSB') {   # 服务器版和长期服务版支持得更久
        $todo = @((T '先把硬盘的问题解决掉、把资料备份好'), (T '装着专用软件的电脑（测试设备、采集卡、工控软件）先问清楚这些软件支不支持新版本 Windows'), (T '在能上网的电脑上用微软的「媒体创建工具」做一个 Windows 安装 U 盘，在这台电脑上运行里面的 setup.exe，选「保留个人文件和应用」升级到 Windows 10 22H2 或 Windows 11'))
        if ($w.LastUpdate) { $todo += (T '这台电脑最近一次装更新是 {0:yyyy-MM-dd}（{1}），之后的安全补丁都没有') -f $w.LastUpdate, $w.LastUpdateId }
        $out += @{ Id = 'oldwin'; Level = 'amber'; Title = (T 'Windows 版本太旧'); Body = ((T '这台电脑是 {0} {1}（版本号 {2}），早就收不到安全更新和修复补丁了：很多蓝屏和驱动问题在新版本里已经修好。') -f $w.Product, $w.Release, $w.BuildNo); Fixes = @('winupdate'); Plan = @(); Todo = $todo }
    }
    if ($out.Count -eq 0) {
        $t = if ($bcs.Count -gt 0) { (T '有蓝屏记录，但看不出集中在哪一类：先检查系统文件，再看每次蓝屏下面的说明。') } else { (T '最近没有蓝屏转储，也没有意外关机、硬件错误和磁盘错误的记录。') }
        $out += @{ Id = 'none'; Level = $(if ($bcs.Count -gt 0) { 'blue' } else { 'green' }); Title = $(if ($bcs.Count -gt 0) { (T '没有明显的规律') } else { (T '没发现问题') }); Body = $t; Fixes = $(if ($bcs.Count -gt 0) { @('sfccheck', 'diagpack') } else { @() }); Plan = $(if ($bcs.Count -gt 0) { @('sfcrepair') } else { @() }); Todo = @() }
    }
    return $out
}

# ---------- 常见问题修复：论坛里流传最广、确实有效的修法 ----------
# 每一步都写清楚改不改东西；只用 Windows 自带的命令，在看得见的终端窗口里跑。
# Kind：check 只看不改 / fix 会改动（先确认）/ open 打开 Windows 自带的工具 / go 跳到本工具的某一页 / special 本工具自己做
# 不删任何文件：Windows 更新组件是改名留底，chkdsk 只在下次开机检查，网络重置要重启才生效
function Get-FixCatalog {
    $sr = if ($env:SystemRoot) { $env:SystemRoot } else { 'C:\Windows' }; $sd = if ($env:SystemDrive) { $env:SystemDrive } else { 'C:' }
    $ts = '{0:yyyyMMdd-HHmmss}' -f (Get-Date)
    $s = [ordered]@{}
    $s.crashtab   = @{ Name = (T '看蓝屏诊断'); Kind = 'go'; Go = 'crash'; Lvl = 0; Desc = (T '本页「蓝屏和崩溃」：每次蓝屏是什么错、可能是谁，几次放在一起的结论') }
    $s.hwtab      = @{ Name = (T '看硬盘健康'); Kind = 'go'; Go = 'hw'; Lvl = 0; Desc = (T '本页「硬件」：硬盘的健康状态、温度、磨损、读错误') }
    $s.boottab    = @{ Name = (T '看开机用时'); Kind = 'go'; Go = 'boot'; Lvl = 1; Desc = (T '本页「开机用时」：Windows 点名拖慢开机的程序') }
    $s.startapps  = @{ Name = (T '管理开机启动'); Kind = 'go'; Go = 'startup'; Lvl = 1; Desc = (T '「软件管理 → 开机启动」：关掉不需要开机就运行的程序') }
    $s.sfccheck   = @{ Name = (T '检查系统文件'); Kind = 'check'; Lvl = 0; Cmd = 'echo === sfc /verifyonly === & sfc /verifyonly & echo. & echo === DISM /ScanHealth === & DISM /Online /Cleanup-Image /ScanHealth'; Desc = (T 'sfc /verifyonly 和 DISM /ScanHealth：只检查系统文件和系统映像有没有损坏，不改任何东西。要几分钟') }
    $s.dismcheck  = @{ Name = (T '快速检查系统映像'); Kind = 'check'; Lvl = 1; Cmd = 'DISM /Online /Cleanup-Image /CheckHealth'; Desc = (T 'DISM /CheckHealth：几秒钟看一下系统映像有没有被标记为损坏，不改东西') }
    $s.sfcrepair  = @{ Name = (T '修复系统文件…'); Kind = 'fix'; Lvl = 0; Cmd = ('echo === DISM /RestoreHealth === & DISM /Online /Cleanup-Image /RestoreHealth & echo. & echo {0} & echo. & echo === sfc /scannow === & sfc /scannow' -f (T '上不了外网时 DISM 会报错（0x800f081f、0x800f0906），不要紧：接着运行的 sfc 用的是本机的备份，照样有效。')); Desc = (T '先 DISM /RestoreHealth 修好系统映像（可能要联网下载），再 sfc /scannow 把损坏的系统文件换成正常的。只动 Windows 自己的文件，不碰你的资料。十几分钟到半小时')
                      Confirm = (T "会运行 DISM /RestoreHealth 和 sfc /scannow：把损坏的系统文件换成正常的副本。这会改动系统文件（只动 Windows 自己的文件，不碰你的资料），DISM 可能要联网下载，一共要十几分钟到半小时，中途不要关窗口。`n`n可以先用「检查系统文件」看一眼有没有问题，再决定要不要修复。") }
    $s.chkscan    = @{ Name = (T '扫描 C 盘文件系统'); Kind = 'check'; Lvl = 0; Cmd = ('chkdsk {0} /scan' -f $sd); Desc = (T 'chkdsk /scan：在线扫描 C 盘的文件系统，不用重启、不锁盘。发现问题会提示下一步') }
    $s.chkfix     = @{ Name = (T '下次开机检查并修复 C 盘…'); Kind = 'fix'; Lvl = 1; Reboot = $true; Cmd = ('echo {2}| chkdsk {0} /f & echo. & echo {1}' -f $sd, ((T '重启电脑后会先检查 {0}，期间不要断电。不想检查了可以运行 chkntfs /x {0}') -f $sd), (Get-YesLetter)); Desc = (T 'chkdsk /f：安排在下次开机时检查并修复 C 盘的文件系统。开机会多花几分钟到一小时，期间不能断电。可以撤销')
                      Confirm = (T "会安排在下次开机时检查并修复 C 盘（chkdsk /f）。开机时会先检查，可能要几分钟到一小时，期间不要断电、不要强制关机。`n`n如果硬盘可能在坏（蓝屏诊断说硬盘掉线、硬件页里硬盘健康报警），请先把重要资料备份出来再做：检查会大量读写硬盘。`n`n不想检查了，可以用「取消开机检查」撤销。") }
    $s.chkundo    = @{ Name = (T '取消开机检查'); Kind = 'fix'; Lvl = 1; Harmless = $true; Cmd = ('chkntfs /x {0} & echo. & echo {1}' -f $sd, ((T '已取消 {0} 的开机检查。') -f $sd)); Desc = (T 'chkntfs /x：撤销上面安排的开机检查') }
    $s.memtest    = @{ Name = (T 'Windows 内存诊断'); Kind = 'open'; Lvl = 0; Exe = "$sr\System32\mdsched.exe"; Desc = (T '打开 Windows 自带的内存诊断：选「立即重新启动并检查」或「下次启动时检查」，大约 15 分钟，结果在重启后右下角提示') }
    $s.diskpower  = @{ Name = (T '关闭硬盘省电…'); Kind = 'special'; Lvl = 1; Desc = (T '把当前电源计划里的「PCI Express 链路状态电源管理」「AHCI 链路电源管理」「关闭硬盘」改成不省电。治硬盘掉线、卡顿最常用的一招；笔记本续航会少一点。改之前记下原来的值，随时能恢复')
                      Confirm = (T "会把当前电源计划里这三项改成不省电：`n• PCI Express 链路状态电源管理 → 关闭`n• AHCI 链路电源管理（HIPM/DIPM）→ 活动`n• 在此时间后关闭硬盘 → 从不`n`n硬盘、固态硬盘不再进入省电状态，能避免省电后唤醒失败导致的掉盘和卡顿。笔记本用电池时续航会少一点。原来的值会记下来，随时可以点「恢复硬盘省电」改回去。") }
    $s.diskpowerundo = @{ Name = (T '恢复硬盘省电'); Kind = 'special'; Lvl = 0; Desc = (T '把上面改过的三项恢复成改之前的值') }
    $s.devmgmt    = @{ Name = (T '设备管理器'); Kind = 'open'; Lvl = 0; Exe = "$sr\System32\devmgmt.msc"; Desc = (T '更新、回退或卸载驱动：右键设备 →「属性」→「驱动程序」。带黄色感叹号的设备有问题') }
    $s.rstrui     = @{ Name = (T '系统还原'); Kind = 'open'; Lvl = 0; Exe = "$sr\System32\rstrui.exe"; Desc = (T '回到以前的还原点：会撤销那之后装的程序、驱动和更新，你的文档、照片不受影响。向导里每一步都可以取消') }
    $s.winupdate  = @{ Name = (T 'Windows 更新'); Kind = 'open'; Lvl = 0; Uri = 'ms-settings:windowsupdate'; Desc = (T '打开 Windows 更新：装最新的补丁和驱动') }
    $s.wutrouble  = @{ Name = (T '更新疑难解答'); Kind = 'open'; Lvl = 0; Uri = 'ms-settings:troubleshoot'; Desc = (T '打开 Windows 自带的疑难解答，运行「Windows 更新」那一项') }
    $s.wureset    = @{ Name = (T '重置 Windows 更新组件…'); Kind = 'fix'; Lvl = 1
                      Cmd = ('net stop wuauserv & net stop cryptSvc & net stop bits & net stop msiserver & ren "{0}\SoftwareDistribution" SoftwareDistribution.bak-{1} & ren "{0}\System32\catroot2" catroot2.bak-{1} & net start msiserver & net start bits & net start cryptSvc & net start wuauserv & echo. & echo {2}' -f $sr, $ts, ((T '旧的更新缓存改了名留在原处（{0}、{1}），确认更新正常后可以手动删掉。') -f "SoftwareDistribution.bak-$ts", "catroot2.bak-$ts"))
                      Desc = (T '更新一直失败、卡在百分之几时最常用的修法：暂停更新服务，把更新缓存文件夹改名（不删除），再启动服务，Windows 会重新下载。更新历史的显示会变空，已装的更新不受影响')
                      Confirm = (T "会暂停 Windows 更新、加密、后台传输、安装程序这四个服务，把 SoftwareDistribution 和 catroot2 两个更新缓存文件夹改名留底（不删除），再把服务启动起来。`n`nWindows 会重新下载需要的更新；「更新历史」的列表会变空，已经装好的更新不受影响。正在安装更新时不要做。") }
    $s.flushdns   = @{ Name = (T '清除 DNS 缓存'); Kind = 'fix'; Lvl = 0; Harmless = $true; Cmd = 'ipconfig /flushdns'; Desc = (T 'ipconfig /flushdns：网站换了地址、个别网站打不开时用。只清缓存，马上生效') }
    $s.netinfo    = @{ Name = (T '查看网络状态'); Kind = 'check'; Lvl = 0; Cmd = 'ipconfig /all & echo. & echo === ping www.microsoft.com === & ping -n 4 www.microsoft.com & echo. & nslookup www.microsoft.com'; Desc = (T 'ipconfig /all、ping、nslookup：看网卡有没有拿到地址、能不能解析域名和连上外网。不改东西') }
    $s.netreset   = @{ Name = (T '重置网络…'); Kind = 'fix'; Lvl = 1; Reboot = $true; Cmd = ('netsh winsock reset & netsh int ip reset & ipconfig /flushdns & echo. & echo {0}' -f (T '重启电脑后生效。')); Desc = (T 'netsh winsock reset 和 netsh int ip reset：网络设置被软件改乱、能连上 Wi-Fi 却上不了网时用。要重启；手动设的固定 IP 要重新填')
                      Confirm = (T "会把 Winsock 和 TCP/IP 设置恢复成默认（netsh winsock reset、netsh int ip reset），并清除 DNS 缓存，重启电脑后生效。`n`n• 手动设置的固定 IP 地址和 DNS 可能要重新填，先记下来`n• 部分 VPN、加速器类软件可能要重新安装`n`n只在上不了网、其他办法都试过时再用。") }
    $s.netsettings = @{ Name = (T '网络和 Internet 设置'); Kind = 'open'; Lvl = 0; Uri = 'ms-settings:network-status'; Desc = (T '打开网络设置：里面有网络疑难解答和「网络重置」') }
    $s.ncpa       = @{ Name = (T '网络连接'); Kind = 'open'; Lvl = 1; Exe = "$sr\System32\control.exe"; Args = 'ncpa.cpl'; Desc = (T '打开网络连接：禁用再启用网卡、看网卡属性') }
    $s.timecheck  = @{ Name = (T '检查时间准不准'); Kind = 'check'; Lvl = 0; Cmd = ('w32tm /tz & echo. & echo === {0} === & w32tm /stripchart /computer:time.windows.com /samples:3 /dataonly' -f (T '和 time.windows.com 比较，o: 后面是相差的秒数')); Desc = (T 'w32tm /stripchart：和微软的时间服务器比一比差多少秒。只看不改，要联网') }
    $s.timesync   = @{ Name = (T '同步系统时间'); Kind = 'fix'; Lvl = 0; Harmless = $true; Cmd = ('net start w32time & w32tm /resync & echo. & echo {0} & start ms-settings:dateandtime' -f (T '如果上面提示时间差太大、没有同步：请在打开的「日期和时间」里手动改，或者先关再开「自动设置时间」。')); Desc = (T '启动 Windows 时间服务并马上同步一次。差得太多时 Windows 不肯自动改，会打开「日期和时间」让你手动改') }
    $s.datetime   = @{ Name = (T '日期和时间'); Kind = 'open'; Lvl = 0; Exe = "$sr\System32\control.exe"; Args = 'timedate.cpl'; Desc = (T '打开「日期和时间」：点「更改日期和时间」手动改成正确的时间，上不了网的电脑只能这样改') }
    $s.faststartup = @{ Name = (T '关闭快速启动…'); Kind = 'special'; Lvl = 1; Desc = (T '快速启动让「关机」其实是半休眠：驱动出错会一直带到下次开机。关掉后关机就是真关机，开机慢几秒。随时能再打开')
                      Confirm = (T "会关闭快速启动（控制面板 → 电源选项 →「启用快速启动」）。`n`n关掉以后「关机」就是真正的关机，驱动和设备每次都重新初始化：能解决关机变重启、睡眠唤醒失败、开机后设备不正常这类问题。代价是开机慢几秒。`n`n随时可以在这里再打开。") }
    $s.powerreq   = @{ Name = (T '查看谁不让电脑睡眠'); Kind = 'check'; Lvl = 1; Cmd = 'echo === powercfg /requests === & powercfg /requests & echo. & echo === powercfg /lastwake === & powercfg /lastwake & echo. & echo === powercfg /waketimers === & powercfg /waketimers'; Desc = (T 'powercfg /requests、/lastwake、/waketimers：哪个程序或设备阻止睡眠、上次是谁唤醒的。不改东西') }
    $s.audiorestart = @{ Name = (T '重启音频服务'); Kind = 'fix'; Lvl = 0; Harmless = $true; Cmd = ('net stop audiosrv & net start audiosrv & echo. & echo {0}' -f (T '已重启 Windows Audio 服务。')); Desc = (T '突然没声音时先试这个：重启 Windows Audio 服务，几秒钟，正在播放的声音会断一下') }
    $s.soundcpl   = @{ Name = (T '声音设置'); Kind = 'open'; Lvl = 0; Exe = "$sr\System32\control.exe"; Args = 'mmsys.cpl'; Desc = (T '看默认的播放设备对不对，耳机和音箱是不是选反了') }
    $s.icons      = @{ Name = (T '刷新图标缓存'); Kind = 'fix'; Lvl = 0; Harmless = $true; Cmd = ('ie4uinit.exe -show & echo. & echo {0}' -f (T '已刷新。还不对的话，注销再登录一次。')); Desc = (T 'ie4uinit -show：图标显示成白块或者是别的程序的图标时用。马上生效，不用重启') }
    $s.wsreset    = @{ Name = (T '重置应用商店缓存'); Kind = 'fix'; Lvl = 0; Harmless = $true; Exe = "$sr\System32\wsreset.exe"; Desc = (T 'wsreset：应用商店打不开、下载一直卡住时用。会清掉商店的缓存并重新打开商店，不影响装好的应用') }
    $s.reliability = @{ Name = (T '可靠性监视器'); Kind = 'open'; Lvl = 0; Exe = "$sr\System32\perfmon.exe"; Args = '/rel'; Desc = (T '按天列出程序崩溃、蓝屏、更新失败，看问题从哪天开始') }
    $s.eventvwr   = @{ Name = (T '事件查看器'); Kind = 'open'; Lvl = 1; Exe = "$sr\System32\eventvwr.msc"; Desc = (T 'Windows 的全部日志：「Windows 日志 → 系统」里看错误和警告') }
    $s.dumpdir    = @{ Name = (T '打开转储文件夹'); Kind = 'open'; Lvl = 0; Folder = ($sr + '\Minidump'); Desc = (T '蓝屏转储所在的文件夹（C:\Windows\Minidump）：可以拷出来给别人分析') }
    $s.vendor     = @{ Name = (T '厂商驱动下载页'); Kind = 'special'; Lvl = 0; Desc = (T '按这台电脑的厂商和型号（Dell 按服务编号）打开 BIOS、驱动和固件的下载页，链接同时复制下来：这台电脑上不了外网时，到别的电脑上打开、下载好用 U 盘拷过来') }
    $s.ahciguide  = @{ Name = (T '改用 Windows 自带的硬盘驱动…'); Kind = 'special'; Lvl = 0; Desc = (T '硬盘接在 Intel RST（RAID On）上、更新驱动和 BIOS 后还掉线时：把 BIOS 的硬盘模式改成 AHCI，改用 Windows 自带的驱动。显示这台电脑能不能改、详细步骤和改回去的办法；要进 BIOS，本工具不替你改') }
    $s.diagpack   = @{ Name = (T '导出诊断包…'); Kind = 'special'; Lvl = 0; Desc = (T '把蓝屏转储、最近 30 天的系统和应用日志、系统信息、驱动列表、本工具的诊断结论打成一个 zip，方便发给懂的人看。只读不改') }
    $p = @(
        @{ Id = 'bsod'; Title = (T '蓝屏、死机、自动重启'); Desc = (T '先看蓝屏诊断的结论，点结论里的「按建议处理」；再按「系统文件 → 硬盘 → 内存 → 驱动」的顺序排查。一次只改一样，改完用几天看还会不会出现。'); Steps = @('crashtab', 'sfccheck', 'sfcrepair', 'chkscan', 'memtest', 'devmgmt', 'vendor', 'rstrui', 'diagpack') },
        @{ Id = 'disk'; Title = (T '硬盘掉线、卡顿、读写出错'); Desc = (T '蓝屏代码 0x7A、0xEF、0xF4，系统突然卡住几十秒又恢复，磁盘占用一直 100%，都可能是硬盘或硬盘连接的问题。先备份资料。'); Steps = @('hwtab', 'diskpower', 'diskpowerundo', 'faststartup', 'vendor', 'chkscan', 'chkfix', 'chkundo', 'devmgmt', 'ahciguide') },
        @{ Id = 'sysfile'; Title = (T '系统文件损坏'); Desc = (T '系统设置或自带程序打不开、提示缺少某个 dll、装完更新后出怪问题。'); Steps = @('sfccheck', 'dismcheck', 'sfcrepair', 'rstrui') },
        @{ Id = 'update'; Title = (T 'Windows 更新失败或一直卡住'); Desc = (T '更新报错、反复安装同一个更新、卡在某个百分比不动。系统时间不对也会让更新失败，先看时间。'); Steps = @('timecheck', 'wutrouble', 'wureset', 'sfcrepair', 'winupdate') },
        @{ Id = 'net'; Title = (T '上不了网、个别网站打不开'); Desc = (T '从轻到重：先看网络状态，再清 DNS 缓存，最后才重置网络。'); Steps = @('netinfo', 'flushdns', 'netsettings', 'ncpa', 'netreset') },
        @{ Id = 'time'; Title = (T '时间不准'); Desc = (T '网页提示证书错误或「你的时钟快了 / 慢了」、更新失败、文件时间对不上。台式机每次断电后时间都变回去，是主板纽扣电池（CR2032）没电了，要换电池。'); Steps = @('timecheck', 'timesync', 'datetime') },
        @{ Id = 'sleep'; Title = (T '关机变重启、睡眠后醒不来、开机后设备不正常'); Desc = (T '多半和快速启动、驱动的电源管理有关。'); Steps = @('faststartup', 'powerreq', 'devmgmt') },
        @{ Id = 'sound'; Title = (T '没有声音'); Desc = (T '先看是不是选错了播放设备，再重启音频服务；还不行就到设备管理器里更新声卡驱动。'); Steps = @('soundcpl', 'audiorestart', 'devmgmt') },
        @{ Id = 'icons'; Title = (T '图标显示不对、应用商店打不开'); Desc = (T '图标变白块或显示成别的程序的图标；应用商店转圈、下载卡住。'); Steps = @('icons', 'wsreset') },
        @{ Id = 'slow'; Title = (T '开机慢'); Desc = (T '看 Windows 点名的拖慢开机的程序，把不需要的开机启动关掉。'); Steps = @('boottab', 'startapps') },
        @{ Id = 'collect'; Title = (T '把信息发给别人帮忙看'); Desc = (T '诊断包里有转储、日志和系统信息，可能包含电脑名、用户名、装过的软件和内存片段，只发给你信任的人。'); Steps = @('diagpack', 'dumpdir', 'reliability', 'eventvwr') }
    )
    return @{ Steps = $s; Problems = $p }
}

# ---------- 硬盘省电、快速启动：改之前记下原来的值，随时能恢复 ----------
function Get-PowerFixItems {
    return @(
        @{ Sub = 'SUB_PCIEXPRESS'; Set = 'ASPM'; Want = 0; Name = (T 'PCI Express 链路状态电源管理') },
        @{ Sub = '0012ee47-9041-4b5d-9b77-535fba8b1442'; Set = '0b2d69d7-a2a1-449c-9680-f91c70521c60'; Want = 0; Name = (T 'AHCI 链路电源管理（HIPM/DIPM）') },
        @{ Sub = 'SUB_DISK'; Set = 'DISKIDLE'; Want = 0; Name = (T '在此时间后关闭硬盘') }
    )
}
function Get-ActiveSchemeGuid {
    $o = (& "$sys32\powercfg.exe" /getactivescheme 2>$null) -join ' '
    $m = [regex]::Match($o, '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}')
    if ($m.Success) { return $m.Value } else { return '' }
}
# powercfg /q 的输出最后两个 0x 数就是当前的交流、直流值（标签随系统语言变，数字格式不变）
function Get-PowerValue([string]$scheme, [string]$sub, [string]$set) {
    $o = @(& "$sys32\powercfg.exe" /q $scheme $sub $set 2>$null)
    if ($LASTEXITCODE -ne 0) { return $null }
    $hex = @([regex]::Matches(($o -join "`n"), '0x([0-9a-fA-F]{8})') | ForEach-Object { [Convert]::ToUInt32($_.Groups[1].Value, 16) })
    if ($hex.Count -lt 2) { return $null }
    return @{ Ac = [long]$hex[$hex.Count - 2]; Dc = [long]$hex[$hex.Count - 1] }
}
function Set-DiskPowerFix([bool]$on) {
    $pc = "$sys32\powercfg.exe"
    if ($on) {
        $g = Get-ActiveSchemeGuid
        if (-not $g) { return @{ Ok = $false; Why = (T '读不到当前的电源计划') } }
        $undo = @(); $names = @()
        foreach ($it in (Get-PowerFixItems)) { $v = Get-PowerValue $g $it.Sub $it.Set; if ($v) { $undo += @{ Sub = $it.Sub; Set = $it.Set; Ac = $v.Ac; Dc = $v.Dc }; $names += $it.Name } }
        if ($undo.Count -eq 0) { return @{ Ok = $false; Why = (T '当前电源计划里没有这几项设置') } }
        # 先把原来的值记下来再改；已经记过（改过一次还没恢复）就保留最早的那份
        if (-not (Get-Setting 'PowerFixUndo' '')) { Set-Setting 'PowerFixUndo' (ConvertTo-Json @{ Scheme = $g; Items = $undo } -Compress -Depth 4) }
        if (-not (Get-Setting 'PowerFixUndo' '')) { return @{ Ok = $false; Why = (T '没能记下原来的设置，所以没有改') } }
        foreach ($u in $undo) { $it = @(Get-PowerFixItems | Where-Object { $_.Set -eq $u.Set })[0]; & $pc /setacvalueindex $g $u.Sub $u.Set $it.Want 2>$null | Out-Null; & $pc /setdcvalueindex $g $u.Sub $u.Set $it.Want 2>$null | Out-Null }
        & $pc /setactive $g 2>$null | Out-Null
        OpLog '系统设置' (T '关闭硬盘和 PCIe 省电') $g ($names -join (T '、'))
        return @{ Ok = $true; Names = $names }
    }
    $j = Get-Setting 'PowerFixUndo' ''
    if (-not $j) { return @{ Ok = $false; Why = (T '没有改过，不用恢复') } }
    try { $u = ConvertFrom-Json $j } catch { return @{ Ok = $false; Why = (T '记下的原值读不出来') } }
    foreach ($it in @($u.Items)) { & $pc /setacvalueindex $u.Scheme $it.Sub $it.Set ([long]$it.Ac) 2>$null | Out-Null; & $pc /setdcvalueindex $u.Scheme $it.Sub $it.Set ([long]$it.Dc) 2>$null | Out-Null }
    & $pc /setactive (Get-ActiveSchemeGuid) 2>$null | Out-Null
    Set-Setting 'PowerFixUndo' ''
    OpLog '系统设置' (T '恢复硬盘和 PCIe 省电') ([string]$u.Scheme) ''
    return @{ Ok = $true }
}
function Get-FastStartup {
    $h = Get-HiberInfo
    if (-not $h.Exists) { return 'na' }
    $v = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power' -ErrorAction SilentlyContinue).HiberbootEnabled
    if ($v -eq 0) { return 'off' } else { return 'on' }
}
function Set-FastStartup([bool]$on) {
    Set-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power' -Name HiberbootEnabled -Value ([int]$on) -Type DWord -ErrorAction Stop
    OpLog '系统设置' $(if ($on) { (T '打开快速启动') } else { (T '关闭快速启动') }) 'HiberbootEnabled' ([string][int]$on)
}
function Get-PowerFixState { return @{ FastStartup = (Get-FastStartup); DiskFix = [bool](Get-Setting 'PowerFixUndo' '') } }

# ---------- 诊断包 ----------
# 运行一个命令行程序，按控制台代码页读它的输出（systeminfo、driverquery 写的是 OEM 编码）。超时就不等了，不结束它
function Invoke-Capture([string]$exe, [string]$argLine, [int]$timeoutSec = 120) {
    $p = New-Object Diagnostics.Process
    $p.StartInfo.FileName = $exe; $p.StartInfo.Arguments = $argLine; $p.StartInfo.UseShellExecute = $false
    $p.StartInfo.RedirectStandardOutput = $true; $p.StartInfo.RedirectStandardError = $true; $p.StartInfo.CreateNoWindow = $true
    # 控制台程序按「系统区域设置」的 OEM 代码页输出（中文系统是 936），和界面语言、当前用户的区域无关
    $oem = 0; try { $oem = [int](Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Nls\CodePage' -ErrorAction Stop).OEMCP } catch {}
    if ($oem -le 0) { $oem = [Globalization.CultureInfo]::CurrentCulture.TextInfo.OEMCodePage }
    try { $p.StartInfo.StandardOutputEncoding = [Text.Encoding]::GetEncoding($oem) } catch {}
    try { [void]$p.Start() } catch { return ('(' + $_.Exception.Message + ')') }
    $o = $p.StandardOutput.ReadToEndAsync(); $er = $p.StandardError.ReadToEndAsync()
    if (-not $p.WaitForExit($timeoutSec * 1000)) { return ((T '（{0} 秒没运行完，没等它）') -f $timeoutSec) }
    return ([string]$o.Result + [string]$er.Result)
}
function Get-EventText([string]$log, [int]$days, [int]$max) {
    $sb = New-Object Text.StringBuilder
    try {
        $ev = @(Get-WinEvent -FilterHashtable @{ LogName = $log; Level = @(1, 2, 3); StartTime = (Get-Date).AddDays(-$days) } -MaxEvents $max -ErrorAction Stop)
        foreach ($e in $ev) {
            [void]$sb.AppendLine(('{0:yyyy-MM-dd HH:mm:ss}  {1}  {2}  [{3}]' -f $e.TimeCreated, $e.LevelDisplayName, $e.ProviderName, $e.Id))
            $m = [string]$e.Message
            if ($m) { [void]$sb.AppendLine('    ' + ((@($m -split "`r?`n" | Where-Object { $_.Trim() }) | Select-Object -First 6) -join "`r`n    ")) }
        }
    } catch { [void]$sb.AppendLine($_.Exception.Message) }
    return $sb.ToString()
}
function Format-Bytes([double]$b) { if ($b -ge 1GB) { '{0:N1} GB' -f ($b / 1GB) } elseif ($b -ge 1MB) { '{0:N1} MB' -f ($b / 1MB) } else { '{0:N0} KB' -f ($b / 1KB) } }
# 健康页的内容写成一份纯文本报告（诊断包里的 summary.txt，也能复制给别人）
function Get-HealthReportText($r) {
    $L = New-Object System.Collections.Generic.List[string]
    $L.Add((T '腾挪 ClearC 系统健康报告')); $L.Add(('{0:yyyy-MM-dd HH:mm}  {1}' -f $r.At, $env:COMPUTERNAME)); $L.Add('')
    $w = $r.Win
    if ($w) { $L.Add(('Windows: {0} {1}  {2}.{3}' -f $w.Product, $w.Release, $w.Build, $w.Ubr)); if ($w.Uptime) { $L.Add(((T '开机已经 {0:N1} 天') -f $w.Uptime.TotalDays)) }; if ($w.LastUpdate) { $L.Add(((T '最近一次更新 {0:yyyy-MM-dd} {1}') -f $w.LastUpdate, $w.LastUpdateId)) } }
    if ($r.Clock -and $r.Clock.BehindBuild -gt 0) { $L.Add(((T '时钟不准：系统时间比本工具的发布日期（{0:yyyy-MM-dd}）还早 {1} 天') -f $script:AppBuilt, $r.Clock.BehindBuild)) }
    elseif ($r.Clock -and $r.Clock.Wrong) { $L.Add(((T '时钟可能不准：有比现在晚 {0} 天的系统文件（{1}）') -f $r.Clock.AheadDays, $r.Clock.Source)) }
    $f = $r.Sys
    if ($f) {
        $L.Add(''); $L.Add('== ' + (T '这台电脑'))
        $L.Add(('{0} {1}' -f $f.Maker, $f.Model).Trim())
        if ($f.Bios) { $L.Add(((T 'BIOS {0}（{1:yyyy-MM-dd}），服务编号 / 序列号 {2}') -f $f.Bios, $f.BiosDate, $f.Serial)) }
        if ($f.SysDisk) { $L.Add(((T '系统盘：{0}，固件 {1}，接口 {2}') -f $f.SysDisk.Name, $f.SysDisk.Firmware, $f.SysDisk.Bus)) }
        foreach ($s in @($f.Stor)) { if ($s) { $L.Add(((T '存储驱动：{0}，{1}，{2:yyyy-MM-dd}，{3}') -f $s.Device, $s.Version, $s.Date, $s.Provider)) } }
        if ($f.BitLocker -ge 0) { $L.Add('BitLocker: ' + $(if ($f.BitLocker -eq 1) { (T '开着') } else { (T '关着') })) }
    }
    $ck = $r.Clock; if ($ck) { $L.Add(((T '时间同步：最近 30 天失败 {0} 次、成功 {1} 次{2}') -f $ck.SyncFails, $ck.SyncOk, $(if ($ck.DnsFail) { (T '，连不上时间服务器（上不了外网）') } else { '' }))) }
    $pw = $r.Power; if ($pw) { $L.Add(((T '硬盘省电：{0}；快速启动：{1}') -f $(if ($pw.DiskFix) { (T '已关闭（本工具改的，能恢复）') } else { (T '系统默认') }), $(switch ($pw.FastStartup) { 'on' { (T '开') } 'off' { (T '关') } default { (T '没有') } }))) }
    $L.Add(''); $L.Add('== ' + (T '诊断结论和处理办法'))
    $fc = $null; try { $fc = Get-FixCatalog } catch {}
    foreach ($v in @($r.Verdicts)) {
        $L.Add(('[{0}] {1}' -f $v.Level, $v.Title)); foreach ($x in ([string]$v.Body -split "`n")) { $L.Add('    ' + $x) }
        $pl = @($v.Plan | Where-Object { $_ -and $fc -and $fc.Steps.Contains($_) } | ForEach-Object { ([string]$fc.Steps[$_].Name).TrimEnd('…') })
        if ($pl.Count) { $L.Add('    ' + (T '本工具能直接做（结论下面的「按建议处理」）：') + ($pl -join (T '、'))) }
        $td = @($v.Todo | Where-Object { $_ })
        if ($td.Count) { $L.Add('    ' + (T '需要你自己做：')); for ($i = 0; $i -lt $td.Count; $i++) { $L.Add(('      {0}. {1}' -f ($i + 1), $td[$i])) } }
    }
    $bc = @($r.Crash.BugChecks | Where-Object { $_ })
    if ($bc.Count) {
        $L.Add(''); $L.Add('== ' + ((T '最近 30 天的蓝屏记录（{0} 次）') -f $bc.Count))
        foreach ($b in $bc) { $L.Add(('{0:yyyy-MM-dd HH:mm}  0x{1:X} {2}  {3}' -f $b.Time, [long]$b.Code, $b.CodeName, ($b.Params -join ' '))) }
    }
    $L.Add(''); $L.Add('== ' + (T '蓝屏转储'))
    foreach ($d in @($r.Crash.Dumps)) {
        $e = Get-DumpExplain $d
        $L.Add(('{0:yyyy-MM-dd HH:mm}  0x{1:X} {2}  {3}' -f $d.Time, [long]$d.Code, $d.CodeName, $d.Name))
        $L.Add('    ' + $e.Plain); foreach ($x in @($e.Detail)) { $L.Add('    ' + $x) }
        $L.Add(('    params {0}' -f ($d.Params -join ' '))); if (@($d.Stack).Count) { $L.Add(('    stack {0}' -f (@($d.Stack) -join ', '))) }
        if ($d.Error) { $L.Add('    ' + $d.Error) }
    }
    if (@($r.Crash.Dumps).Count -eq 0) { $L.Add((T '（没有）')) }
    $L.Add(''); $L.Add('== ' + (T '最近 30 天的相关事件'))
    foreach ($x in @($r.Crash.Events)) { $L.Add(('{0}  {1}  ×{2}  {3:yyyy-MM-dd HH:mm}  {4}' -f $x.Source, $x.What, $x.Count, $x.Last, $x.Sample)) }
    $L.Add(''); $L.Add('== ' + (T '硬盘'))
    foreach ($d in @($r.Disks)) { $L.Add(('{0}  {1}  {2}  temp={3} wear={4} readErrors={5} hours={6}' -f $d.Drive, $d.Model, $d.Health, $d.Temp, $d.Wear, $d.ReadErrors, $d.Hours)) }
    $m = $r.Mem; if ($m -and $m.Ok) { $L.Add(''); $L.Add((('== ' + (T '内存') + '  {0} / {1}  WHEA={2}') -f (Format-Bytes ($m.Total - $m.Free)), (Format-Bytes $m.Total), $m.Whea)) }
    $c = $r.Cpu; if ($c -and $c.Ok) { $L.Add(('== CPU  {0}  {1}%' -f $c.Name, $c.Load)) }
    $L.Add(''); $L.Add('== ' + (T '最近 30 天装的驱动'))
    foreach ($x in @($r.Crash.Drivers)) { $L.Add(('{0:yyyy-MM-dd HH:mm}  {1}  {2}  {3}' -f $x.When, $x.Provider, $x.Name, $x.Version)) }
    if ($w) { $L.Add(''); $L.Add('== ' + (T '有问题的设备')); foreach ($bd in @($w.BadDevices)) { $L.Add(('{0}  ({1}) {2}' -f $bd.Name, $bd.Code, $bd.Note)) } }
    return ($L -join "`r`n")
}
# 诊断包：蓝屏转储、最近 30 天的系统和应用日志、系统信息、驱动列表、健康报告、本工具的操作日志，打成一个 zip。
# 只读这些文件，不改任何东西。中间文件放在 TEMP 里自己建的文件夹，用完逐个删掉（不整个递归删）
function Export-DiagPack([string]$zip, $health) {
    $r = @{ Ok = $false; Path = $zip; Count = 0; Bytes = [double]0; Skipped = @(); Error = '' }
    try { Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem } catch { $r.Error = $_.Exception.Message; return $r }
    if (Test-Path -LiteralPath $zip) { $r.Error = (T '这个文件已经存在'); return $r }
    $tmp = Join-Path ([IO.Path]::GetTempPath()) ('ClearC-diag-{0:yyyyMMdd-HHmmss}' -f (Get-Date))
    $made = New-Object System.Collections.ArrayList
    $fs = $null; $za = $null
    try {
        [void][IO.Directory]::CreateDirectory($tmp)
        $fs = New-Object IO.FileStream($zip, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write)
        $za = New-Object IO.Compression.ZipArchive($fs, [IO.Compression.ZipArchiveMode]::Create)
        $addText = { param($name, $text) $en = $za.CreateEntry($name); $sw = New-Object IO.StreamWriter($en.Open(), (New-Object Text.UTF8Encoding $true)); $sw.Write([string]$text); $sw.Dispose(); $r.Count++ }
        $addFile = { param($name, $path) try { [void][IO.Compression.ZipFileExtensions]::CreateEntryFromFile($za, $path, $name); $r.Count++ } catch { $r.Skipped += ('{0}: {1}' -f $name, $_.Exception.Message) } }
        Progress-Note (T '健康报告')
        if ($health) { & $addText 'summary.txt' (Get-HealthReportText $health) }
        Progress-Note (T '蓝屏转储')
        $md = Join-Path $env:SystemRoot 'Minidump'
        foreach ($f in @(Get-ChildItem -LiteralPath $md -Filter *.dmp -File -Force -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 20)) {
            if ($f.Length -gt 64MB) { $r.Skipped += ('{0}: {1}' -f $f.Name, (T '太大，没放进去')); continue }
            & $addFile ('minidump/' + $f.Name) $f.FullName
        }
        $mem = Join-Path $env:SystemRoot 'MEMORY.DMP'
        if (Test-Path -LiteralPath $mem) { $r.Skipped += ('MEMORY.DMP: ' + (T '完整转储太大，没放进去；需要的话单独拷')) }
        Progress-Note (T '系统和应用日志')
        foreach ($log in 'System', 'Application') {
            $ev = Join-Path $tmp ($log + '.evtx'); [void]$made.Add($ev)
            [void](Invoke-Capture "$sys32\wevtutil.exe" ('epl {0} "{1}" "/q:*[System[TimeCreated[timediff(@SystemTime) <= 2592000000]]]"' -f $log, $ev) 180)
            if (Test-Path -LiteralPath $ev) { & $addFile ('events/' + $log + '.evtx') $ev } else { $r.Skipped += ('{0}.evtx: {1}' -f $log, (T '导出失败')) }
            & $addText ('events/' + $log + '-30days.txt') (Get-EventText $log 30 1500)
        }
        Progress-Note (T '系统信息')
        & $addText 'systeminfo.txt' (Invoke-Capture "$sys32\systeminfo.exe" '' 180)
        & $addText 'drivers.csv' (Invoke-Capture "$sys32\driverquery.exe" '/v /fo csv' 120)
        $dk = ''
        try { $dk += (Get-PhysicalDisk -ErrorAction Stop | Select-Object FriendlyName, MediaType, BusType, HealthStatus, OperationalStatus, Size, FirmwareVersion | Format-List | Out-String -Width 200) } catch { $dk += $_.Exception.Message + "`r`n" }
        try { $dk += (Get-PhysicalDisk -ErrorAction Stop | Get-StorageReliabilityCounter -ErrorAction Stop | Select-Object DeviceId, Temperature, Wear, ReadErrorsTotal, ReadErrorsUncorrected, WriteErrorsTotal, PowerOnHours, StartStopCycleCount | Format-List | Out-String -Width 200) } catch {}
        try { $dk += (Get-Volume -ErrorAction Stop | Format-Table DriveLetter, FileSystemLabel, FileSystem, HealthStatus, Size, SizeRemaining -AutoSize | Out-String -Width 200) } catch {}
        & $addText 'disks.txt' $dk
        $wer = Join-Path $env:ProgramData 'Microsoft\Windows\WER\ReportArchive'
        $wl = @(Get-ChildItem -LiteralPath $wer -Directory -Force -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 200 | ForEach-Object { '{0:yyyy-MM-dd HH:mm}  {1}' -f $_.LastWriteTime, $_.Name })
        & $addText 'wer-reports.txt' ($wl -join "`r`n")
        foreach ($f in @(Get-ChildItem -LiteralPath $script:opLogDir -Filter '*.txt' -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 3)) { & $addFile ('clearc-oplog/' + ('oplog-' + ($f.BaseName -replace '^\D+', '') + '.txt')) $f.FullName }
        if ($r.Skipped.Count -gt 0) { & $addText 'skipped.txt' ($r.Skipped -join "`r`n") }
        $r.Ok = $true
    } catch { $r.Error = $_.Exception.Message }
    finally {
        if ($za) { try { $za.Dispose() } catch {} }
        if ($fs) { try { $fs.Dispose() } catch {} }
        foreach ($f in $made) { try { if ([IO.File]::Exists($f)) { [IO.File]::Delete($f) } } catch {} }
        try { [IO.Directory]::Delete($tmp, $false) } catch {}
    }
    try { $r.Bytes = [double](Get-Item -LiteralPath $zip).Length } catch {}
    if (-not $r.Ok -and (Test-Path -LiteralPath $zip) -and $r.Count -eq 0) { try { [IO.File]::Delete($zip) } catch {} }
    return $r
}
# 后台任务里报进度用；界面线程里调用时什么也不做
function Progress-Note([string]$s) { try { if (Get-Command SetP -ErrorAction SilentlyContinue) { SetP @{ StepName = $s } } } catch {} }

# ---------- 活动监控：窗口开着时每隔几秒采一次样，看谁在吃 CPU、内存、磁盘 ----------
# 一次采样：每个进程的累计 CPU 时间、工作集、累计写入字节（Windows 从进程启动起记的）
function Get-ProcSample {
    $out = @{}
    foreach ($p in @(Try-Cim 'Win32_Process')) {
        $id = [int]$p.ProcessId
        if ($id -le 0) { continue }
        $out[$id] = @{ Pid = $id; Name = [string]$p.Name; Path = [string]$p.ExecutablePath; Cpu100ns = [double]$p.KernelModeTime + [double]$p.UserModeTime; Ws = [double]$p.WorkingSetSize; Write = [double]$p.WriteTransferCount; Read = [double]$p.ReadTransferCount; Started = $p.CreationDate }
    }
    return @{ At = (Get-Date); Procs = $out }
}
# 两次采样的差：这段时间里每个进程用了多少 CPU（占全部核心的百分比）、写了多少；再加上从监控开始到现在的累计
function Compare-ProcSample($prev, $cur, $base, [int]$threads) {
    $rows = @()
    $secs = [math]::Max(0.001, ($cur.At - $prev.At).TotalSeconds)
    foreach ($id in $cur.Procs.Keys) {
        $c = $cur.Procs[$id]
        $p = if ($prev.Procs.ContainsKey($id)) { $prev.Procs[$id] } else { $null }
        $b = if ($base -and $base.Procs.ContainsKey($id)) { $base.Procs[$id] } else { $null }
        $cpu = if ($p) { 100.0 * ($c.Cpu100ns - $p.Cpu100ns) / 10000000.0 / $secs / [math]::Max(1, $threads) } else { 0 }
        $w = if ($p) { $c.Write - $p.Write } else { 0 }
        $wSince = if ($b) { $c.Write - $b.Write } else { $c.Write }   # 监控开始后才出现的进程：从它启动起算
        $rows += @{ Pid = $id; Name = $c.Name; Path = $c.Path; Cpu = [math]::Max(0, $cpu); Ws = $c.Ws; WriteRate = [math]::Max(0, $w) / $secs; WriteSince = [math]::Max(0, $wSince); WriteTotal = $c.Write; ReadTotal = $c.Read }
    }
    return $rows
}

# 一项的指纹：名字加全部路径。清理页的一行和后台按编号找到的那一项必须是同一个东西（清理列表改过后编号会挪位）
function Get-ItemSig($it) { if (-not $it) { return '' }; return ('{0}|{1}' -f $it.N, (@($it.Paths) -join ';')) }
# Kind: cache = 缓存类(删除/跳过)   action = 操作类(执行/跳过)   move = 只能搬(搬到其他盘/跳过)   flex = 可搬可删
function Get-Catalog {
    $docs = [Environment]::GetFolderPath('MyDocuments')
    $desk = [Environment]::GetFolderPath('Desktop')
    $down = (Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders' -EA SilentlyContinue).'{374DE290-123F-4565-9164-39C4925E467B}'
    if ($down) { $down = [Environment]::ExpandEnvironmentVariables($down) } else { $down = "$env:USERPROFILE\Downloads" }
    $safeG  = '安全清理（缓存、临时文件、日志，删了程序会自动重建）'
    $careG  = '清后要重建（删了要重新下载或重新生成，第一次打开会慢一点；默认也清，执行前会单独列出来）'
    $confG  = '默认不清（有代价，看清说明再选）'
    $chatG  = '聊天软件的聊天记录（搬到其他盘：聊天记录和文件原样保留，原位置留链接，软件照常使用）'
    $otherG = '其他可搬的文件夹（数据原样保留，原位置留链接，软件照常使用）'
    $customG = '自定义清理（你在设置里加的文件夹：删除里面的东西，文件夹本身保留）'
    $lib = Get-CacheLibrary
    $list = @()
    # ---- 安全清理：缓存 / 临时文件 / 日志，删了程序自动重建（目录库里的）----
    foreach ($x in $lib) {
        if ($x.Confirm -or $x.Careful) { continue }
        $list += @{ G=$safeG; Kind='cache'; Def=(T '删除'); N=$x.N; Paths=$x.Paths; Note=$x.Note; Filter=$x.Filter; Whole=$x.Whole; Svc=$x.Svc; Lvl=$x.Lvl }
    }
    # ---- 清后要重建：浏览器缓存、缩略图、着色器、下载缓存这类，删了要重新下载或重新生成 ----
    foreach ($x in $lib) {
        if ($x.Confirm -or -not $x.Careful) { continue }
        $list += @{ G=$careG; Kind='cache'; Def=(T '删除'); N=$x.N; Paths=$x.Paths; Note=$x.Note; Filter=$x.Filter; Whole=$x.Whole; Svc=$x.Svc; Lvl=$x.Lvl; Careful=$true }
    }
    $list += @(
        @{ G=$confG; Kind='cache'; Def=(T '跳过'); N=(T '清空回收站');            Note=(T '回收站里是你以前删掉、但还能找回的文件。清空后就永远找不回了，请先打开回收站确认里面没有要的东西')
           Size={ $q = [FsTools]::RecycleBinBytes(); if ($q -ge 0) { [double]$q } else { try { $s = ((New-Object -ComObject Shell.Application).NameSpace(0xA).Items() | Measure-Object -Property Size -Sum).Sum; if ($s) { $s } else { 0 } } catch { 0 } } }
           Act ={ if ($script:recycledThisRun) { Log (T '  这一轮刚把文件放进回收站，不清空回收站（下次再清）') } else { Clear-RecycleBin -Force -ErrorAction SilentlyContinue } } }
        @{ G='安全清理（缓存、临时文件、日志，删了程序会自动重建）'; Kind='cache'; Def=(T '删除'); N=(T 'Windows 传递优化缓存'); Note=(T 'Windows 更新的点对点分发缓存'); Bg=$true
           Size={ try { $s = (Get-DeliveryOptimizationStatus -ErrorAction Stop | Measure-Object -Property FileSize -Sum).Sum; if ($s) { $s } else { 0 } } catch { 0 } }
           Act ={ Delete-DeliveryOptimizationCache -Force -ErrorAction SilentlyContinue } }

        # ---- 默认不清：有代价 ----
        @{ G=$confG; Kind='cache';  Def=(T '跳过'); One=(T '跳过'); N='Windows.old';        Paths=@('C:\Windows.old'); Whole=$true; Note=(T '上一版 Windows 的完整副本。删后不能回退到上一版系统（系统升级 10 天后会自动删）')
           Act ={ Remove-WindowsOld } }
        @{ G=$confG; Kind='action'; Def=(T '跳过'); One=(T '执行'); N=(T '重建 Windows 搜索索引'); Lvl=1; Note=(T '搜索索引膨胀时可重建，重建后通常只剩 1 到 2 GB。重建期间（约 1 小时）搜文件会变慢')
           Size={ $s = 0; foreach ($f in 'C:\ProgramData\Microsoft\Search\Data\Applications\Windows\Windows.edb','C:\ProgramData\Microsoft\Search\Data\Applications\Windows\Windows.db') { $i = Get-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue; if ($i) { $s += $i.Length } }; if ($s -gt 2GB) { $s } else { 0 } }
           Act ={ Stop-Service WSearch -Force -ErrorAction SilentlyContinue; Start-Sleep -Seconds 3; foreach ($f in 'C:\ProgramData\Microsoft\Search\Data\Applications\Windows\Windows.edb','C:\ProgramData\Microsoft\Search\Data\Applications\Windows\Windows.db') { [void](Invoke-SafeRemove -Path $f -Scope list -How delete -What (T '重建 Windows 搜索索引')) }; Set-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows Search' -Name SetupCompletedSuccessfully -Value 0 -ErrorAction SilentlyContinue; Start-Service WSearch -ErrorAction SilentlyContinue } }
        @{ G=$confG; Kind='action'; Def=(T '跳过'); N=(T '关闭休眠 (hiberfil.sys)'); Lvl=1; Paths=@('C:\hiberfil.sys'); Note=(T '休眠文件约等于内存大小。关闭后睡眠不受影响，只是没有「休眠」和「快速启动」')
           Act ={ & "$env:SystemRoot\System32\powercfg.exe" /h off } }
        @{ G=$confG; Kind='action'; Def=(T '跳过'); One=(T '执行'); N=(T '禁用 XTU 超频日志服务'); Lvl=2; Note=(T '外星人 Command Center 的 CPU 超频组件，会持续写几 GB 日志。不超频可禁用，AWCC 的风扇和性能档位不受影响')
           Size={ $s = Get-Service XTU3SERVICE -ErrorAction SilentlyContinue; if ($s -and $s.Status -eq 'Running') { -1 } else { 0 } }
           Act ={ Stop-Service XTU3SERVICE -Force -ErrorAction SilentlyContinue; Set-Service XTU3SERVICE -StartupType Disabled -ErrorAction SilentlyContinue } }
        @{ G=$confG; Kind='cache'; Def=(T '跳过'); One=(T '跳过'); N=(T 'Windows Installer 孤儿安装包'); Lvl=2; Bg=$true; Note=(T 'C:\Windows\Installer 里没有任何已装软件和补丁再引用的安装包（.msi / .msp），多半是软件升级、卸载后留下的。判断方法和 PatchCleaner 一样。删了以后，万一哪个软件修复或卸载时提示找不到安装包，重新下载安装一次即可')
           Size={ $s = [double]0; foreach ($f in (Get-InstallerOrphans)) { $s += $f.Length }; $s }
           Act ={ $n = 0; $b = [double]0; foreach ($f in (Get-InstallerOrphans)) { $r = Invoke-SafeRemove -Item $f -Scope list -How delete -Bytes $f.Length -What (T 'Windows Installer 孤儿安装包'); if ($r.Ok) { $n++; $b += $f.Length } else { Log ((T "  没删掉：{0}（{1}）") -f $f.FullName, $r.Why) } }; Log ((T "  Windows Installer 孤儿安装包：删了 {0} 个，{1}") -f $n, (GB $b)) } }
        @{ G=$confG; Kind='cache'; Def=(T '跳过'); One=(T '跳过'); N=(T '驱动存储里的旧版驱动包'); Lvl=2; Bg=$true; Note=(T '驱动更新后，旧版本的安装包还留在 C:\Windows\System32\DriverStore 里（和 Driver Store Explorer 的判断一样：同一个驱动、同一厂商有更新版本的那些）。用 pnputil 删除，正在使用的删不掉、启动必需的不碰。删了以后不能回滚到旧版驱动')
           Size={ $s = [double]0; foreach ($d in (Get-OldDriverPackages)) { $s += $d.Bytes }; $s }
           Act ={ $n = 0; $b = [double]0; foreach ($d in (Get-OldDriverPackages -Fresh)) { if (Stopping) { break }; $r = Remove-DriverPackage $d.Published; if ($r -eq '') { $n++; $b += $d.Bytes; Log ((T "  已删除旧版驱动包 {0}（{1} {2}）") -f $d.Published, $d.Provider, $d.Version) } else { Log ((T "  没删掉 {0}：{1}") -f $d.Published, $r) } }; Log ((T "  旧版驱动包：删了 {0} 个，{1}") -f $n, (GB $b)) } }
        @{ G=$confG; Kind='cache'; Def=(T '跳过'); One=(T '跳过'); N=(T '开始菜单里失效的快捷方式'); Lvl=1; Bg=$true; Note=(T '指向的程序已经不在了的快捷方式（只看开始菜单，不碰桌面）。目标在没插着的硬盘上的不算。不占什么空间，只是清爽')
           Size={ $s = [double]0; foreach ($f in (Get-BrokenShortcuts)) { $s += $f.Length }; $s }
           Act ={ $n = 0; foreach ($f in (Get-BrokenShortcuts)) { if ((Invoke-SafeRemove -Item $f -Scope list -How delete -What (T '失效的快捷方式')).Ok) { $n++ } }; Log ((T "  删了 {0} 个失效的快捷方式") -f $n) } }
        @{ G=$confG; Kind='cache'; Def=(T '跳过'); One=(T '跳过'); N=(T 'Windows 事件日志'); Lvl=2; Note=(T '系统、应用程序、安全等日志，排查问题的工程师会看。清空后就查不到以前的记录了，不确定就跳过')
           Size={ $s = [double]0; foreach ($f in @(Get-ChildItem -LiteralPath "$env:SystemRoot\System32\winevt\Logs" -Filter '*.evtx' -File -Force -ErrorAction SilentlyContinue)) { $s += $f.Length }; $s }
           Act ={ $n = 0; foreach ($l in @(& "$sys32\wevtutil.exe" el 2>$null)) { if (Stopping) { break }; & "$sys32\wevtutil.exe" cl "$l" 2>$null | Out-Null; if ($LASTEXITCODE -eq 0) { $n++ } }; Log ((T "  清空了 {0} 个事件日志") -f $n) } }
        @{ G=$confG; Kind='action'; Def=(T '跳过'); One=(T '执行'); N=(T 'WinSxS 组件清理 (DISM)'); Lvl=1; Note=(T '清掉系统更新替换下来的旧组件，通常能省 2 到 10 GB。耗时 10 到 20 分钟，完成后建议重启'); Last=$true
           Size={ -1 }
           Act ={ & "$env:SystemRoot\System32\Dism.exe" /Online /Cleanup-Image /StartComponentCleanup /ResetBase | Out-Null }; Slow=$true }

        # ---- 可搬家：数据不能删，但可以整体搬到其他盘并在原位置留链接 ----
        # ---- 聊天软件：聊天记录不能删，整体搬到其他盘，原位置留链接 ----
        @{ G=$chatG; Kind='move'; Def=(T '搬到其他盘'); N=(T '微信/QQ 缓存 (Roaming)');  Paths=@("$env:APPDATA\Tencent");      Apps=@('微信','QQ','企业微信','腾讯会议'); Note=(T '微信、QQ、企业微信、腾讯会议的聊天图片、视频和缓存。搬之前要先退出它们，开着的话会提醒你') }
        @{ G=$chatG; Kind='move'; Def=(T '搬到其他盘'); N=(T '微信/QQ 缓存 (Local)');    Paths=@("$env:LOCALAPPDATA\Tencent"); Apps=@('微信','QQ','企业微信','腾讯会议'); Note=(T '微信、QQ 等腾讯软件的本地缓存') }
        @{ G=$chatG; Kind='move'; Def=(T '搬到其他盘'); N=(T '微信文件 (旧版)');         Paths=@("$docs\WeChat Files","$env:USERPROFILE\WeChat Files");     Apps=@('微信'); Note=(T '微信 3.x 的聊天记录和接收的文件') }
        @{ G=$chatG; Kind='move'; Def=(T '搬到其他盘'); N=(T '微信文件 (新版)');         Paths=@("$docs\xwechat_files","$env:USERPROFILE\xwechat_files");   Apps=@('微信'); Note=(T '微信 4.x 的聊天记录、图片、视频和接收的文件，通常是 C 盘最大的一块') }
        @{ G=$chatG; Kind='move'; Def=(T '搬到其他盘'); N=(T '企业微信文件');            Paths=@("$docs\WXWork");                                         Apps=@('企业微信'); Note=(T '企业微信的聊天记录、图片、文件和缓存') }
        @{ G=$chatG; Kind='move'; Def=(T '搬到其他盘'); N=(T 'QQ 文件');                 Paths=@("$docs\Tencent Files","$env:USERPROFILE\Tencent Files");   Apps=@('QQ'); Note=(T 'QQ 的聊天记录和接收的文件') }
        @{ G=$chatG; Kind='move'; Def=(T '搬到其他盘'); N=(T '飞书聊天记录');            Paths=@("$env:APPDATA\LarkShell");                               Apps=@('飞书'); Note=(T '飞书的聊天记录、图片、文件和缓存。搬之前要先退出飞书') }
        @{ G=$chatG; Kind='move'; Def=(T '搬到其他盘'); N=(T '钉钉聊天记录');            Paths=@("$env:APPDATA\DingTalk");                                Apps=@('钉钉'); Note=(T '钉钉的聊天记录、图片和缓存（每个账号一个以 _v2 结尾的文件夹）。搬之前要先退出钉钉') }
        @{ G=$chatG; Kind='move'; Def=(T '搬到其他盘'); N=(T 'Telegram 聊天记录');       Paths=@("$env:APPDATA\Telegram Desktop");                        Apps=@('Telegram'); Note=(T 'Telegram 电脑版的本地数据、缓存和程序本身。搬之前要先退出 Telegram') }
        @{ G=$chatG; Kind='move'; Def=(T '搬到其他盘'); N=(T 'Discord 数据和缓存');      Paths=@("$env:APPDATA\discord");                               Apps=@('Discord'); Note=(T 'Discord 的登录状态、缓存，以及看过的图片和视频。搬之前要先退出 Discord（包括右下角托盘图标）') }
        @{ G=$chatG; Kind='move'; Def=(T '搬到其他盘'); N=(T 'Slack 数据和缓存');        Paths=@("$env:APPDATA\Slack");                                 Apps=@('Slack'); Note=(T 'Slack 的登录状态、缓存和下载过的文件预览') }
        @{ G=$chatG; Kind='move'; Def=(T '搬到其他盘'); N=(T 'Signal 聊天记录');         Paths=@("$env:APPDATA\Signal");                                Apps=@('Signal'); Note=(T 'Signal 电脑版的聊天记录（加密存放）和收到的附件') }
        @{ G=$chatG; Kind='move'; Def=(T '搬到其他盘'); N=(T 'LINE 聊天记录');           Paths=@("$env:LOCALAPPDATA\LINE\Data");                         Apps=@('LINE'); Note=(T 'LINE 电脑版的聊天记录、图片和收到的文件') }
        @{ G=$chatG; Kind='move'; Def=(T '搬到其他盘'); N=(T 'Viber 聊天记录');          Paths=@("$env:APPDATA\ViberPC");                               Apps=@('Viber'); Note=(T 'Viber 电脑版的聊天记录、图片和视频') }
        @{ G=$chatG; Kind='move'; Def=(T '搬到其他盘'); N=(T 'KakaoTalk 聊天记录');      Paths=@("$env:LOCALAPPDATA\Kakao\KakaoTalk");                   Apps=@('KakaoTalk'); Note=(T 'KakaoTalk 电脑版的聊天记录和图片、视频缓存') }
        @{ G=$chatG; Kind='move'; Def=(T '搬到其他盘'); N=(T 'Zoom 程序和数据');         Paths=@("$env:APPDATA\Zoom");                                  Apps=@('Zoom'); Note=(T 'Zoom 装在这里的程序和本地数据。会议录像默认存在「文档」里的 Zoom 文件夹，那里属于个人文件夹，不动') }

        # ---- 其他可搬的文件夹 ----
        @{ G=$otherG; Kind='move'; Def=(T '跳过');    N=(T '桌面'); Lvl=1;                   Paths=@($desk); NoOneDrive=$true; Note=(T '桌面上的所有文件。搬后桌面照常显示，文件实际在 D 盘') }
        @{ G=$otherG; Kind='move'; Def=(T '跳过');    N=(T '下载'); Lvl=1;                   Paths=@($down); NoOneDrive=$true; Note=(T '下载文件夹。搬后浏览器照常下载到这里，文件实际在 D 盘') }
        @{ G=$otherG; Kind='flex'; Def=(T '跳过');    N=(T '用户目录 .cache'); Lvl=2;        Paths=@("$env:USERPROFILE\.cache"); Note=(T '各类开发工具的缓存（HuggingFace 模型、uv、playwright 等）。删了会重新下载；也可搬走') }
        @{ G=$otherG; Kind='flex'; Def=(T '跳过');    N=(T 'conda 环境 (.conda)'); Lvl=2;    Paths=@("$env:USERPROFILE\.conda"); Note=(T 'conda 创建的 Python 环境。搬走后照常使用；删了要重建环境') }
        @{ G=$otherG; Kind='flex'; Def=(T '跳过');    N=(T 'pip --user 安装的包'); Lvl=2;    Paths=@("$env:APPDATA\Python"); Note=(T '用 pip install --user 装的 Python 包。有 conda 的话多半已不用，可删；不确定就搬走') }
    )
    foreach ($x in $lib) {
        if (-not $x.Confirm) { continue }
        $list += @{ G=$confG; Kind='cache'; Def=(T '跳过'); One=(T '删除'); N=$x.N; Paths=$x.Paths; Note=$x.Note; Filter=$x.Filter; Whole=$x.Whole; Svc=$x.Svc; Lvl=$x.Lvl }
    }
    # ---- 自定义：用户在设置里加的文件夹，删里面的东西 ----
    foreach ($p in (Get-CustomClean)) {
        $list += @{ G=$customG; Kind='cache'; Def=(T '删除'); N=(Split-Path $p -Leaf); Paths=@($p); Note=$p; Custom=$true; Lvl=2 }
    }
    $apps = Get-ChatApps
    $i = 0
    foreach ($it in $list) {
        $i++; $it.Idx = $i
        if ($it.Apps) {
            $k = @(); $d = @()
            foreach ($a in $it.Apps) { $k += $apps[$a].P; if ($apps[$a].K) { $k += $apps[$a].K }; $d += $apps[$a].Dirs }
            $it.Kill = @($k | Select-Object -Unique); $it.KillDirs = @($d | Select-Object -Unique)
        }
        # 稳定的分组编号：代码按它判断，不看界面上的组名（组名可以改、会翻译）
        $it.Tier = if ($it.G -eq $careG) { 'careful' } elseif ($it.G -eq $confG) { 'confirm' } elseif ($it.G -eq $chatG) { 'chat' } elseif ($it.G -eq $otherG) { 'other' } elseif ($it.G -eq $customG) { 'custom' } else { 'safe' }
        $it.Actions = switch ($it.Kind) { 'cache' { @((T '删除'),(T '跳过')) } 'action' { @((T '执行'),(T '跳过')) } 'move' { @((T '搬到其他盘'),(T '跳过')) } 'flex' { @((T '搬到其他盘'),(T '删除'),(T '跳过')) } }
    }
    return $list
}

function Measure-Item($it, $tree = $null) {
    if ($it.Size) { return [double](& $it.Size) }
    $paths = @()
    foreach ($p in $it.Paths) {
        if ($it.NoOneDrive -and $p -like '*OneDrive*') { continue }
        $paths += $p
    }
    if (-not $paths) { return 0 }
    return Get-Size $paths $it.Filter $tree (Get-ExcludeList)
}

$script:recycledThisRun = $false
$script:autoMinAge = $null
function Invoke-Delete($it, $res, [switch]$Auto) {
    $f0 = FreeC
    $script:recycleNow = (-not $Auto) -and ((Get-Setting 'Recycle' '0') -eq '1') -and -not $it.Act
    $script:recycleRefused = 0
    $script:autoMinAge = if ($Auto) { (Get-Date).AddDays(-1) } else { $null }   # 自动清理：一天内写过的临时文件可能还在用，不碰
    $kind = if ($it.Slow) { 'slow' } elseif ($it.Act) { 'action' } else { 'delete' }
    SetP @{ SubKind = $kind; SubStart = (Get-Date); FreeC0 = [double]$f0; Detail = $it.Note }
    if ($it.Svc) { $it.Svc | ForEach-Object { Stop-Service $_ -Force -ErrorAction SilentlyContinue } }
    if ($it.Act) { Set-CanCancel $false; try { & $it.Act } finally { Set-CanCancel $true } }
    else {
        $paths = @($it.Paths)
        if ($it.Custom) {
            $paths = @($paths | Where-Object { $why = Get-DeleteBlock $_; if (-not $why -and (IsLink $_)) { $why = (T '是链接') }; if ($why) { Log ((T "  跳过（{0}）：{1}") -f $why, $_) }; -not $why })
        }
        Remove-Contents $paths $it.Filter ([bool]$it.Whole)
        if ($res -and $sync -and $sync.WasCancelled) { $res.Cancelled = $true }
    }
    if ($it.Svc) { $it.Svc | ForEach-Object { Start-Service $_ -ErrorAction SilentlyContinue } }
    if ($script:recycleNow) { $script:recycledThisRun = $true }
    if ($script:recycleRefused -gt 20) { Log ((T "  另有 {0} 项因为放不进回收站没有删") -f ($script:recycleRefused - 20)) }
    $script:autoMinAge = $null
    $freed = [math]::Max([double]0, [double]((FreeC) - $f0))
    if ($res) { $res.Freed = $freed }
    Log ((T "  完成  {0,-26} 释放 {1}") -f $it.N, (GB $freed))
    $cat = if ($it.Kind -eq 'action') { '系统设置' } else { '删除' }   # 日志类别保持中文原样，是日志页筛选用的键
    $what = if ($Auto) { ((T "每周自动清理：{0}") -f $($it.N)) } else { ((T "清理：{0}") -f $($it.N)) }
    OpLog $cat $what $(if ($it.Paths) { $it.Paths -join (T '；') } else { '' }) (((T "C 盘多出 ") + (GB $freed)) + ((T "（剩余 {0} → {1}）") -f (GB $f0), (GB (FreeC))) + $(if ($script:recycleNow) { (T '，已放进回收站') } else { '' }))
    $script:recycleNow = $false
}
# 删除前的文件清单：这些项目会删掉哪些文件、文件夹（和 Remove-Contents 的规则一样：个人文件夹和排除的不碰）。
# 最多看 limit 个，按大小排；每一条 @{ Path; Bytes; IsDir; Item }
function Get-DeletePreview($items, [int]$limit = 20000) {
    $ex = Get-ExcludeList
    $out = New-Object System.Collections.Generic.List[object]
    $n = 0
    foreach ($it in $items) {
        if ($it.Act -or -not $it.Paths) { continue }
        foreach ($p in $it.Paths) {
            foreach ($x in @(Get-PathItems $p)) {
                if ($n -ge $limit) { break }
                if ((Test-Personal $x.FullName) -or (Test-Excluded $x.FullName $ex)) { continue }
                if (($x.PSIsContainer -and ($x.Attributes -band [IO.FileAttributes]::ReparsePoint)) -or (Get-LinkedAncestor $x.FullName)) { continue }
                if ($x.PSIsContainer -and -not $it.Whole) {
                    $f = if ($it.Filter) { $it.Filter } else { '*' }
                    foreach ($c in @(Get-ChildItem -LiteralPath $x.FullName -Filter $f -Force -ErrorAction SilentlyContinue)) {
                        if ($n -ge $limit) { break }
                        if ((Test-Personal $c.FullName) -or (Test-Excluded $c.FullName $ex) -or ($c.PSIsContainer -and (Test-HasExcluded $c.FullName $ex))) { continue }
                        $b = if ($c.PSIsContainer) { try { [double][FsTools]::OnDiskTree($c.FullName) } catch { [double]0 } } else { [double]$c.Length }
                        $out.Add(@{ Path = $c.FullName; Bytes = $b; IsDir = [bool]$c.PSIsContainer; Item = $it.N }); $n++
                    }
                } else {
                    if ($x.PSIsContainer -and (Test-HasExcluded $x.FullName $ex)) { continue }
                    $b = if ($x.PSIsContainer) { try { [double][FsTools]::OnDiskTree($x.FullName) } catch { [double]0 } } else { [double]$x.Length }
                    $out.Add(@{ Path = $x.FullName; Bytes = $b; IsDir = [bool]$x.PSIsContainer; Item = $it.N }); $n++
                }
            }
        }
    }
    return $out
}

# ---------- 搬家 ----------
# 每个搬家目标文件夹里有一份记录（.cleanc-map.txt）：哪个 C 盘文件夹复制到了哪里。
# 再搬一次时直接用上次的副本，只补有变化的文件，不用从头复制。
function MoveMapFile([string]$root) { Join-Path $root '.cleanc-map.txt' }
function Read-MoveMap([string]$root) {
    $map = @{}
    $f = MoveMapFile $root
    if (Test-Path -LiteralPath $f) {
        foreach ($l in [IO.File]::ReadAllLines($f, [Text.Encoding]::UTF8)) {
            $a = $l.Split("`t")
            if ($a.Count -ge 2 -and $a[0] -and $a[1]) { $map[$a[0].ToLowerInvariant()] = $a[1] }
        }
    }
    return $map
}
function Save-MoveMap([string]$root, [string]$src, [string]$dst) {
    $f = MoveMapFile $root
    try {
        $keep = @()
        if (Test-Path -LiteralPath $f) {
            $keep = @([IO.File]::ReadAllLines($f, [Text.Encoding]::UTF8) | Where-Object { $_ -and ($_.Split("`t")[0] -ine $src) })
            (Get-Item -LiteralPath $f -Force).Attributes = 'Normal'
        }
        $keep += "$src`t$dst"
        [IO.File]::WriteAllLines($f, [string[]]$keep, (New-Object Text.UTF8Encoding $true))
        (Get-Item -LiteralPath $f -Force).Attributes = 'Hidden'
    } catch {}
}
function LinkTarget($p) {
    $i = Get-Item -LiteralPath $p -Force -ErrorAction SilentlyContinue
    if ($i -and ($i.Attributes -band [IO.FileAttributes]::ReparsePoint)) { return [string](@($i.Target)[0]) }
    return ''
}
# 要找旧副本的位置：选定的目标，加上其他硬盘上本工具建的 CDriveMoved 文件夹
function MoveRoots([string]$destRoot) {
    $r = @($destRoot)
    foreach ($d in [IO.DriveInfo]::GetDrives()) {
        try {
            if ($d.DriveType -ne 'Fixed' -or -not $d.IsReady) { continue }
            $p = Join-Path $d.RootDirectory.FullName 'CDriveMoved'
            if (($p -ine $destRoot) -and (Test-Path -LiteralPath $p -PathType Container)) { $r += $p }
        } catch {}
    }
    return $r
}
# 决定 $src 搬到哪里。Reuse = 那里已经有上次复制的副本
function Find-MoveDest([string]$src, [string]$destRoot) {
    $roots = MoveRoots $destRoot
    $key = $src.ToLowerInvariant()
    $taken = @{}
    foreach ($root in $roots) {
        $map = Read-MoveMap $root
        if ($map.ContainsKey($key)) {
            $d = [string]$map[$key]
            if ((Test-Path -LiteralPath $d -PathType Container) -and -not (IsLink $d)) { return @{ Path = $d; Reuse = $true } }
        }
        foreach ($k in $map.Keys) { if ($k -ne $key) { $taken[([string]$map[$k]).TrimEnd('\').ToLowerInvariant()] = $true } }
    }
    # 已经搬好的文件夹（原位置是链接）指向的副本，绝不能拿来当别的文件夹的副本
    foreach ($c in (Get-Catalog)) {
        if ($c.Kind -ne 'move' -and $c.Kind -ne 'flex') { continue }
        foreach ($p in $c.Paths) { $t = LinkTarget $p; if ($t) { $taken[$t.TrimEnd('\').ToLowerInvariant()] = $true } }
    }
    # 上一版没留记录：在 CDriveMoved 里找同名的旧副本，顶层内容基本一样才算
    $leaf = Split-Path $src -Leaf
    $names = @(Get-ChildItem -LiteralPath $src -Force -Name -ErrorAction SilentlyContinue | ForEach-Object { $_.ToLowerInvariant() })
    if ($names.Count -gt 0) {
        $best = $null; $bestScore = 0.7
        $pat = '^' + [regex]::Escape($leaf) + '_\d{12}$'
        foreach ($root in $roots) {
            if ((Split-Path $root -Leaf) -ine 'CDriveMoved') { continue }
            foreach ($c in @(Get-ChildItem -LiteralPath $root -Directory -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name -ieq $leaf -or $_.Name -match $pat })) {
                if ($taken.ContainsKey($c.FullName.TrimEnd('\').ToLowerInvariant()) -or (IsLink $c.FullName)) { continue }
                $cn = @(Get-ChildItem -LiteralPath $c.FullName -Force -Name -ErrorAction SilentlyContinue | ForEach-Object { $_.ToLowerInvariant() })
                $union = @($names + $cn | Select-Object -Unique).Count
                $both = @($names | Where-Object { $cn -contains $_ }).Count
                $score = if ($union -gt 0) { $both / $union } else { 0 }
                if ($score -ge $bestScore) { $best = $c.FullName; $bestScore = $score }
            }
        }
        if ($best) { return @{ Path = $best; Reuse = $true } }
    }
    # 新搬：用原文件夹的名字；重名（比如 Roaming 和 Local 下都有 Tencent）就加上上一级的名字
    $d = Join-Path $destRoot $leaf
    if ((Test-Path -LiteralPath $d) -or $taken.ContainsKey($d.ToLowerInvariant())) { $d = Join-Path $destRoot ("{0} ({1})" -f $leaf, (Split-Path (Split-Path $src -Parent) -Leaf)) }
    if ((Test-Path -LiteralPath $d) -or $taken.ContainsKey($d.ToLowerInvariant())) { $d = Join-Path $destRoot ("{0}_{1}" -f $leaf, (Get-Date -Format 'yyyyMMddHHmm')) }
    return @{ Path = $d; Reuse = $false }
}

# 关掉占着文件夹的程序：清理项里列出的（微信、QQ 等），以及从这个文件夹里运行的程序（比如微信的插件）
function Close-Holders($it, [string]$src) {
    $names = @()
    # Restrict：只关用户在确认框里看到并同意关掉的程序（Allowed 里的进程名），确认之后才打开的程序不碰，搬不成就留到下次
    $only = [bool]$it.Restrict; $ok = @($it.Allowed)
    if ($it.Kill) {
        $p = @(Get-Process -Name $it.Kill -ErrorAction SilentlyContinue | Where-Object { -not $only -or $ok -contains $_.Name })
        if ($p) { $names += $p.Name; $p | Stop-Process -Force -ErrorAction SilentlyContinue }
    }
    $pre = $src.TrimEnd('\') + '\'
    $dirs = @($it.KillDirs)
    $inside = @(Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.Id -ne $PID -and $_.Path -and (-not $only -or $ok -contains $_.Name) -and
        ($_.Path.StartsWith($pre, [StringComparison]::OrdinalIgnoreCase) -or ($dirs.Count -gt 0 -and (PathHasAny $_.Path $dirs))) })
    if ($inside) { $names += $inside.Name; $inside | Stop-Process -Force -ErrorAction SilentlyContinue }
    $names = @($names | Select-Object -Unique)
    if ($names) { Log ((T "  关闭 {0}") -f ($names -join ', ')); Start-Sleep -Seconds 2 }
    return ,$names
}

# 搬家时会关掉哪些程序：和 Close-Holders 同样的规则（进程名、程序所在的文件夹、从要搬的文件夹里运行的程序），
# 在确认框里列出来；确认后后台只关这些。$items：@{ Kill; KillDirs; Paths } 的列表
function Get-KillPreview($items) {
    $procs = @(Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.Id -ne $PID })
    $names = @()
    foreach ($it in @($items)) {
        if (-not $it) { continue }
        $pats = @($it.Kill | Where-Object { $_ }); $dirs = @($it.KillDirs | Where-Object { $_ })
        $pres = @($it.Paths | Where-Object { $_ } | ForEach-Object { ([string]$_).TrimEnd('\') + '\' })
        foreach ($p in $procs) {
            $hit = $false
            foreach ($pat in $pats) { if ($p.Name -like $pat) { $hit = $true; break } }
            if (-not $hit) {
                $path = ''; try { $path = [string]$p.Path } catch {}
                if ($path) {
                    foreach ($pre in $pres) { if ($path.StartsWith($pre, [StringComparison]::OrdinalIgnoreCase)) { $hit = $true; break } }
                    if (-not $hit -and $dirs.Count -gt 0 -and (PathHasAny $path $dirs)) { $hit = $true }
                }
            }
            if ($hit) { $names += $p.Name }
        }
    }
    return ,@($names | Select-Object -Unique)
}
# 把原文件夹改名。被占用时关掉占用的程序再试，一共试 $tries 次（约半分钟）
function Rename-WithRetry([string]$from, [string]$to, $it, [int]$tries = 8) {
    $err = ''
    for ($i = 1; $i -le $tries; $i++) {
        try { [IO.Directory]::Move($from, $to); return @{ Err = ''; Tries = $i } }
        catch { $e = $_.Exception; if ($e.InnerException) { $e = $e.InnerException }; $err = $e.Message }
        if ($i -lt $tries) {
            if (Stopping) { return @{ Err = $err; Tries = $i; Cancelled = $true } }
            SetP @{ Detail = ((T "原文件夹还被占用，关闭占用的程序后重试（第 {0} / {1} 次）：{2}") -f $i, ($tries - 1), $err) }
            [void](Close-Holders $it $from)
            Start-Sleep -Seconds 3
        }
    }
    return @{ Err = $err; Tries = $tries }
}

# OneDrive 的同步根目录（个人版、公司版，可能有好几个）：里面的文件夹换成链接，OneDrive 会当成删除同步到云端
function Get-OneDriveRoots {
    $out = New-Object System.Collections.Generic.List[string]
    foreach ($v in @($env:OneDrive, $env:OneDriveConsumer, $env:OneDriveCommercial)) { if ($v) { $out.Add($v.TrimEnd('\')) } }
    try { foreach ($k in @(Get-ChildItem 'HKCU:\Software\Microsoft\OneDrive\Accounts' -ErrorAction Stop)) { $uf = (Get-ItemProperty $k.PSPath -ErrorAction SilentlyContinue).UserFolder; if ($uf) { $out.Add(([string]$uf).TrimEnd('\')) } } } catch {}
    if ($env:USERPROFILE) { foreach ($d in @(Get-ChildItem -LiteralPath $env:USERPROFILE -Directory -Filter 'OneDrive*' -Force -ErrorAction SilentlyContinue)) { $out.Add($d.FullName.TrimEnd('\')) } }
    return @($out | Where-Object { $_ } | Select-Object -Unique)
}
function Test-InOneDrive([string]$path) {
    if (-not $path) { return $false }
    $p = $path.TrimEnd('\')
    foreach ($r in (Get-OneDriveRoots)) { if ($p -ieq $r -or $p.StartsWith($r + '\', [StringComparison]::OrdinalIgnoreCase)) { return $true } }
    return $false
}
function Invoke-Move($it, $destRoot, $res) {
    if (-not $res) { $res = @{} }
    $res.Done = 0; $res.Fail = 0; $res.Wait = 0; $res.Moved = [double]0; $res.Dest = @(); $res.Msgs = @(); $res.Skipped = 0
    # 本程序自己的当前目录不能落在要搬的文件夹里，否则自己就占着它
    try { [Environment]::CurrentDirectory = $env:SystemRoot; Set-Location -LiteralPath $env:SystemRoot } catch {}
    $todo = @($it.Paths | Where-Object { $_ -and (Test-Path -LiteralPath $_) })
    if ((Split-Path $destRoot -Leaf) -ine 'CDriveMoved') {
        $mr = @((Get-Setting 'MoveRoots' '') -split '\|' | Where-Object { $_ })
        if ($mr -notcontains $destRoot) { Set-Setting 'MoveRoots' (($mr + $destRoot) -join '|') }
    }
    SetP @{ MoveItem = $true; MoveBack = $false; HasKill = [bool]$it.Kill; MovePhase = 'kill'; PathNo = 0; PathCount = $todo.Count; MovePath = ''; MoveDest = ''; MoveReuse = $false }
    if ($it.Kill) { foreach ($s in $todo) { [void](Close-Holders $it $s) } }
    foreach ($src in $it.Paths) {
      $jr = $null   # 这一项的搬家进度记录；这一项结束时（不管成没成）还停在「复制中」就删掉：C 盘没动过
      try {
        Set-CanCancel $true
        if (-not (Test-Path -LiteralPath $src)) { continue }
        if (Stopping) { $m = (T '已取消，剩下的文件夹没有搬'); Log "  $m"; $res.Cancelled = $true; $res.Msgs += $m; break }
        if (IsLink $src) { Log ((T "  已经搬过（是链接），跳过 {0}") -f $src); $res.Skipped++; continue }
        if (($it.NoOneDrive -and $src -like '*OneDrive*') -or (Test-InOneDrive $src)) { $m = ((T "  {0} 在 OneDrive 同步目录里，不搬：换成链接后 OneDrive 会当成删除同步到云端") -f $src); Log $m; OpLog '搬运' (T '不搬：在 OneDrive 同步目录里') $src ''; $res.Skipped++; $res.Msgs += $m.Trim(); continue }
        if ($src.Substring(0,1) -ieq $destRoot.Substring(0,1)) { Log ((T "  {0} 已在目标盘") -f $src); $res.Skipped++; continue }
        $leaf = Split-Path $src -Leaf
        $pick = Find-MoveDest $src $destRoot
        $dst = [string]$pick.Path; $reuse = [bool]$pick.Reuse
        $dstRoot = Split-Path $dst -Parent
        $pathNo = [int]$sync.P.PathNo + 1
        SetP @{ MovePhase = 'measure'; PathNo = $pathNo; MovePath = $src; MoveDest = $dst; MoveReuse = $reuse; SubKind = 'measure'; SubStart = (Get-Date); Detail = ((T "统计 {0} 的大小") -f $src) }
        $sc = DirCount $src; $srcBytes = [double]$sc.Bytes
        $cxNone = (T "已取消：{0} 还没开始复制，原文件夹没动") -f $src
        if ((Stopping) -or $sc.Cancelled) { Log "  $cxNone"; $res.Cancelled = $true; $res.Msgs += $cxNone; break }
        if ($sc.Reparse -gt 0) {
            # 里面的链接（或系统压缩过的文件）复制和核对时都会被跳过，搬完删原目录时就会丢。宁可不搬
            $m = (T "{0} 里有 {1} 个特殊项目（链接，或用 Windows 压缩功能压过的文件，比如 {2}）。复制时可能漏掉它们，为了不丢东西，这个文件夹不搬，原目录未动") -f $src, $sc.Reparse, $sc.ReparseSample
            Log "  $m"; OpLog '搬运' (T '搬家失败') $src $m; $res.Fail++; $res.Msgs += $m; continue
        }
        $haveBytes = [double]0
        if ($reuse) {
            SetP @{ SubStart = (Get-Date); Detail = ((T "统计上次留下的副本 {0}") -f $dst) }
            $hc = DirCount $dst; $haveBytes = [double]$hc.Bytes; $haveFiles = [long]$hc.Files
            if ((Stopping) -or $hc.Cancelled) { Log "  $cxNone"; $res.Cancelled = $true; $res.Msgs += $cxNone; break }
            SetP @{ Detail = ((T "核对 {0} 是不是这个文件夹的旧副本") -f $dst) }
            $extra = Get-ExtraCount $dst $src
            # 副本里只要有一个 C 盘上没有（或比 C 盘上新）的文件就不复用：/E 会用 C 盘上的旧版本覆盖副本里新的，/MIR 会删掉它们
            if ($extra -ne 0) {
                # 副本里有大量 C 盘上没有的文件：可能是唯一的一份（比如 C 盘上的链接被软件换成了新的空文件夹），绝不覆盖它
                $old = $dst
                $dst = Join-Path $destRoot ("{0}_{1}" -f $leaf, (Get-Date -Format 'yyyyMMddHHmm'))
                $dstRoot = Split-Path $dst -Parent
                $reuse = $false; $haveBytes = [double]0
                $m = ((T "目标盘上的 {0} 里有 {1} 个文件在 C 盘上没有，可能是唯一的一份，保留不动；这次搬到新文件夹 {2}") -f $old, $extra, $dst)
                Log "  $m"; OpLog '搬运' (T '保留旧副本，改用新文件夹') $old $m; $res.Msgs += $m
                SetP @{ MoveDest = $dst; MoveReuse = $false }
            } else { Log ((T "  {0} 里已有上次复制的 {1}，这次只补有变化的文件") -f $dst, (GB $haveBytes)) }
        }
        $destDrive = $dst.Substring(0, 2)
        $destFree0 = [double](Get-PSDrive $destDrive.Substring(0,1)).Free
        $need = [math]::Max([double]0, [double]($srcBytes - $haveBytes)) + [double]200MB
        if ($destFree0 -lt $need) { $m = (T "{0} 只剩 {1}，还需要约 {2}，放不下，原目录未动") -f $destDrive, (GB $destFree0), (GB $need); Log "  $m"; OpLog '搬运' (T '搬家失败') $src $m; $res.Fail++; $res.Msgs += $m; continue }
        if (Stopping) { Log "  $cxNone"; $res.Cancelled = $true; $res.Msgs += $cxNone; break }
        Log ((T "  搬 {0} ({1}) -> {2}") -f $src, (GB $srcBytes), $dst)
        New-Item -ItemType Directory -Path $dst -Force | Out-Null
        # 目标文件夹先设成和 C 盘上一样的访问权限：不然它继承目标盘根目录的权限，电脑上的其他账户也能打开
        # （搬软件时再连同每个文件的权限一起复制）。设不成、其他账户还能打开的就不搬
        $acc = if ($it.Sddl) { [string]$it.Sddl } else { Get-AccessSddl $src }
        if ($acc) { [void](Set-DirAccess $dst $acc) }
        if (-not (Test-OthersCanRead $src) -and (Test-OthersCanRead $dst)) {
            $m = (T "没能把 {0} 的权限设成和 C 盘上一样，搬过去后电脑上的其他账户也能打开，所以 {1} 不搬，原目录未动") -f $dst, $src
            Log "  $m"; OpLog '搬运' (T '搬家失败') $src $m; $res.Fail++; $res.Msgs += $m; continue
        }
        $cp = if ($it.Sddl) { '/COPY:DATS' } else { '/COPY:DAT' }
        Save-MoveMap $dstRoot $src $dst
        $bak = "$src.moved_backup"
        $jr = @{ Kind = 'move'; Src = $src; Dst = $dst; Bak = $bak; Cp = $cp; Step = 'copying' }; [void](Set-MoveStep $jr)
        $base = [math]::Min([double]$haveBytes, [double]$srcBytes)
        SetP @{ MovePhase = 'copy'; SubKind = 'copy'; SubTotal = [double]$srcBytes; SubBase = $base; SubDone = $base; SubStart = (Get-Date); DestDrive = $destDrive; DestFree0 = $destFree0; Detail = "$src  ->  $dst" }
        # 每复制完一个文件，robocopy 输出一行「大小<Tab>文件名」，累加起来就是已复制的字节数。
        # 用上次的副本时用 /MIR：副本和原目录完全一致（原目录里已删掉的旧文件，副本里也删掉）
        # 副本里有一个 C 盘上没有的文件（在允许范围内）也不用 /MIR：那些文件留着不删，只补新的
        $mode = if ($reuse -and $extra -eq 0) { '/MIR' } else { '/E' }
        $more = @(); if ($reuse -and $it.Sddl) { $more += '/SECFIX' }   # 用上次的副本时，连没变的文件的权限也改对
        $rcArgs = @($src, $dst, $mode, $cp) + $more + @('/DCOPY:DAT', '/R:2', '/W:2', '/NDL', '/NJH', '/NJS', '/NP', '/BYTES', '/XJ')
        $rc = Invoke-Tool "$sys32\robocopy.exe" $rcArgs '' $base
        $cxHalf = (T "已取消：{0} 原文件夹没动。已复制的部分留在 {1}，下次再搬这一项会接着复制；不需要的话，可以在「搬家管理」里删掉这份副本") -f $src, $dst
        $cxCopied = (T "已取消：{0} 已经复制到 {1}，但还没换成链接，原文件夹没动。下次再搬只补有变化的文件") -f $src, $dst
        if ($rc.Cancelled) { Log "  $cxHalf"; OpLog '搬运' (T '搬家已取消') $src $cxHalf; $res.Cancelled = $true; $res.Msgs += $cxHalf; break }
        if ($rc.Code -ge 8 -or $rc.Code -lt 0) { $m = ((T "复制失败（robocopy 代码 {0}，可能是空间不够或有文件被占用），原目录未动") -f $rc.Code); Log "  $m"; OpLog '搬运' (T '搬家失败') $src $m; $res.Fail++; $res.Msgs += $m; continue }
        # 代码里带 4：有同名的文件和文件夹对不上，那几项没复制过去。数量核对可能照样通过，所以这里就停
        if (($rc.Code -band 4) -ne 0) { $m = ((T "复制时有名字对不上的项目（robocopy 代码 {0}：同一个名字一边是文件一边是文件夹），原目录未动。打开 {1} 看看") -f $rc.Code, $dst); Log "  $m"; OpLog '搬运' (T '搬家失败') $src $m; $res.Fail++; $res.Msgs += $m; continue }
        SetP @{ MovePhase = 'verify'; SubKind = 'measure'; SubStart = (Get-Date); Detail = (T '复制完成，核对两边大小') }
        # 两边重新数一遍，文件个数和总大小一个都不能差，才继续（之后才会删 C 盘上的原目录）。
        # 对不上多半是复制时还有程序在写：再补复制一遍、再数一次，还对不上就不搬
        $sc = DirCount $src; $dc = DirCount $dst
        if (-not (Stopping) -and -not (Test-SameCount $sc $dc)) {
            SetP @{ Detail = (T '两边差一点，补复制一遍再核对') }
            & "$sys32\robocopy.exe" @rcArgs | Out-Null
            $sc = DirCount $src; $dc = DirCount $dst
        }
        $srcBytes = [double]$sc.Bytes; $srcFiles = [long]$sc.Files; $dstBytes = [double]$dc.Bytes; $dstFiles = [long]$dc.Files
        if ((Stopping) -or $sc.Cancelled -or $dc.Cancelled) { Log "  $cxCopied"; OpLog '搬运' (T '搬家已取消') $src $cxCopied; $res.Cancelled = $true; $res.Msgs += $cxCopied; break }
        if (-not (Test-SameCount $sc $dc)) {
            $m = (T "核对不一致（源 {0:N0} 个文件 {1}，目标 {2:N0} 个文件 {3}），原目录未动") -f $srcFiles, (GB $srcBytes), $dstFiles, (GB $dstBytes)
            Log "  $m"; OpLog '搬运' (T '搬家失败') $src $m; $res.Fail++; $res.Msgs += $m; continue
        }
        Log ((T "  核对通过：{0:N0} 个文件，{1}") -f $srcFiles, (GB $srcBytes))

        if (Stopping) { Log "  $cxCopied"; OpLog '搬运' (T '搬家已取消') $src $cxCopied; $res.Cancelled = $true; $res.Msgs += $cxCopied; break }
        SetP @{ MovePhase = 'link'; SubKind = 'action'; SubStart = (Get-Date); Detail = ((T "把 {0} 换成指向 {1} 的链接") -f $src, $dst) }
        if (Test-Path -LiteralPath $bak) {
            # 以前留下的备份不直接删（万一是唯一的一份），改个名放在旁边
            $old = "{0}_{1:yyyyMMddHHmmss}" -f $bak, (Get-Date)
            try { [IO.Directory]::Move($bak, $old); Log ((T "  以前留下的备份已改名为 {0}，确认没用后可手动删除") -f $old) } catch {}
        }
        $r = Rename-WithRetry $src $bak $it
        if ($r.Cancelled) { Log "  $cxCopied"; OpLog '搬运' (T '搬家已取消') $src $cxCopied; $res.Cancelled = $true; $res.Msgs += $cxCopied; break }
        if ($r.Err) {
            $self = [string]$env:CLEANC_SELF
            $why = if ($it.BusyHint) { [string]$it.BusyHint } else { (T '还有程序开着里面的文件。请彻底退出相关的聊天软件（微信、QQ、企业微信、飞书、钉钉等，包括屏幕右下角托盘里的图标），关掉打开着这个文件夹的窗口，再点一次「执行」') }
            if ($self -and $self.StartsWith($src.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) { $why = (T '本工具就放在这个文件夹里，请把工具挪到别处再运行') }
            $m = ((T "已复制到 {0}，但原文件夹被占用，还没换成链接：{1}。再搬时直接用这份副本，只补差异，很快就好") -f $dst, $why)
            Log ((T "  {0}（系统提示：{1}）") -f $m, $($r.Err)); OpLog '搬运' (T '搬家未完成：原文件夹被占用') $src $m; $res.Wait++; $res.Msgs += $m; continue
        }
        # 从这里到删掉 C 盘上的备份，停在一半会留下半截状态：不能取消，做完这一项才停；断电的话下次打开按记录接着做完或撤回
        Set-CanCancel $false
        $jr.Step = 'renamed'; [void](Set-MoveStep $jr)
        & "$sys32\cmd.exe" /c mklink /J "$src" "$dst" | Out-Null
        if (-not (IsLink $src)) {
            $back = $true
            try { if (Test-Path -LiteralPath $src) { Remove-Item -LiteralPath $src -Force -ErrorAction Stop }; [IO.Directory]::Move($bak, $src) } catch { $back = $false }
            if ($back) { Clear-MoveStep $src }   # 改回去了；没改回去的留着记录，下次打开还能处理
            $m = if ($back) { ((T "建链接失败，已改回原目录，副本在 {0}") -f $dst) } else { ((T "建链接失败，而且没能把原目录改回来：你的数据在 {0}，请手动把它改名回 {1}（{1} 现在可能是别的程序新建的空文件夹）；副本在 {2}") -f $bak, $src, $dst) }
            Log "  $m"; OpLog '搬运' (T '搬家失败') $src $m; $res.Fail++; $res.Msgs += $m; continue
        }
        $jr.Step = 'linked'; [void](Set-MoveStep $jr)
        # 核对之后到改名之间可能有程序又写了文件，补复制一遍新文件；补不过去就保留 C 盘上的旧文件夹（记录留着，下次打开可以接着做完或撤回）
        SetP @{ Detail = (T '补复制最后写入的文件') }
        & "$sys32\robocopy.exe" "$bak" "$dst" /E /XO $cp /R:1 /W:1 /XJ /NFL /NDL /NJH /NJS /NP | Out-Null
        if ($LASTEXITCODE -ge 8) {
            $m = ((T "已搬好，但最后几个文件没补复制过去，C 盘上的旧文件夹先保留：{0}") -f $bak)
            Log "  $m"; OpLog '搬运' (T '搬到其他盘') "$src → $dst" ((T "{0:N0} 个文件，{1}，两边已核对一致") -f $srcFiles, (GB $srcBytes)); OpLog '搬运' (T '搬家后保留 C 盘旧文件夹') $bak $m
            $res.Done++; $res.Moved += $srcBytes; $res.Dest += $dst; $res.Msgs += $m; $script:movedTargets = $null
            SetP @{ MovePhase = 'done' }
            continue
        }
        SetP @{ MovePhase = 'cleanup'; SubKind = 'delete'; SubTotal = [double]$srcBytes; SubStart = (Get-Date); FreeC0 = [double](FreeC); Detail = (T '链接已建好，删除 C 盘上的原目录') }
        $jr.Step = 'cleanup'; [void](Set-MoveStep $jr)
        if (Remove-MovedOriginal $bak) { Clear-MoveStep $src }
        if (Test-Path -LiteralPath $bak) { $m = ((T "C 盘上的旧文件夹没删干净（可能有文件被占用），数据已经在 {0}，可以以后再删：{1}") -f $dst, $bak); Log "  $m"; $res.Msgs += $m }
        $res.Done++; $res.Moved += $srcBytes; $res.Dest += $dst
        SetP @{ MovePhase = 'done' }
        OpLog '搬运' (T '搬到其他盘') "$src → $dst" ((T "{0:N0} 个文件，{1}，两边已核对一致") -f $srcFiles, (GB $srcBytes))
        $script:movedTargets = $null
        if (Test-Path -LiteralPath $bak) { $m = ((T "已搬好，但 C 盘上的备份没删干净（有文件被占用），过后可手动删除：{0}") -f $bak); Log "  $m"; OpLog '删除' (T '搬家后 C 盘旧文件夹没删干净') $bak ''; $res.Msgs += $m }
        else { Log ((T "  完成  {0}  ->  {1}") -f $src, $dst); OpLog '删除' (T '搬家后删除 C 盘上的原文件夹') $bak (((T "数据已在 {0}") -f $dst)) }
      } finally { if ($jr -and $jr.Step -eq 'copying') { Clear-MoveStep $src } }
    }
    Set-CanCancel $true
}


# ============================================================
# 设置、操作日志、空间记录（都放在 %LOCALAPPDATA%\CleanC）
# ============================================================
$script:appDir       = Join-Path $env:LOCALAPPDATA 'CleanC'
$script:opLogDir     = Join-Path $script:appDir '操作日志'
$script:settingsFile = Join-Path $script:appDir 'settings.txt'
$script:historyFile  = Join-Path $script:appDir 'history.txt'
$script:snapDir      = Join-Path $script:appDir '空间快照'

# 同一时间只做一件会改东西的事：界面里删除、搬家、改设置时拿着这把锁，定时的自动清理拿不到就跳过这一次；
# 自动清理在跑时，界面里要开始这类操作也要等它做完。锁本身出问题（极少见）时不拦着
$script:busyMutex = $null; $script:busyHeld = $false
function Enter-BusyLock {
    if ($script:busyHeld) { return $true }
    try {
        if (-not $script:busyMutex) { $script:busyMutex = New-Object System.Threading.Mutex($false, 'Local\ClearC-Busy') }
        $script:busyHeld = $script:busyMutex.WaitOne(0)
    } catch [System.Threading.AbandonedMutexException] { $script:busyHeld = $true } catch { $script:busyHeld = $true }
    return $script:busyHeld
}
function Exit-BusyLock { if ($script:busyHeld -and $script:busyMutex) { try { $script:busyMutex.ReleaseMutex() } catch {} }; $script:busyHeld = $false }
# 设置文件读不出来（被别的程序占着、坏了）时记下来：这时不知道你排除了哪些文件夹，清理一律不删
$script:settingsBad = $false
# 设置文件的全部行；没有这个文件返回空数组，有但读不出（重试几次以后）返回 $null
function Read-SettingsLines {
    if (-not $script:settingsFile -or -not (Test-Path -LiteralPath $script:settingsFile)) { return ,@() }
    for ($i = 0; $i -lt 5; $i++) {
        try { return ,[IO.File]::ReadAllLines($script:settingsFile, [Text.Encoding]::UTF8) } catch { Start-Sleep -Milliseconds 40 }
    }
    $script:settingsBad = $true
    return $null
}
function Get-Setting([string]$k, [string]$def = '') {
    $lines = Read-SettingsLines
    if ($null -eq $lines) { return $def }
    foreach ($l in $lines) {
        $i = $l.IndexOf('=')
        if ($i -gt 0 -and $l.Substring(0, $i).Trim() -eq $k) { return $l.Substring($i + 1).Trim() }
    }
    return $def
}
# 写设置：先写到旁边的临时文件，再整个换上去（写到一半断电、C 盘满了，原来的文件都还在）；
# 界面和定时任务可能同时写，用一把锁排队；原来的文件读不出来时不写（不然会把别的设置都冲掉）
function Set-Setting([string]$k, [string]$v) {
    $mx = $null; $got = $false
    try {
        try { $mx = New-Object System.Threading.Mutex($false, 'Local\ClearC-Settings'); $got = $mx.WaitOne(3000) } catch [System.Threading.AbandonedMutexException] { $got = $true } catch {}
        New-Item -ItemType Directory -Path $script:appDir -Force | Out-Null
        $old = Read-SettingsLines
        if ($null -eq $old) { return }
        $lines = New-Object System.Collections.Generic.List[string]
        foreach ($l in $old) { if ($l -and -not $l.StartsWith("$k=")) { $lines.Add($l) } }
        $lines.Add("$k=$v")
        $tmp = $script:settingsFile + '.tmp'
        [IO.File]::WriteAllLines($tmp, $lines.ToArray(), (New-Object Text.UTF8Encoding $true))
        if (Test-Path -LiteralPath $script:settingsFile) { [IO.File]::Replace($tmp, $script:settingsFile, ($script:settingsFile + '.bak')) } else { [IO.File]::Move($tmp, $script:settingsFile) }
    } catch {
        try { if (Test-Path -LiteralPath ($script:settingsFile + '.tmp')) { [IO.File]::Delete($script:settingsFile + '.tmp') } } catch {}
    } finally { if ($mx) { if ($got) { try { $mx.ReleaseMutex() } catch {} }; $mx.Dispose() } }
}

# 操作日志：每月一个 txt，一行一条：时间 <Tab> 类别 <Tab> 操作 <Tab> 对象 <Tab> 详情
# 类别：删除 / 搬运 / 合并 / 压缩 / 卸载 / 系统设置 / 日志
function OpLog([string]$cat, [string]$what, [string]$target = '', [string]$detail = '') {
    $now = Get-Date
    $f = Join-Path $script:opLogDir ("操作日志-{0:yyyy-MM}.txt" -f $now)
    $c = { param($x) (([string]$x) -replace "[`t`r`n]+", ' ').Trim() }
    $line = "{0:yyyy-MM-dd HH:mm:ss}`t{1}`t{2}`t{3}`t{4}" -f $now, (& $c $cat), (& $c $what), (& $c $target), (& $c $detail)
    $tries = if ([int]$script:opLogFailed -gt 0) { 1 } else { 5 }   # 已经写不进去过（多半是 C 盘满了）：不再每条都等半秒重试
    for ($try = 0; $try -lt $tries; $try++) {
        try {
            if (-not (Test-Path -LiteralPath $script:opLogDir)) { New-Item -ItemType Directory -Path $script:opLogDir -Force | Out-Null }
            $enc = New-Object System.Text.UTF8Encoding $true
            if (-not (Test-Path -LiteralPath $f)) {
                [IO.File]::AppendAllText($f, "# 腾挪 ClearC 操作日志（每行：时间、类别、操作、对象、详情，用 Tab 分隔）`r`n", $enc)
            }
            [IO.File]::AppendAllText($f, $line + "`r`n", $enc)
            return
        } catch { if ($tries -gt 1) { Start-Sleep -Milliseconds 120 } }
    }
    # 写不进去：记个数，告诉界面（后台线程通过 $sync），由界面告诉用户
    $script:opLogFailed = [int]$script:opLogFailed + 1
    try { if ($null -ne $sync) { $sync.OpLogFail = $line } } catch {}
}
# 本工具自己的文件夹（设置、操作日志、空间记录）现在能不能写：试着写一个小文件再删掉
function Test-AppDirWritable([string]$dir) {
    try {
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force -ErrorAction Stop | Out-Null }
        $p = Join-Path $dir ('.write-test-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
        [IO.File]::WriteAllText($p, 'ok'); [IO.File]::Delete($p)
        return $true
    } catch { return $false }
}
# 删除超过保存时间的日志（$months = 0 表示永久保存）。返回删掉的条数
function Prune-OpLog([int]$months) {
    if ($months -le 0 -or -not (Test-Path -LiteralPath $script:opLogDir)) { return 0 }
    $cut = (Get-Date).Date.AddMonths(-$months)
    $removed = 0
    $inv = [Globalization.CultureInfo]::InvariantCulture
    foreach ($f in @(Get-ChildItem -LiteralPath $script:opLogDir -Filter '操作日志-*.txt' -File -ErrorAction SilentlyContinue)) {
        $m = [regex]::Match($f.Name, '(\d{4})-(\d{2})')
        if (-not $m.Success) { continue }
        try { $start = New-Object DateTime ([int]$m.Groups[1].Value), ([int]$m.Groups[2].Value), 1 } catch { continue }
        $lines = @([IO.File]::ReadAllLines($f.FullName, [Text.Encoding]::UTF8))
        if ($start.AddMonths(1) -le $cut) {
            $removed += @($lines | Where-Object { $_ -and -not $_.StartsWith('#') }).Count
            Remove-Item -LiteralPath $f.FullName -Force -ErrorAction SilentlyContinue
            continue
        }
        if ($start -lt $cut) {
            $keep = New-Object System.Collections.Generic.List[string]; $drop = 0
            foreach ($l in $lines) {
                $t = [datetime]::MinValue
                if ($l.Length -ge 19 -and -not $l.StartsWith('#') -and [datetime]::TryParseExact($l.Substring(0, 19), 'yyyy-MM-dd HH:mm:ss', $inv, 'None', [ref]$t) -and $t -lt $cut) { $drop++ }
                else { $keep.Add($l) }
            }
            if ($drop -gt 0) { [IO.File]::WriteAllLines($f.FullName, $keep.ToArray(), (New-Object Text.UTF8Encoding $true)); $removed += $drop }
        }
    }
    return $removed
}
function Get-LogMonths { $v = 0; if ([int]::TryParse((Get-Setting 'LogMonths' '6'), [ref]$v)) { return $v }; return 6 }

# C 盘空间记录：每次打开工具、每次定时检查、每次清理后记一笔，用来画「空间变化」
function Add-History {
    try {
        $d = New-Object System.IO.DriveInfo ($env:SystemDrive + '\')
        New-Item -ItemType Directory -Path $script:appDir -Force | Out-Null
        $lines = New-Object System.Collections.Generic.List[string]
        if (Test-Path -LiteralPath $script:historyFile) { foreach ($l in [IO.File]::ReadAllLines($script:historyFile, [Text.Encoding]::UTF8)) { if ($l) { $lines.Add($l) } } }
        $lines.Add(("{0:yyyy-MM-dd HH:mm}`t{1}`t{2}" -f (Get-Date), [long]$d.AvailableFreeSpace, [long]$d.TotalSize))
        while ($lines.Count -gt 1500) { $lines.RemoveAt(0) }
        [IO.File]::WriteAllLines($script:historyFile, $lines.ToArray(), (New-Object Text.UTF8Encoding $true))
    } catch {}
}
function Get-History {
    $out = New-Object System.Collections.ArrayList
    if (-not (Test-Path -LiteralPath $script:historyFile)) { return ,$out }
    $inv = [Globalization.CultureInfo]::InvariantCulture
    foreach ($l in [IO.File]::ReadAllLines($script:historyFile, [Text.Encoding]::UTF8)) {
        $a = $l.Split("`t"); $t = [datetime]::MinValue
        if ($a.Count -ge 3 -and [datetime]::TryParseExact($a[0], 'yyyy-MM-dd HH:mm', $inv, 'None', [ref]$t)) {
            [void]$out.Add(@{ When = $t; Free = [double]$a[1]; Total = [double]$a[2] })
        }
    }
    return ,$out
}

# ============================================================
# 删除前的保护：返回不能删的原因；空字符串表示可以删
# ============================================================
$script:movedTargets = $null
function Get-MovedTargets {
    if ($null -eq $script:movedTargets) { $script:movedTargets = @(foreach ($r in (Get-MoveRecords)) { $d = ([string]$r.Dst).TrimEnd('\'); if ($d) { $d } }) }
    return ,$script:movedTargets
}
$script:progKeep = @('Common Files','WindowsApps','ModifiableWindowsApps','Windows Defender','Windows Defender Advanced Threat Protection','Windows Mail','Windows Media Player',
    'Windows NT','Windows Photo Viewer','Windows Portable Devices','Windows Security','Windows Sidebar','WindowsPowerShell','Internet Explorer','Reference Assemblies','MSBuild','dotnet','Microsoft Update Health Tools','Uninstall Information')
# 聊天软件的数据：目录里「聊天软件的聊天记录」那几项的文件夹、它们搬走后的位置、商店版聊天软件的数据。只能搬，不能删。
# 在这些文件夹里面的、或者把它们包在里面的，都不让删（空间地图、软件残留、自定义清理、重复文件都经过这里）
$script:chatDataPaths = $null
function Get-ChatDataPaths {
    if ($null -ne $script:chatDataPaths) { return ,$script:chatDataPaths }
    $l = New-Object System.Collections.Generic.List[string]
    try {
        foreach ($c in (Get-Catalog)) {
            if ($c.Tier -ne 'chat' -or -not $c.Paths) { continue }
            foreach ($p in $c.Paths) {
                if (-not $p) { continue }
                $l.Add(([string]$p).TrimEnd('\'))
                $t = LinkTarget $p; if ($t) { $l.Add($t.TrimEnd('\')) }
            }
        }
    } catch {}
    if ($env:LOCALAPPDATA) {
        foreach ($pat in @('*WhatsAppDesktop*', 'MSTeams*', 'FACEBOOK.317180B0BB486*', '*TelegramDesktop*', '*Signal*', '*LINE*')) {
            foreach ($d in @(Get-ChildItem -LiteralPath (Join-Path $env:LOCALAPPDATA 'Packages') -Directory -Filter $pat -Force -ErrorAction SilentlyContinue)) { $l.Add($d.FullName.TrimEnd('\')) }
        }
    }
    $script:chatDataPaths = @($l | Where-Object { $_ } | Select-Object -Unique)
    return ,$script:chatDataPaths
}
function Test-ChatData([string]$path) {
    if (-not $path) { return '' }
    $f = $path.TrimEnd('\')
    foreach ($c in (Get-ChatDataPaths)) {
        if ($f -ieq $c -or $f.StartsWith($c + '\', [StringComparison]::OrdinalIgnoreCase) -or $c.StartsWith($f + '\', [StringComparison]::OrdinalIgnoreCase)) {
            return (T '这是聊天软件的聊天记录和文件，只能整体搬到其他盘，不能删。要腾地方请到「搬家管理」')
        }
    }
    return ''
}
# 重复文件里这个文件删不得的原因（个人文件夹由页面上的开关单独管，这里只管其他的：聊天记录不管开关都不能删）
function Get-DupBlock([string]$path, [bool]$personal) {
    $chat = Test-ChatData $path
    if ($chat) { return $chat }
    if ($personal) { return '' }
    $why = Get-DeleteBlock $path
    if (-not $why) { $la = Get-LinkedAncestor $path; if ($la) { $why = ((T "所在的 {0} 是链接（多半是搬家留下的），这里看到的是另一个位置的文件") -f $la) } }
    return $why
}
function Get-DeleteBlock([string]$path, [switch]$Leftover) {
    if (-not $path) { return (T '路径为空') }
    $full = $path
    try { $full = [IO.Path]::GetFullPath($path) } catch {}
    $full = $full.TrimEnd('\')
    if ($full.Length -le 2) { return (T '整块磁盘不能删') }
    if (Test-Personal $full) { return (T 'C 盘个人文件夹（桌面、文档、下载、图片、视频、音乐等）里的东西不删') }
    # 任何一块盘根下的这些文件夹：回收站（所有用户的）、还原点、恢复分区的东西、启动文件
    if ($full -match '^[A-Za-z]:\\(\$Recycle\.Bin|System Volume Information|Recovery|EFI|Boot|Config\.Msi|\$WinREAgent)(\\|$)') { return (T '系统文件夹，删了 Windows 可能出问题') }
    $sd = $env:SystemDrive
    foreach ($d in @($env:SystemRoot, "$sd\System Volume Information", "$sd\`$Recycle.Bin", "$sd\Recovery", "$sd\Boot", "$sd\EFI", "$sd\Config.Msi", "$sd\Documents and Settings", "$sd\ProgramData\Microsoft")) {
        if ($full -ieq $d -or $full.StartsWith("$d\", [StringComparison]::OrdinalIgnoreCase)) { return (T '系统文件夹，删了 Windows 可能出问题') }
    }
    foreach ($pf in @("$sd\Program Files", "$sd\Program Files (x86)")) {
        if ($full -ieq $pf) { return (T '程序总文件夹不能删') }
        if ($full.StartsWith("$pf\", [StringComparison]::OrdinalIgnoreCase)) {
            $first = $full.Substring($pf.Length + 1).Split('\')[0]
            if ($script:progKeep -contains $first -or $first -like 'Microsoft*' -or $first -like 'Windows*') { return (T '系统自带的程序，不能删') }
            if (-not $Leftover) { return (T '软件的安装文件夹，请到「软件管理」里卸载，不要直接删') }
        }
    }
    $parent = Split-Path $full -Parent
    if ($parent -and $parent.TrimEnd('\').Length -le 2) {
        $leaf = Split-Path $full -Leaf
        if (@('pagefile.sys','hiberfil.sys','swapfile.sys','DumpStack.log','DumpStack.log.tmp','bootmgr','BOOTNXT','Users','ProgramData','Windows','Program Files','Program Files (x86)') -contains $leaf) {
            if ($leaf -like '*.sys') { return (T '系统文件，请用「省空间」里的功能处理') }
            return (T '系统文件夹，不能整个删')
        }
    }
    $users = Split-Path $env:USERPROFILE -Parent
    if ($full -ieq $users -or ($parent -and $parent -ieq $users)) { return (T '用户目录本身不能整个删') }
    foreach ($a in @("$env:USERPROFILE\AppData", $env:LOCALAPPDATA, $env:APPDATA, "$env:USERPROFILE\AppData\LocalLow", "$sd\ProgramData",
                     "$env:LOCALAPPDATA\Programs", "$env:LOCALAPPDATA\Packages", "$env:LOCALAPPDATA\Microsoft", "$env:APPDATA\Microsoft")) {
        if ($a -and $full -ieq $a.TrimEnd('\')) { return (T '这是软件数据的总文件夹，只能删里面具体的项目') }
    }
    if ($parent -and (Split-Path $parent -Parent) -ieq $users) {
        if (@('AppData') -contains (Split-Path $full -Leaf)) { return (T '这是软件数据的总文件夹，只能删里面具体的项目') }
    }
    if ($full -match ('^' + [regex]::Escape($users) + '\\[^\\]+\\AppData\\(Local|Roaming|LocalLow)$')) { return (T '这是软件数据的总文件夹，只能删里面具体的项目') }
    foreach ($k in @("$env:APPDATA\Microsoft\Protect", "$env:APPDATA\Microsoft\Credentials", "$env:APPDATA\Microsoft\Crypto", "$env:APPDATA\Microsoft\SystemCertificates",
                     "$env:LOCALAPPDATA\Microsoft\Credentials", "$env:LOCALAPPDATA\Microsoft\Vault")) {
        if ($full -ieq $k -or $full.StartsWith("$k\", [StringComparison]::OrdinalIgnoreCase)) { return (T '系统保存密码、证书和密钥的地方，删了会丢失登录信息和证书') }
    }
    # 这台电脑上其他账户的同样这几个文件夹也不删（空间地图能看到整块盘）
    if ($full -match ('^' + [regex]::Escape($users) + '\\[^\\]+\\AppData\\(Roaming|Local|LocalLow)\\Microsoft\\(Protect|Credentials|Crypto|SystemCertificates|Vault)(\\|$)')) { return (T '系统保存密码、证书和密钥的地方，删了会丢失登录信息和证书') }
    $pc = "$sd\ProgramData\Package Cache"
    if ($full -ieq $pc -or $full.StartsWith("$pc\", [StringComparison]::OrdinalIgnoreCase)) { return (T '软件的安装包缓存，删了以后这些软件可能没法修复、升级或卸载') }
    if ($full -ieq $script:appDir -or $full.StartsWith("$($script:appDir)\", [StringComparison]::OrdinalIgnoreCase)) { return (T '本工具自己的设置和日志') }
    if ((Split-Path $full -Leaf) -ieq 'CDriveMoved' -or $full -match '(?i)\\CDriveMoved(\\|$)') { return (T '这是搬家后的数据（CDriveMoved 文件夹），C 盘上的链接指向这里。要处理请到「搬家管理」') }
    foreach ($t in (Get-MovedTargets)) {
        if ($full -ieq $t -or $full.StartsWith("$t\", [StringComparison]::OrdinalIgnoreCase) -or $t.StartsWith("$full\", [StringComparison]::OrdinalIgnoreCase)) {
            return (T '这里是搬家后的数据，C 盘上的链接指向这里。要处理请到「搬家管理」')
        }
    }
    $chat = Test-ChatData $full
    if ($chat) { return $chat }
    return ''
}
function Get-CompressBlock([string]$path) {
    $full = $path; try { $full = [IO.Path]::GetFullPath($path) } catch {}
    $full = $full.TrimEnd('\')
    if ($full.Length -le 2) { return (T '整块磁盘请用系统压缩，不要整盘压') }
    $sd = $env:SystemDrive
    foreach ($d in @($env:SystemRoot, "$sd\System Volume Information", "$sd\`$Recycle.Bin", "$sd\Recovery", "$sd\Boot", "$sd\EFI")) {
        if ($full -ieq $d -or $full.StartsWith("$d\", [StringComparison]::OrdinalIgnoreCase)) { return (T '系统文件夹请用上面的「系统压缩」') }
    }
    foreach ($v in (Get-VDisks)) {
        $vp = ([string]$v.Path).TrimEnd('\')
        if (-not $vp) { continue }
        if ($vp -ieq $full -or $vp.StartsWith("$full\", [StringComparison]::OrdinalIgnoreCase) -or $full.StartsWith("$vp\", [StringComparison]::OrdinalIgnoreCase)) {
            return ((T "这个文件夹里有虚拟磁盘（{0}），压缩会让它变慢，甚至出错。可以压缩里面别的子文件夹，虚拟磁盘请用「省空间」页里的「压缩虚拟磁盘」") -f $($v.Name))
        }
    }
    return ''
}

# ============================================================
# 搬家记录：C 盘上哪些文件夹已经搬走、搬到哪、现在什么状态
# ============================================================
function Read-MoveMapPairs([string]$root) {
    $out = New-Object System.Collections.ArrayList
    $f = MoveMapFile $root
    if (Test-Path -LiteralPath $f) {
        foreach ($l in [IO.File]::ReadAllLines($f, [Text.Encoding]::UTF8)) { $a = $l.Split("`t"); if ($a.Count -ge 2 -and $a[0] -and $a[1]) { [void]$out.Add(@($a[0], $a[1])) } }
    }
    return ,$out
}
# 上次搬家或搬回做到一半（关机、断电、崩溃）留下的：C 盘原文件夹已经改名成 *.moved_backup（或搬回时复制到 *.cleanc_back），
# 还没换成链接 / 还没换回来。数据都在，但用户看到的可能是软件新建的空文件夹。找出来告诉用户数据在哪
function Find-HalfMoves {
    $srcs = New-Object System.Collections.Generic.List[string]
    try { foreach ($c in (Get-Catalog)) { if ($c.Kind -eq 'move' -or $c.Kind -eq 'flex') { foreach ($p in $c.Paths) { if ($p) { $srcs.Add([string]$p) } } } } } catch {}
    foreach ($root in (All-MoveRoots)) { foreach ($pr in (Read-MoveMapPairs $root)) { $srcs.Add([string]$pr[0]) } }
    $out = @()
    foreach ($s in @($srcs | Select-Object -Unique)) {
        foreach ($suf in '.moved_backup', '.cleanc_back') {
            $b = $s.TrimEnd('\', '/') + $suf
            if (Test-Path -LiteralPath $b) { $out += @{ Src = $s; Bak = $b; Kind = $suf } }
        }
    }
    return $out
}
# ---------- 搬家进度记录：每做完一步写一次，断电、崩溃后下次打开能接着做完或者撤回 ----------
# 每个正在搬的文件夹一个文件（%LOCALAPPDATA%\CleanC\搬家进度），一行一项：Kind（move 搬走 / back 搬回）、Src（C 盘上的位置）、
# Dst（目标盘上的副本）、Bak（搬走时 C 盘原文件夹改成的名字；搬回时复制回来的临时文件夹）、Cp（复制参数）、Fresh、Step、Time。
# 搬走：copying 复制中（C 盘没动）→ renamed 原文件夹已改名 → linked 已换成链接 → cleanup 删 C 盘上的旧文件夹 → 删掉记录
# 搬回：copying 复制回 C 盘中（链接没动）→ unlinked 链接已拆 → swapped 已换回真文件夹 → cleanup 删目标盘上的那份 → 删掉记录
# 写不进去（C 盘满）不拦着搬家：打开时还会按 *.moved_backup 找没做完的
function MoveJournalPath([string]$src) {
    $name = ($src.TrimEnd('\', '/').ToLowerInvariant() -replace '[\\/:*?"<>|]', '_') + '.txt'
    return (Join-Path (Join-Path $script:appDir '搬家进度') $name)
}
function Set-MoveStep($j) {
    try {
        $f = MoveJournalPath ([string]$j.Src)
        $dir = Split-Path $f -Parent
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        $lines = foreach ($k in 'Kind', 'Src', 'Dst', 'Bak', 'Cp', 'Fresh', 'Step') { "{0}`t{1}" -f $k, ([string]$j.$k -replace "[`t`r`n]", ' ') }
        $text = (@($lines) + ("Time`t{0:yyyy-MM-dd HH:mm:ss}" -f (Get-Date))) -join "`r`n"
        $tmp = "$f.tmp"
        [IO.File]::WriteAllText($tmp, $text, (New-Object System.Text.UTF8Encoding $true))
        if ([IO.File]::Exists($f)) { [IO.File]::Replace($tmp, $f, [NullString]::Value) } else { [IO.File]::Move($tmp, $f) }   # $null 会被当成空字符串
        return $true
    } catch { Log ((T "  没能写下搬家进度（{0}）：断电的话，下次打开要按 *.moved_backup 找") -f $_.Exception.Message); return $false }
}
function Clear-MoveStep([string]$src) {
    $f = MoveJournalPath $src
    foreach ($x in $f, "$f.tmp") { try { if ([IO.File]::Exists($x)) { [IO.File]::Delete($x) } } catch {} }
}
function Get-MoveJournal {
    $dir = Join-Path $script:appDir '搬家进度'
    $out = New-Object System.Collections.Generic.List[object]
    foreach ($f in @(Get-ChildItem -LiteralPath $dir -Filter '*.txt' -File -ErrorAction SilentlyContinue)) {
        $j = @{ File = $f.FullName }
        try { foreach ($l in [IO.File]::ReadAllLines($f.FullName, [Text.Encoding]::UTF8)) { $p = $l.Split("`t", 2); if ($p.Count -eq 2) { $j[$p[0]] = $p[1] } } } catch { continue }
        if ($j.Src -and $j.Step -and ($j.Kind -eq 'move' -or $j.Kind -eq 'back')) { $out.Add([pscustomobject]$j) }
    }
    return $out.ToArray()
}
# 两次统计是不是完全一样：个数、大小一个都不能差，哪边数到一半被取消都不算
function Test-SameCount($a, $b) { return [bool]($a -and $b -and -not $a.Cancelled -and -not $b.Cancelled -and [long]$a.Files -eq [long]$b.Files -and [long]$a.Bytes -eq [long]$b.Bytes) }
# C 盘上那个位置现在是什么：none 不在、link 链接、empty 空文件夹（多半是软件重新建的）、data 有内容的真文件夹
function Get-PlaceState([string]$p) {
    if (IsLink $p) { return 'link' }
    if (-not (Test-Path -LiteralPath $p)) { return 'none' }
    if (@(Get-ChildItem -LiteralPath $p -Force -ErrorAction SilentlyContinue | Select-Object -First 1).Count -eq 0) { return 'empty' }
    return 'data'
}
# 记录里写的那一步，和磁盘上实际的样子对一下：写记录前一刻断电时，实际可能已经多做了一步
function Get-JournalStep($j) {
    $st = Get-PlaceState ([string]$j.Src)
    $bakThere = $j.Bak -and (Test-Path -LiteralPath ([string]$j.Bak))
    $step = [string]$j.Step
    if ($j.Kind -eq 'move') {
        if ($step -eq 'copying' -and $bakThere -and ($st -eq 'none' -or $st -eq 'empty')) { $step = 'renamed' }
        if ($step -eq 'renamed' -and $st -eq 'link') { $step = 'linked' }
        if (($step -eq 'linked' -or $step -eq 'cleanup') -and -not $bakThere -and $st -eq 'link') { $step = 'done' }
    } else {
        if ($step -eq 'copying' -and $bakThere -and ($st -eq 'none' -or $st -eq 'empty')) { $step = 'unlinked' }
        if ($step -eq 'unlinked' -and -not $bakThere -and $st -eq 'data') { $step = 'swapped' }
        if (($step -eq 'swapped' -or $step -eq 'cleanup') -and -not (Test-Path -LiteralPath ([string]$j.Dst))) { $step = 'done' }
    }
    return $step
}
# 给人看的一句：停在了哪一步
function Get-JournalText($j) {
    $s = [string]$j.Src; $d = [string]$j.Dst; $b = [string]$j.Bak
    switch ((Get-JournalStep $j) + '/' + $j.Kind) {
        'copying/move'  { return ((T "{0}：复制到 {1} 时停了，C 盘上的原文件夹没动") -f $s, $d) }
        'renamed/move'  { return ((T "{0}：原文件夹已改名为 {1}，还没换成链接") -f $s, $b) }
        'linked/move'   { return ((T "{0}：已换成指向 {1} 的链接，C 盘上的旧文件夹 {2} 还没删") -f $s, $d, $b) }
        'cleanup/move'  { return ((T "{0}：已搬好，删 C 盘上的旧文件夹 {1} 时停了") -f $s, $b) }
        'copying/back'  { return ((T "{0}：搬回 C 盘时复制到一半，C 盘上的链接没动") -f $s) }
        'unlinked/back' { return ((T "{0}：搬回时链接已拆掉，复制回来的数据在 {1}") -f $s, $b) }
        'swapped/back'  { return ((T "{0}：已搬回 C 盘，目标盘上的 {1} 还没删") -f $s, $d) }
        'cleanup/back'  { return ((T "{0}：已搬回 C 盘，删目标盘上的 {1} 时停了") -f $s, $d) }
        default         { return ((T "{0}：已经做完了") -f $s) }
    }
}
# 搬家时 C 盘上改了名的原文件夹（搬回时目标盘上的那份）：核对过以后删掉。rd /s 遇到链接只拆不跟；
# 没删干净（有文件被占用，或者里面后来多了链接）就先拆掉里面的链接再删一次，绝不用会跟进链接的 Remove-Item -Recurse
function Remove-MovedOriginal([string]$dir) {
    if (-not (Test-CmdPathOk $dir) -or (IsLink $dir)) { return $false }
    foreach ($pass in 1, 2) {
        if ($pass -eq 2) { if (-not (Test-Path -LiteralPath $dir)) { break }; [void](Remove-LinksInside $dir) }
        & "$sys32\cmd.exe" /c rd /s /q "\\?\$dir" 2>$null | Out-Null
    }
    return -not (Test-Path -LiteralPath $dir)
}
# 上次没做完的搬家：$how = finish（按记录接着做完）或 undo（撤回到搬之前的样子）。返回 @{ Ok; Msg }。
# C 盘那个位置已经有了新的内容（软件重新建了文件夹并写了东西）时两样都不做，告诉用户数据在哪
function Resume-Move($j, [string]$how) {
    $res = @{ Ok = $false; Msg = '' }
    $src = [string]$j.Src; $dst = [string]$j.Dst; $bak = [string]$j.Bak
    $cp = if ($j.Cp) { [string]$j.Cp } else { '/COPY:DAT' }
    if (-not (Test-CmdPathOk $src) -or -not (Test-CmdPathOk $dst) -or ($bak -and -not (Test-CmdPathOk $bak))) { $res.Msg = (T '路径里有 % 或引号，为了不删错地方，没法在这里处理'); return $res }
    $step = Get-JournalStep $j
    $st = Get-PlaceState $src
    $busy = (T "{0} 又有了新的内容（多半是软件重新建的），所以没有动。原来的数据在 {1}，副本在 {2}。先退出那个软件，把两边对比一下再决定") -f $src, $(if ($bak) { $bak } else { $src }), $dst
    $log = { param($what) OpLog '搬运' $what $src $res.Msg }
    if ($j.Kind -eq 'move') {
        if ($step -eq 'done') { Clear-MoveStep $src; $res.Ok = $true; $res.Msg = (T '已经做完了'); return $res }
        if ($step -eq 'copying') {
            Clear-MoveStep $src; $res.Ok = $true
            $res.Msg = (T "{0} 没动过。复制了一部分的副本在 {1}，再搬这一项时会接着复制；不需要的话，可以在「搬家管理」里删掉这份副本") -f $src, $dst
            & $log (T '没做完的搬家：C 盘没动过'); return $res
        }
        if ($step -eq 'cleanup' -and $how -eq 'undo') { $how = 'finish' }   # 旧文件夹已经删了一部分，撤回不了；数据都在目标盘上，接着删完
        if ($step -eq 'renamed') {
            if ($st -eq 'data') { $res.Msg = $busy; & $log (T '没做完的搬家：没动'); return $res }
            if ($st -eq 'empty') { try { [IO.Directory]::Delete($src, $false) } catch { $res.Msg = $busy; return $res } }
            if ($how -eq 'undo') {
                try { [IO.Directory]::Move($bak, $src) } catch { $res.Msg = (T "没能把 {0} 改回 {1}：{2}") -f $bak, $src, $_.Exception.Message; & $log (T '撤回没做完的搬家失败'); return $res }
                Clear-MoveStep $src; $res.Ok = $true
                $res.Msg = (T "已撤回：{0} 恢复成搬之前的样子。复制到 {1} 的副本还在，再搬时会用上") -f $src, $dst
                & $log (T '撤回没做完的搬家'); return $res
            }
            & "$sys32\cmd.exe" /c mklink /J "$src" "$dst" | Out-Null
            if (-not (IsLink $src)) { $res.Msg = (T "建链接失败，没改；数据在 {0}") -f $bak; & $log (T '接着做完搬家失败'); return $res }
            $j.Step = 'linked'; [void](Set-MoveStep $j); $step = 'linked'; $st = 'link'
        }
        if ($step -eq 'linked' -or $step -eq 'cleanup') {
            $lt = LinkTarget $src
            if ($st -ne 'link' -or ($lt -and $lt.TrimEnd('\') -ine $dst.TrimEnd('\'))) { $res.Msg = (T "{0} 现在不是指向 {1} 的链接，没动。数据在 {2}") -f $src, $dst, $bak; return $res }
            if ($step -eq 'linked' -and $how -eq 'undo') {
                $newer = Get-ExtraCount $dst $bak
                & "$sys32\cmd.exe" /c rmdir "$src" 2>$null | Out-Null
                if (Test-Path -LiteralPath $src) { $res.Msg = (T 'C 盘上的链接拆不掉（可能被占用），没改'); return $res }
                try { [IO.Directory]::Move($bak, $src) } catch {
                    & "$sys32\cmd.exe" /c mklink /J "$src" "$dst" | Out-Null
                    $res.Msg = (T "没能把 {0} 改回 {1}，已恢复成链接：{2}") -f $bak, $src, $_.Exception.Message; & $log (T '撤回没做完的搬家失败'); return $res
                }
                Clear-MoveStep $src; $res.Ok = $true
                $res.Msg = (T "已撤回：{0} 恢复成搬之前的样子。目标盘上的副本 {1} 还在") -f $src, $dst
                if ($newer -gt 0) { $res.Msg += ((T "，里面有 {0} 个文件比 C 盘上的新（链接期间写的），留在那里") -f $newer) }
                & $log (T '撤回没做完的搬家'); return $res
            }
            if ($step -eq 'linked') {
                # 改名之后才写进去的文件补复制过去，核对 C 盘旧文件夹里没有一个文件是目标盘上没有或比它新的，才删旧文件夹
                & "$sys32\robocopy.exe" "$bak" "$dst" /E /XO $cp /R:1 /W:1 /XJ /NFL /NDL /NJH /NJS /NP | Out-Null
                if ($LASTEXITCODE -ge 8) { $res.Msg = (T "补复制没成功（robocopy 代码 {0}），C 盘上的旧文件夹先保留：{1}") -f $LASTEXITCODE, $bak; & $log (T '接着做完搬家失败'); return $res }
                $left = Get-ExtraCount $bak $dst
                if ($left -ne 0) { $res.Msg = (T "核对不一致：{0} 里有 {1} 个文件在目标盘上没有，先保留") -f $bak, $left; & $log (T '接着做完搬家失败'); return $res }
                $j.Step = 'cleanup'; [void](Set-MoveStep $j)
            }
            if (-not (Remove-MovedOriginal $bak)) { $res.Msg = (T "已搬好，但 C 盘上的旧文件夹没删干净（可能有文件被占用），过后可以再试：{0}") -f $bak; & $log (T '接着做完搬家：旧文件夹没删干净'); return $res }
            Clear-MoveStep $src; $res.Ok = $true; $script:movedTargets = $null
            $res.Msg = (T "已做完：{0} 的数据在 {1}，C 盘上的旧文件夹已删") -f $src, $dst
            & $log (T '接着做完搬家'); return $res
        }
    } else {
        if ($step -eq 'done') { Clear-MoveStep $src; $res.Ok = $true; $res.Msg = (T '已经做完了'); return $res }
        if ($step -eq 'copying') {
            $r = @{}; Undo-MoveBackCopy $bak ($j.Fresh -eq 'True') $dst $src $r
            Clear-MoveStep $src; $res.Ok = $true; $res.Msg = $r.Msg; return $res
        }
        if ($step -eq 'unlinked') {
            if ($st -eq 'data' -or $st -eq 'link') { $res.Msg = $busy; return $res }
            if ($st -eq 'empty') { try { [IO.Directory]::Delete($src, $false) } catch { $res.Msg = $busy; return $res } }
            if ($how -eq 'undo') {
                & "$sys32\cmd.exe" /c mklink /J "$src" "$dst" | Out-Null
                if (-not (IsLink $src)) { $res.Msg = (T "建链接失败，没改；复制回来的数据在 {0}") -f $bak; return $res }
                $r = @{}; Undo-MoveBackCopy $bak ($j.Fresh -eq 'True') $dst $src $r
                Clear-MoveStep $src; $res.Ok = $true; $res.Msg = (T "已撤回：{0} 又是指向 {1} 的链接") -f $src, $dst
                & $log (T '撤回没做完的搬回'); return $res
            }
            try { [IO.Directory]::Move($bak, $src) } catch { $res.Msg = (T "没能把 {0} 改回 {1}：{2}") -f $bak, $src, $_.Exception.Message; return $res }
            $j.Step = 'swapped'; [void](Set-MoveStep $j); $step = 'swapped'
        }
        if ($step -eq 'swapped' -or $step -eq 'cleanup') {
            if ($how -eq 'undo' -and $step -eq 'swapped') {
                Clear-MoveStep $src; $res.Ok = $true; $res.Msg = (T "{0} 已经在 C 盘上了；目标盘上的 {1} 留着没删，确认不需要的话可以自己删") -f $src, $dst
                & $log (T '没做完的搬回：保留目标盘上的那份'); return $res
            }
            if ($step -eq 'swapped') {
                & "$sys32\robocopy.exe" "$dst" "$src" /E /XO /COPY:DAT /R:1 /W:1 /XJ /NFL /NDL /NJH /NJS /NP | Out-Null
                if ($LASTEXITCODE -ge 8 -or -not (Test-OurMoveCopy $src $dst) -or (Get-ExtraCount $dst $src) -ne 0) {
                    Clear-MoveStep $src; $res.Ok = $true; $res.Msg = (T "已搬回 C 盘；目标盘上的 {0} 先保留，确认不需要的话可以自己删") -f $dst
                    foreach ($root in (All-MoveRoots)) { Remove-MoveMapEntry $root $src }
                    & $log (T '接着做完搬回：保留目标盘上的那份'); return $res
                }
                $j.Step = 'cleanup'; [void](Set-MoveStep $j)
            }
            if (-not (Remove-MovedOriginal $dst)) { $res.Msg = (T "已搬回，但目标盘上的旧副本没删干净：{0}") -f $dst; return $res }
            foreach ($root in (All-MoveRoots)) { Remove-MoveMapEntry $root $src }
            Clear-MoveStep $src; $res.Ok = $true; $script:movedTargets = $null
            $res.Msg = (T "已做完：{0} 搬回了 C 盘，目标盘上的那份已删") -f $src
            & $log (T '接着做完搬回'); return $res
        }
    }
    $res.Msg = (T '记录看不懂，没动'); return $res
}
function Remove-MoveMapEntry([string]$root, [string]$src) {
    $f = MoveMapFile $root
    if (-not (Test-Path -LiteralPath $f)) { return }
    try {
        $keep = @([IO.File]::ReadAllLines($f, [Text.Encoding]::UTF8) | Where-Object { $_ -and ($_.Split("`t")[0] -ine $src) })
        (Get-Item -LiteralPath $f -Force).Attributes = 'Normal'
        [IO.File]::WriteAllLines($f, [string[]]$keep, (New-Object Text.UTF8Encoding $true))
        (Get-Item -LiteralPath $f -Force).Attributes = 'Hidden'
    } catch {}
}
function All-MoveRoots {
    $r = @()
    foreach ($d in [IO.DriveInfo]::GetDrives()) {
        try { if ($d.DriveType -eq 'Fixed' -and $d.IsReady) { $p = Join-Path $d.RootDirectory.FullName 'CDriveMoved'; if (Test-Path -LiteralPath $p) { $r += $p } } } catch {}
    }
    foreach ($x in ((Get-Setting 'MoveRoots' '') -split '\|')) { if ($x -and (Test-Path -LiteralPath $x) -and ($r -notcontains $x)) { $r += $x } }
    return ,$r
}
# 搬回 C 盘以后，目标盘上的那份能不能删：只有本工具搬过去的（在 CDriveMoved 这类搬家目标文件夹里）、
# 而且没有别的 C 盘位置还链接着它，才删。用户自己建的链接指向的文件夹（比如 E:\WeChat）一律留着
function Test-OurMoveCopy([string]$src, [string]$dst) {
    $d = $dst.TrimEnd('\', '/')
    $sep = [IO.Path]::DirectorySeparatorChar
    $under = $false
    foreach ($r in (All-MoveRoots)) { $rr = ([string]$r).TrimEnd('\', '/'); if ($d.StartsWith($rr + $sep, [StringComparison]::OrdinalIgnoreCase)) { $under = $true; break } }
    if (-not $under) { return $false }
    foreach ($rec in (Get-MoveRecords)) {
        if ([string]$rec.Src -ine $src -and ([string]$rec.Dst).TrimEnd('\', '/') -ieq $d -and (IsLink ([string]$rec.Src))) { return $false }
    }
    return $true
}
function Get-MoveRecords {
    $recs = New-Object System.Collections.ArrayList
    $seen = @{}
    $names = @{}
    foreach ($c in (Get-Catalog)) {
        if ($c.Kind -ne 'move' -and $c.Kind -ne 'flex') { continue }
        foreach ($p in $c.Paths) {
            if (-not $p) { continue }
            $names[$p.ToLowerInvariant()] = @($c.N, $c.Idx)
            $t = LinkTarget $p
            if ($t) { [void]$recs.Add(@{ Name = $c.N; Idx = $c.Idx; Src = $p; Dst = $t.TrimEnd('\'); Root = '' }); $seen[$p.ToLowerInvariant()] = $true }
        }
    }
    foreach ($root in (All-MoveRoots)) {
        foreach ($pr in (Read-MoveMapPairs $root)) {
            $src = [string]$pr[0]; $dst = ([string]$pr[1]).TrimEnd('\')
            $k = $src.ToLowerInvariant()
            if ($seen.ContainsKey($k)) { foreach ($r in $recs) { if ($r.Src -ieq $src) { $r.Root = $root } }; continue }
            $seen[$k] = $true
            $nm = if ($names.ContainsKey($k)) { $names[$k] } else { @((Split-Path $src -Leaf), 0) }
            $t = LinkTarget $src
            [void]$recs.Add(@{ Name = $nm[0]; Idx = $nm[1]; Src = $src; Dst = $(if ($t) { $t.TrimEnd('\') } else { $dst }); Root = $root })
        }
    }
    return ,$recs
}
# 目标盘副本里有、C 盘原文件夹里没有（或比 C 盘上新）的文件个数。-1 表示核对不了
# （robocopy /L 只列出不复制；/XO 不算副本里比 C 盘旧的，/XX 不算只有 C 盘上才有的）
function Get-ExtraCount([string]$dst, [string]$src) {
    if (-not (Test-Path -LiteralPath $dst) -or -not (Test-Path -LiteralPath $src)) { return -1 }
    $lines = @(& "$sys32\robocopy.exe" "$dst" "$src" /L /E /XO /XX /XJ /NJH /NJS /NDL /NC /NS /NP /FP /R:0 /W:0 | Where-Object { ([string]$_).Trim() })
    return $lines.Count
}
# 看一条记录现在的状态
function Get-MoveState($rec) {
    $src = [string]$rec.Src; $dst = [string]$rec.Dst
    $srcLink = IsLink $src
    $srcThere = Test-Path -LiteralPath $src
    $dstThere = $dst -and (Test-Path -LiteralPath $dst)
    if ($srcLink -and $dstThere) { return @{ State = 'ok'; Text = ((T "正常：数据在 {0} 盘，C 盘这里只留了一个指向它的链接，不占 C 盘空间，软件照常使用") -f $dst.Substring(0, 1).ToUpper()); Brush = '#1D7A35' } }
    if ($srcLink -and -not $dstThere) {
        $fix = ''
        $leaf = Split-Path $dst -Leaf
        $taken = @(Get-MovedTargets)
        foreach ($root in (All-MoveRoots)) {
            $c = Join-Path $root $leaf
            if (-not (Test-Path -LiteralPath $c)) { continue }
            if (@($taken | Where-Object { $_ -ieq $c.TrimEnd('\') }).Count -gt 0) { continue }   # 别的链接正指着它：是另一项的数据
            $fix = $c; break
        }
        $t = (T '链接断了：目标文件夹不在了（硬盘拔了、或者盘符变了？）')
        if ($fix) { $t += ((T "。在 {0} 找到一份同名的，可以改指向它") -f $fix) }
        return @{ State = 'broken'; Text = $t; Brush = '#D70015'; Fix = $fix }
    }
    if ($srcThere -and -not $srcLink -and $dstThere) { return @{ State = 'pending'; Text = (T '没搬完：C 盘原文件夹还在，目标盘上也有一份。可以在「可以搬的」里再搬一次，只补有变化的文件；也可以删掉这份副本，删之前会先核对，副本里有不少 C 盘上没有的文件就不删'); Brush = '#B25000' } }
    if (-not $srcThere -and $dstThere) { return @{ State = 'nosrc'; Text = (T 'C 盘上的链接不见了（软件卸载了，或者链接被删了）。软件还在用的话，可以重建链接；软件已经卸载的话，打开看看，确认不要了再自己删掉这份数据'); Brush = '#D70015'; Fix = $dst } }
    return @{ State = 'gone'; Text = (T '已经不在了'); Brush = '#6E6E73' }
}

# 搬回 C 盘：复制回来、核对、拆掉链接、换回真文件夹，最后删掉目标盘上的那份
# 搬回时取消：删掉复制回 C 盘的那一半（数据仍在目标盘上，C 盘上的链接没动）
function Undo-MoveBackCopy([string]$tmp, [bool]$fresh, [string]$dst, [string]$src, $res) {
    $res.Cancelled = $true
    if ($fresh -and (Test-Path -LiteralPath $tmp) -and -not (IsLink $tmp) -and (Test-CmdPathOk $tmp)) { & "$sys32\cmd.exe" /c rd /s /q "\\?\$tmp" 2>$null | Out-Null }
    if (Test-Path -LiteralPath $tmp) { $res.Msg = (T "已取消，什么都没改，数据仍在 {0}。复制回 C 盘的那一半在 {1}，确认没用后可以手动删除") -f $dst, $tmp }
    else { $res.Msg = (T "已取消，什么都没改，数据仍在 {0}。复制回 C 盘的那一半已删掉") -f $dst }
    OpLog '搬运' (T '搬回 C 盘已取消') $src $res.Msg
}
function Invoke-MoveBack($rec, $res) {
    $res.Ok = $false; $res.Msg = ''
    $src = [string]$rec.Src; $dst = [string]$rec.Dst
    if (-not (IsLink $src) -or -not (Test-Path -LiteralPath $dst)) { $res.Msg = (T '这一项现在不是正常的搬家状态，没法搬回'); return }
    $lt = LinkTarget $src
    if ($lt -and $lt.TrimEnd('\') -ine $dst.TrimEnd('\')) { $res.Msg = ((T "C 盘上的链接现在指向 {0}，和记录里的 {1} 不一样，没动。请刷新「搬家管理」再试") -f $lt, $dst); return }
    if (-not (Test-CmdPathOk $dst) -or -not (Test-CmdPathOk $src)) { $res.Msg = (T '路径里有 % 或引号，为了不删错地方，没法在这里搬回'); return }
    try { [Environment]::CurrentDirectory = $env:SystemRoot; Set-Location -LiteralPath $env:SystemRoot } catch {}
    $it = @{ Kill = @(); KillDirs = @() }
    if ($rec.Idx) { foreach ($c in (Get-Catalog)) { if ($c.Idx -eq $rec.Idx) { $it = $c } } }
    if ($rec.Restrict) { $it.Restrict = $true; $it.Allowed = @($rec.Allowed) }
    SetP @{ MoveItem = $true; MoveBack = $true; HasKill = [bool]$it.Kill; MovePhase = 'kill'; PathNo = 0; PathCount = 1; MovePath = $dst; MoveDest = $src; MoveReuse = $false }
    [void](Close-Holders $it $src); [void](Close-Holders $it $dst)
    SetP @{ MovePhase = 'measure'; SubKind = 'measure'; SubStart = (Get-Date); Detail = ((T "统计 {0} 的大小") -f $dst) }
    $dc = DirCount $dst; $bytes = [double]$dc.Bytes; $files = [long]$dc.Files
    if ((Stopping) -or $dc.Cancelled) { $res.Cancelled = $true; $res.Msg = (T '已取消，什么都没改'); return }
    $free = [double](FreeC)
    if ($free -lt $bytes + 2GB) { $res.Msg = (T "C 盘只剩 {0}，放不下 {1}（还要留 2 GB 余量）") -f (GB $free), (GB $bytes); OpLog '搬运' (T '搬回 C 盘失败') $src $res.Msg; return }
    $tmp = "$src.cleanc_back"
    if (Test-Path -LiteralPath $tmp) { try { [IO.Directory]::Move($tmp, ("{0}_{1:yyyyMMddHHmmss}" -f $tmp, (Get-Date))) } catch {} }
    $tmpFresh = -not (Test-Path -LiteralPath $tmp)   # 是这次新建的，里面只有这次复制回来的东西
    New-Item -ItemType Directory -Path $tmp -Force | Out-Null
    $jr = @{ Kind = 'back'; Src = $src; Dst = $dst; Bak = $tmp; Cp = '/COPY:DAT'; Fresh = [string]$tmpFresh; Step = 'copying' }; [void](Set-MoveStep $jr)
    SetP @{ MovePhase = 'copy'; SubKind = 'copy'; SubTotal = [double]$bytes; SubBase = [double]0; SubDone = [double]0; SubStart = (Get-Date); DestDrive = $env:SystemDrive; DestFree0 = $free; Detail = "$dst  ->  $src" }
    $rcArgs = @($dst, $tmp, '/E', '/COPY:DAT', '/DCOPY:DAT', '/R:2', '/W:2', '/NDL', '/NJH', '/NJS', '/NP', '/BYTES', '/XJ')
    $rc = Invoke-Tool "$sys32\robocopy.exe" $rcArgs '' 0
    if ($rc.Cancelled) { Undo-MoveBackCopy $tmp $tmpFresh $dst $src $res; Clear-MoveStep $src; return }
    if ($rc.Code -ge 8 -or $rc.Code -lt 0) { $res.Msg = ((T "复制回 C 盘失败（robocopy 代码 {0}），什么都没改，复制了一半的临时文件夹在 {1}") -f $rc.Code, $tmp); OpLog '搬运' (T '搬回 C 盘失败') $src $res.Msg; return }
    SetP @{ MovePhase = 'verify'; SubKind = 'measure'; SubStart = (Get-Date); Detail = (T '核对两边是否一致') }
    # 个数和大小一个都不能差；差一点多半是复制时还有程序在写：再补复制一遍、再数一次
    $dc = DirCount $dst; $tc = DirCount $tmp
    if (-not (Stopping) -and -not (Test-SameCount $dc $tc)) { & "$sys32\robocopy.exe" @rcArgs | Out-Null; $dc = DirCount $dst; $tc = DirCount $tmp }
    $bytes = [double]$dc.Bytes; $files = [long]$dc.Files; $b2 = [double]$tc.Bytes; $f2 = [long]$tc.Files
    if ((Stopping) -or $tc.Cancelled -or $dc.Cancelled) { Undo-MoveBackCopy $tmp $tmpFresh $dst $src $res; Clear-MoveStep $src; return }
    if (-not (Test-SameCount $dc $tc)) {
        $res.Msg = (T "核对不一致（目标盘 {0:N0} 个文件，复制回来 {1:N0} 个），什么都没改") -f $files, $f2; OpLog '搬运' (T '搬回 C 盘失败') $src $res.Msg; return
    }
    Set-CanCancel $false   # 拆链接、换回文件夹、删目标盘上的那份：不能停在一半
    SetP @{ MovePhase = 'link'; SubKind = 'action'; SubStart = (Get-Date); Detail = (T '拆掉链接，换回真正的文件夹') }
    & "$sys32\cmd.exe" /c rmdir "$src" 2>$null | Out-Null
    if (Test-Path -LiteralPath $src) { $res.Msg = ((T "C 盘上的链接拆不掉（可能被占用），什么都没改；复制回来的数据在 {0}") -f $tmp); OpLog '搬运' (T '搬回 C 盘失败') $src $res.Msg; return }
    $jr.Step = 'unlinked'; [void](Set-MoveStep $jr)
    try { [IO.Directory]::Move($tmp, $src) }
    catch {
        & "$sys32\cmd.exe" /c mklink /J "$src" "$dst" | Out-Null
        if (IsLink $src) { Clear-MoveStep $src }
        $res.Msg = ((T "换回文件夹失败，已恢复原来的链接；复制回来的数据在 {0}") -f $tmp); OpLog '搬运' (T '搬回 C 盘失败') $src $res.Msg; return
    }
    $jr.Step = 'swapped'; [void](Set-MoveStep $jr)
    OpLog '搬运' (T '搬回 C 盘') "$dst → $src" ((T "{0:N0} 个文件，{1}，已核对") -f $files, (GB $bytes))
    & "$sys32\robocopy.exe" "$dst" "$src" /E /XO /COPY:DAT /R:1 /W:1 /XJ /NFL /NDL /NJH /NJS /NP | Out-Null
    if ($LASTEXITCODE -ge 8) {
        $res.Ok = $true; $res.Bytes = $bytes; $res.Msg = ((T "已搬回 C 盘，但有几个最后写入的文件没补复制过来，目标盘上的那份先保留：{0}") -f $dst)
        OpLog '搬运' (T '搬回后保留目标盘副本') $dst $res.Msg
        foreach ($root in (All-MoveRoots)) { Remove-MoveMapEntry $root $src }
        Clear-MoveStep $src; $script:movedTargets = $null; SetP @{ MovePhase = 'done' }; return
    }
    if (-not (Test-OurMoveCopy $src $dst)) {
        $res.Msg = ((T "已搬回 C 盘。{0} 不是本工具搬过去的（或者还有别的地方链接着它），没有删；确认不需要的话可以自己删") -f $dst)
        OpLog '搬运' (T '搬回后保留目标盘上的文件夹') $dst $res.Msg
    } else {
        SetP @{ MovePhase = 'cleanup'; SubKind = 'action'; SubStart = (Get-Date); Detail = (T '删除目标盘上的那份') }
        $jr.Step = 'cleanup'; [void](Set-MoveStep $jr)
        if (Test-CmdPathOk $dst) { & "$sys32\cmd.exe" /c rd /s /q "\\?\$dst" 2>$null | Out-Null }
        if (Test-Path -LiteralPath $dst) { $res.Msg = ((T "已搬回，但目标盘上的旧副本没删干净：{0}") -f $dst) }
        else { OpLog '删除' (T '搬回后删除目标盘上的旧副本') $dst (GB $bytes) }
    }
    foreach ($root in (All-MoveRoots)) { Remove-MoveMapEntry $root $src }
    if (-not (Test-Path -LiteralPath $dst) -or -not (Test-OurMoveCopy $src $dst)) { Clear-MoveStep $src }   # 目标盘那份没删干净时记录留着，下次打开可以接着删
    $script:movedTargets = $null
    $res.Ok = $true; $res.Bytes = $bytes
    SetP @{ MovePhase = 'done' }
}
# 重建链接：C 盘原位置（断掉的链接或已经不在）重新指向 $target
function Invoke-FixLink([string]$src, [string]$target, $res) {
    $res.Ok = $false
    if (-not (Test-Path -LiteralPath $target)) { $res.Msg = ((T "目标 {0} 不存在") -f $target); return }
    if (IsLink $src) { & "$sys32\cmd.exe" /c rmdir "$src" 2>$null | Out-Null }
    if (Test-Path -LiteralPath $src) { $res.Msg = ((T "C 盘上 {0} 是一个真文件夹，不能覆盖") -f $src); return }
    & "$sys32\cmd.exe" /c mklink /J "$src" "$target" | Out-Null
    if (IsLink $src) { $res.Ok = $true; OpLog '搬运' (T '重建链接') "$src → $target" '' ; $script:movedTargets = $null }
    else { $res.Msg = (T '建链接失败'); OpLog '搬运' (T '重建链接失败') "$src → $target" '' }
}
# 删掉没搬完留下的多余副本（只有 C 盘原文件夹还在时才允许）
function Invoke-DropCopy($rec, $res) {
    $res.Ok = $false
    $src = [string]$rec.Src; $dst = [string]$rec.Dst
    if (-not (Test-Path -LiteralPath $src) -or (IsLink $src)) { $res.Msg = (T 'C 盘原文件夹不在，这份副本可能是唯一的一份，不删'); return }
    foreach ($c in (Get-Catalog)) { foreach ($p in $c.Paths) { $t = LinkTarget $p; if ($t -and $t.TrimEnd('\') -ieq $dst.TrimEnd('\')) { $res.Msg = ((T "这份副本正被 {0} 的链接使用，不能删") -f $p); return } } }
    foreach ($r in (Get-MoveRecords)) {
        if ([string]$r.Src -ine $src -and ([string]$r.Dst).TrimEnd('\') -ieq $dst.TrimEnd('\') -and (IsLink ([string]$r.Src))) { $res.Msg = ((T "这份副本正被 {0} 的链接使用，不能删") -f $r.Src); return }
    }
    if (-not (Test-CmdPathOk $dst)) { $res.Msg = (T '路径里有 % 或引号，为了不删错地方，没法在这里删'); return }
    SetP @{ Detail = (T '核对副本里有没有 C 盘上没有的文件') }
    $dc = DirCount $dst; $b = [double]$dc.Bytes; $nf = [long]$dc.Files
    if ((Stopping) -or $dc.Cancelled) { $res.Msg = (T '已取消，副本没删'); return }
    $extra = Get-ExtraCount $dst $src
    if ($extra -ne 0) {
        $res.Msg = if ($extra -lt 0) { (T '核对不了，不删') } else { ((T "副本里有 {0} 个文件在 C 盘原文件夹里没有（或比 C 盘上的新），这份副本可能是唯一的一份，所以不删。请打开两边对比后再决定") -f $extra) }
        OpLog '删除' (T '没删多余副本（副本里有 C 盘没有的文件）') $dst $res.Msg; return
    }
    & "$sys32\cmd.exe" /c rd /s /q "\\?\$dst" 2>$null | Out-Null
    if (Test-Path -LiteralPath $dst) { $res.Msg = (T '没删干净，可能有文件被占用'); return }
    foreach ($root in (All-MoveRoots)) { Remove-MoveMapEntry $root $src }
    $script:movedTargets = $null
    OpLog '删除' (T '删除没搬完留下的多余副本') $dst ((T "{0}，C 盘原文件夹 {1} 保留") -f (GB $b), $src)
    $res.Ok = $true; $res.Bytes = $b
}

# ============================================================
# 软件整个搬到其他盘：搬安装文件夹，原位置留链接，快捷方式、卸载、更新照常
# ============================================================
# 不能搬的原因；空字符串表示可以搬。'store' 表示应用商店的软件（由 Windows 自己管）
function Get-AppMoveBlock($app, $others, $svc = $null) {
    if ($app.Kind -eq 'store') { return 'store' }
    $loc = ([string]$app.Location).Trim().TrimEnd('\')
    $sd = $env:SystemDrive
    if (-not $loc -or -not (Test-Path -LiteralPath $loc -PathType Container)) { return (T '安装程序没有写明这个软件装在哪个文件夹，没法确定要搬什么') }
    if (-not $loc.StartsWith("$sd\", [StringComparison]::OrdinalIgnoreCase)) { return (T '这个软件本来就不在 C 盘') }
    if (IsLink $loc) { return (T '已经搬过了，C 盘上这里只剩一个链接。要搬回来请到「搬家管理」') }
    $up = Get-LinkedAncestor $loc
    if ($up) { return ((T "它所在的文件夹 {0} 已经搬到其他盘了，这个软件的文件其实已经不在 C 盘") -f $up) }
    $pf = "$sd\Program Files"; $pf86 = "$sd\Program Files (x86)"; $lp = "$env:LOCALAPPDATA\Programs"
    $par = (Split-Path $loc -Parent).TrimEnd('\')
    if (-not $app.LocReg -and @($pf, $pf86, $lp) -notcontains $par) {
        return ((T "安装程序没有写明软件装在哪个文件夹（只知道它的图标在 {0} 里），为了不搬错，不搬") -f $loc)
    }
    foreach ($g in @("$sd", $pf, $pf86, "$sd\ProgramData", "$sd\Users", $env:USERPROFILE, $env:LOCALAPPDATA, $env:APPDATA, $lp, "$env:USERPROFILE\AppData", "$env:USERPROFILE\AppData\LocalLow")) {
        if ($g -and $loc -ieq $g.TrimEnd('\')) { return (T '记录的安装位置是一个总文件夹，里面还有很多别的东西，不能整个搬') }
    }
    foreach ($d in @($env:SystemRoot, "$sd\ProgramData\Microsoft", "$sd\ProgramData\Package Cache", "$pf\WindowsApps", "$pf\ModifiableWindowsApps", "$pf\Common Files", "$pf86\Common Files",
                     "$sd\Recovery", "$sd\Boot", "$sd\EFI", "$sd\System Volume Information", "$sd\`$Recycle.Bin", "$sd\Config.Msi", "$sd\Intel", "$sd\AMD", "$sd\NVIDIA", "$sd\Drivers")) {
        if ($loc -ieq $d -or $loc.StartsWith("$d\", [StringComparison]::OrdinalIgnoreCase)) { return (T '这是系统或硬件驱动的文件夹，不能搬') }
    }
    foreach ($root in @($pf, $pf86)) {
        if ($loc.StartsWith("$root\", [StringComparison]::OrdinalIgnoreCase)) {
            $first = $loc.Substring($root.Length + 1).Split('\')[0]
            if ($script:progKeep -contains $first -or $first -like 'Microsoft*' -or $first -like 'Windows*') { return (T '微软的软件或 Windows 自带的组件，由系统统一管理更新和修复，不能搬') }
        }
    }
    if (Test-Personal $loc) { return (T '装在个人文件夹（桌面、文档、下载等）里，不动') }
    if ([string]$app.Publisher -match '(?i)^Microsoft' -and -not $loc.StartsWith("$lp\", [StringComparison]::OrdinalIgnoreCase)) {
        return (T '微软的软件（Office、Visual Studio、.NET、Edge 等）由微软的安装程序统一管理更新和修复，搬走后容易出错，不搬')
    }
    $self = [string]$env:CLEANC_SELF
    if ($self -and $self.StartsWith("$loc\", [StringComparison]::OrdinalIgnoreCase)) { return (T '本工具就放在这个文件夹里，请把工具挪到别处再搬') }
    foreach ($o in @($others)) {
        $ol = ([string]$o.Location).Trim().TrimEnd('\')
        if (-not $ol -or $ol.Length -le 3 -or [string]$o.Name -eq [string]$app.Name -or $ol -ieq $loc) { continue }
        if ($ol.StartsWith("$loc\", [StringComparison]::OrdinalIgnoreCase)) { return ((T "这个文件夹里还装着别的软件「{0}」，整个搬会连它一起搬走。可以单独搬「{1}」") -f $($o.Name), $($o.Name)) }
        if ($loc.StartsWith("$ol\", [StringComparison]::OrdinalIgnoreCase) -and -not $app.LocReg) { return ((T "它装在「{0}」的文件夹里面，是那个软件的一部分。要搬请搬「{1}」") -f $($o.Name), $($o.Name)) }
    }
    # 带系统服务或驱动的（杀毒、VPN、显卡和外设驱动、远程控制……）：开机早期就要加载，搬走可能启动失败，甚至影响开机
    $pre = "$loc\"; $hits = @()
    if ($null -eq $svc) { $svc = Get-ServicePaths }
    foreach ($sv in $svc) { if (([string]$sv.PathName).IndexOf($pre, [StringComparison]::OrdinalIgnoreCase) -ge 0) { $hits += [string]$sv.DisplayName } }
    if ($hits.Count -gt 0) {
        return ((T "这个软件带有系统服务或驱动（{0}）。服务和驱动在开机时就要加载，搬走后可能启动失败，甚至影响开机，所以不搬") -f (@($hits | Select-Object -Unique -First 3) -join (T '、')))
    }
    return ''
}
# 上面哪一级文件夹是链接（已经搬走了）。没有就返回空
function Get-LinkedAncestor([string]$path) {
    $p = Split-Path $path.TrimEnd('\') -Parent
    $memo = $script:linkMemo   # 只在清理扫描（统计大小）时有：同一个上级文件夹只查一次；删除时每次都现查
    while ($p -and $p.TrimEnd('\').Length -gt 2) {
        if ($null -ne $memo) {
            $k = $p.TrimEnd('\').ToLowerInvariant()
            if (-not $memo.ContainsKey($k)) { $memo[$k] = [bool](IsLink $p) }
            if ($memo[$k]) { return $p.TrimEnd('\') }
        } elseif (IsLink $p) { return $p.TrimEnd('\') }
        $p = Split-Path $p -Parent
    }
    return ''
}
# 从这个文件夹（或这几个文件夹）里运行的程序
# 所有系统服务和驱动的程序路径（判断软件能不能搬时用）
function Get-ServicePaths {
    $out = New-Object System.Collections.ArrayList
    # 直接读注册表里每个服务和驱动登记的程序路径（服务管理器和 WMI 读的也是这一份；WMI 有时要等好几秒）。读不到再问 WMI
    $root = $null
    try {
        $root = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey('SYSTEM\CurrentControlSet\Services')
        if ($root) {
            foreach ($n in $root.GetSubKeyNames()) {
                $k = $null
                try {
                    $k = $root.OpenSubKey($n)
                    if ($k) {
                        $ip = [string]$k.GetValue('ImagePath')
                        if ($ip) { $dn = [string]$k.GetValue('DisplayName'); if (-not $dn -or $dn.StartsWith('@')) { $dn = $n }; [void]$out.Add(@{ PathName = $ip; DisplayName = $dn }) }
                    }
                } catch {} finally { if ($k) { $k.Close() } }
            }
        }
    } catch {} finally { if ($root) { $root.Close() } }
    if ($out.Count -gt 0) { return ,$out }
    foreach ($cls in 'Win32_Service', 'Win32_SystemDriver') {
        try { foreach ($sv in @(Get-CimInstance -ClassName $cls -ErrorAction Stop)) { [void]$out.Add(@{ PathName = [string]$sv.PathName; DisplayName = [string]$sv.DisplayName }) } } catch {}
    }
    return ,$out
}
# 读出装过的软件：注册表里的桌面软件，加上应用商店的软件（-NoStore 时不读）。不统计大小
function Get-InstalledApps([switch]$NoStore) {
    $out = New-Object System.Collections.ArrayList
    $seen = @{}
    $keys = @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*', 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*', 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*')
    foreach ($k in $keys) {
        foreach ($p in @(Get-ItemProperty $k -ErrorAction SilentlyContinue)) {
            $name = [string]$p.DisplayName
            if (-not $name -or -not $p.UninstallString) { continue }
            if ($p.SystemComponent -eq 1 -or $p.ParentKeyName -or ([string]$p.ReleaseType) -match 'Update|Hotfix') { continue }
            $key = ($name + '|' + [string]$p.DisplayVersion).ToLowerInvariant()
            if ($seen.ContainsKey($key)) { continue }; $seen[$key] = $true
            $loc = ([string]$p.InstallLocation).Trim().Trim('"').TrimEnd('\')
            $locReg = [bool]$loc
            if (-not $loc -and $p.DisplayIcon) {
                $ic = (([string]$p.DisplayIcon) -split ',')[0].Trim().Trim('"')
                if ($ic -and (Test-Path -LiteralPath $ic -PathType Leaf)) { $loc = Split-Path $ic -Parent }
            }
            [void]$out.Add(@{ Name = $name; Publisher = [string]$p.Publisher; Version = [string]$p.DisplayVersion; Date = [string]$p.InstallDate
                Location = $loc; LocReg = $locReg; Est = [double]$p.EstimatedSize * 1KB; Uninstall = [string]$p.UninstallString; Kind = 'desktop'; Package = '' })
        }
    }
    if ($NoStore) { return ,$out }
    try {
        foreach ($a in @(Get-AppxPackage -PackageTypeFilter Main -ErrorAction Stop | Where-Object { -not $_.IsFramework -and $_.SignatureKind -ne 'System' -and -not $_.NonRemovable })) {
            $dn = $a.Name
            # 显示名直接从安装文件夹里的 AppxManifest.xml 读（Get-AppxPackageManifest 每个要零点几秒，几十个应用就要等很久）
            try {
                $mf = Join-Path ([string]$a.InstallLocation) 'AppxManifest.xml'
                if ($a.InstallLocation -and [IO.File]::Exists($mf)) {
                    $mx = [regex]::Match([IO.File]::ReadAllText($mf), '(?s)<Properties>.*?<DisplayName>([^<]+)</DisplayName>')
                    if ($mx.Success) { $x = [Net.WebUtility]::HtmlDecode($mx.Groups[1].Value.Trim()); if ($x -and $x -notlike 'ms-resource:*') { $dn = $x } }
                }
            } catch {}
            [void]$out.Add(@{ Name = $dn; Publisher = ([string]$a.Publisher -replace '^CN=([^,]+).*$', '$1'); Version = [string]$a.Version; Date = ''
                Location = [string]$a.InstallLocation; LocReg = $true; Est = [double]0; Uninstall = ''; Kind = 'store'; Package = $a.PackageFullName })
        }
    } catch {}
    return ,$out
}
# 从应用商店装的聊天软件（由 Windows 管理，本工具不搬，只提示可以在 Windows 设置里换盘）
function Get-StoreChatApps {
    $known = [ordered]@{ 'WhatsApp' = '*WhatsAppDesktop*'; 'Microsoft Teams' = 'MSTeams'; 'Messenger' = 'FACEBOOK.317180B0BB486'; 'Telegram' = '*TelegramDesktop*' }
    $out = @()
    try {
        $pk = @(Get-AppxPackage -ErrorAction Stop | ForEach-Object { [string]$_.Name })
        foreach ($k in $known.Keys) { if (@($pk | Where-Object { $_ -like $known[$k] }).Count -gt 0) { $out += $k } }
    } catch {}
    return ,$out
}
# 软件整个搬走：先确认没有别的程序加载着它的组件，带上原来的访问权限，关掉从这里运行的程序，再复制、核对、换成链接
function Invoke-AppMove($item, [string]$dest, $res) {
    $p = [string]$item.Paths[0]
    SetP @{ SubKind = 'action'; SubStart = (Get-Date); Detail = (T '检查有没有别的程序在用它的文件') }
    $held = Get-ModuleHolders $p
    if (Stopping) { $res.Cancelled = $true; $res.Msgs = @((T '已取消，什么都没动。')); return }
    if ($held.Count -gt 0) {
        $m = (T "这些程序正在使用它的组件：{0}。文件夹被它们占着，搬不了。输入法、右键菜单、杀毒、驱动这一类软件一般都不适合搬。") -f ($held -join (T '、'))
        $res.Fail = 1; $res.Msgs = @($m); OpLog '搬运' (T '软件没搬：组件正被别的程序使用') $p ($held -join (T '、')); return
    }
    try { $item.Sddl = (Get-Acl -LiteralPath $p).GetSecurityDescriptorSddlForm('Access') } catch {}
    # 先关掉从这个文件夹运行的程序（确认框里已经告诉过用户），否则正在写的文件会让复制失败
    SetP @{ Detail = (T '关闭正在运行的程序') }
    [void](Close-Holders $item $p)
    Invoke-Move $item $dest $res
    if ($res.Done -gt 0) { OpLog '搬运' ((T "软件搬到其他盘：{0}") -f $item.N) "$p → $($res.Dest -join (T '；'))" (T '安装文件夹整个搬走，原位置留链接') }
}
# 一项搬家的结果，写成列表里的一句话和颜色：@(文字, ok/warn/fail/skip)
function Move-ResultText($res) {
    if ($res.Cancelled) {
        $t = if ($res.Done -gt 0) { (T "中途取消：已搬 {0}；{1}") -f (GB $res.Moved), $res.Msgs[-1] } else { [string]$res.Msgs[-1] }
        return @($t, 'warn')
    }
    if ($res.Done -gt 0 -and $res.Fail -eq 0 -and $res.Wait -eq 0) { return @(((T "已搬 {0} 到 {1}") -f (GB $res.Moved), ($res.Dest -join (T '；'))), 'ok') }
    if ($res.Done -gt 0) { return @(((T "部分完成：搬了 {0}；{1}") -f (GB $res.Moved), $res.Msgs[-1]), 'warn') }
    if ($res.Wait -gt 0 -and $res.Fail -eq 0) { return @(((T "差最后一步：") + $res.Msgs[-1]), 'warn') }
    if ($res.Fail -gt 0) { return @(((T "没搬成：") + $res.Msgs[0]), 'fail') }
    return @((T '不用搬（已经搬过或不在 C 盘）'), 'skip')
}
function Get-ProcsInside([string[]]$dirs) {
    $pres = @($dirs | Where-Object { $_ } | ForEach-Object { $_.TrimEnd('\') + '\' })
    $out = @()
    foreach ($p in @(Get-Process -ErrorAction SilentlyContinue)) {
        if ($p.Id -eq $PID) { continue }
        $path = ''; try { $path = [string]$p.Path } catch {}
        if (-not $path) { continue }
        foreach ($pre in $pres) { if ($path.StartsWith($pre, [StringComparison]::OrdinalIgnoreCase)) { $out += $p.Name; break } }
    }
    return ,@($out | Select-Object -Unique)
}
# 别的程序（不是从这个文件夹启动的）有没有加载这个文件夹里的组件：资源管理器的右键菜单、输入法、杀毒插件等。有的话文件夹一直被占着，搬不了
function Get-ModuleHolders([string]$dir) {
    $pre = $dir.TrimEnd('\') + '\'
    $out = @()
    foreach ($p in @(Get-Process -ErrorAction SilentlyContinue)) {
        if ($p.Id -eq $PID -or $p.Id -le 4) { continue }
        $path = ''; try { $path = [string]$p.Path } catch {}
        if ($path -and $path.StartsWith($pre, [StringComparison]::OrdinalIgnoreCase)) { continue }   # 从这个文件夹运行的程序，搬之前会关掉
        $mods = $null; try { $mods = $p.Modules } catch { continue }
        foreach ($m in $mods) {
            $f = ''; try { $f = [string]$m.FileName } catch {}
            if ($f -and $f.StartsWith($pre, [StringComparison]::OrdinalIgnoreCase)) {
                $out += $(if ($p.Name -ieq 'explorer') { (T '资源管理器（桌面、文件夹窗口、右键菜单）') } else { $p.Name }); break
            }
        }
    }
    return ,@($out | Select-Object -Unique)
}
# 这块盘是不是接在 USB、1394、SD 卡这类插拔式总线上（移动硬盘在 Windows 里也算「本机硬盘」）。读不到当作不是
function Test-PluggableDrive([string]$drive) { try { return [bool][FsTools]::IsPluggable($drive) } catch { return $false } }
# 搬家目标的候选：C 盘以外、插着的本机硬盘，按空闲从多到少；移动硬盘排在后面，不参与自动选择（拔掉后搬走的软件打不开）。
# $drives 是测试用的，每项 @{ Drive; Free; Plug }
function Get-DestChoices($drives = $null) {
    if ($null -eq $drives) {
        $drives = @([IO.DriveInfo]::GetDrives() | Where-Object { try { $_.DriveType -eq 'Fixed' -and $_.IsReady } catch { $false } } | ForEach-Object {
            $n = $_.Name.Substring(0, 2); @{ Drive = $n; Free = [long]$_.AvailableFreeSpace; Plug = (Test-PluggableDrive $n) } })
    }
    $list = @($drives | Where-Object { $_.Drive -ine $env:SystemDrive } |
        Sort-Object @{ Expression = { [int][bool]$_.Plug } }, @{ Expression = { [long]$_.Free }; Descending = $true })
    $out = New-Object System.Collections.Generic.List[object]
    $auto = $true
    foreach ($d in $list) {
        $plug = [bool]$d.Plug
        $out.Add([pscustomobject]@{ Drive = $d.Drive; Path = $d.Drive + '\CDriveMoved'; Free = [long]$d.Free; Plug = $plug; Auto = ($auto -and -not $plug) })
        if (-not $plug) { $auto = $false }
    }
    return $out.ToArray()
}
# 这块盘有没有用 BitLocker（包括家庭版的「设备加密」）加密：$true 加密了（包括正在加密、暂停保护），$false 没加密，$null 查不到
function Get-DriveEncrypted([string]$drive) {
    if (-not $drive -or $drive.Length -lt 2 -or $drive[1] -ne ':') { return $null }
    try {
        $v = @(Get-CimInstance -Namespace 'root\CIMV2\Security\MicrosoftVolumeEncryption' -ClassName Win32_EncryptableVolume -Filter ("DriveLetter='{0}'" -f $drive.Substring(0, 2).ToUpperInvariant()) -ErrorAction Stop)
        if ($v.Count -eq 0) { return $false }   # 不在列表里：这块盘不能用 BitLocker
        return ([int]$v[0].ConversionStatus -ne 0)   # 0 = 完全没加密
    } catch { return $null }
}
# 从加密的 C 盘搬到没加密的盘：确认框里加的一段话。查不到、两边一样、C 盘没加密时返回空。$cEnc / $dEnc 是测试用的
function Get-EncryptionWarning([string]$dest, $cEnc = 'ask', $dEnc = 'ask') {
    if (-not $dest -or $dest.Length -lt 2) { return '' }
    if ($cEnc -is [string] -and $cEnc -eq 'ask') { $cEnc = Get-DriveEncrypted $env:SystemDrive }
    if (-not ($cEnc -is [bool] -and $cEnc)) { return '' }
    if ($dEnc -is [string] -and $dEnc -eq 'ask') { $dEnc = Get-DriveEncrypted $dest.Substring(0, 2) }
    if (-not ($dEnc -is [bool]) -or $dEnc) { return '' }
    return ((T "C 盘用 BitLocker 加密了，{0} 盘没有：搬过去的聊天记录和文件在那块盘上不加密，电脑丢了或者硬盘被拆走，别人能直接读出来。介意的话，先给 {0} 盘打开 BitLocker（控制面板 →「BitLocker 驱动器加密」）再搬。") -f $dest.Substring(0, 1).ToUpperInvariant())
}
# 用电池时搬东西：要搬的多（2 GB 以上）或者电量低于 30%，确认框里加一句。$ps 是测试用的：@{ Battery = 在用电池; Percent = 0~1 }
function Get-PowerNote([double]$bytes, $ps = $null) {
    if ($null -eq $ps) {
        try {
            Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
            $s = [System.Windows.Forms.SystemInformation]::PowerStatus
            $ps = @{ Battery = ([string]$s.PowerLineStatus -eq 'Offline'); Percent = [double]$s.BatteryLifePercent }
        } catch { return '' }
    }
    if (-not $ps.Battery) { return '' }
    $pct = [int][math]::Round([double]$ps.Percent * 100)
    if ($bytes -lt 2GB -and $pct -ge 30) { return '' }
    return ((T "现在用的是电池（剩 {0}%）。搬家要一段时间，中途没电会停在一半（下次打开可以接着做完或撤回，数据不会丢），最好先插上电源。") -f $pct)
}
# 登录桌面的是谁（这个会话里资源管理器的主人），读不到返回空。打开时输入另一个管理员账户的密码，本工具就以那个账户运行
function Get-DesktopUser {
    try {
        $sid = [Diagnostics.Process]::GetCurrentProcess().SessionId
        foreach ($p in @(Get-CimInstance Win32_Process -Filter "Name='explorer.exe'" -ErrorAction Stop)) {
            if ([int]$p.SessionId -ne $sid) { continue }
            $o = Invoke-CimMethod -InputObject $p -MethodName GetOwner -ErrorAction Stop
            if ($o.User) { return ('{0}\{1}' -f $o.Domain, $o.User) }
        }
    } catch {}
    return ''
}
# 本工具运行的账户和登录桌面的不是同一个：返回给人看的说明，同一个或读不到时返回空
function Get-AccountMismatch([string]$me, [string]$desk) {
    if (-not $me -or -not $desk -or $me -ieq $desk) { return '' }
    $a = ($me -split '\\')[-1]; $b = ($desk -split '\\')[-1]
    return ((T "本工具现在以 {0} 的身份运行，但登录桌面的是 {1}（打开时输入的是另一个管理员账户的密码）。清理的缓存、要搬的聊天记录、受保护的个人文件夹，都按 {0} 的账户算，{1} 的不会动。`n`n要整理 {1} 的，把 {1} 设成管理员后用它打开，或者登录 {0} 再用。") -f $a, $b)
}
# 打开网页、文本文件、报告：交给资源管理器去开。本工具以管理员身份运行，直接开的话浏览器、记事本也是管理员身份，
# 网页里的下载、记事本里的「另存为」都带着管理员权限。资源管理器把它交给当前登录用户的桌面，用普通权限打开
function Open-AsUser([string]$target) {
    if (-not $target) { return $false }
    try { Start-Process -FilePath "$env:SystemRoot\explorer.exe" -ArgumentList ('"{0}"' -f $target.Replace('"', '')); return $true } catch { return $false }
}
# 清理页按当前选择的合计：N 选了几项，Del 删除（和「执行」）能腾出多少，Move 要搬走多少；Groups 每个选项卡选了几项、一共几项
function Get-PlanTotals($rows, $sizes) {
    $out = @{ N = 0; Del = [double]0; Move = [double]0; Groups = @{} }
    $skip = T '跳过'; $mv = T '搬到其他盘'
    foreach ($r in $rows) {
        $g = [string]$r.GroupTitle
        if (-not $out.Groups.ContainsKey($g)) { $out.Groups[$g] = @{ Sel = 0; Cnt = 0 } }
        $out.Groups[$g].Cnt++
        if ([string]$r.Action -eq $skip) { continue }
        $out.N++; $out.Groups[$g].Sel++
        $b = if ($sizes) { [double]$sizes[$r.Idx] } else { [double]0 }
        if ($b -le 0) { continue }
        if ([string]$r.Action -eq $mv) { $out.Move += $b } else { $out.Del += $b }
    }
    return $out
}
# 一键清理给目录里的一项选什么：只删不搬（聊天记录这类要搬的在清理页单独一张卡片，用户自己点）；
# 有代价的（「默认不清」一组）和自己加的文件夹一律跳过
function Get-OneClickAction($it) {
    if ($it.Tier -eq 'confirm' -or $it.Custom -or $it.Kind -eq 'move') { return (T '跳过') }
    $want = if ($it.One) { [string]$it.One } else { [string]$it.Def }
    if ($want -eq (T '搬到其他盘')) { return (T '跳过') }
    return $want
}
# 普通用户能不能往这个文件夹里写（Users、Authenticated Users、Everyone、Interactive 有写入、删除、改权限之类的权限）。
# 读不到权限就当能写：拿不准的时候不信任它
function Test-UserWritable([string]$dir) {
    try {
        $acl = [IO.Directory]::GetAccessControl($dir)
        $w = [Security.AccessControl.FileSystemRights]::WriteData -bor [Security.AccessControl.FileSystemRights]::AppendData -bor [Security.AccessControl.FileSystemRights]::Delete -bor
             [Security.AccessControl.FileSystemRights]::DeleteSubdirectoriesAndFiles -bor [Security.AccessControl.FileSystemRights]::ChangePermissions -bor [Security.AccessControl.FileSystemRights]::TakeOwnership -bor
             [Security.AccessControl.FileSystemRights]::WriteAttributes -bor [Security.AccessControl.FileSystemRights]::WriteExtendedAttributes
        foreach ($r in $acl.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier])) {
            if ($r.AccessControlType -ne [Security.AccessControl.AccessControlType]::Allow) { continue }
            if ($r.PropagationFlags -band [Security.AccessControl.PropagationFlags]::InheritOnly) { continue }
            if (@('S-1-5-32-545', 'S-1-5-11', 'S-1-1-0', 'S-1-5-4') -notcontains $r.IdentityReference.Value) { continue }
            if (([int]$r.FileSystemRights -band [int]$w) -ne 0) { return $true }
        }
        return $false
    } catch { return $true }
}
# 文件夹或文件的访问权限（SDDL 里的 D: 部分，包括继承来的），读不到返回空
function Get-AccessSddl([string]$p) { try { return (Get-Acl -LiteralPath $p).GetSecurityDescriptorSddlForm('Access') } catch { return '' } }
# 电脑上的其他账户能不能打开它（Users、Authenticated Users、Everyone、Interactive 有读的权限）；读不到权限时当成不能
function Test-OthersCanRead([string]$p) {
    try {
        $acl = Get-Acl -LiteralPath $p
        foreach ($r in $acl.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier])) {
            if ($r.AccessControlType -ne [Security.AccessControl.AccessControlType]::Allow) { continue }
            if ($r.PropagationFlags -band [Security.AccessControl.PropagationFlags]::InheritOnly) { continue }
            if (@('S-1-5-32-545', 'S-1-5-11', 'S-1-1-0', 'S-1-5-4') -notcontains $r.IdentityReference.Value) { continue }
            if (([int]$r.FileSystemRights -band [int][Security.AccessControl.FileSystemRights]::ReadData) -ne 0) { return $true }
        }
    } catch {}
    return $false
}
# 以前的版本搬走的、现在电脑上的其他账户也能打开的文件夹：从用户目录（C:\Users\某人\…）搬走的，
# 在 C 盘时只有本人、系统和管理员能打开，搬过去后继承了目标盘根目录的权限
function Find-LooseMoves {
    $users = (Split-Path $env:USERPROFILE -Parent).TrimEnd('\')
    $out = @()
    foreach ($root in (All-MoveRoots)) {
        foreach ($pr in (Read-MoveMapPairs $root)) {
            $src = [string]$pr[0]; $dst = [string]$pr[1]
            if (-not $src.StartsWith($users + '\', [StringComparison]::OrdinalIgnoreCase)) { continue }
            if (-not (IsLink $src) -or -not (Test-Path -LiteralPath $dst -PathType Container)) { continue }
            $par = Split-Path $src -Parent
            if ((Test-OthersCanRead $dst) -and -not (Test-OthersCanRead $par)) { $out += @{ Src = $src; Dst = $dst; Like = $par } }
        }
    }
    return $out
}
# 把这些文件夹的权限改成和它们在 C 盘时所在的文件夹一样（里面的文件跟着继承）
function Repair-MovedAccess($items) {
    $ok = 0; $bad = @()
    foreach ($x in @($items)) {
        $sd = Get-AccessSddl $x.Like
        if ($sd -and (Set-DirAccess $x.Dst $sd) -and -not (Test-OthersCanRead $x.Dst)) { $ok++; OpLog '系统设置' (T '修正搬走的文件夹的权限') $x.Dst ((T "改成和 {0} 一样") -f $x.Like) }
        else { $bad += $x.Dst; OpLog '系统设置' (T '没能修正搬走的文件夹的权限') $x.Dst '' }
    }
    return @{ Ok = $ok; Bad = $bad }
}
# 定时任务运行的那一份 exe：放在 Program Files\ClearC 里，只有管理员能改。任务以最高权限运行，
# 要是指向下载文件夹这类普通权限就能改的地方，有人换掉那个 exe，到点就能不经确认拿到管理员权限
function Get-TaskExePath { $pf = [Environment]::GetFolderPath('ProgramFiles'); if (-not $pf) { return '' }; return (Join-Path $pf 'ClearC\ClearC.exe') }
# 把现在运行的 exe 复制成定时任务用的那一份（内容一样就不复制）；返回 @{ Path } 或 @{ Err }
function Install-TaskExe {
    $src = [string]$env:CLEANC_SELF; $dst = Get-TaskExePath
    if (-not $src -or -not (Test-Path -LiteralPath $src)) { return @{ Err = (T '只有 exe 版本支持定时任务') } }
    if (-not $dst) { return @{ Err = (T '找不到 Program Files 文件夹') } }
    $dir = Split-Path $dst
    try {
        if ([IO.Path]::GetFullPath($src) -ieq [IO.Path]::GetFullPath($dst)) { return @{ Path = $dst } }   # 现在运行的就是这一份
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        if (Test-UserWritable $dir) { return @{ Err = ((T "{0} 的权限让普通用户也能改里面的文件，定时任务不能从这里运行。删掉这个文件夹后再开。") -f $dir) } }
        $h = (Get-FileHash -LiteralPath $src -Algorithm SHA256).Hash
        if ((Test-Path -LiteralPath $dst) -and (Get-FileHash -LiteralPath $dst -Algorithm SHA256).Hash -eq $h) { return @{ Path = $dst } }
        $tmp = $dst + '.new'
        [IO.File]::Copy($src, $tmp, $true)
        if ((Get-FileHash -LiteralPath $tmp -Algorithm SHA256).Hash -ne $h) { [IO.File]::Delete($tmp); return @{ Err = (T '复制后核对不一致，没有改') } }
        if (Test-Path -LiteralPath $dst) { [IO.File]::Replace($tmp, $dst, [NullString]::Value) } else { [IO.File]::Move($tmp, $dst) }   # $null 会被当成空字符串
        OpLog '系统设置' (T '复制本工具给定时任务用') $dst ((T "来自 {0}") -f $src)
        return @{ Path = $dst }
    } catch { return @{ Err = ((T "没能把本工具复制到 {0}：{1}") -f $dir, $_.Exception.Message) } }
}
# 两个任务都关了：删掉 Program Files 里那一份（正在运行的就是它时不删）
function Remove-TaskExeIfUnused {
    $dst = Get-TaskExePath
    if (-not $dst -or -not (Test-Path -LiteralPath $dst)) { return }
    if ([string]$env:CLEANC_SELF -and [IO.Path]::GetFullPath([string]$env:CLEANC_SELF) -ieq $dst) { return }
    try {
        [IO.File]::Delete($dst)
        $d = Split-Path $dst; if (@(Get-ChildItem -LiteralPath $d -Force -ErrorAction SilentlyContinue).Count -eq 0) { [IO.Directory]::Delete($d) }
        OpLog '系统设置' (T '删除定时任务用的那一份本工具') $dst ''
    } catch {}
}
# 让搬过去的文件夹和原来在 C 盘时的访问权限一样（Program Files 里只有管理员能改，其他盘默认所有用户都能改）
function Set-DirAccess([string]$dir, [string]$sddl) {
    try {
        $sec = New-Object System.Security.AccessControl.DirectorySecurity
        $sec.SetSecurityDescriptorSddlForm($sddl, [System.Security.AccessControl.AccessControlSections]::Access)
        $sec.SetAccessRuleProtection($true, $true)
        [IO.Directory]::SetAccessControl($dir, $sec)
        return $true
    } catch { Log ((T "  没能把 {0} 的权限设成和原来一样：{1}") -f $dir, $($_.Exception.Message)); return $false }
}

# ============================================================
# 虚拟磁盘、模拟器、虚拟机
# ============================================================
function Get-VDisks {
    $out = New-Object System.Collections.ArrayList
    foreach ($k in @(Get-ChildItem 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Lxss' -ErrorAction SilentlyContinue)) {
        $p = Get-ItemProperty -LiteralPath $k.PSPath -ErrorAction SilentlyContinue
        if (-not $p -or -not $p.BasePath -or ([string]$p.DistributionName) -like 'docker-desktop*') { continue }
        $base = ([string]$p.BasePath) -replace '^\\\\\?\\', ''
        $vh = Join-Path $base 'ext4.vhdx'
        if (Test-Path -LiteralPath $vh) { [void]$out.Add(@{ Name = ((T "WSL：{0}") -f $($p.DistributionName)); Path = $vh; Kind = 'wsl'; Compact = $true; Move = $true; Distro = [string]$p.DistributionName
            Note = (T 'Linux 子系统的虚拟磁盘。在 Linux 里删了文件，这个文件不会自动变小，压缩一下就能把空间还给 Windows。也可以整个搬到其他盘（用 WSL 自己的 wsl --manage --move，搬完照常使用）') }) }
    }
    foreach ($vh in @("$env:LOCALAPPDATA\Docker\wsl\data\ext4.vhdx", "$env:LOCALAPPDATA\Docker\wsl\disk\docker_data.vhdx", "$env:LOCALAPPDATA\Docker\wsl\main\ext4.vhdx", "$env:LOCALAPPDATA\Docker\wsl\distro\ext4.vhdx")) {
        if (Test-Path -LiteralPath $vh) { [void]$out.Add(@{ Name = (T 'Docker Desktop 数据盘'); Path = $vh; Kind = 'docker'; Compact = $true; Move = $false
            Note = (T 'Docker 的镜像和容器都在里面。先在 Docker 里删掉不用的镜像（docker system prune），再压缩。换位置在 Docker Desktop 设置 → Resources → Disk image location') }) }
    }
    foreach ($vh in @(Get-ChildItem "$env:SystemDrive\ProgramData\Microsoft\Windows\Virtual Hard Disks" -Filter '*.vhd*' -File -ErrorAction SilentlyContinue)) {
        $ck = Test-HasCheckpoint $vh.FullName
        [void]$out.Add(@{ Name = ((T "Hyper-V 虚拟磁盘：{0}") -f $($vh.Name)); Path = $vh.FullName; Kind = 'hyperv'; Compact = (-not $ck); Move = $false
            Note = $(if ($ck) { (T '这块磁盘有检查点（.avhdx），压缩它会让检查点失效，所以不能在这里压缩。先在 Hyper-V 里删除或合并检查点') } else { (T '压缩前要先关掉用它的虚拟机') }) })
    }
    foreach ($d in @(@("$env:USERPROFILE\.android\avd", (T '安卓模拟器（Android Studio）'), (T 'Android 模拟器的系统镜像和数据')),
                     @("$env:USERPROFILE\VirtualBox VMs", (T 'VirtualBox 虚拟机'), (T 'VirtualBox 的虚拟机和虚拟磁盘')),
                     @(([Environment]::GetFolderPath('MyDocuments') + '\Virtual Machines'), (T 'VMware 虚拟机'), (T 'VMware 的虚拟机和虚拟磁盘')))) {
        if (Test-Path -LiteralPath $d[0]) {
            if (IsLink $d[0]) { continue }
            [void]$out.Add(@{ Name = $d[1]; Path = $d[0]; Kind = 'folder'; Compact = $false; Move = $true; Note = $d[2] + (T '。可以整个搬到其他盘，原位置留链接，软件照常使用。搬之前要关掉模拟器或虚拟机') })
        }
    }
    return ,$out
}
# WSL 发行版搬到其他盘：wsl --manage <名字> --move <位置>（WSL 2.5 以后才有；旧的提示先 wsl --update）
function Invoke-WslMove([string]$distro, [string]$dest, $res) {
    $res.Ok = $false; $res.Out = ''
    SetP @{ Detail = (T '先关闭这个发行版（wsl --terminate）') }
    & "$sys32\wsl.exe" --terminate $distro 2>$null | Out-Null
    Start-Sleep -Seconds 2
    New-Item -ItemType Directory -Path $dest -Force | Out-Null
    SetP @{ Detail = ((T "搬到 {0}（WSL 自己复制，可能要几分钟）") -f $dest) }
    $o = (& "$sys32\wsl.exe" --manage $distro --move $dest 2>&1 | Out-String)
    $o = ($o -replace "`0", '').Trim()
    $res.Out = $o
    if ($LASTEXITCODE -eq 0) { $res.Ok = $true }
    elseif ($o -match '(?i)--move|manage|unknown|无效|未知|不正确') { $res.Old = $true }
}
# 虚拟磁盘有没有检查点 / 差分盘挂在它下面（Hyper-V 把 名字_GUID.avhdx 放在同一个文件夹里）
function Test-HasCheckpoint([string]$path) {
    if ([IO.Path]::GetExtension($path) -match '(?i)^\.avhdx?$') { return $true }
    $dir = Split-Path $path -Parent; $base = [IO.Path]::GetFileNameWithoutExtension($path)
    return (@(Get-ChildItem -LiteralPath $dir -File -Force -ErrorAction SilentlyContinue | Where-Object { $_.Extension -match '(?i)^\.avhdx?$' -and $_.BaseName.StartsWith($base, [StringComparison]::OrdinalIgnoreCase) }).Count -gt 0)
}
function Invoke-CompactVdisk([string]$path, [string]$kind, $res) {
    $res.Ok = $false
    $before = [double](Get-Item -LiteralPath $path -Force).Length
    if (Test-HasCheckpoint $path) { $res.Before = $before; $res.After = $before; $res.Out = (T '这块磁盘有检查点（.avhdx），压缩它会让检查点失效，没有压缩'); return }
    if ($kind -eq 'wsl' -or $kind -eq 'docker') {
        SetP @{ Detail = (T '先关掉 WSL（wsl --shutdown），虚拟磁盘不在使用中才能压缩') }
        & "$sys32\wsl.exe" --shutdown 2>$null | Out-Null
        Start-Sleep -Seconds 4
    }
    SetP @{ Detail = ((T "压缩 {0}（diskpart，可能要几分钟）") -f $path) }
    $tmp = Join-Path $env:TEMP ("cleanc-diskpart-{0}.txt" -f (Get-Random))
    $lines = @("select vdisk file=`"$path`"", 'attach vdisk readonly', 'compact vdisk', 'exit')
    [IO.File]::WriteAllText($tmp, (($lines -join "`r`n") + "`r`n"), [Text.Encoding]::Default)
    $out = (& "$sys32\diskpart.exe" /s $tmp 2>&1 | Out-String)
    # 不管上面成没成功，都单独再跑一次把虚拟磁盘卸下来，免得它一直挂着
    [IO.File]::WriteAllText($tmp, ((@("select vdisk file=`"$path`"", 'detach vdisk noerr', 'exit') -join "`r`n") + "`r`n"), [Text.Encoding]::Default)
    & "$sys32\diskpart.exe" /s $tmp 2>&1 | Out-Null
    Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
    $after = [double](Get-Item -LiteralPath $path -Force).Length
    $res.Before = $before; $res.After = $after
    $res.Out = (($out -split "`r?`n") | Where-Object { $_.Trim() } | Select-Object -Last 4) -join ' / '
    $res.Ok = ($after -lt $before)
    OpLog '压缩' (T '压缩虚拟磁盘') $path ("{0} → {1}" -f (GB $before), (GB $after))
}

# ============================================================
# 系统压缩、页面文件、休眠文件
# ============================================================
function Get-CompactOSOn {
    $n = 0
    foreach ($f in @("$env:SystemRoot\explorer.exe", "$env:SystemRoot\System32\shell32.dll", "$env:SystemRoot\System32\mmc.exe", "$env:SystemRoot\System32\wbem\WmiPrvSE.exe")) {
        if ((Test-Path -LiteralPath $f) -and [FsTools]::LooksCompressed($f)) { $n++ }
    }
    return ($n -ge 2)
}
function Invoke-CompactOS([bool]$on, $res) {
    $f0 = [double](FreeC)
    $arg = if ($on) { '/compactos:always' } else { '/compactos:never' }
    SetP @{ Detail = $(if ($on) { (T '正在压缩系统文件，通常要 10 到 30 分钟，期间可以照常用电脑') } else { (T '正在解压系统文件，通常要 10 到 30 分钟') }) }
    & "$sys32\compact.exe" $arg 2>&1 | Out-Null
    $res.Delta = [double](FreeC) - $f0
    OpLog '压缩' $(if ($on) { (T '开启系统压缩（CompactOS）') } else { (T '关闭系统压缩（CompactOS）') }) $env:SystemRoot ((T "C 盘可用空间变化 {0}") -f (GB $res.Delta))
}
function Get-PageFileInfo {
    $auto = $null; $files = @()
    try { $auto = [bool](Get-CimInstance Win32_ComputerSystem -ErrorAction Stop).AutomaticManagedPagefile } catch { try { $auto = [bool](Get-WmiObject Win32_ComputerSystem).AutomaticManagedPagefile } catch {} }
    try { $files = @(Get-CimInstance Win32_PageFileUsage -ErrorAction Stop | ForEach-Object { @{ Path = [string]$_.Name; MB = [double]$_.AllocatedBaseSize } }) } catch {}
    return @{ Auto = $auto; Files = $files }
}
function Set-PageFile([string]$drive) {
    try {
        $cs = Get-CimInstance Win32_ComputerSystem -ErrorAction Stop
        if (-not $drive) {
            Set-CimInstance -InputObject $cs -Property @{ AutomaticManagedPagefile = $true } -ErrorAction Stop
            OpLog '系统设置' (T '页面文件恢复系统默认') 'pagefile.sys' (T '由系统自动管理，重启后生效')
            return ''
        }
        if ($cs.AutomaticManagedPagefile) { Set-CimInstance -InputObject $cs -Property @{ AutomaticManagedPagefile = $false } -ErrorAction Stop }
        foreach ($s in @(Get-CimInstance Win32_PageFileSetting -ErrorAction SilentlyContinue)) { Remove-CimInstance -InputObject $s -ErrorAction SilentlyContinue }
        New-CimInstance -ClassName Win32_PageFileSetting -Property @{ Name = "$drive\pagefile.sys" } -ErrorAction Stop | Out-Null
        OpLog '系统设置' (T '页面文件改到其他盘') "$drive\pagefile.sys" (T 'C 盘不再放页面文件，大小由系统自动管理，重启后生效')
        return ''
    } catch {
        $msg = $_.Exception.Message
        # 改了一半失败时，恢复成系统自动管理，免得重启后没有页面文件
        try { Set-CimInstance -InputObject (Get-CimInstance Win32_ComputerSystem) -Property @{ AutomaticManagedPagefile = $true } -ErrorAction Stop } catch {}
        OpLog '系统设置' (T '修改页面文件失败，已恢复系统默认') $drive $msg; return $msg
    }
}
function Get-HiberInfo {
    $f = "$env:SystemDrive\hiberfil.sys"
    $i = Get-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue
    $type = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Power' -ErrorAction SilentlyContinue).HiberFileType
    return @{ Exists = [bool]$i; Bytes = $(if ($i) { [double]$i.Length } else { [double]0 }); Reduced = ($type -eq 1) }
}
function Set-Hiber([string]$mode) {
    $pc = "$sys32\powercfg.exe"
    switch ($mode) {
        'off'     { & $pc /h off | Out-Null; OpLog '系统设置' (T '关闭休眠') 'hiberfil.sys' (T '没有「休眠」和「快速启动」了，睡眠不受影响') }
        'reduced' { & $pc /h on | Out-Null; & $pc /h /type reduced | Out-Null; OpLog '系统设置' (T '休眠文件改为精简') 'hiberfil.sys' (T '只保留快速启动，不能手动休眠') }
        'full'    { & $pc /h on | Out-Null; & $pc /h /type full | Out-Null; OpLog '系统设置' (T '恢复完整休眠') 'hiberfil.sys' '' }
    }
}

# ============================================================
# 每周自动清理：只做「安全清理」组里默认要删的普通缓存，不搬家、不清空回收站、不停服务
# ============================================================
# ---------- 启动项 ----------
# 和任务管理器「启动」页一样的来源：注册表 Run 项（当前用户、所有用户、32 位）和两个「启动」文件夹。
# 开关状态记在 Explorer\StartupApproved 里（第一个字节偶数 = 启用，奇数 = 禁用），禁用只是改这个记录，随时能恢复，不删任何东西
function Get-StartupSources {
    @(
        @{ Src = 'HKCU'; Key = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run';              Approved = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run' }
        @{ Src = 'HKLM'; Key = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run';              Approved = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run' }
        @{ Src = 'HKLM32'; Key = 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run'; Approved = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run32' }
        @{ Src = 'UserFolder'; Dir = [Environment]::GetFolderPath('Startup');       Approved = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\StartupFolder' }
        @{ Src = 'CommonFolder'; Dir = [Environment]::GetFolderPath('CommonStartup'); Approved = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\StartupFolder' }
    )
}
function Test-StartupEnabled([string]$approved, [string]$name) {
    try { $v = (Get-ItemProperty -LiteralPath $approved -Name $name -ErrorAction Stop).$name; if ($v -is [byte[]] -and $v.Length -gt 0) { return (($v[0] % 2) -eq 0) } } catch {}
    return $true
}
function Get-StartupItems {
    $out = @()
    foreach ($s in (Get-StartupSources)) {
        if ($s.Key) {
            $p = Get-ItemProperty -LiteralPath $s.Key -ErrorAction SilentlyContinue
            if (-not $p) { continue }
            foreach ($prop in $p.PSObject.Properties) {
                if ($prop.Name -like 'PS*') { continue }
                $cmd = [string]$prop.Value; if (-not $cmd) { continue }
                $out += @{ Name = $prop.Name; Cmd = $cmd; Src = $s.Src; Approved = $s.Approved; Val = $prop.Name; Enabled = (Test-StartupEnabled $s.Approved $prop.Name) }
            }
        } elseif ($s.Dir -and (Test-Path -LiteralPath $s.Dir)) {
            foreach ($f in @(Get-ChildItem -LiteralPath $s.Dir -File -Force -ErrorAction SilentlyContinue)) {
                if ($f.Name -ieq 'desktop.ini') { continue }
                $out += @{ Name = [IO.Path]::GetFileNameWithoutExtension($f.Name); Cmd = $f.FullName; Src = $s.Src; Approved = $s.Approved; Val = $f.Name; Enabled = (Test-StartupEnabled $s.Approved $f.Name) }
            }
        }
    }
    return $out
}
function Set-StartupEnabled([string]$approved, [string]$name, [bool]$on) {
    if (-not (Test-Path -LiteralPath $approved)) { New-Item -Path $approved -Force | Out-Null }
    $b = New-Object byte[] 12
    if ($on) { $b[0] = 2 } else { $b[0] = 3; [Array]::Copy([BitConverter]::GetBytes([DateTime]::Now.ToFileTime()), 0, $b, 4, 8) }
    Set-ItemProperty -LiteralPath $approved -Name $name -Value $b -Type Binary -ErrorAction Stop
}
# 从启动命令里取出程序路径（给看发行商和图标用）
function Get-CommandExe([string]$cmd) {
    $cmd = $cmd.Trim()
    if (-not $cmd) { return '' }
    if ($cmd.StartsWith('"')) { $e = $cmd.IndexOf('"', 1); if ($e -gt 0) { return [Environment]::ExpandEnvironmentVariables($cmd.Substring(1, $e - 1)) } }
    $m = [regex]::Match($cmd, '(?i)^(.+?\.(exe|cmd|bat|lnk|vbs))(\s|$)')
    if ($m.Success) { return [Environment]::ExpandEnvironmentVariables($m.Groups[1].Value) }
    return [Environment]::ExpandEnvironmentVariables($cmd.Split(' ')[0])
}
function Get-FileCompany([string]$path) {
    try { if ($path -and (Test-Path -LiteralPath $path)) { return [string][Diagnostics.FileVersionInfo]::GetVersionInfo($path).CompanyName } } catch {}
    return ''
}
# ---------- 计划任务：只列第三方的（\Microsoft\ 下面的是系统自己的，不动）----------
function Get-UserTasks {
    $out = @()
    $all = @()
    try { $all = @(Get-ScheduledTask -ErrorAction Stop) } catch { return @() }
    foreach ($t in $all) {
        if ($t.TaskPath -like '\Microsoft\*') { continue }
        $cmd = ''
        foreach ($a in @($t.Actions)) { if ($a.PSObject.Properties['Execute'] -and $a.Execute) { $cmd = ([string]$a.Execute + ' ' + [string]$a.Arguments).Trim(); break } }
        $out += @{ Name = [string]$t.TaskName; Path = [string]$t.TaskPath; State = [string]$t.State; Author = [string]$t.Author; Desc = [string]$t.Description; Cmd = $cmd; Ours = ([string]$t.TaskPath -eq '\CleanC\') }
    }
    return $out
}
# ---------- 资源管理器右键菜单扩展（shellex）：只列第三方的，禁用是写进 Shell Extensions\Blocked，新开的窗口就不再加载它 ----------
$script:shellexBlocked = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Shell Extensions\Blocked'
function Get-ContextMenuItems {
    $blocked = @{}
    foreach ($k in @($script:shellexBlocked, 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Shell Extensions\Blocked')) {
        $p = Get-ItemProperty -LiteralPath $k -ErrorAction SilentlyContinue
        if ($p) { foreach ($prop in $p.PSObject.Properties) { if ($prop.Name -like '{*}') { $blocked[$prop.Name.ToUpperInvariant()] = $true } } }
    }
    $where = [ordered]@{ '*' = (T '文件'); 'AllFilesystemObjects' = (T '文件和文件夹'); 'Directory' = (T '文件夹'); 'Folder' = (T '文件夹'); 'Directory\Background' = (T '文件夹空白处'); 'Drive' = (T '磁盘') }
    $items = [ordered]@{}
    $sysClsid = @{}   # 已经知道是系统自带的（不列），同一个在别的位置再出现时不用再查
    # 直接用 .NET 读注册表（PowerShell 的注册表驱动器每次要好几毫秒，几百个键加起来要好几秒）；读的位置和以前一样
    $rv = { param($root, [string]$path) $kk = $null; try { $kk = $root.OpenSubKey($path); if ($kk) { return [string]$kk.GetValue('') } } catch {} finally { if ($kk) { $kk.Close() } }; return '' }
    $has = { param($root, [string]$path) $kk = $null; try { $kk = $root.OpenSubKey($path); return [bool]$kk } catch { return $false } finally { if ($kk) { $kk.Close() } } }
    $hklm = [Microsoft.Win32.Registry]::LocalMachine; $hkcu = [Microsoft.Win32.Registry]::CurrentUser
    foreach ($hv in @(@($hklm, 'SOFTWARE\Classes'), @($hkcu, 'Software\Classes'))) {
        foreach ($w in $where.Keys) {
            $base = $null; $names = @()
            try { $base = $hv[0].OpenSubKey($hv[1] + '\' + $w + '\shellex\ContextMenuHandlers'); if ($base) { $names = @($base.GetSubKeyNames()) } } catch {} finally { if ($base) { $base.Close() } }
            foreach ($kn in $names) {
                $clsid = & $rv $hv[0] ($hv[1] + '\' + $w + '\shellex\ContextMenuHandlers\' + $kn)
                if (-not $clsid) { $clsid = $kn }
                $clsid = $clsid.Trim()
                if ($clsid -notmatch '^\{[0-9A-Fa-f-]{36}\}$') { continue }
                $u = $clsid.ToUpperInvariant()
                if ($sysClsid.ContainsKey($u)) { continue }
                if (-not $items.Contains($u)) {
                    $name = ''; $dll = ''
                    foreach ($c in @(@($hklm, "SOFTWARE\Classes\CLSID\$clsid"), @($hkcu, "Software\Classes\CLSID\$clsid"), @($hklm, "SOFTWARE\Classes\WOW6432Node\CLSID\$clsid"))) {
                        if (-not (& $has $c[0] $c[1])) { continue }
                        if (-not $name) { $name = & $rv $c[0] $c[1] }
                        if (-not $dll) { $dll = & $rv $c[0] ($c[1] + '\InprocServer32') }
                    }
                    if ($dll) { $dll = [Environment]::ExpandEnvironmentVariables($dll).Trim('"') }
                    # 系统自带的（dll 在 Windows 文件夹里）不列
                    if (-not $dll -or $dll.StartsWith($env:SystemRoot, [StringComparison]::OrdinalIgnoreCase)) { $sysClsid[$u] = $true; continue }
                    if (-not $name) { $name = $kn }
                    $items[$u] = @{ Clsid = $clsid; Name = $name; Dll = $dll; Company = (Get-FileCompany $dll); Keys = @($kn); Where = @($where[$w]); Enabled = -not $blocked.ContainsKey($u) }
                } else {
                    if ($items[$u].Where -notcontains $where[$w]) { $items[$u].Where += $where[$w] }
                    if ($items[$u].Keys -notcontains $kn) { $items[$u].Keys += $kn }
                }
            }
        }
    }
    return @($items.Values)
}
function Set-ContextMenuEnabled([string]$clsid, [bool]$on) {
    foreach ($k in @($script:shellexBlocked, 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Shell Extensions\Blocked')) {
        if ($on) { Remove-ItemProperty -LiteralPath $k -Name $clsid -ErrorAction SilentlyContinue }
    }
    if (-not $on) {
        if (-not (Test-Path -LiteralPath $script:shellexBlocked)) { New-Item -Path $script:shellexBlocked -Force | Out-Null }
        New-ItemProperty -LiteralPath $script:shellexBlocked -Name $clsid -Value '' -PropertyType String -Force -ErrorAction Stop | Out-Null
    }
}
# ---------- winget：有哪些软件有新版本。只在用户点的时候运行，只读不改 ----------
function Get-WingetExe {
    $c = Get-Command winget.exe -ErrorAction SilentlyContinue
    if ($c) { return [string]$c.Source }
    $p = Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\winget.exe'
    if (Test-Path -LiteralPath $p) { return $p }
    return ''
}
function Get-WingetUpgrades {
    $exe = Get-WingetExe
    if (-not $exe) { return @{ Err = 'nowinget'; Items = @() } }
    $txt = ''
    try {
        $psi = New-Object Diagnostics.ProcessStartInfo
        $psi.FileName = $exe; $psi.Arguments = 'upgrade --include-unknown --accept-source-agreements --disable-interactivity'
        $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
        $psi.StandardOutputEncoding = [Text.Encoding]::UTF8
        $p = [Diagnostics.Process]::Start($psi)
        $txt = $p.StandardOutput.ReadToEnd()
        if (-not $p.WaitForExit(180000)) { try { $p.Kill() } catch {}; return @{ Err = 'timeout'; Items = @() } }
    } catch { return @{ Err = $_.Exception.Message; Items = @() } }
    return @{ Err = ''; Items = @(ConvertFrom-WingetTable $txt); Raw = (($txt -split "`r?`n") | Select-Object -First 60) -join "`n" }
}
# winget 打出来的表格：名称 ID 版本 可用 源。从右往左取后四列，剩下的是名称（名称里可以有空格）；被 … 截断的 ID 不要
function ConvertFrom-WingetTable([string]$txt) {
    $lines = @($txt -split "`r?`n" | ForEach-Object { ($_ -replace '[\x00-\x08\x0B-\x1F]', '').TrimEnd() })
    $items = @(); $inTable = $false
    foreach ($l in $lines) {
        if ($l -match '^-{8,}\s*$') { $inTable = $true; continue }
        if (-not $inTable) { continue }
        if (-not $l.Trim()) { $inTable = $false; continue }
        if ($l -match '^\d+\s') { $inTable = $false; continue }   # 「N 个升级可用」这一行
        $tok = @($l.Trim() -split '\s+')
        if ($tok.Count -lt 5) { continue }
        $n = $tok.Count
        $src = $tok[$n - 1]; $avail = $tok[$n - 2]; $ver = $tok[$n - 3]; $id = $tok[$n - 4]
        $name = ($tok[0..($n - 5)] -join ' ')
        if ($src -notin @('winget', 'msstore')) { continue }
        $items += @{ Name = $name; Id = $(if ($id -like '*…*') { '' } else { $id }); Version = $ver; Available = $avail; Source = $src }
    }
    return $items
}

# 定期自动清理只碰这些：安全清理组里的普通缓存目录（不含清后要重建、默认不清、自定义、整个文件夹删掉的、要停服务的、操作类的）
function Select-AutoCleanItems($catalog) {
    $out = @()
    foreach ($it in $catalog) {
        if ($it.Kind -ne 'cache' -or $it.Def -ne (T '删除') -or $it.Act -or $it.Svc -or $it.Whole -or $it.Custom -or $it.Careful -or $it.Confirm -or $it.Tier -ne 'safe') { continue }
        $out += $it
    }
    return $out
}
function Invoke-AutoClean {
    $f0 = [double](FreeC); $done = @()
    foreach ($it in (Select-AutoCleanItems (Get-Catalog))) {
        $b = Measure-Item $it
        if ($b -le 0) { continue }
        $res = @{}
        Invoke-Delete $it $res -Auto
        $done += ((T "{0}：{1}") -f $it.N, (GB $res.Freed))
    }
    return @{ Freed = [math]::Max([double]0, [double]((FreeC) - $f0)); Items = $done }
}

# ---------- 自检：在这台电脑上核对快速扫描 ----------
# 只读 C 盘；按变更日志更新的那一项，在本工具自己的文件夹里建几个文件、改一改、再删掉。结果写成英文文本给开发者看
function Invoke-SelfTest([string]$Version) {
    $L = New-Object System.Collections.Generic.List[string]
    $res = @{ Pass = 0; Fail = 0; Warn = 0 }
    $add = { param([string]$kind, [string]$msg) $L.Add(("[{0}] {1}" -f $kind, $msg)); if ($res.ContainsKey($kind.Substring(0,1).ToUpper() + $kind.Substring(1).ToLower())) { $res[$kind.Substring(0,1).ToUpper() + $kind.Substring(1).ToLower()]++ } }
    $all = [Diagnostics.Stopwatch]::StartNew()
    $sd = "$env:SystemDrive\"
    $n = [DirStat]::ThreadsFor($env:SystemDrive)
    $di = $null; try { $di = New-Object System.IO.DriveInfo $sd } catch {}
    $L.Add(("ClearC self-test {0}  {1:yyyy-MM-dd HH:mm:ss}" -f $Version, (Get-Date)))
    $L.Add(("Windows {0}, {1}-bit, PowerShell {2}, CLR {3}, culture {4}" -f [Environment]::OSVersion.Version, $(if ([Environment]::Is64BitOperatingSystem) { 64 } else { 32 }), $PSVersionTable.PSVersion, [Environment]::Version, [Globalization.CultureInfo]::CurrentUICulture.Name))
    if ($di) { $L.Add(("{0} {1}, {2:N1} GB total, {3:N1} GB free, threads {4}" -f $sd, $di.DriveFormat, ($di.TotalSize / 1GB), ($di.AvailableFreeSpace / 1GB), $n)) }
    $L.Add('')
    # 1. 批量读目录和 FindFirstFileEx 一样吗
    $step = 0; $steps = 4
    $step++; SetP @{ Steps = $steps; Step = $step; StepName = (T '核对批量读目录'); SubKind = 'action'; SubStart = (Get-Date); Detail = '' }
    foreach ($d in @($env:SystemRoot, "$env:SystemRoot\System32", $env:ProgramFiles, $env:LOCALAPPDATA)) {     # 不看个人文件夹：结果要发给开发者
        if (-not $d -or -not (Test-Path -LiteralPath $d)) { continue }
        $r = [DirReader]::Compare($d)
        & $add $(if ($r -match 'differ 0\b' -and $r -notmatch 'fell back') { 'pass' } elseif ($r -match '^batch \d') { 'fail' } else { 'warn' }) ("listing {0}: {1}" -f $d, $r)
    }
    if (Stopping) { return @{ Lines = $L; Res = $res; Stopped = $true } }
    # 2. 读文件表
    $step++; SetP @{ Steps = $steps; Step = $step; StepName = (T '读取 C 盘的文件表'); SubKind = 'mft'; SubStart = (Get-Date); Detail = '' }
    $tree = $null
    if ([DiskMap]::MftOff) { & $add 'warn' 'direct file table reading is turned off in settings; file table checks skipped' }
    else {
        try { $tree = [DiskMap]::GetTree($sd, $n, $false, $true) } catch { & $add 'fail' ("file table: exception {0}" -f $_.Exception.Message) }
        if ($tree) {
            & $add 'pass' ("file table: method {0}, {1:N0} ms, {2:N0} files, {3:N0} folders, {4:N1} GB, unread records {5}" -f [DiskMap]::LastMethod, [DiskMap]::LastMs, $tree.Files, [DiskMap]::DirsSeen, ($tree.Size / 1GB), [DiskMap]::LastFailed)
            if ($tree.HasDisk) { $L.Add(("       each file once {0:N1} GB, on disk {1:N1} GB, with hard links {2:N1} GB, file table itself {3:N2} GB, used on the drive {4:N1} GB" -f ($tree.UniqueSize / 1GB), ($tree.UniqueDisk / 1GB), ($tree.Linked / 1GB), ($tree.MftBytes / 1GB), $(if ($di) { ($di.TotalSize - $di.TotalFreeSpace) / 1GB } else { 0 }))) }
        }
        elseif (-not (Stopping)) { & $add 'fail' ("file table not used: {0}" -f [DiskMap]::LastNote) }
    }
    if (Stopping) { return @{ Lines = $L; Res = $res; Stopped = $true } }
    # 3. 和逐个文件夹扫描比
    $step++; SetP @{ Steps = $steps; Step = $step; StepName = (T '和逐个文件夹扫描对比'); SubKind = 'action'; SubStart = (Get-Date); Detail = '' }
    if ($tree) {
        foreach ($p in @("$env:SystemRoot\System32", $env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:ProgramData, $env:LOCALAPPDATA)) {
            if (Stopping) { break }
            if (-not $p -or -not (Test-Path -LiteralPath $p -PathType Container) -or (IsLink $p)) { continue }
            SetP @{ Detail = $p }
            $node = [DiskMap]::Find($tree, $p)
            $ws = [Diagnostics.Stopwatch]::StartNew(); $w = [DiskMap]::Scan($p, $n); $wms = $ws.ElapsedMilliseconds
            if (-not $node) { & $add 'fail' ("{0}: not found in the file table" -f $p); continue }
            $den = [DiskMap]::CountDenied($w)
            $df = [long]$node.Files - [long]$w.Files; $db = [long]$node.Size - [long]$w.Size
            $okF = [math]::Abs($df) -le [math]::Max(10, [long]$w.Files / 200); $okB = [math]::Abs($db) -le [math]::Max(64MB, [long]$w.Size / 100)
            $kind = if ($okF -and $okB) { 'pass' } elseif ($den -gt 0 -and $df -ge 0 -and $db -ge 0) { 'warn' } else { 'fail' }
            & $add $kind ("{0}: file table {1:N0} files {2:N0} bytes; walk {3:N0} files {4:N0} bytes in {5:N0} ms; walk could not open {6} folders" -f $p, $node.Files, $node.Size, $w.Files, $w.Size, $wms, $den)
            if ($kind -ne 'pass') { foreach ($x in [DiskMap]::Diff($node, $w, 8)) { $L.Add('       ' + $x) } }
        }
    }
    $L.Add(("listing mode in use: {0} (1 batch, 2 FindFirstFileEx, 0 not decided yet)" -f [DirReader]::Mode))
    if (Stopping) { return @{ Lines = $L; Res = $res; Stopped = $true } }
    # 4. 按变更日志更新：建、改、删几个文件，看看每次都对
    $step++; SetP @{ Steps = $steps; Step = $step; StepName = (T '试一下按变更日志更新'); SubKind = 'action'; SubStart = (Get-Date); Detail = '' }
    $own = Join-Path $env:LOCALAPPDATA 'CleanC'
    try { New-Item -ItemType Directory -Force -Path $own | Out-Null } catch {}
    # 上次没做完留下的测试文件夹（本工具自己建的）先清掉：只认本工具起的名字，链接一律不碰
    if (-not (IsLink $own) -and -not (Get-LinkedAncestor $own)) {
        foreach ($old in @(Get-ChildItem -LiteralPath $own -Directory -Force -ErrorAction SilentlyContinue)) {
            if ($old.Name -notmatch '^selftest-[0-9a-f]{8}$' -or ($old.Attributes -band [IO.FileAttributes]::ReparsePoint)) { continue }
            try { [IO.Directory]::Delete($old.FullName, $true) } catch {}
        }
    }
    if ($tree -and ((IsLink $env:LOCALAPPDATA) -or (IsLink $own) -or (Get-LinkedAncestor $own) -or -not $own.StartsWith($sd, [StringComparison]::OrdinalIgnoreCase))) {
        & $add 'warn' 'journal test skipped: the app folder is a link or not on the system drive'
    } elseif ($tree) {
        $base = Join-Path $own ('selftest-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
        $fs = $null
        $check = {
            param([string]$label, [scriptblock]$expect, [bool]$soft)
            if (Stopping) { return }
            $s2 = [Diagnostics.Stopwatch]::StartNew()
            $t = $null; try { $t = [DiskMap]::GetTree($sd, $n, $false, $true) } catch {}
            $m = [string][DiskMap]::LastMethod; $ms = $s2.ElapsedMilliseconds
            $why = if ($t) { & $expect $t } else { 'no tree: ' + [DiskMap]::LastNote }
            if (Stopping) { return }
            $kind = if ($why) { $(if ($soft) { 'warn' } else { 'fail' }) } elseif ($m -ne 'mft-usn') { 'warn' } else { 'pass' }
            & $add $kind ("journal {0}: method {1}, {2:N0} ms, changed {3}, unread {4}{5}" -f $label, $m, $ms, [DiskMap]::LastChanged, [DiskMap]::LastFailed, $(if ($why) { '; ' + $why } elseif ($m -ne 'mft-usn') { '; expected an incremental update' } else { '' }))
        }
        try {
            New-Item -ItemType Directory -Path (Join-Path $base 'sub') -Force | Out-Null
            $b1 = New-Object byte[] 25000; $b2 = New-Object byte[] 10000
            foreach ($i in 1..40) { [IO.File]::WriteAllBytes((Join-Path $base "f$i.bin"), $b1) }
            foreach ($i in 1..10) { [IO.File]::WriteAllBytes((Join-Path $base "sub\g$i.bin"), $b2) }
            & $check 'create' { param($t) $x = [DiskMap]::Find($t, $base); if (-not $x) { 'test folder missing' } elseif ($x.Files -ne 50 -or $x.Size -ne 1100000) { "test folder {0} files {1} bytes, expected 50 / 1100000" -f $x.Files, $x.Size } } $false
            Rename-Item -LiteralPath (Join-Path $base 'sub') -NewName 'sub2'
            foreach ($i in 1..20) { Remove-Item -LiteralPath (Join-Path $base "f$i.bin") -Force }
            $fa = [IO.File]::Open((Join-Path $base 'f21.bin'), [IO.FileMode]::Append, [IO.FileAccess]::Write); $fa.Write($b2, 0, 5000); $fa.Close()
            & $check 'rename, delete, grow' { param($t) $x = [DiskMap]::Find($t, $base); if (-not $x) { 'test folder missing' } elseif ([DiskMap]::Find($t, (Join-Path $base 'sub'))) { 'old folder name still there' } elseif (-not [DiskMap]::Find($t, (Join-Path $base 'sub2'))) { 'renamed folder missing' } elseif ($x.OwnFiles -ne 20 -or $x.Own -ne 505000) { "test folder own {0} files {1} bytes, expected 20 / 505000" -f $x.OwnFiles, $x.Own } } $false
            $fs = [IO.File]::Open((Join-Path $base 'f22.bin'), [IO.FileMode]::Append, [IO.FileAccess]::Write, [IO.FileShare]::ReadWrite); $fs.Write($b1, 0, 25000); $fs.Flush()
            & $check 'file still open' { param($t) $x = [DiskMap]::Find($t, $base); if ($x -and $x.Own -ne 530000) { "own bytes {0} while the file is open, 530000 after writing (sizes of open files may lag)" -f $x.Own } } $true
            $fs.Write($b1, 0, 25000); $fs.Close(); $fs = $null
            & $check 'file closed' { param($t) $x = [DiskMap]::Find($t, $base); if (-not $x) { 'test folder missing' } elseif ($x.Own -ne 555000) { "own bytes {0}, expected 555000" -f $x.Own } } $false
            # 实际占用：稀疏文件、NTFS 压缩、系统压缩（WOF）和硬链接，和 Windows 自己报的实际占用（GetCompressedFileSize）比
            $dd = Join-Path $base 'disk'; New-Item -ItemType Directory -Path $dd -Force | Out-Null
            $mb = [Text.Encoding]::ASCII.GetBytes(('abcdefghijklmnop' * 65536))
            foreach ($nm in 'plain.bin', 'ntfs.bin', 'wof.bin') { [IO.File]::WriteAllBytes((Join-Path $dd $nm), $mb) }
            $wl = New-Object System.Collections.Generic.List[string]
            try { New-Item -ItemType HardLink -Path (Join-Path $dd 'plain-link.bin') -Target (Join-Path $dd 'plain.bin') -ErrorAction Stop | Out-Null } catch { $wl.Add('hard link: ' + $_.Exception.Message) }
            $sp = Join-Path $dd 'sparse.bin'
            [IO.File]::WriteAllBytes($sp, (New-Object byte[] 0))
            & "$env:SystemRoot\System32\fsutil.exe" sparse setflag $sp 2>&1 | Out-Null
            $fsp = [IO.File]::Open($sp, [IO.FileMode]::Open, [IO.FileAccess]::Write); $fsp.SetLength(64MB); $fsp.Position = 1MB; $fsp.Write($mb, 0, 65536); $fsp.Close()
            & "$env:SystemRoot\System32\compact.exe" /c /q (Join-Path $dd 'ntfs.bin') 2>&1 | Out-Null
            & "$env:SystemRoot\System32\compact.exe" /c /q /exe:xpress4k (Join-Path $dd 'wof.bin') 2>&1 | Out-Null
            $want = [long]0
            foreach ($f in @(Get-ChildItem -LiteralPath $dd -File -Force)) { $o = [FsTools]::OnDisk($f.FullName); $want += $o; $wl.Add(('{0} {1:N0}/{2:N0}' -f $f.Name, $o, $f.Length)) }
            & $check 'size on disk' { param($t) $x = [DiskMap]::Find($t, $dd); if (-not $x) { 'test folder missing' } elseif ([math]::Abs([long]$x.OwnDisk - $want) -gt 5 * 65536 -or [long]$x.OwnShared -ne 2097152) { "on disk {0:N0} (Windows says {1:N0}), with hard links {2:N0} (expected 2,097,152); {3}" -f $x.OwnDisk, $want, $x.OwnShared, ($wl -join ', ') } } $true
            [IO.Directory]::Delete($base, $true)
            & $check 'remove' { param($t) if ([DiskMap]::Find($t, $base)) { 'test folder still there after removing it' } } $false
        } catch { & $add 'fail' ("journal test error: {0}" -f $_.Exception.Message) }
        finally {
            if ($fs) { try { $fs.Close() } catch {} }
            if (Test-Path -LiteralPath $base) { try { [IO.Directory]::Delete($base, $true) } catch {} }
        }
    }
    $L.Add('')
    $L.Add(("summary: {0} pass, {1} warn, {2} fail, {3:N1} s" -f $res.Pass, $res.Warn, $res.Fail, ($all.ElapsedMilliseconds / 1000)))
    return @{ Lines = $L; Res = $res; Stopped = [bool](Stopping) }
}

function Get-Hogs {
    $roots = @('C:\ProgramData','C:\Program Files','C:\Program Files (x86)',"$env:USERPROFILE","$env:LOCALAPPDATA","$env:APPDATA")
    $rows = foreach ($r in $roots) {
        foreach ($d in (Get-ChildItem -LiteralPath $r -Directory -Force -ErrorAction SilentlyContinue)) {
            if ($d.Name -in @('AppData','Local','Roaming','LocalLow')) { continue }
            if (IsLink $d.FullName) { continue }
            $b = DirBytes $d.FullName
            if ($b -ge 500MB) { [pscustomobject]@{ B = $b; P = $d.FullName } }
        }
    }
    $rows | Sort-Object B -Descending | Select-Object -First 25
}
