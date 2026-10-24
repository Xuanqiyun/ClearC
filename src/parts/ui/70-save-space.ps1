# ------------------------------------------------------------
# 省空间
# ------------------------------------------------------------
# ------------------------------------------------------------
# 系统健康：硬件、开机、蓝屏、活动监控、事件
# ------------------------------------------------------------
$script:healthData = $null
function Load-Health {
    $ctl.HealthNote.Text = if ($script:healthData) { (T '正在后台刷新，下面先显示上次读到的…') } else { (T '正在读取硬件、事件日志和转储文件，要几秒…') }
    $ctl.BtnHealthRefresh.IsEnabled = $false
    $ok = Start-BgEngine 'health' 'Get-HealthAll' $null {
        param($r, $err)
        $ctl.BtnHealthRefresh.IsEnabled = $true
        if (-not $r) { $ctl.HealthNote.Text = (T '没能读取：') + $err; return }
        $script:healthData = $r
        Show-Health $r
        Show-Verdicts $r
        Show-Fixes $r.Power
    }
    if (-not $ok) { $ctl.BtnHealthRefresh.IsEnabled = $true }
}
$ctl.BtnHealthRefresh.Add_Click({ Load-Health })
# 档位颜色：绿正常、橙留意、红有问题、灰读不到
$script:hcGreen = @('#1D7A35', '#E5F4E9'); $script:hcAmber = @('#995700', '#FFF1DB'); $script:hcRed = @('#C0101C', '#FDEBEC'); $script:hcGrey = @('#6E6E73', '#F0F0F3'); $script:hcBlue = @('#0A5BC4', '#E3EEFF')
function New-Chip([string]$text, $tier) { $c = New-Object HealthChip; $c.Text = $text; $c.Fg = $tier[0]; $c.Bg = $tier[1]; return $c }
function New-HealthCard([string]$title, [string]$sub, $tier) { $c = New-Object HealthCard; $c.Title = $title; $c.Sub = $sub; $c.Stripe = $tier[0]; $c.BarBrush = $tier[0]; return $c }
function Tier-Worst($a, $b) { $rank = @{ ($script:hcGrey[0]) = 0; ($script:hcGreen[0]) = 1; ($script:hcBlue[0]) = 1; ($script:hcAmber[0]) = 2; ($script:hcRed[0]) = 3 }; if ($rank[$b[0]] -gt $rank[$a[0]]) { $b } else { $a } }
# 空间地图上每块盘一张卡片：卡片一起排满这一排（每张至少 280、最多 560），盘多了就换行
$win.Resources['DcCardW'] = [double]300
function Update-DcCardW {
    $w = [double]$ctl.MapHealth.ActualWidth; if ($w -lt 100) { return }
    $n = @($ctl.MapHealth.ItemsSource).Count; if ($n -lt 1) { $n = 1 }
    $cols = [math]::Max(1, [math]::Min($n, [math]::Floor(($w + 1) / (280 + 12))))
    $cw = [math]::Min([double]560, [math]::Floor($w / $cols) - 12)
    if ([math]::Abs([double]$win.Resources['DcCardW'] - $cw) -lt 1) { return }
    $win.Resources['DcCardW'] = [double]$cw
    # 用量条的长度跟着卡片宽度变
    foreach ($c in @($ctl.MapHealth.ItemsSource)) { if ($c) { $c.BarW = [math]::Round(($cw - 34) * [double]$c.UsedPct / 100.0) } }
    try { $ctl.MapHealth.Items.Refresh() } catch {}
}
$ctl.MapHealth.Add_SizeChanged({ param($s, $e) if ($e.WidthChanged) { Update-DcCardW } })
# 硬件卡片的宽度跟着这一页的宽度走：每张至少 270，一排能放几张放几张，正好排满（最大化时右边不留空白，也不用往下拉很长）
$win.Resources['HcCardW'] = [double]290
# 卡片上的用量条按百分比画：卡片多宽，满格就多长
function Set-CardBar($card, [double]$pct) {
    $card.HasBar = $true; $card.BarPct = $pct
    $card.BarW = [math]::Max(2, ([double]$win.Resources['HcCardW'] - 33) * $pct / 100.0)
}
$ctl.HealthCards.Add_SizeChanged({
    param($s, $e)
    $w = [double]$s.ActualWidth; if ($w -lt 100) { return }
    $cols = [math]::Max(1, [math]::Floor(($w + 1) / (270 + 12)))
    $cw = [math]::Floor($w / $cols) - 12
    if ([math]::Abs([double]$win.Resources['HcCardW'] - $cw) -lt 1) { return }
    $win.Resources['HcCardW'] = [double]$cw
    $any = $false
    foreach ($c in @($ctl.HealthCards.ItemsSource)) { if ($c -and $c.HasBar) { $c.BarW = [math]::Max(2, ($cw - 33) * [double]$c.BarPct / 100.0); $any = $true } }
    if ($any) { try { $ctl.HealthCards.Items.Refresh() } catch {} }
})
# 事件的说明文字：一行一行合起来，太长的截到 300 字（完整的在鼠标提示里）
function Shorten-Note([string]$t) {
    if (-not $t) { return '' }
    $t = ($t -replace '\s*[\r\n]+\s*', ' ').Trim()
    if ($t.Length -gt 300) { $t = $t.Substring(0, 300) + '…' }
    return $t
}
function Show-Health($r) {
    $ctl.HealthNote.Text = (T "读取于 {0:HH:mm}，用了 {1:N0} 秒。读取只看不改；修复的按钮点了会先说明要改什么。") -f $r.At, $r.Secs
    $bad = @($r.Verdicts | Where-Object { $_.Level -eq 'red' })
    if ($bad.Count -gt 0 -and $ctl.HTabCrash.Visibility -eq 'Visible') { $ctl.HealthNote.Text += ' ' + ((T '发现 {0} 个要注意的问题：「{1}」，详情和修法在「蓝屏和崩溃」里。') -f $bad.Count, ((@($bad | ForEach-Object { $_.Title })) -join (T '」「'))) }
    $cards = New-Object 'System.Collections.ObjectModel.ObservableCollection[HealthCard]'
    # CPU
    $c = $r.Cpu
    if ($c.Ok) {
        $tier = $script:hcGreen
        $card = New-HealthCard (T 'CPU') $c.Name $tier
        if ($c.Load -ge 0) { $card.Chips.Add((New-Chip ((T "负载 {0}%") -f $c.Load) $(if ($c.Load -ge 90) { $script:hcAmber } else { $script:hcGreen }))); Set-CardBar $card $c.Load }
        if ($c.MaxMHz -gt 0) { $card.Chips.Add((New-Chip ("{0:N1} / {1:N1} GHz" -f ($c.MHz / 1000), ($c.MaxMHz / 1000)) $script:hcBlue)) }
        if ($c.Perf -ge 0) { $t2 = if ($c.Throttle) { $script:hcRed } elseif ($c.Perf -lt 90) { $script:hcAmber } else { $script:hcGreen }; $card.Chips.Add((New-Chip ((T "性能 {0}%") -f $c.Perf) $t2)); $tier = Tier-Worst $tier $t2 }
        if ($c.Temp -ne $null) { $t2 = if ($c.Temp -ge 90) { $script:hcRed } elseif ($c.Temp -ge 75) { $script:hcAmber } else { $script:hcGreen }; $card.Chips.Add((New-Chip ("{0} °C" -f $c.Temp) $t2)); $tier = Tier-Worst $tier $t2; if ($c.TempNote) { $card.Lines.Add($c.TempNote) } }
        else { $card.Chips.Add((New-Chip (T '温度读不到') $script:hcGrey)); $card.Lines.Add($c.TempWhy) }
        $card.Lines.Add(((T "{0} 核 {1} 线程") -f $c.Cores, $c.Threads) + $(if ($c.Throttle) { (T '。性能计数器持续低于标称频率：可能是散热或电源限制在降频') } else { '' }))
        $card.Stripe = $tier[0]; $card.BarBrush = $tier[0]
        $cards.Add($card)
    } else { $card = New-HealthCard (T 'CPU') (T '读不到') $script:hcGrey; $card.Lines.Add($c.Why); $cards.Add($card) }
    # 内存
    $m = $r.Mem
    if ($m.Ok) {
        $tier = switch ($m.Pressure) { 'high' { $script:hcRed } 'mid' { $script:hcAmber } default { $script:hcGreen } }
        $card = New-HealthCard (T '内存') ((T "{0} 已用 {1}，可用 {2}") -f (Fmt $m.Total), (Fmt ($m.Total - $m.Free)), (Fmt $m.Free)) $tier
        Set-CardBar $card $m.UsedPct
        $card.Chips.Add((New-Chip ((T "已用 {0}%") -f $m.UsedPct) $(if ($m.UsedPct -ge 92) { $script:hcRed } elseif ($m.UsedPct -ge 80) { $script:hcAmber } else { $script:hcGreen })))
        $card.Chips.Add((New-Chip ((T "提交 {0}%") -f $m.CommitPct) $(if ($m.CommitPct -ge 90) { $script:hcRed } elseif ($m.CommitPct -ge 75) { $script:hcAmber } else { $script:hcGreen })))
        if ($m.HardFaults -ge 0) { $card.Chips.Add((New-Chip ((T "硬错误 {0}/秒") -f $m.HardFaults) $(if ($m.HardFaults -ge 100) { $script:hcRed } elseif ($m.HardFaults -ge 20) { $script:hcAmber } else { $script:hcGreen }))) }
        if ($m.Whea -gt 0) { $card.Chips.Add((New-Chip ((T "WHEA 内存错误 {0} 次") -f $m.Whea) $script:hcRed)) }
        $card.Lines.Add(((T "提交 {0} / 上限 {1}（物理内存加页面文件）。") -f (Fmt $m.Commit), (Fmt $m.CommitLimit)) + $(switch ($m.Pressure) { 'high' { (T '内存很紧张：程序在频繁换到页面文件，会明显变慢') } 'mid' { (T '内存偏紧') } default { (T '内存够用') } }))
        if ($m.Whea -gt 0) { $card.Lines.Add((T '最近 30 天 Windows 记录过内存硬件错误（WHEA）：建议跑一次 Windows 内存诊断（mdsched）')) }
        $cards.Add($card)
    } else { $card = New-HealthCard (T '内存') (T '读不到') $script:hcGrey; $card.Lines.Add($m.Why); $cards.Add($card) }
    # 磁盘
    foreach ($d in @($r.Disks)) {
        $tier = $script:hcGreen
        $sub = if ($d.Model) { [string]$d.Model } else { (T '型号读不到') }
        $card = New-HealthCard ((T "磁盘 {0}") -f $d.Drive) $sub $tier
        try { $di = New-Object System.IO.DriveInfo ($d.Drive + '\'); $pct = [int][math]::Round(100.0 * ($di.TotalSize - $di.TotalFreeSpace) / [math]::Max([double]1, [double]$di.TotalSize)); Set-CardBar $card $pct; $card.Chips.Add((New-Chip ((T "已用 {0}%") -f $pct) $(if ($pct -ge 95) { $script:hcRed } elseif ($pct -ge 85) { $script:hcAmber } else { $script:hcGreen }))) } catch {}
        if ($d.Ok) {
            $h = [string]$d.Health
            $t2 = if ($h -match 'Healthy|正常|OK') { $script:hcGreen } elseif ($h) { $script:hcRed } else { $script:hcGrey }
            $card.Chips.Add((New-Chip $(if ($h) { $h } else { (T '健康状态读不到') }) $t2)); $tier = Tier-Worst $tier $t2
            if ($d.Temp -ne $null -and [int]$d.Temp -gt 0) { $t2 = if ([int]$d.Temp -ge 60) { $script:hcRed } elseif ([int]$d.Temp -ge 45) { $script:hcAmber } else { $script:hcGreen }; $card.Chips.Add((New-Chip ("{0} °C" -f $d.Temp) $t2)); $tier = Tier-Worst $tier $t2 } else { $card.Chips.Add((New-Chip (T '温度读不到') $script:hcGrey)) }
            if ($d.Wear -ne $null -and [int]$d.Wear -ge 0) { $t2 = if ([int]$d.Wear -ge 50) { $script:hcRed } elseif ([int]$d.Wear -ge 10) { $script:hcAmber } else { $script:hcGreen }; $card.Chips.Add((New-Chip ((T "磨损 {0}%") -f $d.Wear) $t2)); $tier = Tier-Worst $tier $t2 }
            if ($d.ReadErrors -ne $null -and [long]$d.ReadErrors -gt 0) { $card.Chips.Add((New-Chip ((T "读错误 {0}") -f $d.ReadErrors) $script:hcRed)); $tier = $script:hcRed }
            if ($d.Hours -ne $null -and [long]$d.Hours -gt 0) { $card.Lines.Add((T "通电 {0:N0} 小时") -f $d.Hours) }
            if ($d.Media) { $card.Lines.Add([string]$d.Media) }
        } else { $card.Chips.Add((New-Chip (T 'SMART 读不到') $script:hcGrey)); $card.Lines.Add((T '这块盘不报告 SMART（USB 硬盘盒、RAID 和部分虚拟机常见）')) }
        $card.Stripe = $tier[0]; $card.BarBrush = $tier[0]
        $cards.Add($card)
    }
    # 电池
    $b = $r.Battery
    if ($b.Present) {
        $tier = $script:hcGreen
        $card = New-HealthCard (T '电池') $b.Status $tier
        if ($b.Charge -ge 0) { Set-CardBar $card $b.Charge; $card.Chips.Add((New-Chip ((T "电量 {0}%") -f $b.Charge) $script:hcBlue)) }
        if ($b.Design -gt 0 -and $b.Full -gt 0) {
            $pct = [int][math]::Round(100.0 * $b.Full / $b.Design)
            $t2 = if ($pct -lt 60) { $script:hcRed } elseif ($pct -lt 80) { $script:hcAmber } else { $script:hcGreen }
            $card.Chips.Add((New-Chip ((T "健康 {0}%") -f $pct) $t2)); $tier = $t2
            $card.Lines.Add((T "设计容量 {0:N0} mWh，现在充满 {1:N0} mWh") -f $b.Design, $b.Full)
        } else { $card.Chips.Add((New-Chip (T '损耗读不到') $script:hcGrey)); if ($b.Why) { $card.Lines.Add($b.Why) } }
        if ($b.Cycles -ge 0) { $card.Chips.Add((New-Chip ((T "循环 {0} 次") -f $b.Cycles) $script:hcBlue)) } else { $card.Lines.Add((T '循环次数：电池没有报告')) }
        $card.Stripe = $tier[0]; $card.BarBrush = $tier[0]
        $cards.Add($card)
    } else { $card = New-HealthCard (T '电池') (T '没有电池（台式机）') $script:hcGrey; $cards.Add($card) }
    # 显卡
    foreach ($g in @($r.Gpu)) {
        if (-not $g.Ok) { $card = New-HealthCard (T '显卡') (T '读不到') $script:hcGrey; $card.Lines.Add($g.Why); $cards.Add($card); continue }
        $card = New-HealthCard (T '显卡') $g.Name $script:hcGreen
        if ($g.Util -ge 0) { Set-CardBar $card $g.Util; $card.Chips.Add((New-Chip ((T "占用 {0}%") -f $g.Util) $(if ($g.Util -ge 95) { $script:hcAmber } else { $script:hcGreen }))) }
        if ($g.Vram -gt 0) { $card.Chips.Add((New-Chip ($(if ($g.VramUsed -ge 0) { (T "显存 {0} / {1}") -f (Fmt $g.VramUsed), (Fmt $g.Vram) } else { (T "显存 {0}") -f (Fmt $g.Vram) })) $script:hcBlue)) }
        $card.Chips.Add((New-Chip (T '温度读不到') $script:hcGrey))
        $card.Lines.Add($g.TempWhy)
        if ($g.Driver) { $card.Lines.Add(((T "驱动 {0}") -f $g.Driver) + $(if ($g.DriverDate) { ("（{0:yyyy-MM-dd}）" -f $g.DriverDate) } else { '' })) }
        $cards.Add($card)
    }
    # Windows
    $w = $r.Win
    $tier = if ($w.BadDevices.Count -gt 0) { $script:hcAmber } else { $script:hcGreen }
    $card = New-HealthCard 'Windows' $(if ($w.Release) { (T "{0} {1}（{2}.{3}）") -f $w.Product, $w.Release, $w.BuildNo, $w.Ubr } else { (T "版本 {0}") -f $w.Build }) $tier
    if ($w.BuildNo -gt 0 -and $w.BuildNo -lt 19045 -and [string]$w.Product -notmatch 'Server|LTSC|LTSB') { $card.Chips.Add((New-Chip (T '版本太旧') $script:hcAmber)); $tier = Tier-Worst $tier $script:hcAmber }
    if ($r.Clock -and $r.Clock.Wrong) { $card.Chips.Add((New-Chip (T '时间可能不准') $script:hcAmber)); $card.Lines.Add(((T '有系统文件的修改时间比现在还晚 {0} 天：时钟被往回调过，或者主板电池没电了') -f $r.Clock.AheadDays)); $tier = Tier-Worst $tier $script:hcAmber }
    if ($w.Uptime) { $card.Chips.Add((New-Chip ((T "开机 {0}") -f (FmtSpan $w.Uptime)) $(if ($w.Uptime.TotalDays -ge 14) { $script:hcAmber } else { $script:hcBlue }))) }
    if ($w.PendingReboot) { $card.Chips.Add((New-Chip (T '等待重启') $script:hcAmber)); $tier = Tier-Worst $tier $script:hcAmber }
    if ($w.LastUpdate) { $card.Chips.Add((New-Chip ((T "更新 {0:yyyy-MM-dd}") -f $w.LastUpdate) $(if (((Get-Date) - $w.LastUpdate).TotalDays -gt 60) { $script:hcAmber } else { $script:hcGreen }))) }
    $card.Chips.Add((New-Chip ($(if ($w.BadDevices.Count -gt 0) { (T "{0} 个设备有问题") -f $w.BadDevices.Count } else { (T '设备都正常') })) $(if ($w.BadDevices.Count -gt 0) { $script:hcAmber } else { $script:hcGreen })))
    foreach ($bd in @($w.BadDevices | Select-Object -First 4)) { $card.Lines.Add(("{0}：{1}" -f $bd.Name, $bd.Note)) }
    if ($w.Uptime -and $w.Uptime.TotalDays -ge 14) { $card.Lines.Add((T '两周没重启了（快速启动的「关机」不算重启）。很多莫名其妙的慢和卡，重启一次就好')) }
    $card.Stripe = $tier[0]; $card.BarBrush = $tier[0]
    $cards.Add($card)
    $ctl.HealthCards.ItemsSource = $cards
    # 开机
    $bt = $r.Boot
    $slow = New-Object 'System.Collections.ObjectModel.ObservableCollection[NoteRow]'
    if ($bt.Ok) {
        $ctl.HealthBootText.Text = (T "最近一次开机（{0:yyyy-MM-dd HH:mm}）用了 {1:N0} 秒：到桌面 {2:N0} 秒，桌面出来后开机程序又忙了 {3:N0} 秒才安静下来。") -f $bt.At, ($bt.BootMs / 1000), ($bt.MainMs / 1000), ($bt.PostMs / 1000)
        if ($bt.History.Count -ge 3) { $avg = ($bt.History | ForEach-Object { $_.BootMs } | Measure-Object -Average).Average; $ctl.HealthBootText.Text += (T "最近 {0} 次平均 {1:N0} 秒。") -f $bt.History.Count, ($avg / 1000) }
        if ($bt.BootMs -gt 120000) { $ctl.HealthBootText.Text += (T '超过两分钟算慢的。') }
        foreach ($s in @($bt.Slow)) { $n = New-Object NoteRow; $n.Head = $s.Name; $n.Sub = [string]$s.Path; $n.Path = $s.Path; $n.Body = (T "拖慢 {0:N0} 秒，{1} 次") -f ($s.DegradeMs / 1000), $s.Times; $slow.Add($n) }
        if ($slow.Count -eq 0) { $ctl.HealthBootText.Text += (T '最近 30 天 Windows 没有点名拖慢开机的程序。') }
    } else { $ctl.HealthBootText.Text = $bt.Why }
    $ctl.HealthSlow.ItemsSource = $slow
    # 蓝屏
    $cr = $r.Crash
    $dumps = New-Object 'System.Collections.ObjectModel.ObservableCollection[DumpRow]'
    foreach ($d in @($cr.Dumps)) {
        $row = New-Object DumpRow
        $row.When = '{0:yyyy-MM-dd HH:mm}' -f $d.Time; $row.File = $d.File
        $row.Code = if ($d.Ok) { ('0x{0:X} {1}' -f $d.Code, $d.CodeName).Trim() } else { (T '没解析出来') }
        $xp = Get-DumpExplain $d
        $row.Plain = $xp.Plain + (T '。') + $(if ($d.Ok -and $xp.Kind -ne 'other') { (T '常见原因：') + $xp.Causes + (T '。') } elseif ($d.Ok) { $xp.Causes + (T '。') } else { '' })
        $row.Suspect = ''; $row.SuspectBrush = '#C0101C'
        if ($d.Suspect -and $d.SuspectFrom -eq 'address' -and -not $d.SuspectMs) { $row.Suspect = (T "可能是 {0}") -f $d.Suspect }
        elseif ($d.Suspect) { $row.Suspect = (T "可能和 {0} 有关") -f $d.Suspect; $row.SuspectBrush = '#995700' }
        elseif ($xp.Kind -eq 'storage') { $row.Suspect = (T '读盘失败'); $row.SuspectBrush = '#C0101C' }
        $det = @($xp.Detail)
        if ($d.Ok) { $det += (T "参数 {0}") -f ($d.Params -join ' ') }
        if ($d.Stack.Count -gt 0) { $det += (T "栈上的驱动：{0}") -f (($d.Stack | Select-Object -First 6) -join ', ') }
        if ($d.Ok) { $det += (T "出事时加载了 {0} 个驱动") -f $d.Drivers }
        if ($d.Error) { $det += $d.Error }
        $det += (T "{0}，{1}") -f $d.Name, (Fmt $d.Size)
        $row.Detail = $det -join (T '。')
        $dumps.Add($row)
    }
    $ctl.HealthDumps.ItemsSource = $dumps
    $ctl.HealthCrashText.Text = if ($dumps.Count -gt 0) { (T "{0} 里有 {1} 个转储文件（最近的 10 个）。") -f $cr.DumpDir, $dumps.Count } else { (T "没有转储文件：最近没有蓝屏，或者蓝屏时没来得及写出转储。") }
    if ($cr.MemoryDmp) { $ctl.HealthCrashText.Text += (T "另有完整转储 MEMORY.DMP（{0}，{1:yyyy-MM-dd}），在「省空间」里可以改成只存小转储。") -f (Fmt $cr.MemoryDmp.Size), $cr.MemoryDmp.Time }
    $evs = New-Object 'System.Collections.ObjectModel.ObservableCollection[NoteRow]'
    foreach ($x in @($cr.Events)) { $n = New-Object NoteRow; $n.Head = ("{0}（{1}）" -f $x.What, $x.Source); $n.Sub = Shorten-Note ([string]$x.Sample); $n.Path = $x.Sample; $n.Body = (T "{0} 次，最近 {1:MM-dd HH:mm}") -f $x.Count, $x.Last; $evs.Add($n) }
    if ($evs.Count -eq 0) { $n = New-Object NoteRow; $n.Head = (T '没有意外关机、硬件错误和磁盘错误的记录'); $evs.Add($n) }
    $ctl.HealthEvents.ItemsSource = $evs
    $drs = New-Object 'System.Collections.ObjectModel.ObservableCollection[NoteRow]'
    foreach ($x in @($cr.Drivers | Select-Object -First 12)) { $n = New-Object NoteRow; $n.Head = ("{0} {1} {2}" -f $x.Provider, $x.Name, $x.Version).Trim(); $n.Sub = [string]$x.Device; $n.Path = $x.Device; $n.Body = '{0:MM-dd HH:mm}' -f $x.When; $drs.Add($n) }
    if ($drs.Count -eq 0) { $n = New-Object NoteRow; $n.Head = (T '最近 30 天没有装过驱动'); $drs.Add($n) }
    $ctl.HealthDrivers.ItemsSource = $drs
    # 小选项卡上写明有几条，不点进去也知道
    $ctl.CTabDumpsN.Text = [string]$dumps.Count; $ctl.CTabDumpsB.Visibility = if ($dumps.Count -gt 0) { 'Visible' } else { 'Collapsed' }
    $nEv = @($cr.Events).Count + @($cr.Drivers).Count
    $ctl.CTabEventsN.Text = [string]$nEv; $ctl.CTabEventsB.Visibility = if ($nEv -gt 0) { 'Visible' } else { 'Collapsed' }
    # Windows 事件
    $errs = New-Object 'System.Collections.ObjectModel.ObservableCollection[NoteRow]'
    foreach ($x in @($w.Errors)) { $n = New-Object NoteRow; $n.Head = [string]$x.Source; $n.Sub = Shorten-Note ([string]$x.Sample); $n.Path = $x.Sample; $n.Body = (T "{0} 次，最近 {1:MM-dd HH:mm}") -f $x.Count, $x.Last; $errs.Add($n) }
    $ctl.HealthErrors.ItemsSource = $errs
    $ctl.HealthWinText.Text = if ($w.ErrorCount -gt 0) { (T "最近 7 天系统日志里有 {0} 条严重或错误事件，来源最多的几个：") -f $w.ErrorCount } else { (T '最近 7 天系统日志里没有严重或错误事件。') }
}
$ctl.HealthDumps.AddHandler([System.Windows.Controls.Button]::ClickEvent, [System.Windows.RoutedEventHandler]{ param($s, $e) $b = $e.OriginalSource; if ($b -is [System.Windows.Controls.Button] -and $b.Tag -is [DumpRow]) { Open-Location $b.Tag.File } })
# 「蓝屏和崩溃」里的三个小选项卡
$script:crashTabs = [ordered]@{ verdict = @('CTabVerdict', 'CrashViewVerdict'); dumps = @('CTabDumps', 'CrashViewDumps'); events = @('CTabEvents', 'CrashViewEvents') }
function Select-CrashTab([string]$k) {
    if (-not $script:crashTabs.Contains($k)) { $k = 'verdict' }
    foreach ($t in $script:crashTabs.Keys) { $ctl[$script:crashTabs[$t][1]].Visibility = $(if ($t -eq $k) { 'Visible' } else { 'Collapsed' }) }
    $rb = $ctl[$script:crashTabs[$k][0]]; if (-not $rb.IsChecked) { $rb.IsChecked = $true }
    $script:crashTab = $k
}
foreach ($t in $script:crashTabs.Keys) { $rb = $ctl[$script:crashTabs[$t][0]]; $rb.Tag = $t; $rb.Add_Checked({ Select-CrashTab ([string]$this.Tag) }) }
# ---------- 选项卡：点哪一项只显示哪一项 ----------
$script:healthTabs = [ordered]@{ hw = @('HTabHw', 'HealthViewHw'); boot = @('HTabBoot', 'HealthViewBoot'); crash = @('HTabCrash', 'HealthViewCrash'); fix = @('HTabFix', 'HealthViewFix'); mon = @('HTabMon', 'HealthViewMon'); events = @('HTabEvents', 'HealthViewEvents') }
$script:healthTab = Get-Setting 'HealthTab' 'hw'; $script:htabQuiet = $false
function Select-HealthTab([string]$k) {
    if (-not $script:healthTabs.Contains($k) -or $ctl[$script:healthTabs[$k][0]].Visibility -ne 'Visible') { $k = 'hw' }
    foreach ($t in $script:healthTabs.Keys) { $ctl[$script:healthTabs[$t][1]].Visibility = $(if ($t -eq $k) { 'Visible' } else { 'Collapsed' }) }
    $rb = $ctl[$script:healthTabs[$k][0]]
    if (-not $rb.IsChecked) { $script:htabQuiet = $true; try { $rb.IsChecked = $true } finally { $script:htabQuiet = $false } }
    $script:healthTab = $k
}
foreach ($t in $script:healthTabs.Keys) {
    $rb = $ctl[$script:healthTabs[$t][0]]; $rb.Tag = $t
    $rb.Add_Checked({ if ($script:htabQuiet) { return }; Select-HealthTab ([string]$this.Tag); Set-Setting 'HealthTab' $script:healthTab })
}
# ---------- 诊断结论和常见问题修复 ----------
$script:fixCat = $null
function Get-FixCat { if (-not $script:fixCat) { $script:fixCat = Get-FixCatalog }; return $script:fixCat }
# 一步修复在界面上的样子：标签写明只看 / 会改动 / 要重启；硬盘省电、快速启动按现在的状态换说法
function New-FixStepRow([string]$id, $st) {
    $s = (Get-FixCat).Steps[$id]
    $row = New-Object FixStepRow; $row.Id = $id; $row.Name = $s.Name; $row.Desc = $s.Desc; $row.Enabled = $true
    $tier = $script:hcGrey; $tag = ''
    switch ($s.Kind) {
        'check' { $tag = (T '只看'); $tier = $script:hcGreen }
        'fix' { if ($s.Reboot) { $tag = (T '要重启'); $tier = $script:hcRed } elseif ($s.Harmless) { $tag = (T '马上生效'); $tier = $script:hcBlue } else { $tag = (T '会改动'); $tier = $script:hcAmber } }
        'open' { $tag = (T '打开工具') }
        'go' { $tag = (T '跳转') }
        'special' { $tag = (T '可恢复'); $tier = $script:hcAmber }
    }
    switch ($id) {
        'diagpack' { $tag = (T '只读'); $tier = $script:hcGreen }
        'diskpowerundo' { $tag = (T '恢复'); $tier = $script:hcBlue; $row.Enabled = [bool]($st -and $st.DiskFix); if (-not $row.Enabled) { $row.Desc = $s.Desc + (T '（现在没改过，不用恢复）') } }
        'diskpower' { if ($st -and $st.DiskFix) { $row.Name = (T '已关闭硬盘省电'); $row.Enabled = $false; $tag = (T '已改') } }
        'faststartup' {
            if ($st -and $st.FastStartup -eq 'off') { $row.Name = (T '打开快速启动…'); $row.Desc = (T '快速启动现在是关着的。打开后「关机」变成半休眠，开机快几秒；关机变重启、唤醒失败的问题可能会回来') }
            elseif ($st -and $st.FastStartup -eq 'na') { $row.Name = (T '没有快速启动'); $row.Enabled = $false; $row.Desc = (T '休眠关着，所以没有快速启动，不用管'); $tag = (T '不用改'); $tier = $script:hcGrey }
        }
    }
    $row.Tag = $tag; $row.TagFg = $tier[0]; $row.TagBg = $tier[1]
    # 卡片上：标题是这一步做什么，按钮上写动作；点了会先问一下的，按钮后面带省略号
    $row.Title = ([string]$row.Name).TrimEnd([char]0x2026)
    $ask = ([string]$row.Name).EndsWith([string][char]0x2026)
    $act = switch ($s.Kind) { 'open' { T '打开' } 'go' { T '查看' } default { T '运行' } }
    switch ($id) { 'diagpack' { $act = (T '导出') } 'vendor' { $act = (T '打开') } 'ahciguide' { $act = (T '查看步骤') } 'diskpowerundo' { $act = (T '恢复') } }
    $row.Act = if (-not $row.Enabled) { $tag } elseif ($ask) { $act + [char]0x2026 } else { $act }
    return $row
}
function New-FixBtn([string]$id, $st) {
    if (-not (Get-FixCat).Steps.Contains($id)) { return $null }
    $x = New-FixStepRow $id $st
    $b = New-Object FixBtn; $b.Id = $id; $b.Name = $x.Name; $b.Tip = $x.Desc; $b.Enabled = $x.Enabled
    return $b
}
function Show-Fixes($st) {
    $c = Get-FixCat; $m = Get-Mode
    $col = New-Object 'System.Collections.ObjectModel.ObservableCollection[FixGroupRow]'
    foreach ($p in $c.Problems) {
        $g = New-Object FixGroupRow; $g.Id = $p.Id; $g.Title = $p.Title; $g.Desc = $p.Desc
        foreach ($id in $p.Steps) {
            $s = $c.Steps[$id]; if (-not $s) { continue }
            $show = [int]$s.Lvl -le $m
            if ($id -eq 'diskpowerundo') { $show = ($st -and $st.DiskFix) -or $m -ge [int]$c.Steps['diskpower'].Lvl }   # 改过了就一直能恢复，不管什么模式
            if ($show) { $x = New-FixStepRow $id $st; $x.No = [string]($g.Steps.Count + 1); $g.Steps.Add($x) }
        }
        if ($g.Steps.Count -gt 0) { $col.Add($g) }
    }
    # 左边的问题列表换了内容，原来选的那个问题还选着（第一次打开选记住的那个，没有就选第一个）
    $keep = if ($ctl.FixGroups.SelectedItem) { [string]$ctl.FixGroups.SelectedItem.Id } else { Get-Setting 'FixGroup' '' }
    $ctl.FixGroups.ItemsSource = $col
    $sel = @($col | Where-Object { $_.Id -eq $keep })[0]
    if (-not $sel -and $col.Count -gt 0) { $sel = $col[0] }
    $ctl.FixGroups.SelectedItem = $sel
}
$ctl.FixGroups.Add_SelectionChanged({ if ($ctl.FixGroups.SelectedItem) { Set-Setting 'FixGroup' ([string]$ctl.FixGroups.SelectedItem.Id); $ctl.FixDetailScroll.ScrollToTop() } })
function Show-Verdicts($r) {
    $col = New-Object 'System.Collections.ObjectModel.ObservableCollection[VerdictRow]'
    $rec = New-Object 'System.Collections.ObjectModel.ObservableCollection[FixBtn]'; $seen = @{}
    foreach ($v in @($r.Verdicts)) {
        $row = New-Object VerdictRow; $row.Title = $v.Title; $row.Body = $v.Body
        $tier = switch ($v.Level) { 'red' { $script:hcRed } 'amber' { $script:hcAmber } 'green' { $script:hcGreen } default { $script:hcBlue } }
        $row.Fg = $tier[0]; $row.Bg = $tier[1]
        foreach ($id in @($v.Fixes)) {
            $b = New-FixBtn $id $r.Power; if (-not $b) { continue }
            $row.Fixes.Add($b)
            if ($v.Id -ne 'none' -and -not $seen.ContainsKey($id)) { $seen[$id] = $true; $rec.Add((New-FixBtn $id $r.Power)) }
        }
        $row.HasFixes = $row.Fixes.Count -gt 0
        $pend = @(Get-PlanPending $v $r.Power)
        $row.HasPlan = $pend.Count -gt 0; $row.PlanTag = 'plan:' + [string]$v.Id; $row.PlanName = (T '按建议处理…')
        $row.PlanTip = (T '会做：') + ((@($pend | ForEach-Object { ([string](Get-FixCat).Steps[$_].Name).TrimEnd('…') })) -join (T '、'))
        $td = @($v.Todo | Where-Object { $_ })
        $row.HasTodo = $td.Count -gt 0
        $row.Todo = (@(for ($i = 0; $i -lt $td.Count; $i++) { '{0}. {1}' -f ($i + 1), $td[$i] })) -join "`n"
        $col.Add($row)
    }
    $ctl.HealthVerdicts.ItemsSource = $col
    $ctl.FixRec.ItemsSource = $rec
    $ctl.FixRecBox.Visibility = $(if ($rec.Count -gt 0) { 'Visible' } else { 'Collapsed' })
}
# 改完硬盘省电、快速启动后重新读一下状态，按钮跟着变
function Refresh-FixState {
    $st = Get-PowerFixState
    if ($script:healthData) { $script:healthData.Power = $st; Show-Verdicts $script:healthData }
    Show-Fixes $st
}
$script:uiFixRuns = New-Object System.Collections.Generic.List[string]
# 一条结论里还没做的自动步骤（硬盘省电已经关了、快速启动已经关了的就不再列）
function Get-PlanPending($v, $st) {
    $out = @()
    foreach ($id in @($v.Plan)) {
        if (-not $id -or -not (Get-FixCat).Steps.Contains($id)) { continue }
        if ($id -eq 'diskpower' -and $st -and $st.DiskFix) { continue }
        if ($id -eq 'faststartup' -and $st -and $st.FastStartup -ne 'on') { continue }
        $out += $id
    }
    return $out
}
# 按建议处理：本工具能直接做的几步一次做完（先列出来确认一次），做完告诉你哪些做好了、还剩哪些要你自己做
function Invoke-RepairPlan([string]$vid) {
    if (-not $script:healthData) { return }
    $v = @($script:healthData.Verdicts | Where-Object { [string]$_.Id -eq $vid })[0]
    if (-not $v) { return }
    $st = Get-PowerFixState; $c = Get-FixCatalog
    $pend = @(Get-PlanPending $v $st)
    if ($pend.Count -eq 0) { Show-Sheet -Title ([string]$v.Title) -Text (T '本工具能做的都已经做过了。剩下的要你自己做，见结论下面「需要你自己做的」。') | Out-Null; return }
    $items = @($pend | ForEach-Object { '{0}：{1}' -f ([string]$c.Steps[$_].Name).TrimEnd('…'), $c.Steps[$_].Desc })
    $td = @($v.Todo | Where-Object { $_ })
    $text = (T '本工具会直接做下面这几件，都能撤销（硬盘省电和快速启动可以在「常见问题修复」里改回来）。') + $(if ($td.Count) { "`n`n" + (T '做完以后还需要你自己做：') + "`n" + ((@(for ($i = 0; $i -lt $td.Count; $i++) { '{0}. {1}' -f ($i + 1), $td[$i] })) -join "`n") } else { '' })
    $ans = Show-Sheet -Kind warn -Title ((T '{0}：按建议处理？') -f $v.Title) -Text $text -Items $items -Buttons @((T '取消'), (T '开始处理')) -Primary (T '开始处理') -Cancel (T '取消')
    if ($ans -ne (T '开始处理')) { return }
    $done = @(); $fail = @()
    foreach ($id in $pend) {
        $name = ([string]$c.Steps[$id].Name).TrimEnd('…')
        try {
            switch ($id) {
                'diskpower' { $res = Set-DiskPowerFix $true; if ($res.Ok) { $done += ((T '{0}（马上生效）') -f $name) } else { $fail += ('{0}：{1}' -f $name, $res.Why) } }
                'faststartup' { Set-FastStartup $false; $done += ((T '{0}（下次关机起生效）') -f $name) }
                default { Invoke-FixStep $id -Quiet; $done += ((T '{0}（已在新窗口里打开或运行）') -f $name) }
            }
        } catch { $fail += ('{0}：{1}' -f $name, $_.Exception.Message) }
    }
    OpLog '系统设置' (T '按建议处理') ([string]$v.Title) (($done + $fail) -join (T '；'))
    Refresh-FixState
    $msg = (T '做好了：') + "`n" + (@($done | ForEach-Object { '• ' + $_ }) -join "`n")
    if ($fail.Count) { $msg += "`n`n" + (T '没做成：') + "`n" + (@($fail | ForEach-Object { '• ' + $_ }) -join "`n") }
    if ($td.Count) { $msg += "`n`n" + (T '还需要你自己做：') + "`n" + ((@(for ($i = 0; $i -lt $td.Count; $i++) { '{0}. {1}' -f ($i + 1), $td[$i] })) -join "`n") }
    $msg += "`n`n" + (T '改完用几天，再回来点「刷新」看还有没有新的蓝屏。')
    Show-Sheet -Kind done -Title (T '处理完了') -Text $msg | Out-Null
}
# 厂商驱动下载页：打开，同时把链接复制下来（这台电脑上不了网时，到别的电脑上打开）
function Open-VendorPage {
    $f = if ($script:healthData) { $script:healthData.Sys } else { $null }
    if (-not $f) { $f = Get-SysFacts }
    $url = Get-VendorSupportUrl $f
    if (-not $url) { return }
    try { [System.Windows.Clipboard]::SetText($url) } catch {}
    if ($script:uiTest) { $script:uiFixRuns.Add('vendor:' + $url); return }
    $txt = (T "{0} {1}，服务编号 / 序列号 {2}`n`n{3}`n`n链接已经复制。要下载的：BIOS、芯片组驱动、存储驱动（Intel RST）、固态硬盘固件；装的顺序是 BIOS → 芯片组 → 存储驱动 → 固件，每装一样重启一次。这台电脑上不了外网的话，在别的电脑上打开这个链接，下载好用 U 盘拷过来。") -f $f.Maker, $f.Model, $f.Serial, $url
    $ans = Show-Sheet -Title (T '厂商驱动下载页') -Text $txt -Buttons @((T '关闭'), (T '在浏览器里打开')) -Primary (T '在浏览器里打开') -Cancel (T '关闭')
    if ($ans -eq (T '在浏览器里打开')) { [void](Open-AsUser $url) }
}
# 改用 Windows 自带的硬盘驱动：只给步骤（要进 BIOS），先替你查好能不能改
function Show-AhciGuide {
    $f = if ($script:healthData) { $script:healthData.Sys } else { Get-SysFacts }
    $sd = if ($f) { $f.SysDisk } else { $null }
    $chk = @()
    $stop = $false
    if ($sd) {
        $chk += (T '系统盘：{0}，接口 {1}') -f $sd.Name, $sd.Bus
        if ($sd.RaidVolume) { $chk += (T '✗ 这看起来是 RAID 阵列（几块盘组在一起）：不要改，改了阵列会读不出来'); $stop = $true }
        elseif ($sd.Bus -ne 'RAID') { $chk += (T '✗ 系统盘没有接在 RAID / RST 控制器上，用不着改'); $stop = $true }
        else { $chk += (T '✓ 单块盘，不是 RAID 阵列') }
    } else { $chk += (T '读不到系统盘的接口，改之前自己在 BIOS 里确认是单块盘、没有组 RAID') }
    if ($f -and $f.BitLocker -eq 1) { $chk += (T '✗ BitLocker 开着：先在「控制面板 → BitLocker 驱动器加密」里点「暂停保护」，并准备好恢复密钥，否则改完要输恢复密钥') }
    elseif ($f -and $f.BitLocker -eq 0) { $chk += (T '✓ BitLocker 关着') }
    $steps = (T "1. 先把重要资料备份到另一块盘。`n2. 以管理员身份打开命令提示符，运行：`n      bcdedit /set {current} safeboot minimal`n3. 重启，开机时进 BIOS（Dell 按 F2），在 System Configuration → SATA/NVMe Operation 里把 RAID On 改成 AHCI/NVMe，保存退出。`n4. Windows 会进安全模式，并自动装上 Windows 自带的 NVMe / AHCI 驱动。`n5. 在安全模式里再以管理员身份运行：`n      bcdedit /deletevalue {current} safeboot`n   然后重启，回到正常模式。`n`n改完开不了机：进 BIOS 把模式改回 RAID On，一切照旧，数据不受影响。之后 Intel RST 的管理软件用不了，这没关系。")
    $txt = (T "适用：硬盘接在 Intel RST（RAID On）上、只有一块盘，更新 BIOS 和 RST 驱动后还是掉线。改用 Windows 自带的驱动后，就不经过 RST 了。`n`n这台电脑：`n{0}`n`n{1}`n`n本工具不替你改：要进 BIOS，中途出错要你手动改回来。") -f ($chk -join "`n"), $(if ($stop) { (T '按上面的检查结果，这台电脑不要这样改。') } else { $steps })
    $ans = Show-Sheet -Kind warn -Title (T '改用 Windows 自带的硬盘驱动') -Text $txt -Buttons @((T '关闭'), (T '复制两条命令')) -Primary (T '复制两条命令') -Cancel (T '关闭')
    if ($ans -eq (T '复制两条命令')) { try { [System.Windows.Clipboard]::SetText("bcdedit /set {current} safeboot minimal`r`nbcdedit /deletevalue {current} safeboot") } catch {} }
}
# 运行一步修复。会改动的先确认（界面自测时 Show-Sheet 当作点了取消）；命令都在看得见的终端窗口里跑
function Invoke-FixStep([string]$id, [switch]$Quiet) {
    $c = Get-FixCatalog; if (-not $c.Steps.Contains($id)) { return }   # 每次现取：命令里的时间戳（改名留底用）要是现在的
    $s = $c.Steps[$id]; $name = ([string]$s.Name).TrimEnd('…')
    if ($s.Kind -eq 'go') {
        switch ($s.Go) { 'startup' { Show-Page 'apps'; if ($ctl.AppsViewStartup.Visibility -eq 'Visible') { $ctl.AppsViewStartup.IsChecked = $true } } default { Select-HealthTab $s.Go } }
        return
    }
    if ($s.Kind -eq 'special') {
        switch ($id) {
            'diagpack' { Start-DiagPack }
            'vendor' { Open-VendorPage }
            'ahciguide' { Show-AhciGuide }
            'diskpower' {
                $ans = Show-Sheet -Kind warn -Title (T '关闭硬盘省电？') -Text $s.Confirm -Buttons @((T '取消'), (T '关闭省电')) -Primary (T '关闭省电') -Cancel (T '取消')
                if ($ans -ne (T '关闭省电')) { return }
                $res = Set-DiskPowerFix $true
                if ($res.Ok) { Show-Sheet -Kind done -Title (T '已关闭硬盘省电') -Text ((T "改了：{0}。马上生效，不用重启。想改回去，点「恢复硬盘省电」。") -f ($res.Names -join (T '、'))) | Out-Null }
                else { Show-Sheet -Kind warn -Title (T '没有改') -Text $res.Why | Out-Null }
                Refresh-FixState
            }
            'diskpowerundo' {
                $res = Set-DiskPowerFix $false
                if ($res.Ok) { Show-Sheet -Kind done -Title (T '已恢复硬盘省电') -Text (T '三项设置都改回了原来的值。') | Out-Null } else { Show-Sheet -Kind warn -Title (T '没有恢复') -Text $res.Why | Out-Null }
                Refresh-FixState
            }
            'faststartup' {
                $cur = Get-FastStartup
                if ($cur -eq 'na') { return }
                if ($cur -eq 'on') {
                    $ans = Show-Sheet -Kind warn -Title (T '关闭快速启动？') -Text $s.Confirm -Buttons @((T '取消'), (T '关闭快速启动')) -Primary (T '关闭快速启动') -Cancel (T '取消')
                    if ($ans -ne (T '关闭快速启动')) { return }
                } else {
                    $ans = Show-Sheet -Title (T '打开快速启动？') -Text (T '会重新打开快速启动：「关机」变成半休眠，下次开机快几秒。') -Buttons @((T '取消'), (T '打开')) -Primary (T '打开') -Cancel (T '取消')
                    if ($ans -ne (T '打开')) { return }
                }
                try { New-RestorePointIfWanted (T '快速启动'); Set-FastStartup ($cur -ne 'on'); UI-Log $(if ($cur -eq 'on') { (T '已关闭快速启动') } else { (T '已打开快速启动') }) } catch { Show-Sheet -Kind warn -Title (T '没能改') -Text (Get-FriendlyError $_) | Out-Null }
                Refresh-FixState
            }
        }
        return
    }
    if ($s.Kind -eq 'fix' -and -not $s.Harmless -and -not $Quiet) {   # Quiet：「按建议处理」已经一起确认过
        $ans = Show-Sheet -Kind warn -Title ((T '{0}？') -f $name) -Text $(if ($s.Confirm) { $s.Confirm } else { $s.Desc }) -Buttons @((T '取消'), (T '开始')) -Primary (T '开始') -Cancel (T '取消')
        if ($ans -ne (T '开始')) { return }
    }
    if ($script:uiTest) { $script:uiFixRuns.Add($id); return }   # 界面自测：不真的运行
    if ($s.Kind -eq 'fix') { New-RestorePointIfWanted $name }
    try {
        if ($s.Cmd) { Start-Process -FilePath "$env:SystemRoot\System32\cmd.exe" -ArgumentList ('/k title ClearC - {0} & {1} & echo. & echo {2}' -f $name, $s.Cmd, (T '运行完了，可以关掉这个窗口。')) }
        elseif ($s.Uri) { [void](Open-AsUser $s.Uri) }
        elseif ($s.Folder) { Open-Location $s.Folder; return }
        elseif ($s.Exe -and $s.Args) { Start-Process -FilePath $s.Exe -ArgumentList $s.Args }
        elseif ($s.Exe) { Start-Process -FilePath $s.Exe }
        if ($s.Kind -in 'fix', 'check') { OpLog '系统设置' $name '' $(if ($s.Cmd) { $s.Cmd } else { $s.Exe }) }
        UI-Log ((T "已打开：{0}") -f $name)
    } catch { Show-Sheet -Kind warn -Title ((T '没能打开：{0}') -f $name) -Text (Get-FriendlyError $_) | Out-Null }
}
foreach ($ic in @($ctl.HealthVerdicts, $ctl.FixRec, $ctl.FixDetail)) {
    $ic.AddHandler([System.Windows.Controls.Button]::ClickEvent, [System.Windows.RoutedEventHandler]{ param($s, $e) $b = $e.OriginalSource; if ($b -is [System.Windows.Controls.Button] -and $b.Tag -is [string] -and $b.Tag) { $t = [string]$b.Tag; if ($t.StartsWith('plan:')) { Invoke-RepairPlan $t.Substring(5) } else { Invoke-FixStep $t } } })
}
# 原来的两个按钮：和「常见问题修复」里的是同一步
function Start-SystemFileTool([bool]$repair) { Invoke-FixStep $(if ($repair) { 'sfcrepair' } else { 'sfccheck' }) }
$ctl.BtnSfcCheck.Add_Click({ Start-SystemFileTool $false })
$ctl.BtnSfcRepair.Add_Click({ Start-SystemFileTool $true })
# 诊断包：在后台打包，存到你选的位置（默认桌面），不覆盖已有的文件
function Start-DiagPack {
    if (-not $script:healthData) { Show-Sheet -Kind warn -Title (T '还在读取') -Text (T '等系统健康读完再导出。') | Out-Null; return }
    if ($script:uiTest) { $script:uiFixRuns.Add('diagpack'); return }
    # 先说清楚包里有什么：转储里有出事时内存里的一部分内容，日志和系统信息里有电脑名、用户名、装过的软件
    $dumps = @(Get-ChildItem -LiteralPath (Join-Path $env:SystemRoot 'Minidump') -Filter *.dmp -File -Force -ErrorAction SilentlyContinue)
    $db = [double]0; foreach ($f in $dumps) { $db += $f.Length }
    $items = @(
        (T '健康报告：硬件、Windows 和硬盘的状态')
        $(if ($dumps.Count) { (T "最近 {0} 个蓝屏小转储（{1}）：里面有蓝屏那一刻内存里的一部分内容") -f [math]::Min(20, $dumps.Count), (Fmt $db) } else { (T '蓝屏小转储：这台电脑上没有') })
        (T '最近 30 天的系统和应用日志')
        (T 'systeminfo、驱动列表、硬盘信息、Windows 错误报告的列表')
        (T '本工具最近的操作日志')
        (T '一份清单（manifest.txt），列出包里的每个文件')
    )
    $all = T '导出'; $lite = T '不带转储导出'
    $btns = if ($dumps.Count) { @((T '取消'), $lite, $all) } else { @((T '取消'), $all) }
    $ans = Show-Sheet -Kind warn -Title (T '导出诊断包？') -Text (T '诊断包里会有下面这些。里面有电脑名、用户名、装过的软件和文件路径，只发给你信得过、要帮你看问题的人。') -Items $items -Buttons $btns -Primary $all -Cancel (T '取消')
    if ($ans -ne $all -and $ans -ne $lite) { return }
    $noDumps = ($ans -eq $lite)
    $dlg = New-Object Microsoft.Win32.SaveFileDialog
    $dlg.Title = (T '诊断包保存到'); $dlg.Filter = (T 'zip 压缩包') + ' (*.zip)|*.zip'; $dlg.OverwritePrompt = $false
    $dlg.FileName = ('ClearC-diag-{0:yyyyMMdd-HHmm}.zip' -f (Get-Date)); $dlg.InitialDirectory = [Environment]::GetFolderPath('Desktop')
    if (-not $dlg.ShowDialog($win)) { return }
    $zip = $dlg.FileName
    if (Test-Path -LiteralPath $zip) { Show-Sheet -Kind warn -Title (T '已经有这个文件') -Text (T '换一个文件名再导出：不会覆盖已有的文件。') | Out-Null; return }
    $ctl.BtnDiagPack.IsEnabled = $false
    $ctl.HealthNote.Text = (T '正在导出诊断包，要半分钟到几分钟（systeminfo 比较慢）…')
    $ok = Start-BgEngine 'diagpack' 'Export-DiagPack $arg.Zip $arg.Health -NoDumps:$arg.NoDumps' @{ Zip = $zip; Health = $script:healthData; NoDumps = $noDumps } {
        param($res, $err)
        $ctl.BtnDiagPack.IsEnabled = $true
        if ($res -and $res.Ok) {
            $ctl.HealthNote.Text = (T "诊断包已导出：{0}（{1} 个文件，{2}）") -f $res.Path, $res.Count, (Fmt $res.Bytes)
            OpLog '系统设置' (T '导出诊断包') $res.Path ((T '{0} 个文件，{1}') -f $res.Count, (Fmt $res.Bytes))
            $ans = Show-Sheet -Kind done -Title (T '诊断包已导出') -Text ((T "{0}`n`n{1} 个文件，{2}。里面有蓝屏转储、日志和系统信息，可能包含电脑名、用户名、装过的软件和内存片段，只发给你信任的人。") -f $res.Path, $res.Count, (Fmt $res.Bytes)) -Buttons @((T '好'), (T '打开所在位置')) -Primary (T '打开所在位置') -Cancel (T '好')
            if ($ans -eq (T '打开所在位置')) { Open-Location $res.Path }
        } else { $ctl.HealthNote.Text = (T '没能导出诊断包'); Show-Sheet -Kind warn -Title (T '没能导出诊断包') -Text $(if ($res -and $res.Error) { $res.Error } else { [string]$err }) | Out-Null }
    }
    if (-not $ok) { $ctl.BtnDiagPack.IsEnabled = $true }
}
$ctl.BtnDiagPack.Add_Click({ Start-DiagPack })
$ctl.BtnCopyReport.Add_Click({
    if (-not $script:healthData) { return }
    try { [System.Windows.Clipboard]::SetText((Get-HealthReportText $script:healthData)); UI-Log (T '诊断报告已复制，可以直接粘贴') ; $ctl.HealthNote.Text = (T '诊断报告已复制，可以直接粘贴给别人。') } catch { Show-Sheet -Kind warn -Title (T '没能复制') -Text (Get-FriendlyError $_) | Out-Null }
})
Show-Fixes $null
# 活动监控：后台线程每 3 秒采一次样，把结果放进共享表；界面每秒看一眼
$script:monShared = $null; $script:monSeen = -1; $script:monTimer = $null
function Start-Monitor {
    if ($script:monShared -and -not $script:monShared.Stop) { return }
    $sh = [hashtable]::Synchronized(@{ Stop = $false; Ver = 0; Rows = $null; At = $null; Base = $null })
    $script:monShared = $sh; $script:monSeen = -1
    $threads = [Environment]::ProcessorCount
    $code = @'
$sh = $arg.Shared
$base = Get-ProcSample; $prev = $base; $sh.Base = $base.At
while (-not $sh.Stop) {
    Start-Sleep -Seconds 3
    if ($sh.Stop) { break }
    $cur = Get-ProcSample
    $sh.Rows = @(Compare-ProcSample $prev $cur $base $arg.Threads); $sh.At = $cur.At; $sh.Ver++
    $prev = $cur
}
'ok'
'@
    $ok = Start-BgEngine 'monitor' $code @{ Shared = $sh; Threads = $threads } { param($r, $err) if ($err) { $ctl.HealthMonText.Text = (T '监控出错：') + $err } }
    if (-not $ok) { return }
    $ctl.BtnMonStart.IsEnabled = $false; $ctl.BtnMonStop.IsEnabled = $true
    $ctl.HealthMonText.Text = (T '正在采样…第一组数据 3 秒后出来')
    if (-not $script:monTimer) {
        $script:monTimer = New-Object System.Windows.Threading.DispatcherTimer
        $script:monTimer.Interval = [TimeSpan]::FromMilliseconds(1000)
        $script:monTimer.Add_Tick({ Refresh-Monitor })
    }
    $script:monTimer.Start()
    OpLog '系统设置' (T '开始活动监控') '' ''
}
function Stop-Monitor {
    if ($script:monShared) { $script:monShared.Stop = $true }
    if ($script:monTimer) { $script:monTimer.Stop() }
    $ctl.BtnMonStart.IsEnabled = $true; $ctl.BtnMonStop.IsEnabled = $false
    if ($script:monShared -and $script:monShared.Base) { $ctl.HealthMonText.Text = (T "已停止。下面是从 {0:HH:mm:ss} 到 {1:HH:mm:ss} 的结果。") -f $script:monShared.Base, $(if ($script:monShared.At) { $script:monShared.At } else { Get-Date }) }
}
function Refresh-Monitor {
    $sh = $script:monShared
    if (-not $sh -or $sh.Ver -eq $script:monSeen -or -not $sh.Rows) { return }
    $script:monSeen = $sh.Ver
    Show-Monitor @($sh.Rows)
    $ctl.HealthMonText.Text = (T "从 {0:HH:mm:ss} 开始监控，到 {1:HH:mm:ss}，第 {2} 次采样。同名的进程合在一起算。") -f $sh.Base, $sh.At, $sh.Ver
}
function Show-Monitor($rows) {
    # 同名进程合并（Chrome、Edge 一个标签一个进程）
    $by = @{}
    foreach ($x in $rows) {
        $k = [string]$x.Name
        if (-not $by.ContainsKey($k)) { $by[$k] = @{ Name = $k; Path = $x.Path; N = 0; Cpu = 0.0; Ws = 0.0; Rate = 0.0; Since = 0.0; Total = 0.0 } }
        $a = $by[$k]; $a.N++; $a.Cpu += $x.Cpu; $a.Ws += $x.Ws; $a.Rate += $x.WriteRate; $a.Since += $x.WriteSince; $a.Total += $x.WriteTotal
        if (-not $a.Path -and $x.Path) { $a.Path = $x.Path }
    }
    # 只列 25 个：按表头选的那一列取前 25（点「CPU」就是 CPU 最高的 25 个），表格再按这一列排
    $cfg = $script:sortCfg['MonList']
    $sort = if ($cfg -and $cfg.Prop) { [string]$cfg.Prop } else { 'Since' }
    $desc = -not ($cfg -and $cfg.Prop -and -not $cfg.Desc)
    $key = switch ($sort) { 'Cpu' { { $_.Cpu } } 'Ws' { { $_.Ws } } 'Rate' { { $_.Rate } } 'Total' { { $_.Total } } 'Name' { { $_.Name } } default { { $_.Since * 1000000 + $_.Rate } } }
    $list = @($by.Values | Sort-Object $key -Descending:$desc | Select-Object -First 25)
    $max = [double]0; foreach ($a in $list) { if ($a.Since -gt $max) { $max = $a.Since } }
    $col = New-Object 'System.Collections.ObjectModel.ObservableCollection[ProcRow]'
    foreach ($a in $list) {
        $p = New-Object ProcRow
        $p.Name = $a.Name; $p.Meta = $(if ($a.N -gt 1) { (T "{0} 个进程 · ") -f $a.N } else { '' }) + $(if ($a.Path) { Shorten $a.Path } else { '' })
        $p.CpuText = '{0:N0}%' -f $a.Cpu; $p.WsText = Fmt $a.Ws; $p.RateText = (T "{0}/秒") -f (Fmt $a.Rate); $p.SinceText = Fmt $a.Since; $p.TotalText = Fmt $a.Total
        $p.Cpu = [double]$a.Cpu; $p.Ws = [double]$a.Ws; $p.Rate = [double]$a.Rate; $p.Since = [double]$a.Since; $p.Total = [double]$a.Total
        $p.Bar = if ($max -gt 0) { [math]::Max(0, 100.0 * $a.Since / $max) } else { 0 }
        $col.Add($p)
    }
    $ctl.MonList.ItemsSource = $col
}
$ctl.BtnMonStart.Add_Click({ Start-Monitor })
$ctl.BtnMonStop.Add_Click({ Stop-Monitor })
$win.Add_Closed({ try { if ($script:monShared) { $script:monShared.Stop = $true } } catch {} })

# ---------- 省空间：左边目录，点哪项右边只显示那一项（记住上次看的） ----------
$script:saveGroups = [ordered]@{ Sys = @('Cos', 'Pf', 'Hib', 'Rs', 'Cs', 'Dump'); Safe = @('Rp', 'Tmp'); Files = @('Fc', 'Od', 'Merge'); Vd = @('Vd') }
$script:saveLvl = @{ Pf = 1; Rp = 1; Fc = 1; Vd = 1; Merge = 1; Rs = 2; Cs = 2; Dump = 2; Tmp = 2 }   # 没写的谁都能用
$script:saveSec = Get-Setting 'SaveSection' 'Cos'
function Update-SaveNav {
    $m = Get-Mode; $first = ''
    foreach ($g in $script:saveGroups.Keys) {
        $any = $false
        foreach ($k in $script:saveGroups[$g]) {
            $ok = $m -ge [int]$script:saveLvl[$k]
            $ctl['SaveNav' + $k].Visibility = $(if ($ok) { 'Visible' } else { 'Collapsed' })
            if ($ok) { $any = $true; if (-not $first) { $first = $k } }
        }
        $ctl['SaveHead' + $g].Visibility = $(if ($any) { 'Visible' } else { 'Collapsed' })
    }
    $k = $script:saveSec
    if (-not $ctl['SaveNav' + $k] -or $ctl['SaveNav' + $k].Visibility -ne 'Visible') { $k = $first }
    Select-SaveSection $k
}
function Select-SaveSection([string]$k) {
    if (-not $ctl['SaveCard' + $k]) { return }
    $script:saveSec = $k
    foreach ($g in $script:saveGroups.Keys) { foreach ($x in $script:saveGroups[$g]) { $ctl['SaveCard' + $x].Visibility = $(if ($x -eq $k) { 'Visible' } else { 'Collapsed' }) } }
    $rb = $ctl['SaveNav' + $k]; if (-not $rb.IsChecked) { $script:saveNavQuiet = $true; try { $rb.IsChecked = $true } finally { $script:saveNavQuiet = $false } }
    $ctl.SaveScroll.ScrollToTop()
}
foreach ($g in $script:saveGroups.Keys) { foreach ($k in $script:saveGroups[$g]) { $ctl['SaveNav' + $k].Add_Checked({ if ($script:saveNavQuiet) { return }; Select-SaveSection ([string]$this.Tag); Set-Setting 'SaveSection' $script:saveSec }) } }
function Load-Save {
    $on = Get-CompactOSOn
    $ctl.SaveCosState.Text = if ($on) { (T '当前：已开启，系统文件已压缩存放') } else { (T '当前：未开启') }
    $ctl.BtnCosOn.IsEnabled = -not $on; $ctl.BtnCosOff.IsEnabled = $on
    $pf = Get-PageFileInfo
    $desc = @($pf.Files | ForEach-Object { (T "{0}（约 {1}）") -f $_.Path, (Fmt ($_.MB * 1MB)) }) -join (T '、')
    if (-not $desc) { $desc = (T '没有页面文件') }
    $ctl.SavePfState.Text = ((T "当前：{0}") -f $desc) + $(if ($pf.Auto) { (T '，由系统自动管理') } else { '' })
    $ctl.SavePfDrive.Items.Clear()
    foreach ($d in (Fixed-Drives -NoSystem)) {
        $it = New-Object System.Windows.Controls.ComboBoxItem
        $it.Content = Drive-ChoiceLabel $d; $it.Tag = $d.Name.TrimEnd('\')
        [void]$ctl.SavePfDrive.Items.Add($it)
    }
    if ($ctl.SavePfDrive.Items.Count -gt 0) { $ctl.SavePfDrive.SelectedIndex = 0 }
    $ctl.BtnPfMove.IsEnabled = $ctl.SavePfDrive.Items.Count -gt 0
    Start-RestoreInfo
    $h = Get-HiberInfo
    $ctl.SaveHibState.Text = if (-not $h.Exists) { (T '当前：已关闭休眠，没有 hiberfil.sys') } elseif ($h.Reduced) { ((T "当前：精简（只留快速启动），占 {0}") -f $(Fmt $h.Bytes)) } else { ((T "当前：完整休眠，占 {0}") -f $(Fmt $h.Bytes)) }
    $col = New-Object 'System.Collections.ObjectModel.ObservableCollection[VdiskRow]'
    foreach ($v in (Get-VDisks)) {
        $r = New-Object VdiskRow
        $r.Name = $v.Name; $r.Path = $v.Path; $r.Kind = $v.Kind; $r.Note = $v.Note; $r.CanCompact = [bool]$v.Compact; $r.CanMove = [bool]$v.Move; if ($v.Distro) { $r.Distro = [string]$v.Distro }
        if (Test-Path -LiteralPath $v.Path -PathType Leaf) { $r.Size = (Get-Item -LiteralPath $v.Path -Force).Length; $r.SizeText = Fmt $r.Size }
        elseif ($script:worker) { $r.SizeText = '—' }
        else { $r.Size = [long](DirBytes $v.Path); $r.SizeText = Fmt $r.Size }
        $col.Add($r)
    }
    $ctl.VdList.ItemsSource = $col
    $ctl.VdEmpty.Visibility = if ($col.Count -gt 0) { 'Collapsed' } else { 'Visible' }
    # 保留的存储
    $rs = Get-ReservedStorageState
    $ctl.SaveRsState.Text = switch ($rs) { 'Enabled' { (T '当前：已开启（通常占 7 GB 左右）') } 'Disabled' { (T '当前：已关闭') } default { (T '当前：这个版本的 Windows 没有这项（Windows 10 1903 以后才有）') } }
    $ctl.BtnRsOff.IsEnabled = ($rs -eq 'Enabled'); $ctl.BtnRsOn.IsEnabled = ($rs -eq 'Disabled')
    # 蓝屏转储
    $dm = Get-CrashDumpMode
    $ctl.SaveDumpState.Text = (T '当前：') + $(switch ($dm) { 0 { (T '不保存') } 1 { (T '完整内存转储（和内存一样大）') } 2 { (T '内核内存转储') } 3 { (T '小内存转储（256 KB）') } 7 { (T '自动（通常是内核转储，可能有几 GB）') } default { (T '读不到') } })
    $ctl.BtnDumpSmall.IsEnabled = ($dm -ne 3 -and $dm -ge 0); $ctl.BtnDumpAuto.IsEnabled = ($dm -ne 7 -and $dm -ge 0)
    # 临时文件夹
    $tmp = Get-UserTemp
    $ctl.SaveTmpState.Text = (T "当前：{0}") -f $(if ($tmp) { $tmp + $(if ($tmp -ne $env:TEMP -and [Environment]::ExpandEnvironmentVariables($tmp) -ne $env:TEMP) { (T '（注销再登录后生效）') } else { '' }) } else { (T '系统默认') })
    $ctl.SaveTmpDrive.Items.Clear()
    foreach ($d in (Fixed-Drives -NoSystem)) {
        $it = New-Object System.Windows.Controls.ComboBoxItem
        $it.Content = Drive-ChoiceLabel $d; $it.Tag = $d.Name.TrimEnd('\')
        [void]$ctl.SaveTmpDrive.Items.Add($it)
    }
    if ($ctl.SaveTmpDrive.Items.Count -gt 0) { $ctl.SaveTmpDrive.SelectedIndex = 0 }
    $ctl.BtnTmpMove.IsEnabled = $ctl.SaveTmpDrive.Items.Count -gt 0
    $ctl.BtnTmpAuto.IsEnabled = [bool]$tmp -and ([Environment]::ExpandEnvironmentVariables($tmp) -ine "$env:USERPROFILE\AppData\Local\Temp")
    # OneDrive：文件多，到后台数（等没有后台任务时由定时器开始）
    $script:odWanted = $true
}
$ctl.BtnSaveRefresh.Add_Click({ Load-Save })
# ---------- OneDrive ----------
$script:odInfo = $null
Register-BgJob 'odinfo' -Cancel look -ReadOnly -Done { End-Op (T '完成'); Show-OneDriveInfo $sync.OdInfo }
function Start-OneDriveInfo {
    $folders = @(Get-OneDriveFolders)
    if ($folders.Count -eq 0) { $ctl.SaveOdState.Text = (T '这台电脑上没有登录 OneDrive。'); $ctl.BtnOdFree.IsEnabled = $false; return }
    if ($script:worker) { return }
    $ctl.SaveOdState.Text = (T '正在统计 OneDrive 文件夹里有多少本地副本…'); $ctl.BtnOdFree.IsEnabled = $false
    Use-BgJob 'odinfo'; $sync.OdInfo = $null
    Start-Op (T '统计 OneDrive 本地副本') -NoCard; UI-Busy $true
    Start-Worker @'
$sync.OdInfo = Get-OneDriveInfo
'@ $null
}
function Show-OneDriveInfo($i) {
    $script:odInfo = $i
    if (-not $i) { $ctl.SaveOdState.Text = (T '没统计到。'); return }
    $t = (T "当前：{0}，{1:N0} 个文件；本地有副本的 {2}，已经是仅在线的 {3}") -f ($i.Folders -join (T '、')), $i.Files, (Fmt $i.Local), (Fmt $i.Online)
    if ($i.Pinned -gt 0) { $t += (T "；设了「始终保留在此设备」的 {0}（不动）") -f (Fmt $i.Pinned) }
    if (-not $i.Running) { $t += (T "。OneDrive 现在没有运行，改了也要等它启动后才释放") }
    $ctl.SaveOdState.Text = $t
    $ctl.BtnOdFree.IsEnabled = ($i.Local -gt 0)
}
Register-BgJob 'odfree' -Cancel look -Done {
    $x = $sync.OdRes
    End-Op (T '完成')
    if ($x) { $script:pendingDialog = @{ Title = (T '已标记为仅在线'); Kind = 'done'; Text = ((T "{0} 个文件（{1}）已改成仅在线{2}。OneDrive 会在后台释放本地空间，要等它同步一会儿。") -f $x.Done, (Fmt $x.Bytes), $(if ($x.Fail) { ((T "，{0} 个没改成（可能正被占用）") -f $x.Fail) } else { '' })) } }
    $script:odWanted = $true
}
$ctl.BtnOdFree.Add_Click({
    $i = $script:odInfo
    if (-not $i -or $script:worker) { return }
    $ans = Show-Sheet -Title (T '把 OneDrive 里的本地副本都改成仅在线？') -Text ((T "本地有副本的 {0} 会改成「仅在线」：文件还在云端，资源管理器里照常显示，打开时自动下载。什么都不删。你设了「始终保留在此设备」的文件不动。`n`n改完由 OneDrive 自己在后台释放空间，要等它同步一会儿；断网时打不开这些文件。") -f (Fmt $i.Local)) -Buttons @((T '取消'), (T '改成仅在线')) -Primary (T '改成仅在线') -Cancel (T '取消')
    if ($ans -ne (T '改成仅在线')) { return }
    Use-BgJob 'odfree'; $sync.OdRes = $null
    Start-Op (T 'OneDrive 文件改成仅在线'); UI-Busy $true
    Start-Worker @'
SetP @{ Steps = 1; Step = 1; StepName = 'OneDrive'; SubKind = 'none'; Detail = (T '逐个文件标记') }
$res = @{}; Invoke-OneDriveFree $res; $sync.OdRes = $res
OpLog '系统设置' (T 'OneDrive 文件改成仅在线') '' ((T "{0} 个文件，{1}") -f $res.Done, (GB $res.Bytes))
'@ $null
})
# ---------- 保留的存储 ----------
foreach ($b in @($ctl.BtnRsOn, $ctl.BtnRsOff)) {
    $b.Add_Click({
        $on = [object]::ReferenceEquals($this, $ctl.BtnRsOn)
        $t = if ($on) { (T '重新开启保留的存储？') } else { (T '关闭保留的存储？') }
        $x = if ($on) { (T 'Windows 会重新预留 7 GB 左右给系统更新用。') } else { (T '这块空间会还给你。以后更新时 Windows 临时借用空闲空间；C 盘很满时更新可能提示空间不够，再开回来就好。有更新正在安装时改不了。') }
        $btn = if ($on) { (T '开启') } else { (T '关闭') }
        if ((Show-Sheet -Title $t -Text $x -Buttons @((T '取消'), $btn) -Primary $btn -Cancel (T '取消')) -ne $btn) { return }
        $win.Cursor = [System.Windows.Input.Cursors]::Wait
        try { $err = Set-ReservedStorage $on } finally { $win.Cursor = $null }
        if ($err) { Show-Sheet -Kind warn -Title (T '没改成') -Text $err | Out-Null }
        else { OpLog '系统设置' $(if ($on) { (T '开启保留的存储') } else { (T '关闭保留的存储') }) '' ''; UI-Log $(if ($on) { (T '保留的存储：已开启') } else { (T '保留的存储：已关闭') }) }
        Load-Save
    })
}
# ---------- 组件存储分析 ----------
Register-BgJob 'csanalyze' -ReadOnly -Done {
    $x = $sync.CsRes
    End-Op (T '完成')
    if ($x -and $x.Ok) {
        $rec = if ($x.Recommended -match '(?i)^(yes|是|true)') { (T '建议清理') } else { (T '不需要清理') }
        $ctl.SaveCsState.Text = (T "当前：资源管理器显示 {0}，实际 {1}（其中和系统共用的 {2}），可回收的旧组件 {3} 个，上次清理 {4}。Windows 的判断：{5}。") -f $x.Reported, $x.Actual, $x.Shared, $x.Reclaimable, $x.LastCleanup, $rec
    } else { $ctl.SaveCsState.Text = (T '没分析成。') + $(if ($x) { ' ' + (($x.Out -split "`r?`n" | Where-Object { $_.Trim() } | Select-Object -Last 2) -join ' ') } else { '' }) }
}
$ctl.BtnCsAnalyze.Add_Click({
    if ($script:worker) { Show-Sheet -Title (T '请等当前操作做完') -Text (T '另一个操作还在进行中。') | Out-Null; return }
    $ctl.SaveCsState.Text = (T '正在分析（DISM，要一两分钟）…')
    Use-BgJob 'csanalyze'; $sync.CsRes = $null
    Start-Op (T '分析组件存储') -NoCard; UI-Busy $true
    Start-Worker @'
$sync.CsRes = Get-ComponentStoreInfo
'@ $null
})
$ctl.BtnCsClean.Add_Click({ Show-Page 'clean'; if (-not $script:rows -and -not $script:worker) { Do-Scan } })
# ---------- 蓝屏转储 ----------
foreach ($b in @($ctl.BtnDumpSmall, $ctl.BtnDumpAuto)) {
    $b.Add_Click({
        $small = [object]::ReferenceEquals($this, $ctl.BtnDumpSmall)
        $t = if ($small) { (T '蓝屏时只保存小转储？') } else { (T '恢复自动转储？') }
        $x = if ($small) { (T '以后蓝屏只保存 256 KB 的小内存转储（C:\Windows\Minidump），够看出是哪个驱动出的问题，不再生成几个 GB 的 MEMORY.DMP。') } else { (T '恢复 Windows 默认的「自动」：蓝屏时可能生成和内存差不多大的 MEMORY.DMP。') }
        $btn = (T '好')
        if ((Show-Sheet -Title $t -Text $x -Buttons @((T '取消'), $btn) -Primary $btn -Cancel (T '取消')) -ne $btn) { return }
        try { Set-CrashDumpMode $(if ($small) { 3 } else { 7 }) } catch { Show-Sheet -Kind warn -Title (T '没改成') -Text (Get-FriendlyError $_) | Out-Null; return }
        OpLog '系统设置' (T '蓝屏转储类型') $(if ($small) { (T '小内存转储') } else { (T '自动') }) ''
        Load-Save
    })
}
# ---------- 临时文件夹位置 ----------
$ctl.BtnTmpMove.Add_Click({
    $d = [string]$ctl.SaveTmpDrive.SelectedItem.Tag
    if (-not $d) { return }
    $p = "$d\CleanC-Temp"
    if ((Test-Path -LiteralPath $p) -and -not (Test-Path -LiteralPath (Join-Path $p '.cleanc-temp')) -and @(Get-ChildItem -LiteralPath $p -Force -ErrorAction SilentlyContinue | Select-Object -First 1).Count -gt 0) {
        Show-Sheet -Kind warn -Title (T '这个文件夹里已经有东西了') -Text ((T "{0} 已经存在，里面有文件，不是本工具建的。临时文件夹会被定期清空，为了不删到你的文件，不用它。换一块盘，或者把这个文件夹改个名字再试。") -f $p) | Out-Null; return
    }
    $ans = Show-Sheet -Kind warn -Title ((T "把临时文件夹改到 {0}？") -f $p) -Text ((T "当前用户的 TEMP 和 TMP 会指向 {0}。以后新打开的程序把临时文件放在那里，注销再登录（或重启）后对所有程序生效。{1} 必须是一直插着的本机硬盘；个别安装程序对 C 盘以外的临时文件夹不兼容，遇到就点「恢复默认」。") -f $p, $d) -Buttons @((T '取消'), (T '改到这块盘')) -Primary (T '改到这块盘') -Cancel (T '取消')
    if ($ans -ne (T '改到这块盘')) { return }
    try {
        New-Item -ItemType Directory -Path $p -Force | Out-Null
        $mk = Join-Path $p '.cleanc-temp'; [IO.File]::WriteAllText($mk, (T '腾挪 ClearC 建的临时文件夹：有这个文件，清理时才会把它当临时文件夹清。')); try { (Get-Item -LiteralPath $mk -Force).Attributes = 'Hidden' } catch {}
        Set-UserTemp $p
    } catch { Show-Sheet -Kind warn -Title (T '没改成') -Text (Get-FriendlyError $_) | Out-Null; return }
    OpLog '系统设置' (T '临时文件夹位置') $p ''
    Load-Save
})
$ctl.BtnTmpAuto.Add_Click({
    if ((Show-Sheet -Title (T '临时文件夹恢复默认？') -Text (T '改回 C 盘用户目录里的 AppData\Local\Temp。注销再登录后对所有程序生效。') -Buttons @((T '取消'), (T '恢复')) -Primary (T '恢复') -Cancel (T '取消')) -ne (T '恢复')) { return }
    try { Set-UserTemp '' } catch { Show-Sheet -Kind warn -Title (T '没改成') -Text (Get-FriendlyError $_) | Out-Null; return }
    OpLog '系统设置' (T '临时文件夹位置') (T '系统默认') ''
    Load-Save
})
# 系统还原点（卷影副本）：只看，不删；要调整打开 Windows 自己的「系统保护」。
# 在另一个线程里读（查卷影副本可能要先启动卷影复制服务，要几秒），读好了再填到页面上
$script:rpQuery = {
    param([string]$drive)
    $r = @{ Ok = $false; Storage = $false; Count = 0; Used = [double]0; Max = [double]0; Unbounded = $false }
    try {
        $vol = @(Get-CimInstance -ClassName Win32_Volume -Filter ("DriveLetter='{0}'" -f $drive) -ErrorAction Stop)[0]
        if (-not $vol) { return $r }
        $r.Ok = $true
        foreach ($s in @(Get-CimInstance -ClassName Win32_ShadowStorage -ErrorAction Stop)) {
            if ($s.Volume -and [string]$s.Volume.DeviceID -eq [string]$vol.DeviceID) {
                $r.Storage = $true; $r.Used += [double]$s.UsedSpace
                if ([double]$s.MaxSpace -le 0 -or [double]$s.MaxSpace -ge 1e18) { $r.Unbounded = $true } else { $r.Max += [double]$s.MaxSpace }
            }
        }
        $r.Count = @(Get-CimInstance -ClassName Win32_ShadowCopy -ErrorAction Stop | Where-Object { [string]$_.VolumeName -eq [string]$vol.DeviceID }).Count
    } catch {}
    return $r
}
$script:rpPs = $null
function Start-RestoreInfo {
    if ($script:rpPs) { return }            # 上一次还没读完
    $ctl.SaveRpState.Text = (T '当前：正在读取…')
    try {
        $ps = [powershell]::Create()
        [void]$ps.AddScript($script:rpQuery.ToString()).AddArgument([string]$env:SystemDrive)
        $script:rpPs = $ps; $script:rpAr = $ps.BeginInvoke()
    } catch { $script:rpPs = $null; $ctl.SaveRpState.Text = (T '当前：读不到还原点的信息'); return }
    $t = New-Object System.Windows.Threading.DispatcherTimer
    $t.Interval = [TimeSpan]::FromMilliseconds(300)
    $t.Add_Tick({
        if (-not $script:rpPs) { $this.Stop(); return }
        if (-not $script:rpAr.IsCompleted) { return }
        $this.Stop()
        $r = $null
        try { $out = $script:rpPs.EndInvoke($script:rpAr); if ($out.Count -gt 0) { $r = $out[$out.Count - 1] } } catch {}
        try { $script:rpPs.Dispose() } catch {}
        $script:rpPs = $null
        Show-RestoreInfo $r
    })
    $t.Start()
}
function Show-RestoreInfo($r) {
    $ctl.SaveRpState.Text = if (-not $r -or -not $r.Ok) { (T '当前：读不到还原点的信息') }
        elseif ($r.Count -eq 0 -and -not $r.Storage) { (T '当前：这块盘没有还原点（可能没有开系统保护）') }
        else { (T "当前：{0} 个还原点和卷影副本，占 {1}，最多可以用到 {2}") -f $r.Count, (Fmt $r.Used), $(if ($r.Unbounded -or $r.Max -le 0) { (T '没有上限') } else { Fmt $r.Max }) }
}
$ctl.BtnRestoreOpen.Add_Click({
    try { Start-Process -FilePath "$env:SystemRoot\System32\SystemPropertiesProtection.exe" } catch { Show-Sheet -Kind warn -Title (T '打不开系统保护设置') -Text (Get-FriendlyError $_) | Out-Null }
})
$ctl.BtnGoDup.Add_Click({ Show-Page 'dup' })
Register-BgJob 'compactos' -Done {
    $x = $sync.CosRes
    End-Op (T '完成')
    if ($x) { $script:pendingDialog = @{ Title = (T '系统压缩完成'); Kind = 'done'; Text = ((T "C 盘可用空间变化：{0}{1}") -f $(if ($x.Delta -ge 0) { (T '多了 ') } else { (T '少了 ') }), (Fmt ([math]::Abs($x.Delta)))) } }
    if ($ctl.PageSave.Visibility -eq 'Visible') { Load-Save }
}
foreach ($b in @($ctl.BtnCosOn, $ctl.BtnCosOff)) {
    $b.Add_Click({
        if ($script:worker) { return }
        $on = [object]::ReferenceEquals($this, $ctl.BtnCosOn)
        $t = if ($on) { (T '开启系统压缩？') } else { (T '关闭系统压缩？') }
        $x = if ($on) { (T 'Windows 会把系统文件压缩存放，通常省 2 到 4 GB。要 10 到 30 分钟，期间可以照常用电脑，不需要重启。') } else { (T '系统文件会解压回原样，C 盘会多用 2 到 4 GB。要 10 到 30 分钟。') }
        $btn = if ($on) { (T '开启') } else { (T '关闭') }
        if ((Show-Sheet -Title $t -Text $x -Buttons @((T '取消'), $btn) -Primary $btn -Cancel (T '取消')) -ne $btn) { return }
        Use-BgJob 'compactos'; $sync.CosRes = $null
        Start-Op $(if ($on) { (T '开启系统压缩') } else { (T '关闭系统压缩') }); UI-Busy $true
        Start-Worker @'
SetP @{ Steps = 1; Step = 1; StepName = 'compact.exe'; SubKind = 'slow'; SubStart = (Get-Date); Detail = '' }
$res = @{}; Invoke-CompactOS ([bool]$arg.On) $res; $sync.CosRes = $res
'@ @{ On = $on }
    })
}
$ctl.BtnPfMove.Add_Click({
    $d = [string]$ctl.SavePfDrive.SelectedItem.Tag
    if (-not $d) { return }
    $ans = Show-Sheet -Kind warn -Title ((T "把页面文件改到 {0} 盘？") -f $d.Substring(0, 1)) -Text ((T "C 盘不再放页面文件，改为放在 {0}\pagefile.sys，大小由系统自动管理。重启后生效，C 盘会多出几个 GB。{0} 必须是一直插着的本机硬盘。") -f $d) -Buttons @((T '取消'), (T '改到这块盘')) -Primary (T '改到这块盘') -Cancel (T '取消')
    if ($ans -ne (T '改到这块盘')) { return }
    $err = Set-PageFile $d
    if ($err) { Show-Sheet -Kind warn -Title (T '没改成') -Text $err | Out-Null } else { Load-Save; Ask-Restart (T '页面文件的新位置要重启电脑后才生效。') }
})
$ctl.BtnPfAuto.Add_Click({
    if ((Show-Sheet -Title (T '页面文件恢复系统默认？') -Text (T '恢复成 Windows 自动管理（通常放在 C 盘）。重启后生效。') -Buttons @((T '取消'), (T '恢复')) -Primary (T '恢复') -Cancel (T '取消')) -ne (T '恢复')) { return }
    $err = Set-PageFile ''
    if ($err) { Show-Sheet -Kind warn -Title (T '没改成') -Text $err | Out-Null } else { Load-Save; Ask-Restart (T '页面文件的设置要重启电脑后才生效。') }
})
foreach ($b in @($ctl.BtnHibReduced, $ctl.BtnHibOff, $ctl.BtnHibFull)) {
    $b.Add_Click({
        $mode = if ([object]::ReferenceEquals($this, $ctl.BtnHibOff)) { 'off' } elseif ([object]::ReferenceEquals($this, $ctl.BtnHibFull)) { 'full' } else { 'reduced' }
        $txt = @{ off = (T '整个删掉休眠文件。睡眠不受影响，但没有「休眠」和「快速启动」了，开机可能慢几秒。'); reduced = (T '休眠文件缩小到一半左右，只保留「快速启动」，开机速度不变，只是不能手动休眠。'); full = (T '恢复完整的休眠功能，休眠文件会变回约等于内存四到七成的大小。') }[$mode]
        if ((Show-Sheet -Title (T '修改休眠设置？') -Text $txt -Buttons @((T '取消'), (T '好')) -Primary (T '好') -Cancel (T '取消')) -ne (T '好')) { return }
        Set-Hiber $mode
        Load-Save
    })
}
$ctl.BtnFolderCompress.Add_Click({
    $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
    $dlg.Description = (T '选择要压缩的文件夹')
    if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { Start-FolderCompress $dlg.SelectedPath }
})
Register-BgJob 'vdisk' -Done {
    $x = $sync.VdRes
    End-Op (T '完成')
    if ($x) {
        $t = if ($x.After -lt $x.Before) { (T "{0} → {1}，省了 {2}。") -f (Fmt $x.Before), (Fmt $x.After), (Fmt ($x.Before - $x.After)) } else { (T "大小没有变化（{0}）。可能里面本来就没有可回收的空间，或者虚拟磁盘还在使用中。`n`n{1}") -f (Fmt $x.After), $x.Out }
        $script:pendingDialog = @{ Title = (T '虚拟磁盘压缩完成'); Kind = $(if ($x.After -lt $x.Before) { 'done' } else { 'info' }); Text = $t }
    }
    Load-Save
}
Register-BgJob 'wslmove' -Done {
    $x = $sync.WslRes
    End-Op $(if ($x -and $x.Ok) { (T '已搬') } else { (T '没搬成') })
    if ($x -and $x.Ok) { $script:pendingDialog = @{ Title = (T 'WSL 发行版已搬到其他盘'); Kind = 'done'; Text = (T '照常用 wsl 打开即可。') } }
    elseif ($x -and $x.Old) { $script:pendingDialog = @{ Title = (T 'WSL 版本太旧'); Kind = 'warn'; Text = ((T "这个 WSL 还没有 --move 命令。在终端里运行 wsl --update 更新 WSL 后再试。`n`n{0}") -f $x.Out) } }
    elseif ($x) { $script:pendingDialog = @{ Title = (T '没搬成'); Kind = 'warn'; Text = $x.Out } }
    if ($ctl.PageSave.Visibility -eq 'Visible') { Load-Save }
}
Register-BgJob 'vmove' -Cancel move -Done {
    $script:candScanned = $false; if ($ctl.PageMoves.Visibility -eq 'Visible') { $script:candPending = $true }
    $res = $sync.VmRes
    $ok = $res -and $res.Done -gt 0
    $cx = $res -and $res.Cancelled -and -not $ok
    End-Op $(if ($ok) { (T "已搬 {0}") -f (GB $res.Moved) } elseif ($cx) { (T '已取消') } else { (T '没搬成') })
    $msg = if ($res -and $res.Msgs) { ($res.Msgs -join "`n") } else { '' }
    $script:pendingDialog = @{ Title = $(if ($ok) { (T '搬好了') } elseif ($cx) { (T '已取消') } else { (T '没搬成') }); Kind = $(if ($ok) { 'done' } elseif ($cx) { 'info' } else { 'warn' }); Text = $(if ($ok) { (T "已搬到 {0}。原位置留了链接，软件照常使用。{1}") -f ($res.Dest -join (T '；')), $msg } else { $msg }) }
    Load-Save; Fill-DestChoices
}
$ctl.VdList.AddHandler([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent, [System.Windows.RoutedEventHandler]{
    param($s, $e)
    $b = $e.OriginalSource
    if (-not ($b -is [System.Windows.Controls.Button]) -or -not ($b.Tag -is [VdiskRow])) { return }
    $r = $b.Tag
    if ($script:worker) { Show-Sheet -Title (T '请等当前操作做完') -Text (T '另一个操作还在进行中。') | Out-Null; return }
    switch ($b.Name) {
        'VdOpen' { Open-Location $r.Path }
        'VdCompact' {
            $apps = @(); if ($r.Kind -eq 'docker') { $apps = @('Docker Desktop') }
            if ($apps) {
                $busy = Get-BusyApps $apps
                if ($busy.Count -gt 0) { Show-Sheet -Kind warn -Title (T '请先退出 Docker Desktop') -Text (T '在任务栏右下角的 Docker 图标上右键，选「Quit Docker Desktop」，再回来压缩。') | Out-Null; return }
            }
            $extra = if ($r.Kind -eq 'wsl' -or $r.Kind -eq 'docker') { (T '压缩前会先关闭所有 WSL（wsl --shutdown），正在 WSL 里运行的程序会被结束。') } else { (T '用这个磁盘的虚拟机要先关掉。') }
            if ((Show-Sheet -Title ((T "压缩「{0}」？") -f $r.Name) -Text ((T "{0}`n`n现在 {1}。{2}压缩不会删除里面的任何数据，只把已经空出来的部分还给 Windows，可能要几分钟。") -f $r.Path, $r.SizeText, $extra) -Buttons @((T '取消'), (T '压缩')) -Primary (T '压缩') -Cancel (T '取消')) -ne (T '压缩')) { return }
            Use-BgJob 'vdisk'; $sync.VdRes = $null
            Start-Op ((T "压缩虚拟磁盘：{0}") -f $r.Name); UI-Busy $true
            Start-Worker @'
SetP @{ Steps = 1; Step = 1; StepName = (Split-Path $arg.Path -Leaf); SubKind = 'slow'; SubStart = (Get-Date); Detail = '' }
$res = @{}; Invoke-CompactVdisk $arg.Path $arg.Kind $res; $sync.VdRes = $res
'@ @{ Path = $r.Path; Kind = $r.Kind }
        }
        'VdMove' {
            $dest = Get-Dest
            if (-not $dest) { Show-Sheet -Kind warn -Title (T '没有可用的搬家目标') -Text (T '请先在「清理 C 盘」页的「搬家目标」里选一块 C 盘以外的硬盘。') | Out-Null; return }
            if ($r.Kind -eq 'wsl') {
                $to = Join-Path (Join-Path $dest 'WSL') $r.Distro
                $ans = Show-Sheet -Title ((T "把 WSL 发行版「{0}」搬到其他盘？") -f $r.Distro) -Text ((T "用 WSL 自己的命令（wsl --manage {0} --move）把它搬到 {1}，现在 {2}。搬之前会先关闭这个发行版，里面正在运行的程序会被结束，请先保存。搬完照常用 wsl 打开，不用改任何设置。需要 WSL 2.5 以后的版本（wsl --update 可以更新）。") -f $r.Distro, $to, $r.SizeText) -Buttons @((T '取消'), (T '搬')) -Primary (T '搬') -Cancel (T '取消')
                if ($ans -ne (T '搬')) { return }
                Use-BgJob 'wslmove'; $sync.WslRes = $null
                Start-Op ((T "搬到其他盘：WSL {0}") -f $r.Distro); UI-Busy $true
                Start-Worker @'
SetP @{ Steps = 1; Step = 1; StepName = $arg.Distro; SubKind = 'slow'; SubStart = (Get-Date); Detail = '' }
$res = @{}; Invoke-WslMove $arg.Distro $arg.Dest $res; $sync.WslRes = $res
OpLog '搬运' (T 'WSL 发行版搬到其他盘') $arg.Distro $(if ($res.Ok) { $arg.Dest } else { (T '没搬成：') + $res.Out })
'@ @{ Distro = $r.Distro; Dest = $to }
                return
            }
            $apps = switch -Wildcard ($r.Name) { (T '安卓*') { @('Android 模拟器') } 'VirtualBox*' { @('VirtualBox') } 'VMware*' { @('VMware') } default { @() } }
            $defs = Get-ChatApps; $k = @(); $dd = @()
            foreach ($a in $apps) { $k += $defs[$a].P; $dd += $defs[$a].Dirs }
            $item = @{ N = $r.Name; Paths = @($r.Path); Apps = $apps; Kill = @($k); KillDirs = @($dd) }
            $cp = Get-ClosePlan @($item) $apps
            $text = (T "{0}（{1}）整个搬到 {2}，原位置留一个链接，软件照常使用。") -f $r.Path, $r.SizeText, $dest
            if ($cp.Names.Count -gt 0) { $text += ((T "`n`n{0} 正在运行，搬之前会替你关掉它们（正在运行的模拟器或虚拟机会被结束）。") -f $cp.Text) }
            if ((Show-Sheet -Title ((T "把「{0}」搬到其他盘？") -f $r.Name) -Text $text -Buttons @((T '取消'), (T '搬')) -Primary (T '搬') -Cancel (T '取消')) -ne (T '搬')) { return }
            $item.Restrict = $true; $item.Allowed = @($cp.Names)
            Use-BgJob 'vmove'; $sync.VmRes = $null
            Start-Op ((T "搬到其他盘：{0}") -f $r.Name); UI-Busy $true
            Start-Worker @'
New-Item -ItemType Directory -Path $arg.Dest -Force | Out-Null
SetP @{ Steps = 1; Step = 1; StepName = $arg.Item.N; StepNote = '' }
$res = @{}; Invoke-Move $arg.Item $arg.Dest $res; $sync.VmRes = $res
'@ @{ Item = $item; Dest = $dest }
        }
    }
})

