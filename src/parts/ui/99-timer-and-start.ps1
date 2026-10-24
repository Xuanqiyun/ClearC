# ------------------------------------------------------------
# 定时器：把后台日志搬到界面、刷新进度、检测后台结束
# ------------------------------------------------------------
$timer = New-Object System.Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromMilliseconds(300)
$timer.Add_Tick({
    while ($sync.Log.Count -gt 0) { UI-Log $sync.Log.Dequeue() }
    Update-CleanSummary
    if ($Error.Count -gt 0 -and -not [object]::ReferenceEquals($Error[0], $script:lastErrObj)) {
        $script:lastErrObj = $Error[0]
        $em = [string]$Error[0]
        if ($em -ne $script:lastErrMsg) { $script:lastErrMsg = $em; Write-LogFile ((T "[内部] ") + $em + "  @ " + ([string]$Error[0].InvocationInfo.PositionMessage).Split([char]10)[0]) }
    }

    if ([DupRow]::Dirty -and -not $script:worker) { [DupRow]::Dirty = $false; Update-DupSummary }
    if ([AppRow]::PickDirty) { Update-PickBar }
    if ($script:opHideAt -and (Get-Date) -ge $script:opHideAt) { $script:opHideAt = $null; if (-not $script:op -and -not $script:worker) { $ctl.OpPanel.Visibility = 'Collapsed' } }
    Watch-Drives
    if ([CandRow]::Dirty) { [CandRow]::Dirty = $false; Update-CandSel }
    if ($sync.Status -and $script:candRows -and $sync.StatusVer -ne $script:candSeen) {
        $script:candSeen = $sync.StatusVer
        foreach ($r in $script:candRows) { $v = $sync.Status[$r.Key]; if ($v) { $r.Status = $v[0]; $r.StatusBrush = $script:statusColor[[string]$v[1]] } }
    }

    if ($script:worker -and $script:op) { Update-Op }
    if ($script:odWanted -and -not $script:worker -and $ctl.PageSave.Visibility -eq 'Visible') { $script:odWanted = $false; Start-OneDriveInfo }
    if ($sync.Status -and $script:rows -and $sync.StatusVer -ne $script:statusSeen) {
        $script:statusSeen = $sync.StatusVer
        foreach ($r in $script:rows) {
            $v = $sync.Status[$r.Idx]
            if ($v) { $r.Status = $v[0]; $r.StatusBrush = $script:statusColor[[string]$v[1]] }
        }
    }

    if ($script:worker -and $script:worker.Handle.IsCompleted) {
        $w = $script:worker; $script:worker = $null
        Exit-BusyLock; [void][FsTools]::KeepAwake($false)
        $script:movedTargets = $null
        try { $w.PS.EndInvoke($w.Handle) | Out-Null } catch { UI-Log ((T "后台出错：{0}") -f $($_.Exception.Message)) }
        foreach ($er in @($w.PS.Streams.Error | Select-Object -First 5)) { UI-Log ((T "后台出错：{0}") -f $er) }
        $job = Get-BgJob ([string]$sync.Mode)
        Write-WorkerErrors $w ([string]$sync.Mode)
        $w.PS.Dispose(); $w.RS.Dispose()
        [DirStat]::Cancel = $false
        if ($sync.WasCancelled) { UI-Log (T '已中途取消。') }
        # 删过、搬过东西以后，逐个扫描得到的旧树不再拿来用（读文件表的结果靠变更日志更新）
        if (-not ($job -and $job.ReadOnly)) { [DiskMap]::Invalidate() }
        # 刚搬过东西（或者搬回来了）：「搬家管理」在普通用户模式下也列出来 / 没有搬走的了就收起来
        if ($job -and $job.Moves) {
            try { $hm = @(Get-MoveRecords | Where-Object { IsLink ([string]$_.Src) }).Count -gt 0; if ($hm -ne $script:hasMoves) { $script:hasMoves = $hm; Apply-Display } } catch {}
        }

        if ($job -and $job.Done) {
            # 收尾的代码出错，也要把「正在进行」收起来，不然界面一直是忙的
            try { . $job.Done } catch {
                UI-Log ((T "后台出错：{0}") -f $_.Exception.Message)
                Write-LogFile ((T "[内部] ") + $_.Exception.Message + "  @ " + ([string]$_.InvocationInfo.PositionMessage).Split([char]10)[0])
                if ($script:op) { End-Op (T '没有完成') }
            }
        }
        $sync.Mode = $null
        UI-Status; UI-Busy $false
        if ($script:closeWhenDone) { $script:pendingDialog = $null; $script:runAfterScan = $false; $script:askRemindNow = $false; $win.Close(); return }
        if ($script:runAfterScan) {
            $script:runAfterScan = $false
            Apply-OneClick
            Invoke-RunSelected (T '一键清理')
        }
        if ($script:firstResult) { $script:firstResult = $false; Show-FirstResult }
        if ($script:runAfterApps) { $script:runAfterApps = $false; Load-Apps }
        if ($script:runAfterMoves) { $script:runAfterMoves = $false; Load-Moves }
        if ($script:runAfterCand) { $script:runAfterCand = $false; if (-not $script:worker) { Start-CandScan } }
        if ($script:candPending -and -not $script:worker -and $ctl.PageMoves.Visibility -eq 'Visible') { Start-CandScan }
        if (-not $script:uiTest) { Show-WriteTrouble }   # 刚才的操作有没有写进操作日志
        if ($script:pendingDialog) {
            # 先清掉再弹，避免对话框打开期间定时器再弹一次
            $d = $script:pendingDialog; $script:pendingDialog = $null
            if ($d.Buttons) {
                $ans = Show-Sheet -Kind $(if ($d.Kind) { $d.Kind } else { 'done' }) -Title $d.Title -Text $d.Text -Items $d.Items -Buttons $d.Buttons -Primary $d.Primary -Cancel $d.Cancel
                if ($d.Then -and $ans -eq $d.Primary) { try { & $d.Then } catch {} }
            } else { Show-Sheet -Kind $(if ($d.Kind) { $d.Kind } else { 'done' }) -Title $d.Title -Text $d.Text -Items $d.Items | Out-Null }
        }
        if ($script:askRemindNow) { $script:askRemindNow = $false; Ask-EnableRemind }
    }
})

# 有操作在进行时关窗口：不直接关（可能正停在换链接的半路上），先停在安全的地方，停好后自动关闭
$script:closeWhenDone = $false
$win.Add_Closing({
    param($s, $e)
    if (-not $script:worker) { return }
    $e.Cancel = $true
    if ($script:closeWhenDone) { return }
    $ans = Show-Sheet -Kind warn -Title (T '还有操作在进行中') -Text (T '现在直接关掉，可能留下搬了一半的文件夹。选「停下并关闭」会先停在安全的地方（正在做的这一小步会做完），然后自动关闭窗口。') -Buttons @((T '继续等待'), (T '停下并关闭')) -Primary (T '继续等待') -Cancel (T '继续等待')
    if ($ans -ne (T '停下并关闭')) { return }
    if (-not $script:worker) { $e.Cancel = $false; return }   # 对话框开着的时候已经做完了
    Set-CancelFlags
    $script:closeWhenDone = $true
    UI-Log (T '正在停下，停好后自动关闭窗口。')
})

$ctl.OvCancel.Add_Click({ Request-Cancel })
$ctl.OpCancel.Add_Click({ Request-Cancel })
$ctl.OvHide.Add_Click({ $ctl.Overlay.Visibility = 'Collapsed'; UI-Log (T '进度卡片已收起，进度见窗口底部和任务栏图标；做完会弹窗告诉你。') })
$ctl.OvClose.Add_Click({
    $ctl.Overlay.Visibility = 'Collapsed'; $script:cardShowsResult = $false
    if ($script:askRemind) { $script:askRemind = $false; Ask-EnableRemind }
})
# 第一次清理完，问一次要不要开启空间不足提醒（只问一次，选了什么都不再问）
function Ask-EnableRemind {
    $exe = [string]$env:CLEANC_SELF
    if (-not $exe -or -not (Test-Path -LiteralPath $exe) -or (Test-TempPath $exe) -or (Get-Setting 'AskedRemind' '') -eq '1' -or (Test-CleanTask $script:taskRemind)) { return }
    Set-Setting 'AskedRemind' '1'
    $ans = Show-Sheet -Title (T 'C 盘快满时提醒你？') -Text (T "开启后，每次登录电脑和每天中午，Windows 会在后台检查一次 C 盘。剩余空间低于 20 GB 时在屏幕右下角提醒你（每天最多一次），空间够就什么都不显示。`n`n不需要一直开着本工具，也不需要开机启动。以后可以在「自动提醒」页随时关掉。") -Buttons @((T '以后再说'), (T '开启提醒')) -Primary (T '开启提醒') -Cancel (T '以后再说')
    if ($ans -ne (T '开启提醒')) { return }
    $err = Enable-AutoTask $true
    if ($err) { Show-Sheet -Kind warn -Title (T '没开成') -Text $err | Out-Null; return }
    OpLog '系统设置' (T '开启空间不足提醒') $script:taskRemind ((T "任务计划：{0}") -f (Get-TaskExePath))
    Show-Sheet -Kind done -Title (T '提醒已开启') -Text (T '在「自动提醒」页可以改提醒的界限，或者关掉。') | Out-Null
}

# 窗口大小跟着屏幕走：笔记本 150% 缩放时可用高度只有 690 左右，窗口太高会把下面的进度和记录挤出屏幕
$wa = [System.Windows.SystemParameters]::WorkArea
$win.Width     = [math]::Min([double]1240, [double]$wa.Width - 24)
$win.Height    = [math]::Min([double]860,  [double]$wa.Height - 24)
$win.MinWidth  = [math]::Min([double]980,  [double]$wa.Width - 24)
$win.MinHeight = [math]::Min([double]600,  [double]$wa.Height - 24)
if ($wa.Height -lt 800) { $ctl.LogPanel.Height = 130 }
$ctl.OvPlanScroll.MaxHeight = [math]::Max([double]80, [math]::Min([double]190, [double]$wa.Height - 560))
$win.Title = ((T "腾挪 ClearC {0}") -f $script:AppVersion)
Write-LogFile ((T "腾挪 ClearC {0}") -f $script:AppVersion + $(if ($script:AppBuild) { " ($($script:AppBuild))" } else { '' }))
$ctl.AppVer.Text = ((T "版本 {0}") -f $script:AppVersion)
Write-LogFile ((T "==== 腾挪 ClearC {0} 启动；Windows {1}；屏幕可用区域 {2:N0} x {3:N0}") -f $script:AppVersion, [Environment]::OSVersion.Version, $wa.Width, $wa.Height)
if ($script:themeFail) { Write-LogFile ((T "深色界面没能打开，这次用浅色：{0}") -f $script:themeFail) }

# ---------- 空闲时先把系统健康和盘的健康读好：点「系统健康」「空间地图」时不用干等 ----------
# 打开后几秒、没有别的操作在做时在后台读（不占主工作线程，不弹进度条）；读过十分钟再打开那一页，在后台刷新一遍
$script:prefetchStep = 0
$script:prefetchTimer = New-Object System.Windows.Threading.DispatcherTimer
$script:prefetchTimer.Interval = [TimeSpan]::FromSeconds(4)
$script:prefetchTimer.Add_Tick({
    if ($script:worker) { return }
    $script:prefetchStep++
    if ($script:prefetchStep -eq 1) {
        if (-not $script:pageLoaded.health -and $ctl.NavHealth.Visibility -eq 'Visible') { $script:pageLoaded.health = $true; Load-Health; Write-LogFile (T '空闲时在后台读取系统健康') }
        return
    }
    if ($script:prefetchStep -eq 2) {
        # C 盘的文件表也先读进内存（只读）：之后清理扫描、软件管理、搬家、空间地图只按变更日志补读改过的部分，几秒钟的事变成不到一秒
        if (-not $script:uiTest -and -not $script:mftWarm) {
            $script:mftWarm = $true
            # 开发者和 IT 模式顺便问一下驱动存储里的旧版驱动包（DISM 要好几秒；同一次打开程序里驱动包没变就不用再问）
            [void](Start-BgEngine 'mftwarm' 'Init-DriveThreads; $t = [DiskMap]::GetTree($env:SystemDrive, [DirStat]::ThreadsFor($env:SystemDrive), $false, $false); $msg = if ($t) { (T "{0:N0} 个文件，用时 {1:N1} 秒") -f $t.Files, ([double][DiskMap]::LastMs / 1000) } else { [string][DiskMap]::LastNote }; if ((Get-Mode) -ge 2) { [void](Get-OldDriverPackages) }; $msg' $null {
                param($r, $err) if ($r) { Write-LogFile ((T '空闲时在后台读了 C 盘的文件表：') + $r) } })
        }
        return
    }
    $this.Stop()
    if (-not $script:pageLoaded.map -and $ctl.NavMap.Visibility -eq 'Visible') { $script:pageLoaded.map = $true; Fill-MapDrives; Start-DiskHealth }
})
# ---------- 插上、拔掉硬盘：自动刷新搬家目标、空间地图的盘、重复文件的查找位置、硬件卡片 ----------
# 每两秒看一下盘符有没有变（只看盘符列表，不碰盘本身）；变了再等两秒多（新盘要一会儿才准备好）再刷新
$script:driveSig = ([IO.Directory]::GetLogicalDrives() -join ','); $script:drivePend = $null; $script:driveTick = 0
function Watch-Drives {
    $script:driveTick++
    if ($script:driveTick % 7 -ne 0) { return }
    $sig = ''; try { $sig = ([IO.Directory]::GetLogicalDrives() -join ',') } catch { return }
    if ($sig -eq $script:driveSig) { $script:drivePend = $null; return }
    if (-not $script:drivePend) { $script:drivePend = Get-Date; return }
    if (((Get-Date) - $script:drivePend).TotalSeconds -lt 2.5) { return }
    $old = $script:driveSig; $script:driveSig = $sig; $script:drivePend = $null
    Refresh-Drives $old $sig
}
function Refresh-Drives([string]$old, [string]$new) {
    $o = @($old -split ',' | Where-Object { $_ }); $n = @($new -split ',' | Where-Object { $_ })
    $add = @($n | Where-Object { $o -notcontains $_ }); $gone = @($o | Where-Object { $n -notcontains $_ })
    if ($add.Count) { UI-Log ((T "接上了新的磁盘：{0}") -f ((@($add | ForEach-Object { $_.TrimEnd('\') })) -join ' ')) }
    if ($gone.Count) { UI-Log ((T "磁盘拔掉了：{0}") -f ((@($gone | ForEach-Object { $_.TrimEnd('\') })) -join ' ')) }
    try { Fill-DestChoices } catch {}
    if ($script:pageLoaded.map) { try { Fill-MapDrives; Start-DiskHealth } catch {} }
    # 重复文件：新接上的整块盘加进查找位置（不勾，要找自己勾上），拔掉的去掉
    foreach ($d in $add) {
        try {
            $di = New-Object System.IO.DriveInfo $d
            if ($di.DriveType -eq 'Fixed' -and $di.IsReady -and -not [FsTools]::IsSubst($di.Name)) { Add-Root $di.RootDirectory.FullName ((T "整个 {0} 盘") -f $di.Name.Substring(0, 1)) $false ((T "{0}  已用 {1}") -f $di.Name, (Fmt (Get-DriveUse $di.Name).Used)) }
        } catch {}
    }
    foreach ($d in $gone) { foreach ($rt in @($script:roots)) { if (([string]$rt.Path).TrimEnd('\') -ieq $d.TrimEnd('\')) { [void]$script:roots.Remove($rt) } } }
    try { Update-FilterSummary } catch {}
    if ($script:pageLoaded.save) { if ($ctl.PageSave.Visibility -eq 'Visible' -and -not $script:worker) { Load-Save } else { $script:pageLoaded.save = $false } }
    if ($script:pageLoaded.health) { Load-Health }
}

# ---------- 各个列表的表头排序（点列名排序，再点一下反过来；记住每个列表上次怎么排的） ----------
# 表格（GridView）：键是第几列；自己画表头的列表：键是表头按钮的 Tag
Register-ListSort 'MonList' @{ '0' = @{ Prop = 'Name' }; '1' = @{ Prop = 'Cpu'; Num = $true }; '2' = @{ Prop = 'Ws'; Num = $true }; '3' = @{ Prop = 'Rate'; Num = $true }; '4' = @{ Prop = 'Since'; Num = $true }; '5' = @{ Prop = 'Total'; Num = $true } } -defProp 'Since'
$script:sortCfg['MonList'].After = { if ($script:monShared -and $script:monShared.Rows) { Show-Monitor @($script:monShared.Rows) } }
Register-ListSort 'LogList' @{ '0' = @{ Prop = 'When'; Num = $true }; '1' = @{ Prop = 'CatText' }; '2' = @{ Prop = 'What' }; '3' = @{ Prop = 'Target' }; '4' = @{ Prop = 'Detail' } } -defProp 'When'
Register-ListSort 'MapGrow' @{ '0' = @{ Prop = 'Path' }; '1' = @{ Prop = 'BeforeBytes'; Num = $true }; '2' = @{ Prop = 'NowBytes'; Num = $true }; '3' = @{ Prop = 'Delta'; Num = $true } } -Tri
Register-ListSort 'DupList' @{ '0' = @{ Prop = 'ToDelete'; Num = $true }; '1' = @{ Prop = 'Path' }; '2' = @{ Prop = 'ModifiedTicks'; Num = $true }; '3' = @{ Prop = 'Risk' } } -pre @('GroupId') -Tri
Register-ListSort 'MapList' @{ name = @{ Prop = 'Name' }; when = @{ Prop = 'When'; Num = $true }; size = @{ Prop = 'Size'; Num = $true } } -pre @('IsSummary') -bar $ctl.MapHead -Tri
Register-ListSort 'AppsList' @{ name = @{ Prop = 'Name' }; pub = @{ Prop = 'Publisher' }; date = @{ Prop = 'Date'; Num = $true }; size = @{ Prop = 'Size'; Num = $true } } -bar $ctl.AppsHead -defProp 'Size'
Register-ListSort 'StartList' @{ name = @{ Prop = 'Name' }; status = @{ Prop = 'StatusText' } } -bar $ctl.StartHead -Tri
Register-ListSort 'CandList' @{ name = @{ Prop = 'Name' }; size = @{ Prop = 'Size'; Num = $true } } -pre @('GroupOrder') -bar $ctl.CandHead -Tri
Register-ListSort 'MovesList' @{ name = @{ Prop = 'Name' }; state = @{ Prop = 'State' }; size = @{ Prop = 'Size'; Num = $true } } -bar $ctl.MovesHead -Tri
Register-ListSort 'List' @{ name = @{ Prop = 'Name' }; size = @{ Prop = 'Bytes'; Num = $true } } -bar $ctl.CleanHead -Tri
foreach ($p in @(@('AppsList', 'AppsHead'), @('StartList', 'StartHead'), @('MovesList', 'MovesHead'), @('MapList', 'MapHead'), @('CandList', 'CandHead'))) { Register-HeadPad $ctl[$p[0]] $ctl[$p[1]] }
$script:headOf = [ordered]@{ AppsList = $ctl.AppsHead; StartList = $ctl.StartHead; CandList = $ctl.CandHead; MovesList = $ctl.MovesHeadBox; MapList = $ctl.MapHeadBox }
Update-HeadVis
# 分段选项卡：每组第一项前面不画分隔线
function Set-SegFirst($root) {
    $seg = $win.FindResource('Seg')
    $q = New-Object System.Collections.Queue; $q.Enqueue($root)
    while ($q.Count -gt 0) {
        $v = $q.Dequeue()
        if ($v -is [System.Windows.Controls.Panel]) {
            $first = $true
            foreach ($c in $v.Children) { if ($c -is [System.Windows.Controls.RadioButton] -and $c.Style -and ([object]::ReferenceEquals($c.Style, $seg) -or [object]::ReferenceEquals($c.Style.BasedOn, $seg))) { if ($first) { $c.Uid = 'first'; $first = $false } elseif ($c.Uid -eq 'first') { $c.Uid = '' } } }
        }
        foreach ($c in [System.Windows.LogicalTreeHelper]::GetChildren($v)) { if ($c -is [System.Windows.DependencyObject]) { $q.Enqueue($c) } }
    }
}
Set-SegFirst $win

$script:statusColor = @{ wait = '#6E6E73'; run = '#0066CC'; ok = '#1D7A35'; warn = '#995700'; fail = '#D70015'; skip = '#6E6E73' }
$script:pendingDialog = $null
$win.TaskbarItemInfo = New-Object System.Windows.Shell.TaskbarItemInfo
Fill-DestChoices
UI-Status
Update-FilterSummary
Add-History
try { Repair-AutoTasks } catch {}
$pruned = Prune-OpLog (Get-LogMonths)
if ($pruned -gt 0) { OpLog '日志' (T '自动删除超过保存时间的旧记录') '' ((T "{0} 条，保存时间 {1} 个月") -f $pruned, (Get-LogMonths)) }
$timer.Start()

# 重新打开本工具（换语言、换外观后）
# 重开前：记下在看的页面和清理页的扫描结果（重开后由 Restore-ResumeState 读回来）
function Save-ResumeState {
    $sizes = @{}; $sigs = @{}; $acts = @{}
    if ($script:rows -and $sync.Sizes) {
        foreach ($r in $script:rows) { $sizes[$r.Idx] = [double]$sync.Sizes[$r.Idx]; $sigs[$r.Idx] = [string]$script:rowSig[$r.Idx]; $acts[$r.Idx] = ActId ([string]$r.Action) }
    }
    Write-ResumeData (Join-Path $script:appDir 'resume.txt') ([string]$script:curPage) $sizes $sigs $acts
}
function Restore-ResumeState {
    $d = Read-ResumeData (Join-Path $script:appDir 'resume.txt') 120
    if (-not $d) { return }
    if ($d.Page -and $script:pageList.Contains($d.Page) -and $ctl[$script:pageList[$d.Page][1]].Visibility -eq 'Visible') { Show-Page $d.Page }
    if ($d.Sizes.Count -and -not $script:rows) {
        # 每一行的指纹（名字加路径）对得上才用上次的大小；对不上的（清理列表改过）不显示，重新扫描就有
        $cat = @{}; foreach ($c in $catalog) { $cat[$c.Idx] = $c }
        $sizes = @{}
        foreach ($k in $d.Sizes.Keys) { if ($cat.ContainsKey($k) -and (Get-ItemSig $cat[$k]) -eq $d.Sigs[$k]) { $sizes[$k] = $d.Sizes[$k] } }
        if ($sizes.Count) {
            $sync.Sizes = $sizes; Build-Rows $sizes
            foreach ($r in $script:rows) { $a = $d.Acts[$r.Idx]; if ($a) { $a = ActText $a }; if ($a -and @($r.Actions) -contains $a) { $r.Action = $a } }
            $script:planSig = ''; Update-CleanSummary
            UI-Log (T '重开前的扫描结果已经恢复；要最新的数字，点「扫描」')
        }
    }
}
function Restart-App {
    Save-ResumeState
    Exit-UiLock
    try {
        if ($env:CLEANC_SELF -and (Test-Path -LiteralPath $env:CLEANC_SELF)) { Start-Process -FilePath $env:CLEANC_SELF }
        elseif ($script:selfScript) { Start-Process -FilePath "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -ArgumentList ('-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}"' -f $script:selfScript) }
    } catch {}
    $win.Close()
}
# 外观：浅色 / 深色 / 跟随系统
$script:themeNames = @{ light = (T '浅色'); dark = (T '深色'); system = (T '跟随系统') }
function Get-RawBrush([string]$hex) { $b = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color][System.Windows.Media.ColorConverter]::ConvertFromString($hex)); $b.Freeze(); return $b }
# 一张小窗口：左边侧边栏（选中的一项是蓝色），右边标题和一张卡片
function New-ThemeLayer([hashtable]$p) {
    $cv = New-Object System.Windows.Controls.Canvas; $cv.Width = 112; $cv.Height = 72; $cv.Background = Get-RawBrush $p.Bg
    $add = {
        param([double]$x, [double]$y, [double]$w, [double]$h, [double]$r, [string]$c, [string]$stroke)
        $re = New-Object System.Windows.Shapes.Rectangle; $re.Width = $w; $re.Height = $h; $re.RadiusX = $r; $re.RadiusY = $r; $re.Fill = Get-RawBrush $c
        if ($stroke) { $re.Stroke = Get-RawBrush $stroke; $re.StrokeThickness = 0.8 }
        [System.Windows.Controls.Canvas]::SetLeft($re, $x); [System.Windows.Controls.Canvas]::SetTop($re, $y); [void]$cv.Children.Add($re)
    }
    & $add 0 0 27 72 0 $p.Side ''
    & $add 5 10 17 5 2.5 $p.Accent ''
    & $add 5 19 14 4 2 $p.Line ''
    & $add 5 26 16 4 2 $p.Line ''
    & $add 5 33 12 4 2 $p.Line ''
    & $add 34 9 34 5 2.5 $p.Text ''
    & $add 34 20 70 44 6 $p.Card $p.Stroke
    & $add 41 28 44 4 2 $p.Line ''
    & $add 41 36 54 4 2 $p.Line ''
    & $add 41 44 32 4 2 $p.Line ''
    & $add 41 53 22 6 3 $p.Accent ''
    return $cv
}
function New-ThemeThumb([string]$kind) {
    $light = @{ Bg = '#F5F5F7'; Side = '#E6E6EB'; Card = '#FFFFFF'; Line = '#DCDCE1'; Text = '#C7C7CC'; Accent = '#0071E3'; Stroke = '#E2E2E7' }
    $dark = @{ Bg = '#1C1C1E'; Side = '#2A2A2D'; Card = '#2E2E31'; Line = '#4A4A4E'; Text = '#5E5E63'; Accent = '#0A84FF'; Stroke = '#3A3A3D' }
    $g = New-Object System.Windows.Controls.Grid; $g.Width = 112; $g.Height = 72
    $g.Clip = New-Object System.Windows.Media.RectangleGeometry -ArgumentList (New-Object System.Windows.Rect 0, 0, 112, 72), 9.0, 9.0
    if ($kind -eq 'dark') { [void]$g.Children.Add((New-ThemeLayer $dark)) }
    else {
        [void]$g.Children.Add((New-ThemeLayer $light))
        # 跟随系统：一半浅色一半深色，斜着分开
        if ($kind -eq 'system') { $d = New-ThemeLayer $dark; $d.Clip = [System.Windows.Media.Geometry]::Parse('M68,0 L112,0 L112,72 L44,72 Z'); [void]$g.Children.Add($d) }
    }
    return $g
}
foreach ($k in 'Light', 'Dark', 'System') { $pic = $win.FindName('SetTheme' + $k + 'Pic'); if ($pic) { $pic.Child = New-ThemeThumb $k.ToLowerInvariant() } }
# 对话框里的三张缩略图：点一张选中，点「应用」才换
function New-ThemePicker([string]$cur) {
    $sp = New-Object System.Windows.Controls.StackPanel; $sp.Orientation = 'Horizontal'; $sp.HorizontalAlignment = 'Left'
    $script:themePick = $cur
    $keys = @('light', 'dark', 'system')
    foreach ($k in $keys) {
        $rb = New-Object System.Windows.Controls.RadioButton
        $rb.GroupName = 'sheettheme'; $rb.Style = $win.FindResource('ThemeCard'); $rb.Tag = $k
        if ($k -eq $keys[-1]) { $rb.Margin = New-Object System.Windows.Thickness 0 }
        $in = New-Object System.Windows.Controls.StackPanel
        $pic = New-Object System.Windows.Controls.Border; $pic.Style = $win.FindResource('ThemePic'); $pic.Child = New-ThemeThumb $k
        $lb = New-Object System.Windows.Controls.TextBlock; $lb.Style = $win.FindResource('ThemeLbl'); $lb.Text = $script:themeNames[$k]
        [void]$in.Children.Add($pic); [void]$in.Children.Add($lb); $rb.Content = $in
        if ($k -eq $cur) { $rb.IsChecked = $true }
        $rb.Add_Checked({ $script:themePick = [string]$this.Tag })
        [void]$sp.Children.Add($rb)
    }
    return $sp
}
$ctl.BtnThemeText.Text = (T "外观：{0}") -f $script:themeNames[$(if ($script:themeNames.ContainsKey($script:themePref)) { $script:themePref } else { 'light' })]
$ctl.BtnTheme.Add_Click({
    if ($script:worker) { Show-Sheet -Title (T '请等当前操作做完') -Text (T '另一个操作还在进行中。') | Out-Null; return }
    $ok = (T '应用')
    $ans = Show-Sheet -Title (T '选择外观') -Text (T '深色适合在暗的环境里用；跟随系统会照 Windows 设置里「选择应用模式」来。换了以后本工具会关闭，再自动打开。') `
        -Extra (New-ThemePicker $script:themePref) -Buttons @((T '取消'), $ok) -Primary $ok -Cancel (T '取消')
    if ($ans -ne $ok) { return }
    $to = [string]$script:themePick
    if (-not $to -or $to -eq $script:themePref) { return }
    Set-ThemePref $to
})
function Set-ThemePref([string]$to) {
    Set-Setting 'Theme' $to
    OpLog '系统设置' (T '切换外观') $to ''
    Restart-App
}
# 设置页上点了外观：问一下再换（返回 $false：没换）
function Request-Theme([string]$to) {
    if ($to -eq $script:themePref) { return $false }
    if ($script:worker) { Show-Sheet -Title (T '请等当前操作做完') -Text (T '另一个操作还在进行中。') | Out-Null; return $false }
    $ok = (T '换')
    if ((Show-Sheet -Title ((T "换成「{0}」外观？") -f $script:themeNames[$to]) -Text (T '本工具会关闭，然后用新的外观重新打开。') -Buttons @((T '取消'), $ok) -Primary $ok -Cancel (T '取消')) -ne $ok) { return $false }
    Set-ThemePref $to
    return $true
}
# 界面语言切换：存到设置里，关掉本窗口，用新语言重新打开（返回 $false：没换）
$ctl.BtnLangText.Text = if ($script:Lang -eq 'en') { '中文' } else { 'English' }
function Request-Lang {
    if ($script:worker) { Show-Sheet -Title (T '请等当前操作做完') -Text (T '另一个操作还在进行中。') | Out-Null; return $false }
    $to = if ($script:Lang -eq 'en') { 'zh' } else { 'en' }
    if ($to -eq 'en') { $t = '切换为英文界面？'; $x = "本工具会关闭，然后以英文界面重新打开。`n`nClearC will close and reopen in English."; $ok = '切换'; $no = '取消' }
    else { $t = 'Switch to Chinese?'; $x = "ClearC will close and reopen in Chinese.`n`n本工具会关闭，然后以中文界面重新打开。"; $ok = 'Switch'; $no = 'Cancel' }
    if ((Show-Sheet -Title $t -Text $x -Buttons @($no, $ok) -Primary $ok -Cancel $no) -ne $ok) { return $false }
    Set-Setting 'Lang' $to
    OpLog '系统设置' (T '切换界面语言') $to ''
    Save-ResumeState
    Exit-UiLock
    try {
        if ($env:CLEANC_SELF -and (Test-Path -LiteralPath $env:CLEANC_SELF)) { Start-Process -FilePath $env:CLEANC_SELF }
        elseif ($script:selfScript) { Start-Process -FilePath "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -ArgumentList ('-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}"' -f $script:selfScript) }
    } catch {}
    $win.Close()
    return $true
}
$ctl.BtnLang.Add_Click({ [void](Request-Lang) })
$ctl.CleanScroll.Add_ScrollChanged({ Update-CleanBar; Update-CleanMore })
$ctl.CleanMore.Add_Click({ $ctl.CleanScroll.PageDown() })
# 第一次打开时先给出安全风险提示，勾选同意后才能使用；同意过就不再弹
$script:riskFile = Join-Path $env:LOCALAPPDATA 'CleanC\risk-accepted.txt'
$win.Add_ContentRendered({
    Close-Splash
    try { $sync.Hwnd = [long](New-Object System.Windows.Interop.WindowInteropHelper $win).Handle } catch { $sync.Hwnd = [long]0 }
    if (-not $script:startLogged) {
        $script:startLogged = $true
        $shown = $script:startClock.Elapsed.TotalSeconds
        $proc = 0.0; try { $proc = ((Get-Date) - (Get-Process -Id $PID).StartTime).TotalSeconds } catch {}
        Write-LogFile ((T "启动用时 {0:N1} 秒：准备 {1:N1} 秒，加载界面 {2:N1} 秒，显示 {3:N1} 秒") -f [math]::Max($proc, $shown), $script:tPrep, ($script:tUi - $script:tPrep), ($shown - $script:tUi))
    }
    if ($script:uiTest) {
        if (-not $script:uiStarted) {
            $script:uiStarted = $true
            # 万一卡住：四分钟后自己关掉（截图时要扫两遍盘）
            $script:uiWatch = New-Object System.Windows.Threading.DispatcherTimer; $script:uiWatch.Interval = [TimeSpan]::FromMinutes(4)
            $script:uiWatch.Add_Tick({
                $script:uiWatch.Stop(); if (-not $script:uiDone) { $global:CLEANC_EXIT = 99 }
                $win.Close()
                if ($win.IsVisible) { [Environment]::Exit(99) }   # 关不掉（比如后台还在做）：直接结束这次测试
            })
            $script:uiWatch.Start()
            [void]$win.Dispatcher.BeginInvoke([Action]{ Invoke-UiTest }, [System.Windows.Threading.DispatcherPriority]::ApplicationIdle)
        }
        return
    }
    if ($script:riskShown) { return }
    $script:riskShown = $true
    $script:prefetchTimer.Start()
    if (Test-Path -LiteralPath $script:riskFile) { Restore-ResumeState; if (-not (Show-AccountMismatch)) { return }; Show-WriteTrouble -Startup; Show-HalfMoves; Show-LooseMoves; Show-BrokenMoves; return }
    $ans = Show-Sheet -Kind warn -Title (T '使用前请先阅读安全风险提示') `
        -Text (T "本工具会按你的选择删除或搬移电脑上的文件。删除的文件可能无法恢复，存在资料丢失的风险。`n`n每次删除前，请确认这些资料确实不再需要、删除不会给你带来损失；重要资料请先备份。因使用本工具造成的资料丢失或其他损失，责任由使用者自行承担，开发者不承担责任。`n`n完整说明随时可以在左侧「帮助」里查看。") `
        -Confirm (T '我已阅读并了解上述风险，同意自行承担使用本工具的后果。') -Buttons @((T '退出'), (T '同意并继续')) -Primary (T '同意并继续') -Cancel (T '退出')
    if ($ans -ne (T '同意并继续')) { $win.Close(); return }
    try {
        New-Item -ItemType Directory -Path (Split-Path $script:riskFile) -Force | Out-Null
        [IO.File]::WriteAllText($script:riskFile, ((T "{0:yyyy-MM-dd HH:mm:ss}  已同意（版本 {1}）") -f (Get-Date), $script:AppVersion), [Text.Encoding]::UTF8)
    } catch {}
    Write-LogFile (T '用户已同意安全风险提示')
    if (-not (Show-AccountMismatch)) { return }; Show-WriteTrouble -Startup; Show-HalfMoves; Show-BrokenMoves
    # 第一次打开：不用找从哪开始，直接扫一遍，扫完只给一句结论和一个主按钮
    if (-not $script:worker) { $script:firstRun = $true; Show-Page 'clean'; Do-Scan }
})
Register-BgJob 'aclfix' -Done {
    $x = $sync.AclRes
    End-Op (T '完成')
    if ($x) {
        $t = (T "{0} 个文件夹改好了，现在只有你、系统和管理员能打开。") -f $x.Ok
        if (@($x.Bad).Count) { $t += "`n" + ((T "{0} 个没改成：{1}") -f @($x.Bad).Count, (@($x.Bad) -join (T '；'))) }
        $script:pendingDialog = @{ Title = (T '权限改好了'); Kind = $(if (@($x.Bad).Count) { 'warn' } else { 'done' }); Text = $t }
    }
}
# 打开时查一下有没有上次没做完的搬家（数据都在，只是要告诉用户在哪）
# 以前的版本搬走的文件夹，其他账户也能打开：问一次要不要改成和在 C 盘时一样（一个月最多问一次）
function Show-LooseMoves {
    if ($script:worker) { return }
    $l = @(); try { $l = @(Find-LooseMoves) } catch { return }
    if ($l.Count -eq 0) { return }
    $key = '{0}|{1:yyyyMM}' -f $l.Count, (Get-Date)
    if ((Get-Setting 'LooseMovesAsked' '') -eq $key) { return }
    Set-Setting 'LooseMovesAsked' $key
    $ok = (T '改成只有我能打开')
    $ans = Show-Sheet -Kind warn -Title (T '搬走的文件夹，电脑上的其他账户也能打开') `
        -Text (T "下面这些文件夹是以前的版本搬到其他盘的。在 C 盘时只有你、系统和管理员能打开；搬过去后用的是那块盘的默认权限，这台电脑上的其他账户也能打开、修改。`n`n可以改成和在 C 盘时一样。只改权限，不动里面的文件，文件多的要等一会儿。") `
        -Items @($l | ForEach-Object { $_.Dst }) -Buttons @((T '以后再说'), $ok) -Primary $ok -Cancel (T '以后再说')
    if ($ans -ne $ok) { return }
    Use-BgJob 'aclfix'; $sync.AclRes = $null
    Start-Op (T '修正搬走的文件夹的权限') -NoCard; UI-Busy $true
    Start-Worker @'
$sync.AclRes = Repair-MovedAccess $arg.Items
'@ @{ Items = $l }
}
# 以另一个管理员账户运行（登录桌面的是普通账户，打开时输了管理员密码）：每次打开说一声，可以退出
# 返回 $false 表示用户选了退出（窗口在关）
function Show-AccountMismatch {
    $me = [Security.Principal.WindowsIdentity]::GetCurrent().Name
    $t = Get-AccountMismatch $me (Get-DesktopUser)
    if (-not $t) { return $true }
    Write-LogFile $t
    $go = T '仍然继续'
    if ((Show-Sheet -Kind warn -Title (T '本工具没有以你的账户运行') -Text $t -Buttons @((T '退出'), $go) -Primary $go -Cancel (T '退出')) -ne $go) { $win.Close(); return $false }
    return $true
}
# 本工具自己的记录写不进去（多半是 C 盘满了）：打开时、做完一件事后各查一次，说一次就不再说
$script:writeTroubleShown = $false
function Show-WriteTrouble([switch]$Startup) {
    if ($script:writeTroubleShown) { return }
    $kind = ''
    if ($sync.OpLogFail -or [int]$script:opLogFailed -gt 0) { $kind = 'log' }
    elseif ($Startup -and -not (Test-AppDirWritable $script:appDir)) { $kind = 'dir' }
    if (-not $kind) { return }
    $script:writeTroubleShown = $true
    $free = Fmt ([double](FreeC))
    $t = if ($kind -eq 'log') { (T "C 盘只剩 {0}，本工具的操作日志写不进去了：刚才删了、搬了什么，有的没有记下来。先腾出一点 C 盘空间（比如清空回收站），以后的操作才会记下来。") -f $free }
         else { (T "C 盘只剩 {0}，本工具的设置、操作日志和空间记录都写不进去：改的设置不会保存，删了、搬了什么也记不下来。先腾出一点空间再用，比如清空回收站，或者用「一键清理」。") -f $free }
    Write-LogFile $t
    Show-Sheet -Kind warn -Title (T '本工具的记录写不进去') -Text $t | Out-Null
}
# 搬走过东西的（不管什么模式）：左边列出「搬家管理」，搬走的东西在哪、链接好不好都看得到。
# 链接断了的（目标盘拔了、盘符变了）：打开时说一声，一天最多一次
$script:hasMoves = $false
function Show-BrokenMoves {
    $recs = @(); try { $recs = @(Get-MoveRecords | Where-Object { IsLink ([string]$_.Src) }) } catch { return }
    $had = $script:hasMoves
    $script:hasMoves = $recs.Count -gt 0
    if ($script:hasMoves -ne $had) { Apply-Display }
    if ($script:worker) { return }
    $bad = @($recs | Where-Object { (Get-MoveState $_).State -eq 'broken' })
    if ($bad.Count -eq 0) { return }
    $key = '{0:yyyyMMdd}|{1}' -f (Get-Date), $bad.Count
    if ((Get-Setting 'BrokenAsked' '') -eq $key) { return }
    Set-Setting 'BrokenAsked' $key
    $go = T '打开搬家管理'
    $ans = Show-Sheet -Kind warn -Title (T '有搬走的文件夹找不到了') -Text (T "下面这些文件夹搬到了其他盘，C 盘上只留了链接，但链接指向的地方现在找不到（那块盘没插着，或者盘符变了）。用到它们的软件现在打不开，聊天软件会像没有记录一样。`n`n把那块盘插上就好；盘符变了的，可以在「搬家管理」里改指向。") `
        -Items @($bad | ForEach-Object { (T "{0} → {1}") -f $_.Src, $_.Dst }) -Buttons @((T '知道了'), $go) -Primary $go -Cancel (T '知道了')
    if ($ans -eq $go) { Show-Page 'moves' }
}
Register-BgJob 'moveresume' -Moves -Done {
    $x = @($sync.ResumeRes)
    End-Op (T '完成')
    $script:movedTargets = $null
    $bad = @($x | Where-Object { -not $_.Ok })
    $script:pendingDialog = @{ Title = $(if ($bad.Count) { (T '有的没做成') } else { (T '处理好了') }); Kind = $(if ($bad.Count) { 'warn' } else { 'done' }); Text = (@($x | ForEach-Object { $_.Msg }) -join "`n`n") }
}
function Show-HalfMoves {
    # 有进度记录的：说清楚停在哪一步，可以接着做完或撤回
    $js = @(); try { $js = @(Get-MoveJournal) } catch {}
    if ($js.Count -gt 0) {
        if ($script:worker) { return }
        $items = @($js | ForEach-Object { Get-JournalText $_ })
        Write-LogFile ((T '发现上次没做完的搬家：') + ($items -join (T '；')))
        $fin = T '接着做完'; $undo = T '撤回'
        $ans = Show-Sheet -Kind warn -Title (T '有上次没做完的搬家') -Text (T "上次搬家或搬回 C 盘时中途停了（比如关机、断电、程序被关掉）。每一步都有记录，数据都还在，没有删。`n`n「接着做完」按原来的计划做完；「撤回」恢复成搬之前的样子（已经删了一部分旧文件夹的，只能接着做完）。先退出下面这些文件夹所属的软件，再选。") `
            -Items $items -Buttons @((T '以后再说'), $undo, $fin) -Primary $fin -Cancel (T '以后再说')
        if ($ans -ne $fin -and $ans -ne $undo) { return }
        Use-BgJob 'moveresume'; $sync.ResumeRes = $null
        Start-Op $(if ($ans -eq $fin) { (T '接着做完上次的搬家') } else { (T '撤回上次没做完的搬家') }) -NoCard; UI-Busy $true
        Start-Worker @'
$out = @()
foreach ($x in $arg.Items) { $r = Resume-Move $x $arg.How; $out += @{ Ok = $r.Ok; Msg = $r.Msg }; Log ("  " + $r.Msg) }
$sync.ResumeRes = $out
'@ @{ Items = $js; How = $(if ($ans -eq $fin) { 'finish' } else { 'undo' }) }
        return
    }
    # 没有记录的（以前的版本留下的）：只能告诉用户数据在哪
    $h = @(); try { $h = @(Find-HalfMoves) } catch { return }
    if ($h.Count -eq 0) { return }
    $items = @($h | ForEach-Object { if ($_.Kind -eq '.moved_backup') { (T "{0} 的数据在 {1}") -f $_.Src, $_.Bak } else { (T "{0}：搬回时复制回来的数据在 {1}") -f $_.Src, $_.Bak } })
    Write-LogFile ((T '发现上次没做完的搬家：') + ($items -join (T '；')))
    $ans = Show-Sheet -Kind warn -Title (T '有上次没做完的搬家') -Text (T "上次搬家或搬回 C 盘时中途停了（比如关机、断电），下面这些文件夹改了名还没收尾。数据都还在，没有删。`n`n如果软件里的数据看起来不见了：先退出那个软件，把原来名字的文件夹（多半是软件新建的空文件夹）移到别处，再把带后缀的文件夹改回原来的名字；也可以到「搬家管理」里重新搬一次。") `
        -Items $items -Buttons @((T '知道了'), (T '打开所在位置')) -Primary (T '知道了') -Cancel (T '知道了')
    if ($ans -eq (T '打开所在位置')) { Open-Location $h[0].Bak }
}
$global:CLEANC_UI_SHOWN = $true   # 告诉外层 exe：界面已经正常打开
$script:helpAtStart = $script:helpReady   # 界面自测核对：帮助页没有在打开窗口时就建好
if ($script:uiTest) { $win.WindowStartupLocation = 'Manual'; $win.Left = -32000; $win.Top = -32000; $win.ShowActivated = $false; $win.ShowInTaskbar = $false }
$win.ShowDialog() | Out-Null
