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
        $script:movedTargets = $null
        try { $w.PS.EndInvoke($w.Handle) | Out-Null } catch { UI-Log ((T "后台出错：{0}") -f $($_.Exception.Message)) }
        foreach ($er in @($w.PS.Streams.Error | Select-Object -First 5)) { UI-Log ((T "后台出错：{0}") -f $er) }
        $w.PS.Dispose(); $w.RS.Dispose()
        [DirStat]::Cancel = $false
        if ($sync.WasCancelled) { UI-Log (T '已中途取消。') }
        # 删过、搬过东西以后，逐个扫描得到的旧树不再拿来用（读文件表的结果靠变更日志更新）
        if (@('scan', 'movescan', 'apps', 'map', 'movesize', 'dup', 'update', 'startup', 'winget', 'odinfo', 'csanalyze', 'leftovers') -notcontains [string]$sync.Mode) { [DiskMap]::Invalidate() }

        if ($sync.Mode -eq 'scan') {
            if ($sync.WasCancelled -or -not $sync.Sizes) {
                $script:oneClickPending = $false
                $sync.Sizes = $script:prevSizes
                End-Op $(if ($sync.WasCancelled) { (T '已中途取消，列表没有更新') } else { (T '没有完成') })
                if ($script:rows) { $ctl.Summary.Text = (T '扫描已取消，下面还是上一次扫描的结果。') }
                else { $ctl.Summary.Text = (T '扫描已取消。点「扫描」重新开始。'); $ctl.EmptyCleanText.Text = (T '扫描已取消。点「扫描」重新开始。') }
            } else {
                Build-Rows $sync.Sizes; End-Op (T '完成')
                if ($script:oneClickPending) { $script:oneClickPending = $false; $script:runAfterScan = $true }
            }
        }
        elseif ($sync.Mode -eq 'run') {
            $script:candScanned = $false
            $after = [double](FreeC); $freed = $after - $script:runFreeC0
            $cardWasOpen = ($ctl.Overlay.Visibility -eq 'Visible')
            $head = (T "C 盘剩余：{0} → {1}，释放了 {2}") -f (GB $script:runFreeC0), (GB $after), (GB ([math]::Max([double]0, [double]$freed)))
            $waitNote = ''
            if ([int]$sync.WaitCount -gt 0) {
                $waitNote = (T "有 {0} 个文件夹已经复制好，但原文件夹还被别的程序占着，没换成链接。彻底退出相关的聊天软件（包括右下角托盘图标）后再点一次「执行」，会接着用复制好的副本，很快完成。") -f [int]$sync.WaitCount
                $head += "`n" + $waitNote
            }
            $cx = [bool]$sync.WasCancelled
            if ($cx) { $head = (T '已中途取消：还没开始的项目都没做，已经做完的不会撤销。') + "`n" + $head }
            $endText = if ($cx) { (T "已中途取消，释放 {0}，C 盘现在剩余 {1}") } else { (T "完成，释放 {0}，C 盘现在剩余 {1}") }
            End-Op ($endText -f (GB ([math]::Max([double]0, [double]$freed))), (GB $after)) -KeepCard -headline $head -reportLines (Plan-Lines)
            if (-not $cx) { if ($ctl.Overlay.Visibility -eq 'Visible') { $script:askRemind = $true } else { $script:askRemindNow = $true } }
            $sumText = if ($cx) { (T "已中途取消：C 盘从剩余 {0} 变成 {1}。每一项的结果写在列表里；想看还剩什么，再点「扫描」。") } else { (T "已完成：C 盘从剩余 {0} 变成 {1}。每一项的结果写在列表里；想看还剩什么，再点「扫描」。") }
            $ctl.Summary.Text = $sumText -f (GB $script:runFreeC0), (GB $after)
            $script:reclaim = [double]0
            $lines = @(); if ($sync.RunSummary) { $lines = @($sync.RunSummary) }
            $shown = @($lines | Select-Object -First 22)
            if ($lines.Count -gt 22) { $shown += ((T "……另有 {0} 项，见左下角「运行记录」") -f ($lines.Count - 22)) }
            if (-not $cardWasOpen) { $script:pendingDialog = @{ Title = $(if ($cx) { (T '已中途取消') } else { (T '执行完成') }); Kind = $(if ($waitNote -or $cx) { 'warn' } else { 'done' }); Items = $shown
                Text = (T "共用时 {0}。C 盘剩余 {1} → {2}，释放 {3}。{4}") -f (FmtSpan $script:lastElapsed), (GB $script:runFreeC0), (GB $after), (GB ([math]::Max([double]0, [double]$freed))), $(if ($waitNote) { "`n`n" + $waitNote } else { '' }) } }
            try { [System.Media.SystemSounds]::Asterisk.Play() } catch {}
            Fill-DestChoices
        }
        elseif ($sync.Mode -eq 'hogs') { End-Op (T '完成') }
        elseif ($sync.Mode -eq 'dup') {
            $res = $sync.DupResult
            $cnt = if ($res) { $res.Count } else { 0 }
            $stopped = [DupFinder]::Cancel
            $ctl.DupProgressText.Text = ((T "{0}看过 {1:N0} 个文件夹、{2:N0} 个文件，找到 {3:N0} 组重复。") -f $(if ($stopped) { (T '已停止。') } else { (T '查找完成。') }), [DupFinder]::DirsSeen, [DupFinder]::FilesSeen, $cnt)
            End-Op $(if ($stopped) { ((T "已停止，找到 {0} 组") -f $cnt) } else { ((T "完成，找到 {0} 组") -f $cnt) })
            if ($res) { Build-DupRows $res $cnt } else { Build-DupRows @() 0 }
            if ($script:dupRows -and $script:dupRows.Count -gt 0) {
                Pick-Dup 'new'
                UI-Log (T '已自动勾选：每组留最新的一份，其余删除。可以改勾选，或点上面的按钮换一种留法。')
            }
        }
        elseif ($sync.Mode -eq 'dupdel') {
            $gone = @{}
            if ($sync.DupDeleted) { foreach ($p in $sync.DupDeleted) { $gone[$p.ToLowerInvariant()] = $true } }
            $left = New-Object System.Collections.Generic.List[DupGroup]
            foreach ($g in $script:dupGroups) {
                $ng = New-Object DupGroup
                $ng.Name = $g.Name; $ng.Size = $g.Size; $ng.Verified = $g.Verified
                foreach ($f in $g.Files) { if (-not $gone.ContainsKey($f.Path.ToLowerInvariant())) { $ng.Files.Add($f) } }
                if ($ng.Files.Count -ge 2) { $left.Add($ng) }
            }
            Build-DupRows $left $left.Count
            $nDel = if ($sync.DupDeleted) { $sync.DupDeleted.Count } else { 0 }
            $cardWasOpen = ($ctl.Overlay.Visibility -eq 'Visible')
            $bin = if ($script:lastRecycle) { (T "`n`n文件在回收站里，清空回收站后才真正释放磁盘空间。") } else { '' }
            $binShort = if ($script:lastRecycle) { (T '文件在回收站里，清空回收站后才真正释放空间。') } else { '' }
            $cx = [bool]$sync.WasCancelled
            End-Op ($(if ($cx) { (T "已中途取消，删除了 {0} 个文件") } else { (T "完成，删除了 {0} 个文件") }) -f $nDel) -KeepCard -headline ($(if ($cx) { (T "已中途取消：删除了 {0} 个重复文件，剩下的没删。{1}") } else { (T "删除了 {0} 个重复文件。{1}") }) -f $nDel, $binShort) -reportLines @(,@((T '没删的（内容和保留的那份不完全相同，或文件被占用）记在左下角的「运行记录」里。'), '#6E6E73', $false))
            try { [System.Media.SystemSounds]::Asterisk.Play() } catch {}
            if (-not $cardWasOpen) { $script:pendingDialog = @{ Title = $(if ($cx) { (T '已中途取消') } else { (T '删除完成') }); Kind = 'done'; Text = ((T "删除了 {0} 个重复文件，共用时 {1}。{2}`n`n没删的（内容和保留的那份不完全相同，或文件被占用）记在「运行记录」里。") -f $nDel, (FmtSpan $script:lastElapsed), $bin) } }
        }
        elseif ($sync.Mode -eq 'map') {
            $root = $sync.MapResult
            $mm = [string]$sync.MapMethod; $secs = [double]$sync.MapMs / 1000
            # 读文件表时，读完以后（核对的时候）才点停止的，结果是完整的
            $stopped = ($mm -eq 'mft-partial') -or ([DiskMap]::Cancel -and $mm -notlike 'mft*')
            if ($sync.MapNote -and $mm -notlike 'mft*') { UI-Log ((T "空间地图：没能直接读取文件表（{0}），改为逐个文件夹扫描") -f $sync.MapNote) }
            if ($root) {
                $script:mapHow = if ($mm -eq 'mft-usn') { (T '按变更日志更新') } elseif ($mm -like 'mft*') { (T '直接读文件表') } else { (T '逐个文件夹扫描') }
                UI-Log ((T "空间地图：{0}，用时 {1:N1} 秒") -f $script:mapHow, $secs)
                [DiskMap]::Use($root)
                $script:mapMethod = $mm
                $script:mapRoot = $root; $script:mapCur = $root; $script:mapScanAt = Get-Date
                $script:movedTargets = $null
                $script:prevSnap = $null
                if (-not $stopped) { try { Update-Growth $root } catch { $script:growNote = (T '没能和上次比较') } } else { $script:growNote = (T '这次扫描中途停止了，不和上次比较') }
                End-Op ($(if ($stopped) { (T "已中途停止，看过 {0:N0} 个文件，共 {1}") } else { (T "完成，{0:N0} 个文件，共 {1}") }) -f $root.Files, (Fmt $root.Size))
                if ($script:mapView -eq 'grow') { Set-MapView 'grow' } elseif ($script:mapView -eq 'files') { Show-MapFiles } else { Show-MapLevel $root }
                if ($stopped) { $ctl.MapInfo.Text = (T '扫描中途停止了，下面只是已经看过的部分') }
                Add-History
            } else { End-Op (T '没有完成') }
            $ctl.BtnMapStop.IsEnabled = $false
        }
        elseif ($sync.Mode -eq 'mapdel') {
            $res = $sync.MapDel
            $okSet = @{}; if ($res) { foreach ($p in $res.Ok) { $okSet[([string]$p).ToLowerInvariant()] = $true } }
            foreach ($r in @($script:mapDelRows)) {
                if (-not $okSet.ContainsKey(([string]$r.Path).ToLowerInvariant())) { continue }
                if ($r.Node) { [DiskMap]::Detach($r.Node) }
                else {
                    $pn = [DiskMap]::Find($script:mapRoot, (Split-Path $r.Path -Parent))
                    if ($pn) { [DiskMap]::DropFile($pn, $r.Size, $r.Disk, [bool]$r.Shared) }
                    [DiskMap]::ForgetFile($r.Path)
                }
            }
            $nOk = $okSet.Count; $fails = @(); if ($res) { $fails = @($res.Fail) }
            $one = (@($script:mapDelRows).Count -eq 1)
            $txt = if ($sync.WasCancelled) { (T "已中途取消，删除了 {0} 项") -f $nOk } elseif ($fails.Count -eq 0) { $(if ($one) { (T "已删除 {0}") -f @($script:mapDelRows)[0].Name } else { (T "已删除 {0} 项") -f $nOk }) } elseif ($nOk -eq 0) { (T '没有删掉') } else { (T "删除了 {0} 项，{1} 项没删掉") -f $nOk, $fails.Count }
            End-Op $txt
            if ($nOk -gt 0) { if ($script:mapView -eq 'files') { Show-MapFiles } elseif ($script:mapView -ne 'grow') { Show-MapLevel $script:mapCur } }
            if ($fails.Count -gt 0) {
                $script:pendingDialog = @{ Title = $(if ($nOk -eq 0) { (T '没有删掉') } else { (T '有的没有删掉') }); Kind = 'warn'; Items = @($fails | Select-Object -First 20)
                    Text = (T '下面这些没有删掉。正被别的程序打开的文件，关掉那个程序后再删一次。') }
            }
        }
        elseif ($sync.Mode -eq 'selftest') {
            $r = $sync.SelfTest
            if (-not $r) { End-Op (T '没有完成') }
            else {
                $text = (@($r.Lines) -join "`r`n")
                $file = Join-Path $script:appDir 'selftest.txt'
                try { New-Item -ItemType Directory -Force -Path $script:appDir | Out-Null; [IO.File]::WriteAllText($file, $text, (New-Object Text.UTF8Encoding $true)) } catch {}
                $copied = $true; try { [System.Windows.Clipboard]::SetText($text) } catch { $copied = $false }
                $x = $r.Res
                $sum = (T "{0} 项正常，{1} 项提醒，{2} 项有问题") -f $x.Pass, $x.Warn, $x.Fail
                End-Op $(if ($r.Stopped) { (T '已中途停止') } else { $sum })
                UI-Log ((T "检查扫描功能：{0}；结果存在 {1}") -f $sum, $file)
                $msg = $sum + (T '。') + $(if ($copied) { (T '结果已经复制，可以粘贴到 GitHub 的问题（Issue）里。') } else { '' }) + "`n`n" + ((T "完整结果存在 {0}") -f $file)
                if ($x.Fail -gt 0) { $msg += "`n`n" + (T '有问题的项目，扫描时会自动改用逐个文件夹扫描，不影响使用；把结果贴到 GitHub 的问题里可以帮助修好它。') }
                $script:pendingDialog = @{ Title = (T '扫描功能检查完了'); Kind = $(if ($x.Fail -gt 0) { 'warn' } else { 'done' }); Text = $msg
                    Buttons = @((T '好'), (T '打开结果')); Primary = (T '打开结果'); Cancel = (T '好'); Then = { Start-Process -FilePath "$env:SystemRoot\System32\notepad.exe" -ArgumentList ('"{0}"' -f $file) }.GetNewClosure() }
            }
        }
        elseif ($sync.Mode -eq 'update') {
            $u = $sync.Update
            End-Op (T '完成')
            if ($u -and $u.Ok -and -not ([string]$u.Tag).Trim()) { $u = @{ Ok = $false; Err = (T '返回的内容里没有版本号') } }   # 比如被网络登录页拦下来了
            # 版本号补齐到四段再比（2.6 和 2.6.0 是同一个版本）
            $norm = { param([string]$s) $v = $null; if ([version]::TryParse(([string]$s).Trim().TrimStart('v', 'V'), [ref]$v)) { New-Object Version ([math]::Max(0, $v.Major)), ([math]::Max(0, $v.Minor)), ([math]::Max(0, $v.Build)), ([math]::Max(0, $v.Revision)) } else { $null } }
            $cur = & $norm $script:AppVersion
            $new = if ($u -and $u.Ok) { & $norm $u.Tag } else { $null }
            $url = if ($u -and $u.Url -and ([string]$u.Url).StartsWith('https://github.com/')) { [string]$u.Url } else { $script:releasePage }
            $open = { Start-Process -FilePath "$env:SystemRoot\explorer.exe" -ArgumentList $url }.GetNewClosure()   # 用资源管理器打开：浏览器不会以管理员身份运行
            if (-not $u -or -not $u.Ok) {
                $script:pendingDialog = @{ Title = (T '没能检查新版本'); Kind = 'warn'; Text = ((T "连不上 GitHub：{0}`n`n可以直接打开下载页面看看。") -f $(if ($u) { $u.Err } else { '' }))
                    Buttons = @((T '好'), (T '打开下载页面')); Primary = (T '打开下载页面'); Cancel = (T '好'); Then = $open }
            } elseif ($new -and $cur -and $new -gt $cur) {
                $notes = @(([string]$u.Body -split "`r?`n") | Where-Object { $_ -match '^\s*[-*] ' } | Select-Object -First 6 | ForEach-Object { ($_ -replace '^\s*[-*]\s*', '' -replace '\*\*', '').Trim() })
                $script:pendingDialog = @{ Title = ((T "有新版本 {0}") -f $u.Tag); Kind = 'info'; Text = ((T "现在用的是 {0}。下载页面会在浏览器里打开，下载新的 exe 替换现在这个就好，设置都会保留。") -f $script:AppVersion); Items = $notes
                    Buttons = @((T '以后再说'), (T '打开下载页面')); Primary = (T '打开下载页面'); Cancel = (T '以后再说'); Then = $open }
            } else {
                $script:pendingDialog = @{ Title = (T '已经是最新版本'); Kind = 'done'; Text = ((T "现在用的是 {0}，GitHub 上最新的是 {1}。") -f $script:AppVersion, $u.Tag) }
            }
        }
        elseif ($sync.Mode -eq 'fcompress') {
            $x = $sync.FcResult
            if ($x) {
                $saved = [math]::Max([double]0, $x.Before - $x.After)
                End-Op ($(if ($x.Cancelled) { (T "已中途取消，省了 {0}") } else { (T "完成，省了 {0}") }) -f (Fmt $saved))
                $ctl.SaveFcState.Text = (T "上次压缩：{0}，实际占用 {1} → {2}，省了 {3}") -f $x.Path, (Fmt $x.Before), (Fmt $x.After), (Fmt $saved)
                $script:pendingDialog = @{ Title = $(if ($x.Cancelled) { (T '压缩已中途取消') } else { (T '压缩完成') }); Kind = 'done'; Text = ((T "{0}`n`n实际占用 {1} → {2}，省了 {3}。文件照常使用。") -f $x.Path, (Fmt $x.Before), (Fmt $x.After), (Fmt $saved)) + $(if ($x.Cancelled) { (T "`n`n已经压缩的文件保持压缩，剩下的没压缩。想压缩剩下的，再压缩一次这个文件夹就好。") } else { '' }) }
            } else { End-Op (T '没有完成') }
        }
        elseif ($sync.Mode -eq 'compactos') {
            $x = $sync.CosRes
            End-Op (T '完成')
            if ($x) { $script:pendingDialog = @{ Title = (T '系统压缩完成'); Kind = 'done'; Text = ((T "C 盘可用空间变化：{0}{1}") -f $(if ($x.Delta -ge 0) { (T '多了 ') } else { (T '少了 ') }), (Fmt ([math]::Abs($x.Delta)))) } }
            if ($ctl.PageSave.Visibility -eq 'Visible') { Load-Save }
        }
        elseif ($sync.Mode -eq 'odinfo') { End-Op (T '完成'); Show-OneDriveInfo $sync.OdInfo }
        elseif ($sync.Mode -eq 'odfree') {
            $x = $sync.OdRes
            End-Op (T '完成')
            if ($x) { $script:pendingDialog = @{ Title = (T '已标记为仅在线'); Kind = 'done'; Text = ((T "{0} 个文件（{1}）已改成仅在线{2}。OneDrive 会在后台释放本地空间，要等它同步一会儿。") -f $x.Done, (Fmt $x.Bytes), $(if ($x.Fail) { ((T "，{0} 个没改成（可能正被占用）") -f $x.Fail) } else { '' })) } }
            $script:odWanted = $true
        }
        elseif ($sync.Mode -eq 'csanalyze') {
            $x = $sync.CsRes
            End-Op (T '完成')
            if ($x -and $x.Ok) {
                $rec = if ($x.Recommended -match '(?i)^(yes|是|true)') { (T '建议清理') } else { (T '不需要清理') }
                $ctl.SaveCsState.Text = (T "当前：资源管理器显示 {0}，实际 {1}（其中和系统共用的 {2}），可回收的旧组件 {3} 个，上次清理 {4}。Windows 的判断：{5}。") -f $x.Reported, $x.Actual, $x.Shared, $x.Reclaimable, $x.LastCleanup, $rec
            } else { $ctl.SaveCsState.Text = (T '没分析成。') + $(if ($x) { ' ' + (($x.Out -split "`r?`n" | Where-Object { $_.Trim() } | Select-Object -Last 2) -join ' ') } else { '' }) }
        }
        elseif ($sync.Mode -eq 'wslmove') {
            $x = $sync.WslRes
            End-Op $(if ($x -and $x.Ok) { (T '已搬') } else { (T '没搬成') })
            if ($x -and $x.Ok) { $script:pendingDialog = @{ Title = (T 'WSL 发行版已搬到其他盘'); Kind = 'done'; Text = (T '照常用 wsl 打开即可。') } }
            elseif ($x -and $x.Old) { $script:pendingDialog = @{ Title = (T 'WSL 版本太旧'); Kind = 'warn'; Text = ((T "这个 WSL 还没有 --move 命令。在终端里运行 wsl --update 更新 WSL 后再试。`n`n{0}") -f $x.Out) } }
            elseif ($x) { $script:pendingDialog = @{ Title = (T '没搬成'); Kind = 'warn'; Text = $x.Out } }
            if ($ctl.PageSave.Visibility -eq 'Visible') { Load-Save }
        }
        elseif ($sync.Mode -eq 'leftovers') {
            End-Op (T '完成')
            Build-StartRows 'leftover' $sync.LeftoverResult
        }
        elseif ($sync.Mode -eq 'vdisk') {
            $x = $sync.VdRes
            End-Op (T '完成')
            if ($x) {
                $t = if ($x.After -lt $x.Before) { (T "{0} → {1}，省了 {2}。") -f (Fmt $x.Before), (Fmt $x.After), (Fmt ($x.Before - $x.After)) } else { (T "大小没有变化（{0}）。可能里面本来就没有可回收的空间，或者虚拟磁盘还在使用中。`n`n{1}") -f (Fmt $x.After), $x.Out }
                $script:pendingDialog = @{ Title = (T '虚拟磁盘压缩完成'); Kind = $(if ($x.After -lt $x.Before) { 'done' } else { 'info' }); Text = $t }
            }
            Load-Save
        }
        elseif ($sync.Mode -eq 'vmove') {
            $script:candScanned = $false; if ($ctl.PageMoves.Visibility -eq 'Visible') { $script:candPending = $true }
            $res = $sync.VmRes
            $ok = $res -and $res.Done -gt 0
            $cx = $res -and $res.Cancelled -and -not $ok
            End-Op $(if ($ok) { (T "已搬 {0}") -f (GB $res.Moved) } elseif ($cx) { (T '已取消') } else { (T '没搬成') })
            $msg = if ($res -and $res.Msgs) { ($res.Msgs -join "`n") } else { '' }
            $script:pendingDialog = @{ Title = $(if ($ok) { (T '搬好了') } elseif ($cx) { (T '已取消') } else { (T '没搬成') }); Kind = $(if ($ok) { 'done' } elseif ($cx) { 'info' } else { 'warn' }); Text = $(if ($ok) { (T "已搬到 {0}。原位置留了链接，软件照常使用。{1}") -f ($res.Dest -join (T '；')), $msg } else { $msg }) }
            Load-Save; Fill-DestChoices
        }
        elseif ($sync.Mode -eq 'appmove') {
            $script:candScanned = $false; if ($ctl.PageMoves.Visibility -eq 'Visible') { $script:candPending = $true }
            $res = $sync.AmRes; $r = $script:appMoveRow
            $ok = $res -and $res.Done -gt 0
            $cx = $res -and $res.Cancelled -and -not $ok
            End-Op $(if ($ok) { (T "已搬 {0}") -f (GB $res.Moved) } elseif ($cx) { (T '已取消') } else { (T '没搬成') })
            $msg = if ($res -and $res.Msgs) { ($res.Msgs -join "`n") } else { '' }
            if ($ok) {
                $script:pendingDialog = @{ Title = ((T "「{0}」搬好了") -f $r.Name); Kind = 'done'
                    Text = ((T "已搬到 {0}，C 盘腾出约 {1}。原位置留了链接，快捷方式和开始菜单照常能打开。建议现在打开一次这个软件，确认一切正常。`n`n要搬回来，到「搬家管理」点「搬回 C 盘」。{2}") -f ($res.Dest -join (T '；')), (GB $res.Moved), $(if ($msg) { "`n`n$msg" } else { '' })) }
            } else { $script:pendingDialog = @{ Title = $(if ($cx) { (T '已取消') } else { (T '没搬成') }); Kind = $(if ($cx) { 'info' } else { 'warn' }); Text = $(if ($msg) { $msg } else { (T '没有搬，原文件夹没动。') }) } }
            $script:runAfterApps = $true
            Fill-DestChoices
        }
        elseif ($sync.Mode -eq 'apps') {
            End-Op $(if ($sync.WasCancelled) { (T '已中途取消，没统计到的软件显示安装时登记的大小') } else { (T '完成') })
            if ($sync.AppsResult) { Build-AppRows $sync.AppsResult } else { $ctl.EmptyAppsText.Text = (T '没读到已安装的软件') }
        }
        elseif ($sync.Mode -eq 'startup') {
            End-Op (T '完成')
            Build-StartRows ([string]$sync.StartKind) $sync.StartResult
        }
        elseif ($sync.Mode -eq 'winget') {
            End-Op $(if ($sync.WingetResult -and -not $sync.WingetResult.Err) { ((T "{0} 个有新版本") -f @($sync.WingetResult.Items).Count) } else { (T '没查成') })
            Apply-WingetResult $sync.WingetResult
        }
        elseif ($sync.Mode -eq 'uninst') {
            $x = $sync.UninstRes
            End-Op $(if ($x -and $x.Ok) { (T '已卸载') } else { (T '没卸载成') })
            if ($x -and -not $x.Ok) { $script:pendingDialog = @{ Title = (T '没卸载成'); Kind = 'warn'; Text = $x.Msg } }
            $script:runAfterApps = $true
        }
        elseif ($sync.Mode -eq 'leftdel') {
            $x = $sync.LeftRes
            $cx = [bool]$sync.WasCancelled
            End-Op $(if ($cx) { (T '已中途取消') } else { (T '完成') })
            $ctl.AppsLeftBox.Visibility = 'Collapsed'; $script:leftApp = $null
            if ($x) { $script:pendingDialog = @{ Title = $(if ($cx) { (T '已中途取消') } else { (T '残留已清理') }); Kind = 'done'; Text = ((T "「{0}」留下的 {1} 个文件夹已移到回收站。清空回收站后才真正腾出空间。") -f $x.Name, $x.Count) + $(if ($cx) { (T '剩下的没删。') } else { '' }) } }
            $script:runAfterApps = $true
        }
        elseif ($sync.Mode -eq 'movescan') {
            End-Op $(if ($sync.WasCancelled) { (T '已中途取消') } else { (T '完成') })
            if ($sync.WasCancelled -or $null -eq $sync.CandResult) {
                $script:candScanned = $false
                $ctl.EmptyCandText.Text = (T '已取消。点右上角「刷新」重新看。')
                Set-CandInfo (T '已取消，没有看完。')
                if ($script:movesTab -eq 'cand') { $ctl.EmptyCand.Visibility = 'Visible' }
            } else {
                $script:storeChat = @($sync.CandStore)
                $ctl.CandStoreText.Text = if ($script:storeChat.Count -gt 0) { (T "{0} 是从应用商店装的，由 Windows 管理，本工具不搬。可以在 Windows 设置 → 应用 → 已安装的应用 里点它右边的「…」→「移动」，连同数据换到其他盘（要这个应用支持）。") -f ($script:storeChat -join (T '、')) } else { '' }
                Build-CandRows $sync.CandResult
                Set-MovesTab $script:movesTab
            }
        }
        elseif ($sync.Mode -eq 'movemany') {
            $x = $sync.MmRes
            $after = [double](FreeC); $freed = [math]::Max([double]0, [double]($after - $script:mmFreeC0))
            $cx = [bool]$sync.WasCancelled
            $cardWasOpen = ($ctl.Overlay.Visibility -eq 'Visible')
            $head = (T "C 盘剩余：{0} → {1}，腾出了 {2}") -f (GB $script:mmFreeC0), (GB $after), (GB $freed)
            if ($cx) { $head = (T '已中途取消：还没开始的项目都没做，已经做完的不会撤销。') + "`n" + $head }
            $waitNote = ''
            if ([int]$sync.WaitCount -gt 0) { $waitNote = (T "有 {0} 个文件夹已经复制好，但原文件夹还被别的程序占着，没换成链接。彻底退出相关的软件（包括右下角托盘图标）后再搬一次，会接着用复制好的副本，很快完成。") -f [int]$sync.WaitCount; $head += "`n" + $waitNote }
            End-Op ($(if ($cx) { (T "已中途取消，腾出 {0}") } else { (T "完成，腾出 {0}") }) -f (GB $freed)) -KeepCard -headline $head -reportLines (Plan-Lines)
            # 搬好的从「可以搬的」里去掉，其余的保留这次的结果
            if ($x -and $x.Done -and $x.Done.Count -gt 0 -and $script:candList) {
                $gone = @{}; foreach ($k in $x.Done) { $gone[[string]$k] = $true }
                $keep = @($script:candList | Where-Object { $k = if ($_.Type -eq 'app') { 'a:' + ([string]$_.Location).ToLowerInvariant() } else { 'c:' + $_.Idx }; -not $gone.ContainsKey($k) })
                Build-CandRows $keep
                $script:candSeen = -1
            }
            if (-not $cardWasOpen) {
                $lines = @(); if ($x -and $x.Summary) { $lines = @($x.Summary) }
                $script:pendingDialog = @{ Title = $(if ($cx) { (T '已中途取消') } else { (T '搬家完成') }); Kind = $(if ($waitNote -or $cx) { 'warn' } else { 'done' }); Items = @($lines | Select-Object -First 22); Text = $head }
            }
            try { [System.Media.SystemSounds]::Asterisk.Play() } catch {}
            $script:pageLoaded.apps = $false
            $script:runAfterMoves = $true
            Fill-DestChoices
        }
        elseif ($sync.Mode -eq 'movesize') {
            $t = $sync.MoveTotal
            if ($t -and $script:moveRows) { Set-DoneInfo ((T "共 {0} 个文件夹，其中 {1} 个正常，已经帮 C 盘腾出约 {2}。") -f $script:moveRows.Count, $t.Count, (Fmt $t.Bytes)) }
            if ($script:candPending) { $script:runAfterCand = $true }
        }
        elseif ($sync.Mode -eq 'moveback' -or $sync.Mode -eq 'movedrop') {
            $script:candScanned = $false; if ($ctl.PageMoves.Visibility -eq 'Visible') { $script:candPending = $true }
            $x = $sync.MoveRes
            $ok = $x -and $x.Ok
            $back = ($sync.Mode -eq 'moveback')
            $cx = $x -and $x.Cancelled -and -not $ok
            End-Op $(if ($ok) { (T '完成') } elseif ($cx) { (T '已取消') } else { (T '没有完成') })
            if ($ok) { $script:pendingDialog = @{ Title = $(if ($back) { (T '已搬回 C 盘') } else { (T '多余的副本已删除') }); Kind = 'done'; Text = $(if ($x.Msg) { $x.Msg } elseif ($back) { (T "搬回了 {0}，软件照常使用。") -f (Fmt $x.Bytes) } else { (T "腾出了 {0}。") -f (Fmt $x.Bytes) }) } }
            else { $script:pendingDialog = @{ Title = $(if ($cx) { (T '已取消') } else { (T '没有完成') }); Kind = $(if ($cx) { 'info' } else { 'warn' }); Text = $(if ($x) { $x.Msg } else { '' }) } }
            $script:runAfterMoves = $true
            Fill-DestChoices
        }
        elseif ($sync.Mode -eq 'merge') {
            $done = @{}
            if ($sync.DupMerged) { foreach ($p in $sync.DupMerged) { $done[$p.ToLowerInvariant()] = $true } }
            $left = New-Object System.Collections.Generic.List[DupGroup]
            foreach ($g in $script:dupGroups) {
                $ng = New-Object DupGroup
                $ng.Name = $g.Name; $ng.Size = $g.Size; $ng.Verified = $g.Verified
                foreach ($f in $g.Files) { if (-not $done.ContainsKey($f.Path.ToLowerInvariant())) { $ng.Files.Add($f) } }
                if ($ng.Files.Count -ge 2) { $left.Add($ng) }
            }
            Build-DupRows $left $left.Count
            $n = $done.Count
            $cx = [bool]$sync.WasCancelled
            End-Op ($(if ($cx) { (T "已中途取消，合并了 {0} 个文件") } else { (T "完成，合并了 {0} 个文件") }) -f $n) -KeepCard -headline ($(if ($cx) { (T "已中途取消：合并了 {0} 个重复文件，剩下的没合并。每个位置的文件都还在。") } else { (T "合并了 {0} 个重复文件。每个位置的文件都还在，只占一份空间。") }) -f $n) -reportLines @(,@((T '没合并的（内容不完全相同、文件正被打开、不在同一块盘）记在左下角的「运行记录」里。'), '#6E6E73', $false))
        }
        $sync.Mode = $null
        UI-Status; UI-Busy $false
        if ($script:closeWhenDone) { $script:pendingDialog = $null; $script:runAfterScan = $false; $script:askRemindNow = $false; $win.Close(); return }
        if ($script:runAfterScan) {
            $script:runAfterScan = $false
            Apply-OneClick
            Invoke-RunSelected (T '一键清理')
        }
        if ($script:runAfterApps) { $script:runAfterApps = $false; Load-Apps }
        if ($script:runAfterMoves) { $script:runAfterMoves = $false; Load-Moves }
        if ($script:runAfterCand) { $script:runAfterCand = $false; if (-not $script:worker) { Start-CandScan } }
        if ($script:candPending -and -not $script:worker -and $ctl.PageMoves.Visibility -eq 'Visible') { Start-CandScan }
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
    OpLog '系统设置' (T '开启空间不足提醒') $script:taskRemind ((T "任务计划：{0}") -f $exe)
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

$script:statusColor = @{ wait = '#86868B'; run = '#0071E3'; ok = '#248A3D'; warn = '#B25000'; fail = '#D70015'; skip = '#86868B' }
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
function Restart-App {
    try {
        if ($env:CLEANC_SELF -and (Test-Path -LiteralPath $env:CLEANC_SELF)) { Start-Process -FilePath $env:CLEANC_SELF }
        elseif ($script:selfScript) { Start-Process -FilePath "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -ArgumentList ('-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}"' -f $script:selfScript) }
    } catch {}
    $win.Close()
}
# 外观：浅色 / 深色 / 跟随系统
$script:themeNames = @{ light = (T '浅色'); dark = (T '深色'); system = (T '跟随系统') }
$ctl.BtnThemeText.Text = (T "外观：{0}") -f $script:themeNames[$(if ($script:themeNames.ContainsKey($script:themePref)) { $script:themePref } else { 'light' })]
$ctl.BtnTheme.Add_Click({
    if ($script:worker) { Show-Sheet -Title (T '请等当前操作做完') -Text (T '另一个操作还在进行中。') | Out-Null; return }
    $ans = Show-Sheet -Title (T '选择外观') -Text ((T "深色适合在暗的环境里用；跟随系统会照 Windows 设置里「选择应用模式」来。换了以后本工具会关闭，再自动打开。`n`n现在：{0}") -f $script:themeNames[$script:themePref]) `
        -Buttons @((T '取消'), (T '跟随系统'), (T '深色'), (T '浅色')) -Primary (T '浅色') -Cancel (T '取消')
    $to = if ($ans -eq (T '浅色')) { 'light' } elseif ($ans -eq (T '深色')) { 'dark' } elseif ($ans -eq (T '跟随系统')) { 'system' } else { '' }
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
    try {
        if ($env:CLEANC_SELF -and (Test-Path -LiteralPath $env:CLEANC_SELF)) { Start-Process -FilePath $env:CLEANC_SELF }
        elseif ($script:selfScript) { Start-Process -FilePath "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -ArgumentList ('-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}"' -f $script:selfScript) }
    } catch {}
    $win.Close()
    return $true
}
$ctl.BtnLang.Add_Click({ [void](Request-Lang) })
$ctl.CleanScroll.Add_ScrollChanged({ Update-CleanMore })
$ctl.CleanMore.Add_Click({ $ctl.CleanScroll.PageDown() })
# 第一次打开时先给出安全风险提示，勾选同意后才能使用；同意过就不再弹
$script:riskFile = Join-Path $env:LOCALAPPDATA 'CleanC\risk-accepted.txt'
$win.Add_ContentRendered({
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
    if (Test-Path -LiteralPath $script:riskFile) { Ask-Mode; return }
    $ans = Show-Sheet -Kind warn -Title (T '使用前请先阅读安全风险提示') `
        -Text (T "本工具会按你的选择删除或搬移电脑上的文件。删除的文件可能无法恢复，存在资料丢失的风险。`n`n每次删除前，请确认这些资料确实不再需要、删除不会给你带来损失；重要资料请先备份。因使用本工具造成的资料丢失或其他损失，责任由使用者自行承担，开发者不承担责任。`n`n完整说明随时可以在左侧「帮助」里查看。") `
        -Confirm (T '我已阅读并了解上述风险，同意自行承担使用本工具的后果。') -Buttons @((T '退出'), (T '同意并继续')) -Primary (T '同意并继续') -Cancel (T '退出')
    if ($ans -ne (T '同意并继续')) { $win.Close(); return }
    try {
        New-Item -ItemType Directory -Path (Split-Path $script:riskFile) -Force | Out-Null
        [IO.File]::WriteAllText($script:riskFile, ((T "{0:yyyy-MM-dd HH:mm:ss}  已同意（版本 {1}）") -f (Get-Date), $script:AppVersion), [Text.Encoding]::UTF8)
    } catch {}
    Write-LogFile (T '用户已同意安全风险提示')
    Ask-Mode
})
# 还没选过模式就问一句（老版本升上来的也会问一次）
function Ask-Mode {
    if ((Get-Setting 'Mode' '')) { return }
    $ans = Show-Sheet -Title (T '你是哪类用户？') -Text (T "按你的需要决定界面上有多少东西，随时可以在「设置」里换。`n`n普通用户：清理缓存、省空间、看哪里占地方、卸载软件，够用也不复杂。`n工程师：再加上重复文件、搬家管理、自动提醒、操作日志，以及各页的进阶功能。`n开发者和 IT：全部功能，包括计划任务、右键菜单、保留的存储、组件存储分析、自定义清理列表、空间明细和自检。") `
        -Buttons @((T '普通用户'), (T '工程师'), (T '开发者和 IT')) -Primary (T '普通用户') -Cancel (T '普通用户')
    $mode = switch ($ans) { (T '工程师') { 'pro' } (T '开发者和 IT') { 'expert' } default { 'basic' } }
    Set-Mode $mode
}
$global:CLEANC_UI_SHOWN = $true   # 告诉外层 exe：界面已经正常打开
if ($script:uiTest) { $win.WindowStartupLocation = 'Manual'; $win.Left = -32000; $win.Top = -32000; $win.ShowActivated = $false; $win.ShowInTaskbar = $false }
$win.ShowDialog() | Out-Null
