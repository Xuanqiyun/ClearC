# 界面文字翻译：中文是原文；英文界面时查表，查不到就原样显示中文。后台任务通过 $sync.L10n 拿到同一张表
function T([string]$s) {
    $d = $script:L10n
    if ($null -eq $d -and $sync) { $d = $sync.L10n }
    if ($null -ne $d) { $v = $null; if ($d.TryGetValue($s, [ref]$v)) { return $v } }
    return $s
}
$ErrorActionPreference = 'SilentlyContinue'
function Log($m) { if ($sync -and $sync.Log) { $sync.Log.Enqueue($m) } else { Write-Host $m } }
# 向界面报告进度（界面每 0.3 秒读一次）
function SetP([hashtable]$h) { if ($sync -and $sync.P) { foreach ($k in $h.Keys) { $sync.P[$k] = $h[$k] } } }
$sys32 = "$env:SystemRoot\System32"
function GB($b) { "{0:N2} GB" -f ([double]$b / 1GB) }
function FreeC { (Get-PSDrive C).Free }
function DirBytes($p) { [double][DirStat]::Measure([string]$p) }
# 向界面报告某一行的状态：kind = wait / run / ok / warn / fail / skip
function SetStatus($idx, [string]$text, [string]$kind) { if ($sync -and $sync.Status) { $sync.Status[$idx] = @($text, $kind); $sync.StatusVer = [int]$sync.StatusVer + 1 } }

# ---------- 中途取消 ----------
# 用户点了「取消」后，后台只在安全的地方检查这个标记、停下来；返回 $true 时顺便记下「确实有没做完的」。
# 换链接、删备份这类停在一半会出问题的步骤，执行期间把 CanCancel 设成 $false（界面上的取消按钮变灰），做完才停。
function Stopping { if ($sync -and $sync.Cancel) { $sync.WasCancelled = $true; return $true }; return $false }
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

# $tree：Get-SysTree 读出的 C 盘文件夹树，有的话文件夹大小直接从树上查（只用于显示和估算）
function Get-Size([string[]]$paths, [string]$filter, $tree = $null) {
    $sum = [double]0
    foreach ($p in $paths) {
        foreach ($it in (Get-Item -Path $p -Force -ErrorAction SilentlyContinue)) {
            if ($it.PSIsContainer) {
                if (IsLink $it.FullName) { continue }
                if ($filter) {
                    $s = (Get-ChildItem -LiteralPath $it.FullName -Filter $filter -File -Force -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum
                    if ($s) { $sum += $s }
                } else { $sum += (Est-Bytes $it.FullName $tree) }
            } else { $sum += $it.Length }
        }
    }
    return $sum
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
# 估计一个文件夹的大小：树上有就直接查，查不到（不在 C 盘、路径里有链接、短文件名等）再逐个统计
function Est-Bytes([string]$p, $tree) {
    if ($tree) {
        try { $n = [DiskMap]::Find($tree, $p); if ($n -and -not $n.IsLink) { return [double]$n.Size } } catch {}
    }
    return DirBytes $p
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

# 删一个文件夹。是链接（junction / 符号链接）就只拆链接本身，绝不进去删链接指向的数据
function Remove-OneDir($d) {
    if ([bool]($d.Attributes -band [IO.FileAttributes]::ReparsePoint)) { & "$sys32\cmd.exe" /c rmdir "$($d.FullName)" 2>$null | Out-Null; return }
    # rd 比 Remove-Item 快很多；rd /s 遇到里面的链接也只拆链接，不会跟进去
    & "$sys32\cmd.exe" /c rd /s /q "\\?\$($d.FullName)" 2>$null | Out-Null
}
function Remove-Contents([string[]]$paths, [string]$filter, [bool]$wholeDir) {
    foreach ($p in $paths) {
        if (Stopping) { return }
        foreach ($it in (Get-Item -Path $p -Force -ErrorAction SilentlyContinue)) {
            if (Stopping) { return }
            if (Test-Personal $it.FullName) { Log ((T "  跳过（在个人文件夹里，不删）：{0}") -f $($it.FullName)); OpLog '删除' (T '跳过：在个人文件夹里，不删') $it.FullName ''; continue }
            if ($it.PSIsContainer) {
                if ($wholeDir) { Remove-OneDir $it }
                else {
                    $f = if ($filter) { $filter } else { '*' }
                    foreach ($c in @(Get-ChildItem -LiteralPath $it.FullName -Filter $f -Force -ErrorAction SilentlyContinue)) {
                        if (Stopping) { return }
                        if (Test-Personal $c.FullName) { continue }
                        if ($c.PSIsContainer) { Remove-OneDir $c } else { Remove-Item -LiteralPath $c.FullName -Force -ErrorAction SilentlyContinue }
                    }
                }
            } else { Remove-Item -LiteralPath $it.FullName -Force -ErrorAction SilentlyContinue }
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

# Kind: cache = 缓存类(删除/跳过)   action = 操作类(执行/跳过)   move = 只能搬(搬到其他盘/跳过)   flex = 可搬可删
function Get-Catalog {
    $docs = [Environment]::GetFolderPath('MyDocuments')
    $desk = [Environment]::GetFolderPath('Desktop')
    $down = (Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders' -EA SilentlyContinue).'{374DE290-123F-4565-9164-39C4925E467B}'
    if ($down) { $down = [Environment]::ExpandEnvironmentVariables($down) } else { $down = "$env:USERPROFILE\Downloads" }
    $chatG  = '聊天软件的聊天记录（搬到其他盘：聊天记录和文件原样保留，原位置留链接，软件照常使用）'
    $otherG = '其他可搬的文件夹（数据原样保留，原位置留链接，软件照常使用）'
    $list = @(
        # ---- 安全清理：缓存 / 临时文件 / 日志，删了程序自动重建 ----
        @{ G='安全清理（缓存、临时文件、日志，删了程序会自动重建）'; Kind='cache'; Def=(T '删除'); N=(T '用户临时文件');        Paths=@($env:TEMP); Note=(T '各软件运行时的临时文件，关掉软件就没用了') }
        @{ G='安全清理（缓存、临时文件、日志，删了程序会自动重建）'; Kind='cache'; Def=(T '删除'); N=(T '系统临时文件');        Paths=@('C:\Windows\Temp'); Note=(T '系统和安装程序的临时文件') }
        @{ G='安全清理（缓存、临时文件、日志，删了程序会自动重建）'; Kind='cache'; Def=(T '删除'); N=(T 'Windows 更新下载缓存'); Paths=@('C:\Windows\SoftwareDistribution\Download'); Svc=@('wuauserv','bits'); Note=(T '已装完的更新安装包，下次更新会重新下载需要的部分') }
        @{ G='安全清理（缓存、临时文件、日志，删了程序会自动重建）'; Kind='cache'; Def=(T '删除'); N=(T '系统升级残留目录');    Paths=@('C:\$WINDOWS.~BT','C:\$WINDOWS.~WS','C:\$GetCurrent'); Whole=$true; Note=(T '大版本升级留下的临时目录') }
        @{ G='安全清理（缓存、临时文件、日志，删了程序会自动重建）'; Kind='cache'; Def=(T '删除'); N=(T '崩溃转储与错误报告');  Paths=@('C:\Windows\Minidump','C:\Windows\MEMORY.DMP','C:\ProgramData\Microsoft\Windows\WER',"$env:LOCALAPPDATA\CrashDumps"); Note=(T '蓝屏和程序崩溃时留下的调试文件，只对微软工程师有用') }
        @{ G='安全清理（缓存、临时文件、日志，删了程序会自动重建）'; Kind='cache'; Def=(T '删除'); N=(T '系统组件日志');        Paths=@('C:\Windows\Logs\CBS'); Filter='*.log'; Note=(T 'Windows 更新的安装日志') }
        @{ G='安全清理（缓存、临时文件、日志，删了程序会自动重建）'; Kind='cache'; Def=(T '删除'); N=(T '缩略图缓存');          Paths=@("$env:LOCALAPPDATA\Microsoft\Windows\Explorer"); Filter='thumbcache_*.db'; Note=(T '文件夹里图片的小预览图，打开文件夹时会重新生成') }
        @{ G='安全清理（缓存、临时文件、日志，删了程序会自动重建）'; Kind='cache'; Def=(T '删除'); N=(T 'Chrome 浏览器缓存');   Paths=@("$env:LOCALAPPDATA\Google\Chrome\User Data\*\Cache","$env:LOCALAPPDATA\Google\Chrome\User Data\*\Code Cache","$env:LOCALAPPDATA\Google\Chrome\User Data\*\GPUCache"); Note=(T '网页缓存。请先关闭浏览器。不影响密码、书签、历史记录') }
        @{ G='安全清理（缓存、临时文件、日志，删了程序会自动重建）'; Kind='cache'; Def=(T '删除'); N=(T 'Edge 浏览器缓存');     Paths=@("$env:LOCALAPPDATA\Microsoft\Edge\User Data\*\Cache","$env:LOCALAPPDATA\Microsoft\Edge\User Data\*\Code Cache","$env:LOCALAPPDATA\Microsoft\Edge\User Data\*\GPUCache"); Note=(T '网页缓存。请先关闭浏览器。不影响密码、书签、历史记录') }
        @{ G='安全清理（缓存、临时文件、日志，删了程序会自动重建）'; Kind='cache'; Def=(T '删除'); N=(T 'pip 缓存');            Paths=@("$env:LOCALAPPDATA\pip\cache"); Note=(T 'Python 装包时下载的安装包副本，再装时会重新下载') }
        @{ G='安全清理（缓存、临时文件、日志，删了程序会自动重建）'; Kind='cache'; Def=(T '删除'); N=(T 'npm 缓存');            Paths=@("$env:LOCALAPPDATA\npm-cache"); Note=(T 'Node.js 装包时的下载缓存') }
        @{ G='安全清理（缓存、临时文件、日志，删了程序会自动重建）'; Kind='cache'; Def=(T '删除'); N=(T 'Clash Verge 代理日志'); Paths=@("$env:APPDATA\io.github.clash-verge-rev.clash-verge-rev\logs","$env:APPDATA\clash-verge\logs","$env:LOCALAPPDATA\io.github.clash-verge-rev.clash-verge-rev\logs"); Note=(T '代理软件的运行日志，会无限增长。建议在它设置里把日志等级改成 warn') }
        @{ G='安全清理（缓存、临时文件、日志，删了程序会自动重建）'; Kind='cache'; Def=(T '删除'); N=(T 'Intel XTU 超频日志');   Paths=@('C:\ProgramData\Intel\Intel Extreme Tuning Utility\Logs'); Note=(T 'Intel 超频组件的日志，会无限增长') }
        @{ G='安全清理（缓存、临时文件、日志，删了程序会自动重建）'; Kind='cache'; Def=(T '删除'); N=(T 'Apple 设备系统更新包'); Paths=@('C:\ProgramData\Apple\AMPDevicesAgent\*-Temporary-Files',"$env:APPDATA\Apple Computer\iTunes\*Software Updates"); Note=(T '给 iPhone/iPad 升级时下载的固件，装完就没用了') }
        @{ G='安全清理（缓存、临时文件、日志，删了程序会自动重建）'; Kind='cache'; Def=(T '删除'); N=(T 'Dell 更新程序缓存');    Paths=@('C:\ProgramData\Dell\DTP','C:\ProgramData\Dell\SupportAssist'); Note=(T '戴尔驱动更新工具下载的安装包') }
        @{ G='安全清理（缓存、临时文件、日志，删了程序会自动重建）'; Kind='cache'; Def=(T '删除'); N=(T '罗技 Options+ 缓存');   Paths=@('C:\ProgramData\LogiOptionsPlus\cache','C:\ProgramData\LogiOptionsPlus\depots'); Note=(T '罗技驱动的更新包缓存') }
        @{ G='安全清理（缓存、临时文件、日志，删了程序会自动重建）'; Kind='cache'; Def=(T '删除'); N=(T 'NVIDIA 安装包与着色器缓存'); Paths=@('C:\ProgramData\NVIDIA Corporation\Downloader','C:\ProgramData\NVIDIA Corporation\NV_Cache',"$env:LOCALAPPDATA\NVIDIA\DXCache","$env:LOCALAPPDATA\NVIDIA\GLCache"); Note=(T '显卡驱动安装包和游戏着色器缓存，游戏首次启动会重建') }
        @{ G='安全清理（缓存、临时文件、日志，删了程序会自动重建）'; Kind='cache'; Def=(T '删除'); N=(T 'Intel 显卡着色器缓存'); Paths=@("$env:LOCALAPPDATA\Intel\ShaderCache",'C:\ProgramData\Intel\ShaderCache'); Note=(T '核显着色器缓存') }
        @{ G='安全清理（缓存、临时文件、日志，删了程序会自动重建）'; Kind='cache'; Def=(T '删除'); N=(T 'Cursor 状态库备份');    Paths=@("$env:APPDATA\Cursor\User\globalStorage\state.vscdb.backup"); Note=(T 'Cursor 编辑器状态库的备份副本，主文件保留') }
        @{ G='需确认（有代价，默认跳过，看清说明再选）'; Kind='cache'; Def=(T '跳过'); N=(T '清空回收站');            Note=(T '回收站里是你以前删掉、但还能找回的文件。清空后就永远找不回了，请先打开回收站确认里面没有要的东西')
           Size={ try { $s = ((New-Object -ComObject Shell.Application).NameSpace(0xA).Items() | Measure-Object -Property Size -Sum).Sum; if ($s) { $s } else { 0 } } catch { 0 } }
           Act ={ Clear-RecycleBin -Force -ErrorAction SilentlyContinue } }
        @{ G='安全清理（缓存、临时文件、日志，删了程序会自动重建）'; Kind='cache'; Def=(T '删除'); N=(T 'Windows 传递优化缓存'); Note=(T 'Windows 更新的点对点分发缓存')
           Size={ try { $s = (Get-DeliveryOptimizationStatus -ErrorAction Stop | Measure-Object -Property FileSize -Sum).Sum; if ($s) { $s } else { 0 } } catch { 0 } }
           Act ={ Delete-DeliveryOptimizationCache -Force -ErrorAction SilentlyContinue } }

        # ---- 需确认：有代价 ----
        @{ G='需确认（有代价，默认跳过，看清说明再选）'; Kind='cache';  Def=(T '跳过'); One=(T '删除'); N=(T 'NI 安装包缓存');     Paths=@('C:\ProgramData\National Instruments\MDF\ProductCache','C:\ProgramData\National Instruments\NI Package Manager\packages'); Note=(T 'LabVIEW 等 NI 软件的安装媒体缓存。软件本身不受影响；以后修复或重装时需重新下载') }
        @{ G='需确认（有代价，默认跳过，看清说明再选）'; Kind='cache';  Def=(T '跳过'); One=(T '删除'); N='Windows.old';        Paths=@('C:\Windows.old'); Whole=$true; Note=(T '上一版 Windows 的完整副本。删后不能回退到上一版系统（系统升级 10 天后会自动删）')
           Act ={ & "$env:SystemRoot\System32\takeown.exe" /F 'C:\Windows.old' /R /A /D Y | Out-Null; & "$env:SystemRoot\System32\icacls.exe" 'C:\Windows.old' /grant Administrators:F /T /C /Q | Out-Null; Remove-Item 'C:\Windows.old' -Recurse -Force -ErrorAction SilentlyContinue } }
        @{ G='需确认（有代价，默认跳过，看清说明再选）'; Kind='action'; Def=(T '跳过'); One=(T '执行'); N=(T '重建 Windows 搜索索引'); Note=(T '搜索索引膨胀时可重建，重建后通常只剩 1 到 2 GB。重建期间（约 1 小时）搜文件会变慢')
           Size={ $s = 0; foreach ($f in 'C:\ProgramData\Microsoft\Search\Data\Applications\Windows\Windows.edb','C:\ProgramData\Microsoft\Search\Data\Applications\Windows\Windows.db') { $i = Get-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue; if ($i) { $s += $i.Length } }; if ($s -gt 2GB) { $s } else { 0 } }
           Act ={ Stop-Service WSearch -Force -ErrorAction SilentlyContinue; Start-Sleep -Seconds 3; Remove-Item 'C:\ProgramData\Microsoft\Search\Data\Applications\Windows\Windows.edb','C:\ProgramData\Microsoft\Search\Data\Applications\Windows\Windows.db' -Force -ErrorAction SilentlyContinue; Set-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows Search' -Name SetupCompletedSuccessfully -Value 0 -ErrorAction SilentlyContinue; Start-Service WSearch -ErrorAction SilentlyContinue } }
        @{ G='需确认（有代价，默认跳过，看清说明再选）'; Kind='action'; Def=(T '跳过'); N=(T '关闭休眠 (hiberfil.sys)'); Paths=@('C:\hiberfil.sys'); Note=(T '休眠文件约等于内存大小。关闭后睡眠不受影响，只是没有「休眠」和「快速启动」')
           Act ={ & "$env:SystemRoot\System32\powercfg.exe" /h off } }
        @{ G='需确认（有代价，默认跳过，看清说明再选）'; Kind='action'; Def=(T '跳过'); One=(T '执行'); N=(T '禁用 XTU 超频日志服务'); Note=(T '外星人 Command Center 的 CPU 超频组件，会持续写几 GB 日志。不超频可禁用，AWCC 的风扇和性能档位不受影响')
           Size={ $s = Get-Service XTU3SERVICE -ErrorAction SilentlyContinue; if ($s -and $s.Status -eq 'Running') { -1 } else { 0 } }
           Act ={ Stop-Service XTU3SERVICE -Force -ErrorAction SilentlyContinue; Set-Service XTU3SERVICE -StartupType Disabled -ErrorAction SilentlyContinue } }
        @{ G='需确认（有代价，默认跳过，看清说明再选）'; Kind='action'; Def=(T '跳过'); One=(T '执行'); N=(T 'WinSxS 组件清理 (DISM)'); Note=(T '清掉系统更新替换下来的旧组件，通常能省 2 到 10 GB。耗时 10 到 20 分钟，完成后建议重启'); Last=$true
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
        @{ G=$otherG; Kind='move'; Def=(T '跳过');    N=(T '桌面');                   Paths=@($desk); NoOneDrive=$true; Note=(T '桌面上的所有文件。搬后桌面照常显示，文件实际在 D 盘') }
        @{ G=$otherG; Kind='move'; Def=(T '跳过');    N=(T '下载');                   Paths=@($down); NoOneDrive=$true; Note=(T '下载文件夹。搬后浏览器照常下载到这里，文件实际在 D 盘') }
        @{ G=$otherG; Kind='flex'; Def=(T '跳过');    N=(T '用户目录 .cache');        Paths=@("$env:USERPROFILE\.cache"); Note=(T '各类开发工具的缓存（HuggingFace 模型、uv、playwright 等）。删了会重新下载；也可搬走') }
        @{ G=$otherG; Kind='flex'; Def=(T '跳过');    N=(T 'conda 环境 (.conda)');    Paths=@("$env:USERPROFILE\.conda"); Note=(T 'conda 创建的 Python 环境。搬走后照常使用；删了要重建环境') }
        @{ G=$otherG; Kind='flex'; Def=(T '跳过');    N=(T 'pip --user 安装的包');    Paths=@("$env:APPDATA\Python"); Note=(T '用 pip install --user 装的 Python 包。有 conda 的话多半已不用，可删；不确定就搬走') }
    )
    $apps = Get-ChatApps
    $i = 0
    foreach ($it in $list) {
        $i++; $it.Idx = $i
        if ($it.Apps) {
            $k = @(); $d = @()
            foreach ($a in $it.Apps) { $k += $apps[$a].P; if ($apps[$a].K) { $k += $apps[$a].K }; $d += $apps[$a].Dirs }
            $it.Kill = @($k | Select-Object -Unique); $it.KillDirs = @($d | Select-Object -Unique)
        }
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
    return Get-Size $paths $it.Filter $tree
}

function Invoke-Delete($it, $res, [switch]$Auto) {
    $f0 = FreeC
    $kind = if ($it.Slow) { 'slow' } elseif ($it.Act) { 'action' } else { 'delete' }
    SetP @{ SubKind = $kind; SubStart = (Get-Date); FreeC0 = [double]$f0; Detail = $it.Note }
    if ($it.Svc) { $it.Svc | ForEach-Object { Stop-Service $_ -Force -ErrorAction SilentlyContinue } }
    if ($it.Act) { Set-CanCancel $false; try { & $it.Act } finally { Set-CanCancel $true } }
    else {
        Remove-Contents $it.Paths $it.Filter ([bool]$it.Whole)
        if ($res -and $sync -and $sync.WasCancelled) { $res.Cancelled = $true }
    }
    if ($it.Svc) { $it.Svc | ForEach-Object { Start-Service $_ -ErrorAction SilentlyContinue } }
    $freed = [math]::Max([double]0, [double]((FreeC) - $f0))
    if ($res) { $res.Freed = $freed }
    Log ((T "  完成  {0,-26} 释放 {1}") -f $it.N, (GB $freed))
    $cat = if ($it.Kind -eq 'action') { '系统设置' } else { '删除' }   # 日志类别保持中文原样，是日志页筛选用的键
    $what = if ($Auto) { ((T "每周自动清理：{0}") -f $($it.N)) } else { ((T "清理：{0}") -f $($it.N)) }
    OpLog $cat $what $(if ($it.Paths) { $it.Paths -join (T '；') } else { '' }) ((T "C 盘多出 ") + (GB $freed))
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
        Set-CanCancel $true
        if (-not (Test-Path -LiteralPath $src)) { continue }
        if (Stopping) { $m = (T '已取消，剩下的文件夹没有搬'); Log "  $m"; $res.Cancelled = $true; $res.Msgs += $m; break }
        if (IsLink $src) { Log ((T "  已经搬过（是链接），跳过 {0}") -f $src); $res.Skipped++; continue }
        if ($it.NoOneDrive -and $src -like '*OneDrive*') { Log ((T "  {0} 由 OneDrive 管理，不搬") -f $src); $res.Skipped++; continue }
        if ($src.Substring(0,1) -ieq $destRoot.Substring(0,1)) { Log ((T "  {0} 已在目标盘") -f $src); $res.Skipped++; continue }
        $leaf = Split-Path $src -Leaf
        $pick = Find-MoveDest $src $destRoot
        $dst = [string]$pick.Path; $reuse = [bool]$pick.Reuse
        $dstRoot = Split-Path $dst -Parent
        $pathNo = [int]$sync.P.PathNo + 1
        SetP @{ MovePhase = 'measure'; PathNo = $pathNo; MovePath = $src; MoveDest = $dst; MoveReuse = $reuse; SubKind = 'measure'; SubStart = (Get-Date); Detail = ((T "统计 {0} 的大小") -f $src) }
        $srcBytes = DirBytes $src
        $cxNone = (T "已取消：{0} 还没开始复制，原文件夹没动") -f $src
        if (Stopping) { Log "  $cxNone"; $res.Cancelled = $true; $res.Msgs += $cxNone; break }
        if ([long][DirStat]::Reparse -gt 0) {
            # 里面的链接（或系统压缩过的文件）复制和核对时都会被跳过，搬完删原目录时就会丢。宁可不搬
            $m = (T "{0} 里有 {1} 个特殊项目（链接，或用 Windows 压缩功能压过的文件，比如 {2}）。复制时可能漏掉它们，为了不丢东西，这个文件夹不搬，原目录未动") -f $src, [DirStat]::Reparse, [DirStat]::ReparseSample
            Log "  $m"; OpLog '搬运' (T '搬家失败') $src $m; $res.Fail++; $res.Msgs += $m; continue
        }
        $haveBytes = [double]0
        if ($reuse) {
            SetP @{ SubStart = (Get-Date); Detail = ((T "统计上次留下的副本 {0}") -f $dst) }
            $haveBytes = DirBytes $dst; $haveFiles = [long][DirStat]::Files
            if (Stopping) { Log "  $cxNone"; $res.Cancelled = $true; $res.Msgs += $cxNone; break }
            SetP @{ Detail = ((T "核对 {0} 是不是这个文件夹的旧副本") -f $dst) }
            $extra = Get-ExtraCount $dst $src
            if ($extra -lt 0 -or ($extra -gt [math]::Max(20, $haveFiles * 0.05))) {
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
        # 搬软件时：目标文件夹先设成和 C 盘上一样的访问权限，再连同每个文件的权限一起复制
        if ($it.Sddl) { [void](Set-DirAccess $dst ([string]$it.Sddl)) }
        $cp = if ($it.Sddl) { '/COPY:DATS' } else { '/COPY:DAT' }
        Save-MoveMap $dstRoot $src $dst
        $base = [math]::Min([double]$haveBytes, [double]$srcBytes)
        SetP @{ MovePhase = 'copy'; SubKind = 'copy'; SubTotal = [double]$srcBytes; SubBase = $base; SubDone = $base; SubStart = (Get-Date); DestDrive = $destDrive; DestFree0 = $destFree0; Detail = "$src  ->  $dst" }
        # 每复制完一个文件，robocopy 输出一行「大小<Tab>文件名」，累加起来就是已复制的字节数。
        # 用上次的副本时用 /MIR：副本和原目录完全一致（原目录里已删掉的旧文件，副本里也删掉）
        $mode = if ($reuse) { '/MIR' } else { '/E' }
        $more = @(); if ($reuse -and $it.Sddl) { $more += '/SECFIX' }   # 用上次的副本时，连没变的文件的权限也改对
        $rc = Invoke-Tool "$sys32\robocopy.exe" (@($src, $dst, $mode, $cp) + $more + @('/DCOPY:DAT', '/R:2', '/W:2', '/NDL', '/NJH', '/NJS', '/NP', '/BYTES', '/XJ')) '' $base
        $cxHalf = (T "已取消：{0} 原文件夹没动。已复制的部分留在 {1}，下次再搬这一项会接着复制；不需要的话，可以在「搬家管理」里删掉这份副本") -f $src, $dst
        $cxCopied = (T "已取消：{0} 已经复制到 {1}，但还没换成链接，原文件夹没动。下次再搬只补有变化的文件") -f $src, $dst
        if ($rc.Cancelled) { Log "  $cxHalf"; OpLog '搬运' (T '搬家已取消') $src $cxHalf; $res.Cancelled = $true; $res.Msgs += $cxHalf; break }
        if ($rc.Code -ge 8 -or $rc.Code -lt 0) { $m = ((T "复制失败（robocopy 代码 {0}，可能是空间不够或有文件被占用），原目录未动") -f $rc.Code); Log "  $m"; OpLog '搬运' (T '搬家失败') $src $m; $res.Fail++; $res.Msgs += $m; continue }
        SetP @{ MovePhase = 'verify'; SubKind = 'measure'; SubStart = (Get-Date); Detail = (T '复制完成，核对两边大小') }
        # 软件都已关掉，原目录不会再变：两边重新数一遍，文件个数一个不能少、总大小几乎一致，才继续（之后才会删 C 盘上的原目录）
        $srcBytes = DirBytes $src; $srcFiles = [long][DirStat]::Files
        $dstBytes = DirBytes $dst; $dstFiles = [long][DirStat]::Files
        if (Stopping) { Log "  $cxCopied"; OpLog '搬运' (T '搬家已取消') $src $cxCopied; $res.Cancelled = $true; $res.Msgs += $cxCopied; break }
        if ($dstFiles -lt $srcFiles -or [math]::Abs($dstBytes - $srcBytes) -gt [math]::Max([double]16MB, [double]$srcBytes * 0.001)) {
            $m = (T "核对不一致（源 {0:N0} 个文件 {1}，目标 {2:N0} 个文件 {3}），原目录未动") -f $srcFiles, (GB $srcBytes), $dstFiles, (GB $dstBytes)
            Log "  $m"; OpLog '搬运' (T '搬家失败') $src $m; $res.Fail++; $res.Msgs += $m; continue
        }
        Log ((T "  核对通过：{0:N0} 个文件，{1}") -f $srcFiles, (GB $srcBytes))

        if (Stopping) { Log "  $cxCopied"; OpLog '搬运' (T '搬家已取消') $src $cxCopied; $res.Cancelled = $true; $res.Msgs += $cxCopied; break }
        SetP @{ MovePhase = 'link'; SubKind = 'action'; SubStart = (Get-Date); Detail = ((T "把 {0} 换成指向 {1} 的链接") -f $src, $dst) }
        $bak = "$src.moved_backup"
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
        # 从这里到删掉 C 盘上的备份，停在一半会留下半截状态：不能取消，做完这一项才停
        Set-CanCancel $false
        & "$sys32\cmd.exe" /c mklink /J "$src" "$dst" | Out-Null
        if (-not (IsLink $src)) {
            try { [IO.Directory]::Move($bak, $src) } catch {}
            $m = ((T "建链接失败，已改回原目录，副本在 {0}") -f $dst); Log "  $m"; OpLog '搬运' (T '搬家失败') $src $m; $res.Fail++; $res.Msgs += $m; continue
        }
        # 核对之后到改名之间可能有程序又写了文件，补复制一遍新文件；补不过去就保留 C 盘上的旧文件夹
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
        & "$sys32\cmd.exe" /c rd /s /q "\\?\$bak" 2>$null | Out-Null
        if (Test-Path -LiteralPath $bak) { Remove-Item -LiteralPath $bak -Recurse -Force -ErrorAction SilentlyContinue }
        $res.Done++; $res.Moved += $srcBytes; $res.Dest += $dst
        SetP @{ MovePhase = 'done' }
        OpLog '搬运' (T '搬到其他盘') "$src → $dst" ((T "{0:N0} 个文件，{1}，两边已核对一致") -f $srcFiles, (GB $srcBytes))
        $script:movedTargets = $null
        if (Test-Path -LiteralPath $bak) { $m = ((T "已搬好，但 C 盘上的备份没删干净（有文件被占用），过后可手动删除：{0}") -f $bak); Log "  $m"; OpLog '删除' (T '搬家后 C 盘旧文件夹没删干净') $bak ''; $res.Msgs += $m }
        else { Log ((T "  完成  {0}  ->  {1}") -f $src, $dst); OpLog '删除' (T '搬家后删除 C 盘上的原文件夹') $bak (((T "数据已在 {0}") -f $dst)) }
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

function Get-Setting([string]$k, [string]$def = '') {
    try {
        if (Test-Path -LiteralPath $script:settingsFile) {
            foreach ($l in [IO.File]::ReadAllLines($script:settingsFile, [Text.Encoding]::UTF8)) {
                $i = $l.IndexOf('=')
                if ($i -gt 0 -and $l.Substring(0, $i).Trim() -eq $k) { return $l.Substring($i + 1).Trim() }
            }
        }
    } catch {}
    return $def
}
function Set-Setting([string]$k, [string]$v) {
    try {
        New-Item -ItemType Directory -Path $script:appDir -Force | Out-Null
        $lines = New-Object System.Collections.Generic.List[string]
        if (Test-Path -LiteralPath $script:settingsFile) {
            foreach ($l in [IO.File]::ReadAllLines($script:settingsFile, [Text.Encoding]::UTF8)) { if ($l -and -not $l.StartsWith("$k=")) { $lines.Add($l) } }
        }
        $lines.Add("$k=$v")
        [IO.File]::WriteAllLines($script:settingsFile, $lines.ToArray(), (New-Object Text.UTF8Encoding $true))
    } catch {}
}

# 操作日志：每月一个 txt，一行一条：时间 <Tab> 类别 <Tab> 操作 <Tab> 对象 <Tab> 详情
# 类别：删除 / 搬运 / 合并 / 压缩 / 卸载 / 系统设置 / 日志
function OpLog([string]$cat, [string]$what, [string]$target = '', [string]$detail = '') {
    $now = Get-Date
    $f = Join-Path $script:opLogDir ("操作日志-{0:yyyy-MM}.txt" -f $now)
    $c = { param($x) (([string]$x) -replace "[`t`r`n]+", ' ').Trim() }
    $line = "{0:yyyy-MM-dd HH:mm:ss}`t{1}`t{2}`t{3}`t{4}" -f $now, (& $c $cat), (& $c $what), (& $c $target), (& $c $detail)
    for ($try = 0; $try -lt 5; $try++) {
        try {
            if (-not (Test-Path -LiteralPath $script:opLogDir)) { New-Item -ItemType Directory -Path $script:opLogDir -Force | Out-Null }
            $enc = New-Object System.Text.UTF8Encoding $true
            if (-not (Test-Path -LiteralPath $f)) {
                [IO.File]::AppendAllText($f, "# 腾挪 ClearC 操作日志（每行：时间、类别、操作、对象、详情，用 Tab 分隔）`r`n", $enc)
            }
            [IO.File]::AppendAllText($f, $line + "`r`n", $enc)
            return
        } catch { Start-Sleep -Milliseconds 120 }
    }
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
function Get-DeleteBlock([string]$path, [switch]$Leftover) {
    if (-not $path) { return (T '路径为空') }
    $full = $path
    try { $full = [IO.Path]::GetFullPath($path) } catch {}
    $full = $full.TrimEnd('\')
    if ($full.Length -le 2) { return (T '整块磁盘不能删') }
    if (Test-Personal $full) { return (T 'C 盘个人文件夹（桌面、文档、下载、图片、视频、音乐等）里的东西不删') }
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
    $pc = "$sd\ProgramData\Package Cache"
    if ($full -ieq $pc -or $full.StartsWith("$pc\", [StringComparison]::OrdinalIgnoreCase)) { return (T '软件的安装包缓存，删了以后这些软件可能没法修复、升级或卸载') }
    if ($full -ieq $script:appDir -or $full.StartsWith("$($script:appDir)\", [StringComparison]::OrdinalIgnoreCase)) { return (T '本工具自己的设置和日志') }
    if ((Split-Path $full -Leaf) -ieq 'CDriveMoved' -or $full -match '(?i)\\CDriveMoved(\\|$)') { return (T '这是搬家后的数据（CDriveMoved 文件夹），C 盘上的链接指向这里。要处理请到「搬家管理」') }
    foreach ($t in (Get-MovedTargets)) {
        if ($full -ieq $t -or $full.StartsWith("$t\", [StringComparison]::OrdinalIgnoreCase) -or $t.StartsWith("$full\", [StringComparison]::OrdinalIgnoreCase)) {
            return (T '这里是搬家后的数据，C 盘上的链接指向这里。要处理请到「搬家管理」')
        }
    }
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
    if ($srcLink -and $dstThere) { return @{ State = 'ok'; Text = ((T "正常：数据在 {0} 盘，C 盘这里只留了一个指向它的链接，不占 C 盘空间，软件照常使用") -f $dst.Substring(0, 1).ToUpper()); Brush = '#248A3D' } }
    if ($srcLink -and -not $dstThere) {
        $fix = ''
        $leaf = Split-Path $dst -Leaf
        foreach ($root in (All-MoveRoots)) { $c = Join-Path $root $leaf; if (Test-Path -LiteralPath $c) { $fix = $c; break } }
        $t = (T '链接断了：目标文件夹不在了（硬盘拔了、或者盘符变了？）')
        if ($fix) { $t += ((T "。在 {0} 找到一份同名的，可以改指向它") -f $fix) }
        return @{ State = 'broken'; Text = $t; Brush = '#D70015'; Fix = $fix }
    }
    if ($srcThere -and -not $srcLink -and $dstThere) { return @{ State = 'pending'; Text = (T '没搬完：C 盘原文件夹还在，目标盘上也有一份。可以在「可以搬的」里再搬一次，只补有变化的文件；也可以删掉这份副本，删之前会先核对，副本里有不少 C 盘上没有的文件就不删'); Brush = '#B25000' } }
    if (-not $srcThere -and $dstThere) { return @{ State = 'nosrc'; Text = (T 'C 盘上的链接不见了（软件卸载了，或者链接被删了）。软件还在用的话，可以重建链接；软件已经卸载的话，打开看看，确认不要了再自己删掉这份数据'); Brush = '#D70015'; Fix = $dst } }
    return @{ State = 'gone'; Text = (T '已经不在了'); Brush = '#86868B' }
}

# 搬回 C 盘：复制回来、核对、拆掉链接、换回真文件夹，最后删掉目标盘上的那份
# 搬回时取消：删掉复制回 C 盘的那一半（数据仍在目标盘上，C 盘上的链接没动）
function Undo-MoveBackCopy([string]$tmp, [bool]$fresh, [string]$dst, [string]$src, $res) {
    $res.Cancelled = $true
    if ($fresh -and (Test-Path -LiteralPath $tmp) -and -not (IsLink $tmp)) { & "$sys32\cmd.exe" /c rd /s /q "\\?\$tmp" 2>$null | Out-Null }
    if (Test-Path -LiteralPath $tmp) { $res.Msg = (T "已取消，什么都没改，数据仍在 {0}。复制回 C 盘的那一半在 {1}，确认没用后可以手动删除") -f $dst, $tmp }
    else { $res.Msg = (T "已取消，什么都没改，数据仍在 {0}。复制回 C 盘的那一半已删掉") -f $dst }
    OpLog '搬运' (T '搬回 C 盘已取消') $src $res.Msg
}
function Invoke-MoveBack($rec, $res) {
    $res.Ok = $false; $res.Msg = ''
    $src = [string]$rec.Src; $dst = [string]$rec.Dst
    if (-not (IsLink $src) -or -not (Test-Path -LiteralPath $dst)) { $res.Msg = (T '这一项现在不是正常的搬家状态，没法搬回'); return }
    try { [Environment]::CurrentDirectory = $env:SystemRoot; Set-Location -LiteralPath $env:SystemRoot } catch {}
    $it = @{ Kill = @(); KillDirs = @() }
    if ($rec.Idx) { foreach ($c in (Get-Catalog)) { if ($c.Idx -eq $rec.Idx) { $it = $c } } }
    if ($rec.Restrict) { $it.Restrict = $true; $it.Allowed = @($rec.Allowed) }
    SetP @{ MoveItem = $true; MoveBack = $true; HasKill = [bool]$it.Kill; MovePhase = 'kill'; PathNo = 0; PathCount = 1; MovePath = $dst; MoveDest = $src; MoveReuse = $false }
    [void](Close-Holders $it $src); [void](Close-Holders $it $dst)
    SetP @{ MovePhase = 'measure'; SubKind = 'measure'; SubStart = (Get-Date); Detail = ((T "统计 {0} 的大小") -f $dst) }
    $bytes = DirBytes $dst; $files = [long][DirStat]::Files
    if (Stopping) { $res.Cancelled = $true; $res.Msg = (T '已取消，什么都没改'); return }
    $free = [double](FreeC)
    if ($free -lt $bytes + 2GB) { $res.Msg = (T "C 盘只剩 {0}，放不下 {1}（还要留 2 GB 余量）") -f (GB $free), (GB $bytes); OpLog '搬运' (T '搬回 C 盘失败') $src $res.Msg; return }
    $tmp = "$src.cleanc_back"
    if (Test-Path -LiteralPath $tmp) { try { [IO.Directory]::Move($tmp, ("{0}_{1:yyyyMMddHHmmss}" -f $tmp, (Get-Date))) } catch {} }
    $tmpFresh = -not (Test-Path -LiteralPath $tmp)   # 是这次新建的，里面只有这次复制回来的东西
    New-Item -ItemType Directory -Path $tmp -Force | Out-Null
    SetP @{ MovePhase = 'copy'; SubKind = 'copy'; SubTotal = [double]$bytes; SubBase = [double]0; SubDone = [double]0; SubStart = (Get-Date); DestDrive = $env:SystemDrive; DestFree0 = $free; Detail = "$dst  ->  $src" }
    $rc = Invoke-Tool "$sys32\robocopy.exe" @($dst, $tmp, '/E', '/COPY:DAT', '/DCOPY:DAT', '/R:2', '/W:2', '/NDL', '/NJH', '/NJS', '/NP', '/BYTES', '/XJ') '' 0
    if ($rc.Cancelled) { Undo-MoveBackCopy $tmp $tmpFresh $dst $src $res; return }
    if ($rc.Code -ge 8 -or $rc.Code -lt 0) { $res.Msg = ((T "复制回 C 盘失败（robocopy 代码 {0}），什么都没改，复制了一半的临时文件夹在 {1}") -f $rc.Code, $tmp); OpLog '搬运' (T '搬回 C 盘失败') $src $res.Msg; return }
    SetP @{ MovePhase = 'verify'; SubKind = 'measure'; SubStart = (Get-Date); Detail = (T '核对两边是否一致') }
    $b2 = DirBytes $tmp; $f2 = [long][DirStat]::Files
    if (Stopping) { Undo-MoveBackCopy $tmp $tmpFresh $dst $src $res; return }
    if ($f2 -lt $files -or [math]::Abs($b2 - $bytes) -gt [math]::Max([double]16MB, [double]$bytes * 0.001)) {
        $res.Msg = (T "核对不一致（目标盘 {0:N0} 个文件，复制回来 {1:N0} 个），什么都没改") -f $files, $f2; OpLog '搬运' (T '搬回 C 盘失败') $src $res.Msg; return
    }
    Set-CanCancel $false   # 拆链接、换回文件夹、删目标盘上的那份：不能停在一半
    SetP @{ MovePhase = 'link'; SubKind = 'action'; SubStart = (Get-Date); Detail = (T '拆掉链接，换回真正的文件夹') }
    & "$sys32\cmd.exe" /c rmdir "$src" 2>$null | Out-Null
    if (Test-Path -LiteralPath $src) { $res.Msg = ((T "C 盘上的链接拆不掉（可能被占用），什么都没改；复制回来的数据在 {0}") -f $tmp); OpLog '搬运' (T '搬回 C 盘失败') $src $res.Msg; return }
    try { [IO.Directory]::Move($tmp, $src) }
    catch {
        & "$sys32\cmd.exe" /c mklink /J "$src" "$dst" | Out-Null
        $res.Msg = ((T "换回文件夹失败，已恢复原来的链接；复制回来的数据在 {0}") -f $tmp); OpLog '搬运' (T '搬回 C 盘失败') $src $res.Msg; return
    }
    OpLog '搬运' (T '搬回 C 盘') "$dst → $src" ((T "{0:N0} 个文件，{1}，已核对") -f $files, (GB $bytes))
    & "$sys32\robocopy.exe" "$dst" "$src" /E /XO /COPY:DAT /R:1 /W:1 /XJ /NFL /NDL /NJH /NJS /NP | Out-Null
    if ($LASTEXITCODE -ge 8) {
        $res.Ok = $true; $res.Bytes = $bytes; $res.Msg = ((T "已搬回 C 盘，但有几个最后写入的文件没补复制过来，目标盘上的那份先保留：{0}") -f $dst)
        OpLog '搬运' (T '搬回后保留目标盘副本') $dst $res.Msg
        foreach ($root in (All-MoveRoots)) { Remove-MoveMapEntry $root $src }
        $script:movedTargets = $null; SetP @{ MovePhase = 'done' }; return
    }
    SetP @{ MovePhase = 'cleanup'; SubKind = 'action'; SubStart = (Get-Date); Detail = (T '删除目标盘上的那份') }
    & "$sys32\cmd.exe" /c rd /s /q "\\?\$dst" 2>$null | Out-Null
    if (Test-Path -LiteralPath $dst) { $res.Msg = ((T "已搬回，但目标盘上的旧副本没删干净：{0}") -f $dst) }
    else { OpLog '删除' (T '搬回后删除目标盘上的旧副本') $dst (GB $bytes) }
    foreach ($root in (All-MoveRoots)) { Remove-MoveMapEntry $root $src }
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
    SetP @{ Detail = (T '核对副本里有没有 C 盘上没有的文件') }
    $b = DirBytes $dst; $nf = [long][DirStat]::Files
    if (Stopping) { $res.Msg = (T '已取消，副本没删'); return }
    $extra = Get-ExtraCount $dst $src
    if ($extra -lt 0 -or ($extra -gt [math]::Max(20, $nf * 0.05))) {
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
    while ($p -and $p.TrimEnd('\').Length -gt 2) {
        if (IsLink $p) { return $p.TrimEnd('\') }
        $p = Split-Path $p -Parent
    }
    return ''
}
# 从这个文件夹（或这几个文件夹）里运行的程序
# 所有系统服务和驱动的程序路径（判断软件能不能搬时用）
function Get-ServicePaths {
    $out = New-Object System.Collections.ArrayList
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
            try { $m = Get-AppxPackageManifest -Package $a.PackageFullName -ErrorAction Stop; $x = [string]$m.Package.Properties.DisplayName; if ($x -and $x -notlike 'ms-resource:*') { $dn = $x } } catch {}
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
        if (Test-Path -LiteralPath $vh) { [void]$out.Add(@{ Name = ((T "WSL：{0}") -f $($p.DistributionName)); Path = $vh; Kind = 'wsl'; Compact = $true; Move = $false
            Note = ((T "Linux 子系统的虚拟磁盘。在 Linux 里删了文件，这个文件不会自动变小，压缩一下就能把空间还给 Windows。要换位置可以用命令 wsl --manage {0} --move D:\WSL") -f $($p.DistributionName)) }) }
    }
    foreach ($vh in @("$env:LOCALAPPDATA\Docker\wsl\data\ext4.vhdx", "$env:LOCALAPPDATA\Docker\wsl\disk\docker_data.vhdx", "$env:LOCALAPPDATA\Docker\wsl\main\ext4.vhdx", "$env:LOCALAPPDATA\Docker\wsl\distro\ext4.vhdx")) {
        if (Test-Path -LiteralPath $vh) { [void]$out.Add(@{ Name = (T 'Docker Desktop 数据盘'); Path = $vh; Kind = 'docker'; Compact = $true; Move = $false
            Note = (T 'Docker 的镜像和容器都在里面。先在 Docker 里删掉不用的镜像（docker system prune），再压缩。换位置在 Docker Desktop 设置 → Resources → Disk image location') }) }
    }
    foreach ($vh in @(Get-ChildItem "$env:SystemDrive\ProgramData\Microsoft\Windows\Virtual Hard Disks" -Filter '*.vhd*' -File -ErrorAction SilentlyContinue)) {
        [void]$out.Add(@{ Name = ((T "Hyper-V 虚拟磁盘：{0}") -f $($vh.Name)); Path = $vh.FullName; Kind = 'hyperv'; Compact = $true; Move = $false; Note = (T '压缩前要先关掉用它的虚拟机') })
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
function Invoke-CompactVdisk([string]$path, [string]$kind, $res) {
    $res.Ok = $false
    $before = [double](Get-Item -LiteralPath $path -Force).Length
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
function Invoke-AutoClean {
    $f0 = [double](FreeC); $done = @()
    foreach ($it in (Get-Catalog)) {
        if ($it.Kind -ne 'cache' -or $it.Def -ne (T '删除') -or $it.Act -or $it.Svc -or $it.Whole -or -not ([string]$it.G).StartsWith('安全清理')) { continue }
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
        if ($tree) { & $add 'pass' ("file table: method {0}, {1:N0} ms, {2:N0} files, {3:N0} folders, {4:N1} GB, unread records {5}" -f [DiskMap]::LastMethod, [DiskMap]::LastMs, $tree.Files, [DiskMap]::DirsSeen, ($tree.Size / 1GB), [DiskMap]::LastFailed) }
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
