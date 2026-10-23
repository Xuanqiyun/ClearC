# ------------------------------------------------------------
# 空间地图
# ------------------------------------------------------------
$script:mapRoot = $null; $script:mapCur = $null; $script:mapView = 'dirs'; $script:growRows = $null; $script:mapScanAt = $null
function Fill-MapDrives {
    $keep = if ($ctl.MapDrive.SelectedItem) { [string]$ctl.MapDrive.SelectedItem.Tag } else { "$env:SystemDrive\" }
    $ctl.MapDrive.Items.Clear()
    foreach ($d in (Fixed-Drives)) {
        $it = New-Object System.Windows.Controls.ComboBoxItem
        $it.Content = (T "{0}  已用 {1} / 共 {2}") -f $d.Name.TrimEnd('\'), (Fmt ($d.TotalSize - $d.AvailableFreeSpace)), (Fmt $d.TotalSize)
        $it.Tag = $d.RootDirectory.FullName
        [void]$ctl.MapDrive.Items.Add($it)
        if ($it.Tag -ieq $keep) { $ctl.MapDrive.SelectedItem = $it }
    }
    if (-not $ctl.MapDrive.SelectedItem -and $ctl.MapDrive.Items.Count -gt 0) { $ctl.MapDrive.SelectedIndex = 0 }
}
# 盘的健康信息（SSD 磨损、温度、通电时间）：在另一个线程里读，读到了写在标题下面
$script:dhPs = $null
# 在后台线程里跑一段引擎代码（不占主工作线程、不显示进度条），完成后在界面线程里回调。同一个 key 同时只跑一个
$script:bg = @{}
function Start-BgEngine([string]$key, [string]$code, $arg, [scriptblock]$done) {
    if ($script:bg[$key]) { return $false }
    $ps = $null
    try {
        $ps = [powershell]::Create()
        [void]$ps.AddScript("param(`$arg, `$engine)`nInvoke-Expression `$engine`n" + $code).AddArgument($arg).AddArgument($engine)
        $script:bg[$key] = @{ PS = $ps; AR = $ps.BeginInvoke(); Done = $done; Key = $key }
    } catch { Write-LogFile ("bg {0}: {1}" -f $key, $_.Exception.Message); if ($ps) { try { $ps.Dispose() } catch {} }; return $false }
    $t = New-Object System.Windows.Threading.DispatcherTimer
    $t.Interval = [TimeSpan]::FromMilliseconds(400); $t.Tag = $key
    $t.Add_Tick({
        $k = [string]$this.Tag; $j = $script:bg[$k]
        if (-not $j) { $this.Stop(); return }
        if (-not $j.AR.IsCompleted) { return }
        $this.Stop()
        $result = $null; $err = ''
        try { $out = $j.PS.EndInvoke($j.AR); if ($out.Count -gt 0) { $result = $out[$out.Count - 1] } } catch { $err = [string]$_.Exception.Message }
        try { foreach ($er in @($j.PS.Streams.Error | Select-Object -First 3)) { $err += ' | ' + [string]$er } } catch {}
        if ($err) { Write-LogFile ("bg {0}: {1}" -f $k, $err) }
        try { $j.PS.Dispose() } catch {}
        $script:bg.Remove($k)
        if ($j.Done) { try { & $j.Done $result $err } catch { Write-LogFile ("bg {0} done: {1}" -f $k, $_.Exception.Message) } }
    })
    $t.Start()
    return $true
}
function Stop-BgEngine([string]$key) { $j = $script:bg[$key]; if ($j) { try { $j.PS.Stop() } catch {} } }
function Start-DiskHealth {
    if ($script:dhPs) { return }
    $ctl.MapHealthNote.Text = (T '正在读取各块盘的健康信息…'); $ctl.MapHealthNote.Visibility = 'Visible'
    $drives = @(Fixed-Drives | ForEach-Object { $_.Name.TrimEnd('\') })
    if ($drives.Count -eq 0) { return }
    $code = 'param($drives, $engine) Invoke-Expression $engine; $o = @(); foreach ($d in $drives) { $h = Get-DiskHealthInfo $d; $h.Drive = $d; $o += $h }; ,$o'
    try {
        $ps = [powershell]::Create()
        [void]$ps.AddScript($code).AddArgument($drives).AddArgument($engine)
        $script:dhPs = $ps; $script:dhAr = $ps.BeginInvoke()
    } catch { $script:dhPs = $null; return }
    $t = New-Object System.Windows.Threading.DispatcherTimer
    $t.Interval = [TimeSpan]::FromMilliseconds(400)
    $t.Add_Tick({
        if (-not $script:dhPs) { $this.Stop(); return }
        if (-not $script:dhAr.IsCompleted) { return }
        $this.Stop()
        $lines = @(); $script:dhErr = ''
        try { $out = $script:dhPs.EndInvoke($script:dhAr); if ($out.Count -gt 0) { $lines = @($out[$out.Count - 1]) } } catch { $script:dhErr = [string]$_.Exception.Message }
        try { foreach ($er in @($script:dhPs.Streams.Error | Select-Object -First 3)) { $script:dhErr += ' | ' + [string]$er } } catch {}
        if ($script:dhErr) { Write-LogFile ('disk health: ' + $script:dhErr) }
        try { $script:dhPs.Dispose() } catch {}
        $script:dhPs = $null
        Show-DiskHealth $lines
    })
    $t.Start()
}
# 每块盘一张卡片。档位：温度 45 度以下绿、60 以下橙、再高红；磨损 10% 以下绿、50% 以下橙；用量 85% 以上橙、95% 以上红
function Show-DiskHealth($list) {
    $col = New-Object 'System.Collections.ObjectModel.ObservableCollection[DiskCard]'
    $green = @('#1D7A35', '#E5F4E9'); $amber = @('#995700', '#FFF1DB'); $red = @('#C0101C', '#FDEBEC'); $grey = @('#6E6E73', '#F0F0F3')
    foreach ($h in @($list)) {
        if (-not $h -or -not $h.Drive) { continue }
        $c = New-Object DiskCard
        $c.Letter = [string]$h.Drive
        $c.Model = if ($h.Ok -and $h.Model) { $h.Model + $(if ($h.Media) { ' · ' + $h.Media } else { '' }) } else { (T '读不到型号和健康信息') }
        $used = [double]0; $total = [double]0
        try { $di = New-Object System.IO.DriveInfo ([string]$h.Drive + '\'); $total = [double]$di.TotalSize; $used = $total - [double]$di.AvailableFreeSpace } catch {}
        $pct = if ($total -gt 0) { 100.0 * $used / $total } else { 0 }
        $c.UsedPct = $pct; $c.BarW = [math]::Round(266.0 * $pct / 100.0)
        $c.UsedText = (T "已用 {0} / 共 {1}（{2:N0}%），剩 {3}") -f (Fmt $used), (Fmt $total), $pct, (Fmt ($total - $used))
        $c.BarBrush = if ($pct -ge 95) { '#FF3B30' } elseif ($pct -ge 85) { '#FF9F0A' } else { '#0071E3' }
        $worst = 0   # 0 绿 1 橙 2 红
        if ($h.Ok -and $h.Health) {
            $okh = ($h.Health -eq 'Healthy')
            $c.HealthText = if ($okh) { (T '健康') } else { ((T "健康状态：{0}") -f $h.Health) }
            $tone = if ($okh) { $green } else { $red }; if (-not $okh) { $worst = 2 }
        } else { $c.HealthText = (T '健康状态未知'); $tone = $grey }
        $c.HealthFg = $tone[0]; $c.HealthBg = $tone[1]
        if ($h.Ok -and $h.Temp -gt 0) {
            $c.TempText = (T "{0} °C") -f $h.Temp
            $tone = if ($h.Temp -gt 60) { $red } elseif ($h.Temp -gt 45) { $amber } else { $green }
            if ($h.Temp -gt 60) { $worst = [math]::Max($worst, 2) } elseif ($h.Temp -gt 45) { $worst = [math]::Max($worst, 1) }
            $c.TempFg = $tone[0]; $c.TempBg = $tone[1]
        }
        if ($h.Ok -and $h.Wear -ge 0) {
            $c.WearText = (T "磨损 {0}%") -f $h.Wear
            $tone = if ($h.Wear -gt 50) { $red } elseif ($h.Wear -gt 10) { $amber } else { $green }
            if ($h.Wear -gt 50) { $worst = [math]::Max($worst, 2) } elseif ($h.Wear -gt 10) { $worst = [math]::Max($worst, 1) }
            $c.WearFg = $tone[0]; $c.WearBg = $tone[1]
        }
        if ($h.Ok -and $h.Hours -gt 0) { $c.HoursText = (T "通电 {0:N0} 小时") -f $h.Hours }
        $c.Stripe = if (-not $h.Ok) { '#C7C7CC' } elseif ($worst -eq 2) { '#FF3B30' } elseif ($worst -eq 1) { '#FF9F0A' } else { '#34C759' }
        $tip = @((T '点一下扫描这块盘，下面显示它的详细情况。'))
        if ($h.Ok) {
            $tip += (T '温度：45 °C 以下正常，60 °C 以上偏高，长期高温会缩短固态硬盘寿命。')
            $tip += (T '磨损：固态硬盘已用掉的写入寿命，到 100% 厂商就不保了；10% 以下很新，50% 以上要开始考虑备份。')
            if ($h.ReadErrors -gt 0) { $tip += ((T "读错误 {0:N0} 次，有读错误请尽快备份。") -f $h.ReadErrors) }
            $tip += (T '这些数据从 Windows 的存储可靠性计数器读，只读不改；有的硬盘不报温度或磨损。')
        } else { $tip += (T '这台电脑的存储模块读不到这块盘的信息。') }
        $c.Tip = ($tip -join "`n")
        $col.Add($c)
    }
    $ctl.MapHealth.ItemsSource = $col
    Update-MapCardSel
    $ctl.MapHealthNote.Visibility = if ($col.Count -gt 0) { 'Collapsed' } else { 'Visible' }
    if ($col.Count -eq 0) { $ctl.MapHealthNote.Text = (T '读不到磁盘的健康信息（型号、磨损、温度）') }
}
# 选中的盘：卡片描边跟着下拉框走
function Update-MapCardSel {
    $sel = if ($ctl.MapDrive.SelectedItem) { ([string]$ctl.MapDrive.SelectedItem.Tag).TrimEnd('\') } else { '' }
    $any = $false
    foreach ($c in @($ctl.MapHealth.ItemsSource)) { if (-not $c) { continue }; $on = $sel -and ([string]$c.Letter).TrimEnd('\') -ieq $sel; if ($c.Sel -ne $on) { $c.Sel = $on; $any = $true } }
    if ($any) { try { $ctl.MapHealth.Items.Refresh() } catch {} }
}
$ctl.MapDrive.Add_SelectionChanged({ Update-MapCardSel })
# 点卡片 = 选这块盘并扫描它（已经显示的就是这块盘时不重扫；正在忙别的就只选上）
function Select-MapDriveCard([string]$letter, [bool]$scan = $true) {
    $hit = $null
    foreach ($it in $ctl.MapDrive.Items) { if (([string]$it.Tag).StartsWith($letter, [StringComparison]::OrdinalIgnoreCase)) { $hit = $it } }
    if (-not $hit) { return }
    $ctl.MapDrive.SelectedItem = $hit
    if (-not $scan) { return }
    $root = [string]$hit.Tag
    $shown = if ($script:mapRoot) { try { $script:mapRoot.FullPath() } catch { '' } } else { '' }
    if ($shown -and $shown.TrimEnd('\') -ieq $root.TrimEnd('\')) { UI-Log ((T "空间地图：下面已经是 {0} 的结果；要重新扫描点「扫描」") -f $root.TrimEnd('\')); return }
    if ($script:worker) { UI-Log (T '空间地图：正在忙别的，等它做完再点「扫描」'); return }
    if ($script:uiTest) { $script:uiOpened.Add('scan:' + $root); return }
    Start-MapScan $root
}
$ctl.MapHealth.AddHandler([System.Windows.UIElement]::MouseLeftButtonUpEvent, [System.Windows.Input.MouseButtonEventHandler]{
    param($s, $e)
    $el = $e.OriginalSource
    while ($el -and -not ($el -is [System.Windows.Controls.Border] -and $el.Tag -is [DiskCard])) { $el = [System.Windows.Media.VisualTreeHelper]::GetParent($el) }
    if (-not $el) { return }
    Select-MapDriveCard ([string]$el.Tag.Letter) $true
})
function Start-MapScan([string]$root) {
    if ($script:worker -or -not $root) { return }
    $di = $null; try { $di = New-Object System.IO.DriveInfo $root } catch {}
    $sync.MapUsed = if ($di) { [double]($di.TotalSize - $di.AvailableFreeSpace) } else { [double]0 }
    $sync.MapRoot = $root; $sync.MapResult = $null; $sync.MapMethod = ''; $sync.MapNote = ''
    [DiskMap]::Cancel = $false
    $sync.Mode = 'map'
    Start-Op ((T "扫描 {0}") -f $root)
    UI-Busy $true; $ctl.BtnMapStop.IsEnabled = $true
    $ctl.EmptyMap.Visibility = 'Visible'; $ctl.EmptyMapText.Text = (T '正在扫描…')
    $ctl.MapList.ItemsSource = $null; $ctl.MapGrow.ItemsSource = $null; $ctl.BtnMapExport.IsEnabled = $false; $ctl.BtnMapReport.IsEnabled = $false
    $ctl.MapTree.Children.Clear()
    UI-Log ((T "空间地图：开始扫描 {0}") -f $root)
    Start-Worker @'
# 能读文件表（MFT）就读；读不了再逐个文件夹扫一遍
$sync.MapResult = [DiskMap]::GetTree($arg.Root, [DirStat]::ThreadsFor($arg.Root), $true, $true)
$sync.MapMethod = [string][DiskMap]::LastMethod; $sync.MapMs = [double][DiskMap]::LastMs; $sync.MapNote = [string][DiskMap]::LastNote
'@ @{ Root = $root }
}
$ctl.BtnMapScan.Add_Click({ if ($ctl.MapDrive.SelectedItem) { Start-MapScan ([string]$ctl.MapDrive.SelectedItem.Tag) } })
$ctl.BtnMapStop.Add_Click({ [DiskMap]::Cancel = $true; UI-Log (T '空间地图：正在停止…') })

function New-MapRow($name, $path, [double]$size, [double]$max, [double]$parent, [bool]$isDir, $node, [string]$meta, [string]$kind) {
    $r = New-Object MapRow
    $r.Name = $name; $r.Path = $path; $r.Size = [long]$size; $r.SizeText = Fmt $size; $r.IsDir = $isDir; $r.Node = $node; $r.Meta = $meta; $r.Disk = -1; $r.Kind = $kind
    $r.Bar = if ($max -gt 0) { [math]::Max([double]2, 160.0 * $size / $max) } else { 0 }
    if ($size -le 0) { $r.Bar = 0 }
    $r.Pct = if ($parent -gt 0) { "{0:N1}%" -f (100.0 * $size / $parent) } else { '' }
    switch ($kind) {
        'dir'  { $r.Glyph = [string][char]0xE8B7; $r.GlyphBrush = '#0A84FF' }
        'link' { $r.Glyph = [string][char]0xE71B; $r.GlyphBrush = '#8E8E93' }
        'more' { $r.Glyph = [string][char]0xE712; $r.GlyphBrush = '#8E8E93' }
        'type' { $r.Glyph = [string][char]0xE8FD; $r.GlyphBrush = '#0A84FF' }
        'recent' { $r.Glyph = [string][char]0xE823; $r.GlyphBrush = '#0A84FF' }
        default { $r.Glyph = [string][char]0xE8A5; $r.GlyphBrush = '#8E8E93' }
    }
    $why = if ($path -and $kind -ne 'type' -and $kind -ne 'recent') { Get-DeleteBlock $path } else { '' }
    if (-not $why -and $path -and (Test-ChatPath $path)) { $why = (T '聊天记录里的文件只能查看和打开位置；要腾地方，到「搬家管理」把整个聊天记录搬到其他盘') }
    if ($kind -eq 'type' -or $kind -eq 'recent') { $why = (T '这一行是统计，不是文件；双击查看') }
    $r.Locked = [bool]$why; $r.LockTip = $why
    if ($path -and $script:mapMarks -and $script:mapMarks.Contains((Get-MarkKey $r))) { $r.Marked = $true }
    return $r
}
# 路径在不在某个聊天软件的聊天记录文件夹里（这些只看不删，要腾地方就整体搬家）
function Test-ChatPath([string]$path) {
    if ($null -eq $script:chatDirs) {
        $script:chatDirs = New-Object System.Collections.Generic.List[string]
        foreach ($pat in @('*WhatsAppDesktop*', 'MSTeams*', 'FACEBOOK.317180B0BB486*', '*TelegramDesktop*', '*Signal*', '*LINE*')) {
            foreach ($d in @(Get-ChildItem -LiteralPath (Join-Path $env:LOCALAPPDATA 'Packages') -Directory -Filter $pat -Force -ErrorAction SilentlyContinue)) { $script:chatDirs.Add($d.FullName.TrimEnd('\')) }
        }
        foreach ($c in $catalog) {
            if (-not ([string]$c.G).StartsWith('聊天软件') -or -not $c.Paths) { continue }
            foreach ($p in $c.Paths) { if ($p) { foreach ($it in @(Get-PathItems $p)) { if ($it.PSIsContainer) { $script:chatDirs.Add($it.FullName.TrimEnd('\')) } } } }
        }
    }
    $p = $path.TrimEnd('\')
    foreach ($d in $script:chatDirs) { if ($p -ieq $d -or $p.StartsWith($d + '\', [StringComparison]::OrdinalIgnoreCase)) { return $true } }
    return $false
}
# 实际占用和硬链接的说明（快速扫描读文件表时才知道；设置里可以关掉）
function Get-DiskNote([double]$size, [double]$disk, [double]$shared, [bool]$isFile) {
    $t = ''
    if ($isFile -and $shared -gt 0) { $t += (T ' · 硬链接：别处还有同一份，删了这个不腾空间') }
    elseif (-not $isFile -and $shared -ge 32MB -and $shared -ge $size * 0.05) { $t += (T " · 其中 {0} 是硬链接（别处还有同一份）") -f (Fmt $shared) }
    if ($disk -ge 0 -and ($size - $disk) -ge 32MB -and $disk -lt $size * 0.85) { $t += (T " · 实际只占 {0}") -f (Fmt $disk) }
    return $t
}
# 文件大小、实际占用、压缩后大小：NTFS 压缩过的文件，实际占用就是压缩后的大小
function Get-SizeNote([string]$path, [double]$size, [double]$disk, [double]$shared) {
    if ($disk -lt 0 -or ($size - $disk) -lt 32MB -or $disk -ge $size * 0.85) { return Get-DiskNote $size $disk $shared $true }
    if ($path -and [FsTools]::IsCompressed($path)) { return (T " · NTFS 压缩后 {0}（文件大小 {1}）") -f (Fmt $disk), (Fmt $size) }
    return Get-DiskNote $size $disk $shared $true
}
# 同一个列表重新列一遍时（改了设置、删完、方块图和文件夹之间切换、找文件改条件），原来选中的还选着
function Get-MapKeep([string]$key) {
    $keep = @{}
    if ($script:mapListKey -eq $key) { foreach ($x in @($ctl.MapList.SelectedItems)) { if ($x.Path) { $keep[([string]$x.Path).ToLowerInvariant()] = $true } } }
    $script:mapListKey = $key
    return $keep
}
function Restore-MapKeep($keep) {
    if ($keep.Count -eq 0) { return }
    $script:bulkSel = $true
    try { foreach ($x in @($ctl.MapList.Items)) { if ($x.Path -and $keep.ContainsKey(([string]$x.Path).ToLowerInvariant())) { [void]$ctl.MapList.SelectedItems.Add($x) } } }
    finally { $script:bulkSel = $false }
}
function Show-MapLevel($node) {
    if (-not $node) { return }
    $keep = Get-MapKeep ('dirs|' + $node.FullPath())
    # 换了文件夹：记下刚才在哪，好「后退」；后退、前进自己不记
    if ($script:mapCur -and -not [object]::ReferenceEquals($script:mapCur, $node) -and -not $script:mapNavQuiet) {
        $script:mapBack.Add($script:mapCur); if ($script:mapBack.Count -gt 50) { $script:mapBack.RemoveAt(0) }
        $script:mapFwd.Clear()
    }
    $script:mapCur = $node
    $dn = Get-Flag 'MapDisk'
    $hasDisk = $dn -and $script:mapRoot -and $script:mapRoot.HasDisk
    $path = $node.FullPath()
    $rows = New-Object System.Collections.Generic.List[MapRow]
    # 只列最大的 500 项（子文件夹和这一层自己的文件放在一起比），其余合成一行：上万项的文件夹（比如 WinSxS）也能马上打开
    $cap = 500
    $kids = [DiskMap]::TopKids($node, $cap)
    $files = [DiskMap]::TopFiles($path, 300)   # 这一层自己的文件：现场列一下
    $sorted = New-Object System.Collections.ArrayList
    $i = 0; $j = 0
    while ($sorted.Count -lt $cap -and ($i -lt $kids.Count -or $j -lt $files.Count)) {
        if ($j -ge $files.Count -or ($i -lt $kids.Count -and $kids[$i].Size -ge $files[$j].Size)) { [void]$sorted.Add(@{ K = $kids[$i]; S = [double]$kids[$i].Size }); $i++ }
        else { [void]$sorted.Add(@{ F = $files[$j]; S = [double]$files[$j].Size }); $j++ }
    }
    $restN = [long]($node.Kids.Count - $i) + [math]::Max([long]0, [long]$node.OwnFiles - $j)
    $restB = [double]$node.Size; foreach ($x in $sorted) { $restB -= $x.S }
    $max = if ($sorted.Count -gt 0) { [double]$sorted[0].S } else { 0 }
    foreach ($x in $sorted) {
        if ($x.K) {
            $k = $x.K; $p = $k.FullPath()
            if ($k.IsLink) {
                $t = LinkTarget $p
                [void]$rows.Add((New-MapRow $k.Name $p 0 $max $node.Size $false $k ((T "链接，指向 ") + $(if ($t) { $t } else { (T '其他位置') }) + (T "（多半是搬家留下的，不占这块盘）")) 'link'))
                continue
            }
            $when = if ($k.LastWrite -gt 0) { try { [DateTime]::FromFileTime($k.LastWrite).ToString('yyyy-MM-dd') } catch { '' } } else { '' }
            $meta = (T "{0:N0} 个文件") -f $k.Files
            if ($when) { $meta += ((T " · 最近修改 {0}") -f $when) }
            if ($script:prevSnap -and $script:prevSnap.Count -gt 0) {
                $key = $p.ToLowerInvariant()
                if ($script:prevSnap.ContainsKey($key)) {
                    $dd = [double]$k.Size - [double]$script:prevSnap[$key]
                    if ([math]::Abs($dd) -ge 10MB) { $meta += ((T " · 比上次 {0}") -f ($(if ($dd -gt 0) { '+' } else { '−' }) + (Fmt ([math]::Abs($dd))))) }
                }
            }
            if ($k.Denied) { $meta += (T ' · 部分内容没有权限读取') }
            if ($hasDisk) { $meta += Get-DiskNote ([double]$k.Size) ([double]$k.Disk) ([double]$k.Shared) $false }
            $row = New-MapRow $k.Name $p $k.Size $max $node.Size $true $k $meta 'dir'
            $row.When = $when; $row.FileCount = [long]$k.Files
            if ($script:mapRoot.HasDisk) { $row.Disk = [long]$k.Disk }
            [void]$rows.Add($row)
        } else {
            $f = $x.F
            $fm = (T "文件 · 修改于 {0:yyyy-MM-dd}") -f $f.Modified
            $fd = [double]$f.Disk
            # 目录里记的实际占用看着明显小（压缩、稀疏、只在云端）：再问一次 Windows，以它为准
            if ($fd -ge 0 -and ([double]$f.Size - $fd) -ge 32MB) { $fd = [double][FsTools]::OnDisk($f.Path) }
            if ($dn) { $fm += Get-SizeNote $f.Path ([double]$f.Size) $fd 0 }
            $row = New-MapRow $f.Name $f.Path $f.Size $max $node.Size $false $null $fm 'file'
            $row.When = '{0:yyyy-MM-dd HH:mm}' -f $f.Modified
            $row.Disk = [long]$fd
            [void]$rows.Add($row)
        }
    }
    if ($restN -gt 0) {
        $more = New-MapRow ((T "其余 {0:N0} 项") -f $restN) '' ([math]::Max([double]0, $restB)) $max $node.Size $false $null (T '这里只列出最大的 500 项；其余的可以点「打开位置」在资源管理器里看') 'more'
        $more.Locked = $true; $more.LockTip = (T '这一行是合在一起的其余项目'); $more.IsSummary = $true
        $more.Bar = [math]::Min([double]160, $more.Bar)
        [void]$rows.Add($more)
    }
    $ctl.MapList.ItemsSource = $rows
    Restore-MapKeep $keep
    $ctl.MapPath.Text = $path
    Show-MapCrumbs $node
    $ctl.MapInfo.Text = (T "这一层共 {0}，{1:N0} 个文件{2}") -f (Fmt $node.Size), $node.Files, $(if ($script:mapScanAt) { (T " · 扫描于 {0:HH:mm}（{1}）") -f $script:mapScanAt, $script:mapHow } else { '' })
    if ($script:mapView -eq 'tree') { $ctl.MapInfo.Text += (T ' · 点方块就是选中下面列表里的那一行，列表里选中的方块会描边；双击进入') }
    $ctl.BtnMapAcct.Visibility = if ($script:mapRoot -and $script:mapRoot.HasDisk -and (Get-Mode) -ge 2) { 'Visible' } else { 'Collapsed' }
    $ctl.BtnMapUp.IsEnabled = ($null -ne $node.Parent)
    $ctl.BtnMapBack.IsEnabled = $script:mapBack.Count -gt 0; $ctl.BtnMapFwd.IsEnabled = $script:mapFwd.Count -gt 0
    $ctl.EmptyMap.Visibility = if ($rows.Count -gt 0) { 'Collapsed' } else { 'Visible' }
    if ($rows.Count -eq 0) { $ctl.EmptyMapText.Text = (T '这个文件夹是空的') }
    $ctl.BtnMapExport.IsEnabled = ($rows.Count -gt 0)
    $ctl.BtnMapReport.IsEnabled = $true
    if ($script:mapView -eq 'tree') { Draw-MapTree }
    Show-MapOverview
    Update-MapSel
}
# ---------- 后退 / 前进 / 上一级，路径上的每一层都能点（参考 disktree） ----------
$script:mapBack = New-Object System.Collections.Generic.List[object]; $script:mapFwd = New-Object System.Collections.Generic.List[object]; $script:mapNavQuiet = $false
function Reset-MapHistory { $script:mapBack.Clear(); $script:mapFwd.Clear(); $ctl.BtnMapBack.IsEnabled = $false; $ctl.BtnMapFwd.IsEnabled = $false }
function Move-MapHistory([int]$dir) {
    # 直接赋值（不用 if 表达式）：if 表达式会把列表展开成固定大小的数组，RemoveAt 就会出错
    if ($dir -lt 0) { $from = $script:mapBack; $to = $script:mapFwd } else { $from = $script:mapFwd; $to = $script:mapBack }
    if ($from.Count -eq 0 -or -not $script:mapCur) { return }
    $n = $from[$from.Count - 1]; $from.RemoveAt($from.Count - 1)
    $to.Add($script:mapCur)
    if ($script:mapView -ne 'dirs' -and $script:mapView -ne 'tree') { $ctl.MapViewDirs.IsChecked = $true }
    $script:mapNavQuiet = $true
    try { Show-MapLevel $n } finally { $script:mapNavQuiet = $false }
}
function Go-MapUp { if ($script:mapCur -and $script:mapCur.Parent) { Show-MapLevel $script:mapCur.Parent } }
$ctl.BtnMapBack.Add_Click({ Move-MapHistory -1 })
$ctl.BtnMapFwd.Add_Click({ Move-MapHistory 1 })
# 鼠标的后退、前进侧键；Alt+← / Alt+→；Backspace 上一级（在输入框里打字时不管）
$ctl.PageMap.Add_PreviewMouseDown({
    param($s, $e)
    if ($e.ChangedButton -eq [System.Windows.Input.MouseButton]::XButton1) { Move-MapHistory -1; $e.Handled = $true }
    elseif ($e.ChangedButton -eq [System.Windows.Input.MouseButton]::XButton2) { Move-MapHistory 1; $e.Handled = $true }
})
$ctl.PageMap.Add_PreviewKeyDown({
    param($s, $e)
    if ([System.Windows.Input.Keyboard]::FocusedElement -is [System.Windows.Controls.TextBox]) { return }
    $alt = ([System.Windows.Input.Keyboard]::Modifiers -band [System.Windows.Input.ModifierKeys]::Alt) -ne 0
    $k = if ($e.Key -eq [System.Windows.Input.Key]::System) { $e.SystemKey } else { $e.Key }
    if ($alt -and $k -eq [System.Windows.Input.Key]::Left) { Move-MapHistory -1; $e.Handled = $true }
    elseif ($alt -and $k -eq [System.Windows.Input.Key]::Right) { Move-MapHistory 1; $e.Handled = $true }
    elseif (-not $alt -and $k -eq [System.Windows.Input.Key]::Back -and ($script:mapView -eq 'dirs' -or $script:mapView -eq 'tree')) { Go-MapUp; $e.Handled = $true }
})
# 路径：每一层一个按钮，最多显示最后 6 层（前面的用「…」代替，点「…」回到再上一层）
function Show-MapCrumbs($node) {
    $cr = $ctl.MapCrumbs; $cr.Children.Clear()
    $chain = New-Object System.Collections.Generic.List[object]
    for ($n = $node; $n; $n = $n.Parent) { $chain.Insert(0, $n) }
    $start = [math]::Max(0, $chain.Count - 6)
    $link = $win.FindResource('LinkButton')
    $add = {
        param([string]$text, $target, [bool]$last)
        if ($cr.Children.Count -gt 0) { $sep = New-Object System.Windows.Controls.TextBlock; $sep.Text = '›'; $sep.Foreground = New-Brush '#86868B'; $sep.Margin = New-Object System.Windows.Thickness 5, 0, 5, 0; $sep.VerticalAlignment = 'Center'; [void]$cr.Children.Add($sep) }
        if ($last) { $t = New-Object System.Windows.Controls.TextBlock; $t.Text = $text; $t.FontWeight = 'SemiBold'; $t.VerticalAlignment = 'Center'; $t.TextTrimming = 'CharacterEllipsis'; $t.MaxWidth = 260; [void]$cr.Children.Add($t); return }
        $b = New-Object System.Windows.Controls.Button; $b.Style = $link; $b.Content = $text; $b.Tag = $target; $b.VerticalAlignment = 'Center'; $b.ToolTip = $target.FullPath()
        $b.Add_Click({ $script:mapCrumbHit = $this.Tag; if ($script:mapView -ne 'dirs' -and $script:mapView -ne 'tree') { $ctl.MapViewDirs.IsChecked = $true }; Show-MapLevel $this.Tag })
        [void]$cr.Children.Add($b)
    }
    if ($start -gt 0) { & $add '…' $chain[$start - 1] $false }
    for ($i = $start; $i -lt $chain.Count; $i++) {
        $n = $chain[$i]; $nm = [string]$n.Name; if ($i -eq 0) { $nm = $nm.TrimEnd('\') }
        & $add $nm $n ($i -eq $chain.Count - 1)
    }
    $cr.Visibility = 'Visible'; $ctl.MapPath.Visibility = 'Collapsed'
}
# ---------- 待删清单：在不同文件夹里挑要删的，先放进清单，一直看得见删完以后还剩多少，看过清单再一起删（参考 disktree） ----------
# 放进一个文件夹时，清单里它里面的项目合进它；已经在清单里的文件夹里面的东西不再单独放
$script:mapMarks = [ordered]@{}
function Get-MarkKey($r) { ([string]$r.Path).TrimEnd('\').ToLowerInvariant() }
function Add-MapMarks($rows) {
    $added = 0; $inside = 0
    foreach ($r in @($rows)) {
        if (-not $r -or $r.Locked -or $r.IsSummary -or -not $r.Path -or $r.Size -le 0 -or ($r.Kind -ne 'dir' -and $r.Kind -ne 'file')) { continue }
        $k = Get-MarkKey $r
        if ($script:mapMarks.Contains($k)) { continue }
        $up = $false; foreach ($m in @($script:mapMarks.Keys)) { if ($k.StartsWith($m + '\')) { $up = $true; break } }
        if ($up) { $inside++; continue }
        foreach ($m in @($script:mapMarks.Keys)) { if ($m.StartsWith($k + '\')) { $script:mapMarks[$m].Marked = $false; $script:mapMarks.Remove($m) } }
        $script:mapMarks[$k] = $r; $r.Marked = $true; $added++
    }
    Update-MapMarks
    if ($inside -gt 0) { $ctl.MapSel.Text = (T "{0} 项所在的文件夹已经在待删清单里，不用再单独放") -f $inside }
    return $added
}
function Remove-MapMarks($rows) {
    foreach ($r in @($rows)) { if (-not $r -or -not $r.Path) { continue }; $k = Get-MarkKey $r; if ($script:mapMarks.Contains($k)) { $script:mapMarks[$k].Marked = $false; $script:mapMarks.Remove($k) }; $r.Marked = $false }
    Update-MapMarks
}
function Clear-MapMarks { foreach ($m in @($script:mapMarks.Values)) { $m.Marked = $false }; $script:mapMarks.Clear(); Update-MapMarks }
# 清单里的东西删掉能腾出多少：知道实际占用的按实际占用算
function Get-MarkBytes($r) { if ($r.Disk -ge 0 -and $script:mapRoot -and $script:mapRoot.HasDisk) { [double]$r.Disk } else { [double]$r.Size } }
function Update-MapMarks {
    $n = $script:mapMarks.Count
    # 列表里现在显示的行（换过文件夹再回来是新的行）跟着清单走：清空、去掉、合进上级文件夹以后不再标「待删」
    foreach ($x in @($ctl.MapList.Items)) { if ($x -is [MapRow] -and $x.Path) { $want = ($n -gt 0 -and $script:mapMarks.Contains((Get-MarkKey $x))); if ([bool]$x.Marked -ne $want) { $x.Marked = $want } } }
    $ctl.MapMarkBar.Visibility = if ($n -gt 0) { 'Visible' } else { 'Collapsed' }
    if ($n -eq 0) { return }
    $tot = [double]0; $byDrive = @{}
    foreach ($r in @($script:mapMarks.Values)) { $b = Get-MarkBytes $r; $tot += $b; $d = ([string]$r.Path).Substring(0, 2).ToUpperInvariant(); $byDrive[$d] = [double]$byDrive[$d] + $b }
    $parts = @(foreach ($d in @($byDrive.Keys | Sort-Object)) { $free = DriveFree ($d + '\'); (T "{0} 现在空闲 {1}，删完约 {2}") -f $d, (Fmt $free), (Fmt ($free + $byDrive[$d])) })
    $ctl.MapMarkText.Text = ((T "待删清单：{0} 项，共 {1}。") -f $n, (Fmt $tot)) + ($parts -join (T '；')) + (T '（放进回收站的，清空回收站后才腾出来）')
    $ctl.BtnMarkDelete.IsEnabled = -not $script:worker
}
function Show-MapMarks {
    if ($script:mapMarks.Count -eq 0) { return }
    $items = @(@($script:mapMarks.Values) | Sort-Object { -(Get-MarkBytes $_) } | Select-Object -First 60 | ForEach-Object { (T "{0}（{1}）") -f $_.Path, (Fmt (Get-MarkBytes $_)) })
    if ($script:mapMarks.Count -gt 60) { $items += ((T "……另有 {0} 项") -f ($script:mapMarks.Count - 60)) }
    $ans = Show-Sheet -Title ((T "待删清单（{0} 项）") -f $script:mapMarks.Count) -Text ($ctl.MapMarkText.Text + "`n`n" + (T '要去掉某一项：在列表里选中它，右键「从待删清单去掉」。')) -Items $items -Buttons @((T '关闭清单'), (T '清空清单'), (T '删除清单里的…')) -Primary (T '关闭清单') -Cancel (T '关闭清单')
    if ($ans -eq (T '清空清单')) { Clear-MapMarks } elseif ($ans -eq (T '删除清单里的…')) { Start-MapDelete @($script:mapMarks.Values) }
}
$ctl.BtnMarkShow.Add_Click({ Show-MapMarks })
$ctl.BtnMarkClear.Add_Click({ Clear-MapMarks })
$ctl.BtnMarkDelete.Add_Click({ if ($script:mapMarks.Count -gt 0) { Start-MapDelete @($script:mapMarks.Values) } })
$ctl.BtnMapMark.Add_Click({ $sel = @($ctl.MapList.SelectedItems); if (@($sel | Where-Object { -not $_.Marked }).Count -eq 0) { Remove-MapMarks $sel } else { [void](Add-MapMarks $sel) }; Update-MapSel })
$ctl.MmMark.Add_Click({ $rows = @($script:menuRows); if (@($rows | Where-Object { -not $_.Marked }).Count -eq 0) { Remove-MapMarks $rows } else { [void](Add-MapMarks $rows) }; Update-MapSel })
# ---------- 值得一看：名字一看就是缓存、依赖包、构建产物、虚拟环境、临时文件的大文件夹 ----------
$script:worthNames = @('node_modules', '.next', '.nuxt', '.parcel-cache', '.turbo', '.cache', 'cache', 'caches', 'cache2', 'Code Cache', 'GPUCache', 'ShaderCache', 'DXCache', 'GLCache',
    '_cacache', 'npm-cache', '.gradle', '.nuget', '.m2', '.venv', 'venv', 'target', 'obj', '__pycache__', 'Temp', 'tmp', 'CrashDumps', 'DerivedData', '.android', 'Windows.old')
function Get-WorthKind([string]$name) {
    switch -regex ($name) {
        '^(node_modules|\.nuget|\.m2|_cacache|npm-cache|\.gradle)$' { return (T '依赖包，要用时会重新下载') }
        '^(target|obj|\.next|\.nuxt|\.parcel-cache|\.turbo|DerivedData|__pycache__)$' { return (T '构建产物，重新编译会再生成') }
        '^(\.venv|venv)$' { return (T 'Python 虚拟环境，删了要重新建') }
        '^(Temp|tmp|CrashDumps)$' { return (T '临时文件和崩溃转储') }
        '^Windows\.old$' { return (T '旧系统，删了就不能退回去') }
        '^\.android$' { return (T '安卓开发工具的数据') }
        default { return (T '缓存，删了会自动重建') }
    }
}
function Show-MapWorth {
    $ctl.MapWorth.Children.Clear()
    $r = $script:mapRoot
    if (-not $r) { $ctl.MapWorthBox.Visibility = 'Collapsed'; return }
    $hits = @(); try { $hits = @([DiskMap]::Named($r, [string[]]$script:worthNames, [long]300MB, 40)) } catch {}
    $shown = 0
    foreach ($h in $hits) {
        if ($shown -ge 6) { break }
        $p = $h.FullPath()
        if (Get-DeleteBlock $p) { continue }
        if (Test-ChatPath $p) { continue }
        $par = Split-Path $p -Parent
        # target 要旁边有 Cargo.toml（Rust），obj 要旁边有工程文件（.NET）才算构建产物
        if ($h.Name -ieq 'target' -and -not (Test-Path -LiteralPath (Join-Path $par 'Cargo.toml'))) { continue }
        if ($h.Name -ieq 'obj' -and -not @(Get-ChildItem -LiteralPath $par -File -Filter '*.*proj' -ErrorAction SilentlyContinue).Count) { continue }
        $b = New-Object System.Windows.Controls.Button; $b.Style = $win.FindResource('Small'); $b.Margin = New-Object System.Windows.Thickness 0, 0, 8, 6; $b.Tag = $h
        $sp = New-Object System.Windows.Controls.StackPanel; $sp.Orientation = 'Horizontal'
        $t1 = New-Object System.Windows.Controls.TextBlock; $t1.Text = (Split-Path $par -Leaf) + '\' + $h.Name
        $t2 = New-Object System.Windows.Controls.TextBlock; $t2.Text = Fmt $(if ($r.HasDisk) { [double]$h.Disk } else { [double]$h.Size }); $t2.FontWeight = 'SemiBold'; $t2.Margin = New-Object System.Windows.Thickness 8, 0, 0, 0
        [void]$sp.Children.Add($t1); [void]$sp.Children.Add($t2); $b.Content = $sp
        $b.ToolTip = "{0}`n{1}" -f $p, (Get-WorthKind $h.Name)
        $b.Add_Click({
            $n = $this.Tag
            if ($script:mapView -ne 'dirs' -and $script:mapView -ne 'tree') { $ctl.MapViewDirs.IsChecked = $true }
            Show-MapLevel $n.Parent
            foreach ($x in @($ctl.MapList.Items)) { if ([object]::ReferenceEquals($x.Node, $n)) { $ctl.MapList.SelectedItem = $x; try { $ctl.MapList.ScrollIntoView($x) } catch {}; break } }
        })
        [void]$ctl.MapWorth.Children.Add($b); $shown++
    }
    $ctl.MapWorthBox.Visibility = if ($shown -gt 0) { 'Visible' } else { 'Collapsed' }
}
# 概览：这块盘用了多少，系统与软件、个人文件、缓存各占多少。只有扫的是整块盘时才有
$script:ovCache = @{}
function Show-MapOverview {
    $r = $script:mapRoot
    if (-not $r -or ($script:mapView -ne 'dirs' -and $script:mapView -ne 'tree' -and $script:mapView -ne 'types')) { $ctl.MapOverview.Visibility = 'Collapsed'; return }
    $drive = $r.FullPath()
    if ($drive.Length -ne 3 -or $drive[1] -ne ':') { $ctl.MapOverview.Visibility = 'Collapsed'; return }
    $total = [double]0; $used = [double]0; $free = [double]0
    try { $di = New-Object System.IO.DriveInfo $drive; $total = [double]$di.TotalSize; $free = [double]$di.AvailableFreeSpace; $used = $total - $di.TotalFreeSpace } catch {}
    if ($total -le 0) { $ctl.MapOverview.Visibility = 'Collapsed'; return }
    $sz = { param($n) if ($n) { if ($r.HasDisk) { [double]$n.Disk } else { [double]$n.Size } } else { [double]0 } }
    $sys = [double]0
    foreach ($nm in 'Windows', 'Program Files', 'Program Files (x86)', 'ProgramData', 'Recovery', '$WinREAgent', 'Windows.old', 'PerfLogs') { $sys += & $sz ([DiskMap]::Find($r, (Join-Path $drive $nm))) }
    $users = & $sz ([DiskMap]::Find($r, (Join-Path $drive 'Users')))
    # 缓存：清理列表里「安全清理」那些目录在这棵树上的大小（只算系统盘；别的盘没有这些）
    $cache = [double]0
    $key = $drive.ToLowerInvariant() + '|' + $(if ($script:mapScanAt) { $script:mapScanAt.Ticks } else { 0 })
    if ($drive -ieq ($env:SystemDrive + '\')) {
        if ($script:ovCache.ContainsKey($key)) { $cache = $script:ovCache[$key] }
        else {
            foreach ($it in $catalog) {
                if ($it.Kind -ne 'cache' -or $it.Size -or $it.Custom -or -not $it.Paths -or ([string]$it.G) -ne $script:safeGroup) { continue }
                try { $cache += [double](Measure-Item $it $r) } catch {}
            }
            $script:ovCache[$key] = $cache
        }
    }
    $other = [math]::Max([double]0, $used - $sys - $users)
    $sys = [math]::Max([double]0, $sys - $cache * 0.3); $users = [math]::Max([double]0, $users - $cache * 0.7)   # 缓存大多在个人目录（AppData），少数在 Windows 和 ProgramData 里
    $ctl.MapOvTitle.Text = (T "{0} {1}") -f $drive.TrimEnd('\'), $(if ($drive -ieq ($env:SystemDrive + '\')) { (T '系统盘') } else { '' })
    $ctl.MapOvUsed.Text = "{0} / {1}" -f (Fmt $used), (Fmt $total)
    $ctl.MapOvPct.Text = "{0:N1}%" -f (100.0 * $used / $total)
    $parts = @(@((T '系统与软件'), $sys, '#3B82F6'), @((T '个人文件'), $users, '#E0A731'), @((T '可清理的缓存'), $cache, '#3FA37E'), @((T '其他'), $other, '#8E8E93'), @((T '剩余空间'), $free, '#9B6FD6'))
    for ($i = 0; $i -lt 5; $i++) { $ctl.MapOvBar.ColumnDefinitions[$i].Width = New-Object System.Windows.GridLength ([math]::Max([double]0, $parts[$i][1])), ([System.Windows.GridUnitType]::Star) }
    $ctl.MapOvLegend.Children.Clear()
    for ($i = 0; $i -lt 5; $i++) {
        if ($parts[$i][1] -le 0 -and $i -ne 4) { continue }
        $sp = New-Object System.Windows.Controls.StackPanel; $sp.Orientation = 'Horizontal'; $sp.Margin = New-Object System.Windows.Thickness 0, 0, 18, 2
        $dot = New-Object System.Windows.Controls.Border; $dot.Width = 9; $dot.Height = 9; $dot.CornerRadius = New-Object System.Windows.CornerRadius 4.5; $dot.Background = Brush $parts[$i][2] 'b'; $dot.VerticalAlignment = 'Center'; $dot.Margin = New-Object System.Windows.Thickness 0, 0, 6, 0
        $tb = New-Object System.Windows.Controls.TextBlock; $tb.Text = "{0} {1}" -f $parts[$i][0], (Fmt $parts[$i][1]); $tb.FontSize = 12; $tb.Foreground = Brush '#6E6E73'; $tb.VerticalAlignment = 'Center'
        [void]$sp.Children.Add($dot); [void]$sp.Children.Add($tb); [void]$ctl.MapOvLegend.Children.Add($sp)
    }
    $ctl.MapOverview.ToolTip = (T '系统与软件：Windows、Program Files、ProgramData 等；个人文件：Users；可清理的缓存：清理页「安全清理」里的那些目录（估算）；其他：页面文件、休眠文件、文件表等不在上面几类里的。剩余空间按 Windows 报告的算。')
    if ($script:worthKey -ne $key) { $script:worthKey = $key; Show-MapWorth }
    $ctl.MapOverview.Visibility = 'Visible'
}

# ---------- 方块图：每个方块的面积就是它占的空间（squarified treemap） ----------
# 输入从大到小排好的大小，返回每一项的 @(x, y, 宽, 高)
function Get-TreeRects([double[]]$sizes, [double]$x, [double]$y, [double]$w, [double]$h) {
    $n = $sizes.Count
    $rects = New-Object 'object[]' $n
    $total = [double]0; foreach ($s in $sizes) { $total += $s }
    if ($n -eq 0 -or $total -le 0 -or $w -le 0 -or $h -le 0) { return ,$rects }
    $scale = $w * $h / $total
    $areas = New-Object 'double[]' $n
    for ($k = 0; $k -lt $n; $k++) { $areas[$k] = [math]::Max([double]0.0001, $sizes[$k] * $scale) }
    $i = 0
    while ($i -lt $n -and $w -gt 0.5 -and $h -gt 0.5) {
        $side = [math]::Min($w, $h)
        $j = $i; $sum = [double]0; $worst = [double]::MaxValue
        while ($j -lt $n) {
            $s2 = $sum + $areas[$j]
            $wst = [math]::Max(($side * $side * $areas[$i]) / ($s2 * $s2), ($s2 * $s2) / ($side * $side * $areas[$j]))
            if ($j -gt $i -and $wst -gt $worst) { break }
            $worst = $wst; $sum = $s2; $j++
        }
        if ($w -ge $h) {
            $cw = $sum / $h; $yy = $y
            for ($k = $i; $k -lt $j; $k++) { $hh = $areas[$k] / $cw; $rects[$k] = @($x, $yy, $cw, $hh); $yy += $hh }
            $x += $cw; $w -= $cw
        } else {
            $rh = $sum / $w; $xx = $x
            for ($k = $i; $k -lt $j; $k++) { $ww = $areas[$k] / $rh; $rects[$k] = @($xx, $y, $ww, $rh); $xx += $ww }
            $y += $rh; $h -= $rh
        }
        $i = $j
    }
    return ,$rects
}
# 这一层要画的方块：最多 60 块，太小的合成一块「其他」
function Get-TreeItems($rows) {
    $items = @($rows | Where-Object { $_ -and $_.Size -gt 0 })
    $tot = [double]0; foreach ($r in $items) { $tot += [double]$r.Size }
    $show = New-Object System.Collections.ArrayList; $rest = [double]0; $restN = 0
    foreach ($r in $items) { if ($show.Count -lt 60 -and $tot -gt 0 -and ([double]$r.Size / $tot) -ge 0.002) { [void]$show.Add($r) } else { $rest += [double]$r.Size; $restN++ } }
    $sizes = @($show | ForEach-Object { [double]$_.Size }); if ($rest -gt 0) { $sizes += $rest }
    return @{ Show = $show; Sizes = [double[]]$sizes; Rest = $rest; RestN = $restN }
}
$script:treeColors = @('#2F6FDB', '#3B82F6', '#4C8DF6', '#2563EB', '#5A9BF0', '#3576E6')
# 方块的颜色是这个文件夹装的是哪一类东西（参考 disktree）：按名字认，认不出的用蓝色；能腾出来的（缓存、依赖包、临时文件）再加斜线
$script:treeKinds = [ordered]@{
    system = @((T '系统'), '#5A6B8C'); apps = @((T '软件和软件数据'), '#4F7FC4'); docs = @((T '文档和桌面'), '#8C6BC2'); media = @((T '照片、视频、音乐'), '#C07A3A')
    dev = @((T '代码和开发'), '#3E8E7E'); sync = @((T '同步盘'), '#3796C7'); games = @((T '游戏'), '#B05A8A'); cache = @((T '缓存和临时文件'), '#C9A227'); other = @((T '其他文件夹'), '#3B82F6'); file = @((T '文件'), '#8E99AD')
}
function Get-TreeKind($row) {
    if (-not $row.IsDir) { return 'file' }
    $n = ([string]$row.Name).ToLowerInvariant(); $p = ([string]$row.Path).ToLowerInvariant()
    if ($n -match '^(windows|program files|program files \(x86\)|programdata|\$winreagent|recovery|system volume information|perflogs|windows\.old|\$recycle\.bin|msocache|intel|amd|nvidia)$') { return $(if ($n -in 'windows.old', '$recycle.bin') { 'cache' } else { 'system' }) }
    if ($script:worthNames -contains $row.Name -or $n -match '^(temp|tmp|inetcache|crashdumps|logs?|\$recycle\.bin)$' -or $n -match 'cache') { return 'cache' }
    if ($n -match '^(onedrive|onedrive - .*|dropbox|icloud ?drive|google drive|baidunetdisk.*|baidunetdiskdownload|坚果云|nutstore.*)$') { return 'sync' }
    if ($n -match '^(steam|steamapps|steamlibrary|epic games|wegame|games|riot games|battle\.net|origin games|ea games|ubisoft.*|genshin impact.*|xboxgames)$') { return 'games' }
    if ($n -match '^(pictures|videos|music|photos|camera roll|dcim|movies|图片|视频|音乐|照片)$') { return 'media' }
    if ($n -match '^(documents|desktop|downloads|文档|桌面|下载)$') { return 'docs' }
    if ($n -match '^(\.git|src|source|sources|repos|projects|code|workspace|workspaces|github|gitlab|dev|\.vscode|\.cargo|\.rustup|\.conda|anaconda3|miniconda3|\.docker|docker)$') { return 'dev' }
    if ($n -eq 'appdata' -or $p -match '\\appdata(\\|$)' -or $n -match '^(local|roaming|locallow)$') { return 'apps' }
    return 'other'
}
$script:hatchCache = @{}
function Get-TreeBrush([string]$hex, [bool]$hatch) {
    $key = $hex + '|' + $hatch
    if ($script:hatchCache.ContainsKey($key)) { return $script:hatchCache[$key] }
    $base = Brush $hex 'b'
    if (-not $hatch) { $script:hatchCache[$key] = $base; return $base }
    $dg = New-Object System.Windows.Media.DrawingGroup
    [void]$dg.Children.Add((New-Object System.Windows.Media.GeometryDrawing $base, $null, (New-Object System.Windows.Media.RectangleGeometry (New-Object System.Windows.Rect 0, 0, 8, 8))))
    $pen = New-Object System.Windows.Media.Pen ((New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromArgb(90, 255, 255, 255)))), 1.6
    foreach ($ln in @(@(0, 8, 8, 0), @(-2, 2, 2, -2), @(6, 10, 10, 6))) { [void]$dg.Children.Add((New-Object System.Windows.Media.GeometryDrawing $null, $pen, (New-Object System.Windows.Media.LineGeometry (New-Object System.Windows.Point $ln[0], $ln[1]), (New-Object System.Windows.Point $ln[2], $ln[3])))) }
    $db = New-Object System.Windows.Media.DrawingBrush $dg
    $db.TileMode = 'Tile'; $db.Viewport = New-Object System.Windows.Rect 0, 0, 8, 8; $db.ViewportUnits = 'Absolute'; $db.Viewbox = New-Object System.Windows.Rect 0, 0, 8, 8; $db.ViewboxUnits = 'Absolute'
    $db.Freeze()
    $script:hatchCache[$key] = $db
    return $db
}
$script:treeSel = $null
function Draw-MapTree {
    $cv = $ctl.MapTree
    $cv.Children.Clear(); $script:treeSel = $null
    $w = [double]$cv.ActualWidth; $h = [double]$cv.ActualHeight
    if ($w -lt 40 -or $h -lt 40) { return }   # 还没排好版：等 SizeChanged 再画
    $ti = Get-TreeItems @($ctl.MapList.ItemsSource)
    if ($ti.Sizes.Count -eq 0) { return }
    $order = @(0..($ti.Sizes.Count - 1) | Sort-Object { $ti.Sizes[$_] } -Descending)
    $rects = Get-TreeRects ([double[]]@($order | ForEach-Object { $ti.Sizes[$_] })) 0 0 $w $h
    $clear = Brush '#00000000'
    $kindsUsed = @{}
    for ($q = 0; $q -lt $order.Count; $q++) {
        $i = $order[$q]
        $rc = $rects[$q]; if (-not $rc) { continue }
        $row = if ($i -lt $ti.Show.Count) { $ti.Show[$i] } else { $null }
        $b = New-Object System.Windows.Controls.Border
        $b.Width = [math]::Max([double]0, $rc[2] - 2); $b.Height = [math]::Max([double]0, $rc[3] - 2)
        [System.Windows.Controls.Canvas]::SetLeft($b, $rc[0] + 1); [System.Windows.Controls.Canvas]::SetTop($b, $rc[1] + 1)
        $b.CornerRadius = New-Object System.Windows.CornerRadius 3
        $b.BorderThickness = New-Object System.Windows.Thickness 2
        $b.BorderBrush = $clear
        if (-not $row) { $b.Background = Brush '#C7CCD6' 'b' }
        else {
            $kd = Get-TreeKind $row; $kindsUsed[$kd] = $true
            $hex = if ($kd -eq 'other') { $script:treeColors[$i % $script:treeColors.Count] } else { $script:treeKinds[$kd][1] }
            $b.Background = Get-TreeBrush $hex ($kd -eq 'cache')
        }
        $b.Tag = $row
        $b.ToolTip = if ($row) { "{0}`n{1}  ·  {2}`n{3}" -f $row.Name, $row.SizeText, $row.Pct, $row.Path } else { (T "其他 {0} 项，共 {1}") -f $ti.RestN, (Fmt $ti.Rest) }
        if ($b.Width -ge 46 -and $b.Height -ge 20) {
            $tb = New-Object System.Windows.Controls.TextBlock
            $tb.Margin = New-Object System.Windows.Thickness 6, 3, 6, 2
            $tb.Foreground = Brush '#FFFFFF'; $tb.FontSize = 12; $tb.TextTrimming = 'CharacterEllipsis'
            $nm = New-Object System.Windows.Documents.Run $(if ($row) { $row.Name } else { (T "其他 {0} 项") -f $ti.RestN })
            $nm.FontWeight = 'SemiBold'; [void]$tb.Inlines.Add($nm)
            if ($b.Height -ge 38) {
                [void]$tb.Inlines.Add((New-Object System.Windows.Documents.LineBreak))
                $sz = New-Object System.Windows.Documents.Run $(if ($row) { $row.SizeText } else { Fmt $ti.Rest })
                $sz.FontSize = 11; [void]$tb.Inlines.Add($sz)
            }
            $b.Child = $tb
        }
        if ($row) {
            $b.Cursor = [System.Windows.Input.Cursors]::Hand
            $b.Add_MouseEnter({ param($s, $e) $s.Opacity = 0.82 })
            $b.Add_MouseLeave({ param($s, $e) $s.Opacity = 1 })
            $b.Add_MouseLeftButtonDown({
                param($s, $e)
                $r = $s.Tag
                if ($e.ClickCount -ge 2) { if ($r.IsDir -and $r.Node) { Show-MapLevel $r.Node }; $e.Handled = $true; return }
                # 点方块 = 在下面的列表里选中这一行（按住 Ctrl 可以多选），列表滚到它那里；列表选中的变化再把方块描上边
                $ctrl = ([System.Windows.Input.Keyboard]::Modifiers -band [System.Windows.Input.ModifierKeys]::Control) -ne 0
                if ($ctrl) { if ($ctl.MapList.SelectedItems.Contains($r)) { $ctl.MapList.SelectedItems.Remove($r) } else { [void]$ctl.MapList.SelectedItems.Add($r) } }
                else { $ctl.MapList.SelectedItems.Clear(); $ctl.MapList.SelectedItem = $r }
                try { $ctl.MapList.ScrollIntoView($r) } catch {}
                $e.Handled = $true
            })
        }
        [void]$cv.Children.Add($b)
    }
    # 图例：这一层出现了哪几类
    $lg = $ctl.MapTreeLegend; $lg.Children.Clear()
    foreach ($k in $script:treeKinds.Keys) {
        if (-not $kindsUsed.ContainsKey($k)) { continue }
        $sp = New-Object System.Windows.Controls.StackPanel; $sp.Orientation = 'Horizontal'; $sp.Margin = New-Object System.Windows.Thickness 0, 2, 16, 2
        $sw = New-Object System.Windows.Controls.Border; $sw.Width = 12; $sw.Height = 12; $sw.CornerRadius = New-Object System.Windows.CornerRadius 3; $sw.Margin = New-Object System.Windows.Thickness 0, 0, 6, 0; $sw.VerticalAlignment = 'Center'
        $sw.Background = Get-TreeBrush $script:treeKinds[$k][1] ($k -eq 'cache')
        $tb = New-Object System.Windows.Controls.TextBlock; $tb.Text = $script:treeKinds[$k][0] + $(if ($k -eq 'cache') { (T '（带斜线：删了能腾出来）') } else { '' }); $tb.FontSize = 12; $tb.Foreground = Brush '#6E6E73'; $tb.VerticalAlignment = 'Center'
        [void]$sp.Children.Add($sw); [void]$sp.Children.Add($tb); [void]$lg.Children.Add($sp)
    }
    Sync-TreeSel
}
# 列表里选中了哪些，方块图上就给哪些描边（方块图和列表一起显示时两边联动）
function Sync-TreeSel {
    if ($script:mapView -ne 'tree') { return }
    $sel = @{}; foreach ($x in @($ctl.MapList.SelectedItems)) { $sel[[System.Runtime.CompilerServices.RuntimeHelpers]::GetHashCode($x)] = $true }
    $on = Brush '#1D1D1F' 'd'; $off = Brush '#00000000'
    foreach ($b in @($ctl.MapTree.Children)) {
        $r = $b.Tag
        $b.BorderBrush = if ($r -and $sel.ContainsKey([System.Runtime.CompilerServices.RuntimeHelpers]::GetHashCode($r))) { $on } else { $off }
    }
}
$ctl.MapTree.Add_SizeChanged({ if ($script:mapView -eq 'tree') { Draw-MapTree } })
$ctl.MapList.Add_SelectionChanged({ if (-not $script:bulkSel) { Sync-TreeSel } })
# 找文件：在扫描时记下的 1 MB 以上的文件里，按大小、多久没改过、类型、名称、所在文件夹筛选
$script:mapTypes = @{
    video   = '.mp4 .mkv .avi .mov .wmv .flv .m4v .ts .m2ts .webm .mpg .mpeg .rmvb .rm .3gp .vob'
    archive = '.zip .rar .7z .tar .gz .tgz .bz2 .xz .zst .cab .msi .msp .msix .msixbundle .appx .appxbundle .apk .dmg'
    image   = '.iso .img .vhd .vhdx .avhdx .vmdk .vdi .qcow2 .wim .esd .gho'
    picture = '.jpg .jpeg .png .gif .bmp .tif .tiff .heic .webp .raw .cr2 .cr3 .nef .arw .dng .psd'
    music   = '.mp3 .flac .wav .aac .m4a .ogg .wma .ape .opus'
    doc     = '.pdf .doc .docx .xls .xlsx .ppt .pptx .txt .md .epub .mobi .csv .wps .et .dps'
    program = '.exe .dll .sys .ocx .pak .bin .vpk .pck .assets .bundle'
    log     = '.log .etl .dmp .mdmp .hdmp .tmp .temp .bak .old .cache .chk'
    code    = '.cs .js .ts .tsx .jsx .py .java .h .hpp .c .cpp .cc .go .rs .rb .php .json .xml .yml .yaml .map .obj .pdb .lib .o .class .pyc .ipynb .sql .ps1 .psm1 .sh .bat .cmd .swift .kt .scala .lock .toml'
}
$script:mapFindMax = 1000
# 各类文件的名字（和 FileCats 的顺序一样）
$script:catNames = @((T '其他类型'), (T '视频'), (T '图片'), (T '音乐'), (T '文档'), (T '压缩包和安装包'), (T '光盘映像和虚拟磁盘'), (T '程序和游戏数据'), (T '日志、转储和临时文件'), (T '代码和开发文件'))
$script:catKeys = @('', 'video', 'picture', 'music', 'doc', 'archive', 'image', 'program', 'log', 'code')
function Get-MapFilter {
    $min = [double]50MB; $t = $ctl.MapMinSize.SelectedItem; if ($t) { $min = [double]([string]$t.Tag) * 1MB }
    $days = 0; $t = $ctl.MapAge.SelectedItem; if ($t) { $days = [int]([string]$t.Tag) }
    $type = ''; $t = $ctl.MapType.SelectedItem; if ($t) { $type = [string]$t.Tag }
    $under = $null
    if ($ctl.MapUnder.IsChecked -and $script:mapCur -and -not [object]::ReferenceEquals($script:mapCur, $script:mapRoot)) { $under = $script:mapCur }
    $chat = $null
    if ($ctl.MapChat.IsChecked) { $chat = Get-MapChatNodes }
    return @{
        Chat = $chat
        Min = [long]$min
        Before = $(if ($days -gt 0) { (Get-Date).AddDays(-$days) } else { [DateTime]::MaxValue })
        Exts = $(if ($type -and $script:mapTypes.ContainsKey($type)) { $script:mapTypes[$type] } else { '' })
        Name = ([string]$ctl.MapName.Text).Trim()
        Under = $under
    }
}
# 聊天软件的聊天记录文件夹在这棵树上的位置（搬走了的是链接，里面没有东西）
function Get-MapChatNodes {
    $out = @{ Nodes = New-Object System.Collections.Generic.List[DmNode]; Names = New-Object System.Collections.Generic.List[string] }
    if (-not $script:mapRoot) { return $out }
    foreach ($c in $catalog) {
        if (-not ([string]$c.G).StartsWith('聊天软件') -or -not $c.Paths) { continue }
        $hit = $false
        foreach ($p in $c.Paths) {
            if (-not $p) { continue }
            foreach ($it in @(Get-PathItems $p)) {
                if (-not $it.PSIsContainer) { continue }
                $n = [DiskMap]::Find($script:mapRoot, $it.FullName)
                if ($n -and -not $n.IsLink -and -not $out.Nodes.Contains($n)) { $out.Nodes.Add($n); $hit = $true }
            }
        }
        if ($hit) { $out.Names.Add([string]$c.N) }
    }
    return $out
}
function Show-MapFiles {
    $keep = Get-MapKeep 'files'
    $rows = New-Object System.Collections.Generic.List[MapRow]
    $f = Get-MapFilter
    if ($f.Chat) { $res = [DiskMap]::FindFilesIn($f.Min, $f.Before, $f.Exts, $f.Name, $f.Chat.Nodes.ToArray(), $script:mapFindMax) }
    else { $res = [DiskMap]::FindFiles($f.Min, $f.Before, $f.Exts, $f.Name, $f.Under, $script:mapFindMax) }
    $max = if ($res.Files.Count -gt 0) { [double]$res.Files[0].Size } else { 0 }
    $tot = if ($script:mapRoot) { [double]$script:mapRoot.Size } else { 0 }
    $dn = (Get-Flag 'MapDisk') -and $script:mapRoot -and $script:mapRoot.HasDisk
    # 所有者：只给列出来的这些文件查（每个账户只翻译一次，一千个文件不到一秒）
    $wantOwner = ''; $t = $ctl.MapOwner.SelectedItem; if ($t) { $wantOwner = [string]$t.Tag }
    $owners = @{}
    $files = @($res.Files)
    $sortBy = ''; $t = $ctl.MapSort.SelectedItem; if ($t) { $sortBy = [string]$t.Tag }
    if ($sortBy -eq 'new') { $files = @($files | Sort-Object { $_.Modified } -Descending) } elseif ($sortBy -eq 'old') { $files = @($files | Sort-Object { $_.Modified }) }
    foreach ($x in $files) {
        $p = $x.Path
        $ow = [FsTools]::Owner($p)
        if ($ow) { $owners[$ow] = $true }
        if ($wantOwner -and $ow -ne $wantOwner) { continue }
        $fm = (T "{0} · 修改于 {1:yyyy-MM-dd}") -f (Split-Path $p -Parent), $x.Modified
        if ($dn) { $fm += Get-SizeNote $p ([double]$x.Size) ([double]$x.Disk) $(if ($x.Shared) { [double]$x.Size } else { 0 }) }
        if ($ow) { $fm += (T " · 所有者 {0}") -f ($ow -replace '^.*\\', '') }
        $row = New-MapRow $x.Name $p $x.Size $max $tot $false $null $fm 'file'
        $row.When = '{0:yyyy-MM-dd HH:mm}' -f $x.Modified
        $row.Disk = [long]$x.Disk; $row.Shared = [bool]$x.Shared; $row.Owner = $ow
        # 聊天记录里的文件只看不删：要腾地方就整体搬家
        if ($f.Chat) { $row.Locked = $true; $row.LockTip = (T '聊天记录里的文件只能查看和打开位置；要腾地方，到「搬家管理」把整个聊天记录搬到其他盘') }
        [void]$rows.Add($row)
    }
    # 所有者下拉框：列出来的文件里有哪些账户
    $script:ownerFill = $true
    try {
        $cur = $wantOwner
        while ($ctl.MapOwner.Items.Count -gt 1) { $ctl.MapOwner.Items.RemoveAt(1) }
        foreach ($o in @($owners.Keys | Sort-Object)) { $it = New-Object System.Windows.Controls.ComboBoxItem; $it.Content = $o; $it.Tag = $o; [void]$ctl.MapOwner.Items.Add($it); if ($o -eq $cur) { $ctl.MapOwner.SelectedItem = $it } }
        if (-not $ctl.MapOwner.SelectedItem) { $ctl.MapOwner.SelectedIndex = 0 }
    } finally { $script:ownerFill = $false }
    $ctl.MapList.ItemsSource = $rows
    Restore-MapKeep $keep
    $head = (T "找到 {0:N0} 个文件，共 {1}") -f $res.Count, (Fmt $res.Bytes)
    if ($res.Count -gt $rows.Count) { $head += ((T "，下面列出最大的 {0:N0} 个") -f $rows.Count) }
    $ctl.MapPath.Text = $head
    $where = if ($f.Under) { $f.Under.FullPath() } elseif ($script:mapRoot) { $script:mapRoot.FullPath() } else { '' }
    $ctl.MapInfo.Text = (T "在 {0} 里找，只能找到扫描时记下的 1 MB 以上的文件") -f $where
    if ($wantOwner) { $ctl.MapInfo.Text += (T "；所有者只在列出来的这些文件里分") }
    if ($f.Chat) {
        $ctl.MapInfo.Text = if ($f.Chat.Names.Count -gt 0) { (T "在聊天记录里找（{0}）。这些文件只能查看和打开位置；要腾地方，可以到「搬家管理」把整个聊天记录搬到其他盘") -f ($f.Chat.Names -join (T '、')) }
                            else { (T '这块盘上没找到聊天软件的聊天记录文件夹（可能已经搬到其他盘了）') }
    }
    $ctl.MapUnder.ToolTip = if ($script:mapCur) { $script:mapCur.FullPath() } else { $null }
    $ctl.BtnMapUp.IsEnabled = $false
    $ctl.BtnMapAcct.Visibility = 'Collapsed'
    $ctl.EmptyMap.Visibility = if ($rows.Count -gt 0) { 'Collapsed' } else { 'Visible' }
    if ($rows.Count -eq 0) { $ctl.EmptyMapText.Text = (T '没有符合条件的文件，可以把条件放宽一些') }
    $ctl.BtnMapExport.IsEnabled = ($rows.Count -gt 0)
    $ctl.BtnMapReport.IsEnabled = $true
    Update-MapSel
}
function Refresh-MapFiles { if ($script:mapView -eq 'files' -and $script:mapRoot) { Show-MapFiles } }
$ctl.MapMinSize.Add_SelectionChanged({ Refresh-MapFiles })
$ctl.MapAge.Add_SelectionChanged({ Refresh-MapFiles })
$ctl.MapType.Add_SelectionChanged({ Refresh-MapFiles })
$ctl.MapSort.Add_SelectionChanged({ if ($script:sortCfg['MapList'] -and $script:sortCfg['MapList'].Prop) { Reset-ListSort 'MapList' '' $true }; Refresh-MapFiles })
$ctl.MapOwner.Add_SelectionChanged({ if (-not $script:ownerFill) { Refresh-MapFiles } })
$ctl.MapUnder.Add_Checked({ $ctl.MapChat.IsChecked = $false; Refresh-MapFiles })
$ctl.MapUnder.Add_Unchecked({ Refresh-MapFiles })
$ctl.MapChat.Add_Checked({ $ctl.MapUnder.IsChecked = $false; if ($script:mapView -ne 'files' -and $script:mapRoot) { $ctl.MapViewFiles.IsChecked = $true }; Refresh-MapFiles })
$ctl.MapChat.Add_Unchecked({ Refresh-MapFiles })
# 快速扫描（直接读文件表）开关：存在设置里，所有页面统计大小时都按它来
$ctl.MapFast.IsChecked = ((Get-Setting 'FastScan' '1') -ne '0')
[DiskMap]::MftOff = -not $ctl.MapFast.IsChecked
function Set-FastScan([bool]$on) {
    $ctl.MapFast.IsChecked = $on; $ctl.SetFast.IsChecked = $on
    [DiskMap]::MftOff = -not $on
    Set-Setting 'FastScan' $(if ($on) { '1' } else { '0' })
    UI-Log $(if ($on) { (T '已打开快速扫描：直接读文件表') } else { (T '已关闭快速扫描：以后逐个文件夹扫描') })
}
$ctl.MapFast.Add_Click({ Set-FastScan ([bool]$ctl.MapFast.IsChecked) })
# 名称：停下打字 0.4 秒后再找，免得每打一个字就刷新一次
$script:mapNameTimer = New-Object System.Windows.Threading.DispatcherTimer
$script:mapNameTimer.Interval = [TimeSpan]::FromMilliseconds(400)
$script:mapNameTimer.Add_Tick({ $script:mapNameTimer.Stop(); Refresh-MapFiles })
$ctl.MapName.Add_TextChanged({ $script:mapNameTimer.Stop(); $script:mapNameTimer.Start() })

function Set-MapView([string]$v) {
    $script:mapView = $v
    $ctl.MapFilter.Visibility = if ($v -eq 'files') { 'Visible' } else { 'Collapsed' }
    $grow = ($v -eq 'grow'); $tree = ($v -eq 'tree')
    $ctl.MapGrowBar.Visibility = if ($grow) { 'Visible' } else { 'Collapsed' }
    $ctl.MapRecentBar.Visibility = if ($v -eq 'recent') { 'Visible' } else { 'Collapsed' }
    $ctl.MapGrow.Visibility = if ($grow) { 'Visible' } else { 'Collapsed' }
    $ctl.MapTreeBox.Visibility = if ($tree) { 'Visible' } else { 'Collapsed' }
    if ($v -ne 'dirs' -and -not $tree) { $ctl.MapCrumbs.Visibility = 'Collapsed'; $ctl.MapPath.Visibility = 'Visible' }
    # 方块图和列表一起显示：上面方块图，下面列表，点哪边另一边都跟着
    $ctl.MapGrid.RowDefinitions[1].Height = if ($tree) { New-Object System.Windows.GridLength 3, ([System.Windows.GridUnitType]::Star) } else { New-Object System.Windows.GridLength 0 }
    $ctl.MapGrid.RowDefinitions[2].Height = if ($tree) { New-Object System.Windows.GridLength 2, ([System.Windows.GridUnitType]::Star) } else { New-Object System.Windows.GridLength 1, ([System.Windows.GridUnitType]::Star) }
    $ctl.MapList.Visibility = if ($grow) { 'Collapsed' } else { 'Visible' }
    Update-HeadVis
    if (-not $script:mapRoot) { $ctl.MapOverview.Visibility = 'Collapsed'; return }
    if ($v -eq 'dirs' -or $tree) { Show-MapLevel $(if ($script:mapCur) { $script:mapCur } else { $script:mapRoot }) }
    elseif ($v -eq 'files') { Show-MapOverview; Show-MapFiles }
    elseif ($v -eq 'types') { Show-MapTypes }
    elseif ($v -eq 'recent') { Show-MapOverview; Show-MapRecent }
    else {
        $ctl.MapGrow.ItemsSource = $script:growRows
        $ctl.BtnMapUp.IsEnabled = $false
        $ctl.BtnMapAcct.Visibility = 'Collapsed'
        $has = $script:growRows -and $script:growRows.Count -gt 0
        $ctl.EmptyMap.Visibility = if ($has) { 'Collapsed' } else { 'Visible' }
        $ctl.EmptyMapText.Text = $script:growNote
        $ctl.MapPath.Text = if ($script:growSummary) { $script:growSummary } else { (T '和上次扫描相比') }
        $ctl.MapPath.ToolTip = $ctl.MapPath.Text
        $ctl.MapInfo.Text = $script:growNote + $(if ($has) { (T ' 双击一行可以跳到这个文件夹。') } else { '' })
        $ctl.MapOverview.Visibility = 'Collapsed'
        $ctl.BtnMapExport.IsEnabled = [bool]$has
        Update-MapSel
    }
}
$ctl.MapViewDirs.Add_Checked({ Set-MapView 'dirs' })
$ctl.MapViewTree.Add_Checked({ Set-MapView 'tree' })
$ctl.MapViewFiles.Add_Checked({ Set-MapView 'files' })
$ctl.MapViewGrow.Add_Checked({ Set-MapView 'grow' })
$ctl.MapViewTypes.Add_Checked({ Set-MapView 'types' })
$ctl.MapViewRecent.Add_Checked({ Set-MapView 'recent' })
$ctl.MapGrowBase.Add_SelectionChanged({ if ($script:mapRoot -and $script:mapView -eq 'grow' -and -not $script:growLoading) { try { Compare-Snapshot $script:mapRoot } catch { $script:growNote = (T '没能和上次比较') }; Set-MapView 'grow' } })
# 按类型：这块盘上每类文件多少个、多大（扫描时顺手数的，所有文件都算，不只 1 MB 以上的）
function Show-MapTypes {
    $r = $script:mapRoot
    $rows = New-Object System.Collections.Generic.List[MapRow]
    $ctl.BtnMapUp.IsEnabled = $false; $ctl.BtnMapAcct.Visibility = 'Collapsed'
    if ($r -and $r.TypeBytes) {
        $order = @(0..9 | Where-Object { $r.TypeCount[$_] -gt 0 } | Sort-Object { $r.TypeBytes[$_] } -Descending)
        $max = if ($order.Count -gt 0) { [double]$r.TypeBytes[$order[0]] } else { 0 }
        $tot = [double]0; foreach ($i in 0..9) { $tot += $r.TypeBytes[$i] }
        foreach ($i in $order) {
            $meta = (T "{0:N0} 个文件") -f $r.TypeCount[$i]
            if ($r.TypeDisk -and $r.TypeDisk[$i] -ge 0 -and ([double]$r.TypeBytes[$i] - [double]$r.TypeDisk[$i]) -ge 32MB -and $r.TypeDisk[$i] -lt $r.TypeBytes[$i] * 0.85) { $meta += (T " · 实际占 {0}") -f (Fmt ([double]$r.TypeDisk[$i])) }
            $meta += $(if ($i -eq 0) { (T ' · 没归到上面几类的扩展名') } else { (T ' · 双击看这一类最大的文件') })
            $row = New-MapRow $script:catNames[$i] ('type:' + $script:catKeys[$i]) $r.TypeBytes[$i] $max $tot $false $null $meta 'type'
            $row.FileCount = [long]$r.TypeCount[$i]
            [void]$rows.Add($row)
        }
    }
    $ctl.MapList.ItemsSource = $rows; $script:mapListKey = 'types'
    $ctl.MapPath.Text = (T '各类文件占多少')
    $ctl.MapInfo.Text = if ($r) { (T "{0} 上的全部 {1:N0} 个文件按扩展名分类{2}") -f $r.FullPath().TrimEnd('\'), $r.Files, $(if ($script:mapScanAt) { (T " · 扫描于 {0:HH:mm}") -f $script:mapScanAt } else { '' }) } else { '' }
    $ctl.EmptyMap.Visibility = if ($rows.Count -gt 0) { 'Collapsed' } else { 'Visible' }
    if ($rows.Count -eq 0) { $ctl.EmptyMapText.Text = (T '这次扫描没有按类型统计（可能是旧的扫描结果），再扫描一次就有了') }
    $ctl.BtnMapExport.IsEnabled = ($rows.Count -gt 0); $ctl.BtnMapReport.IsEnabled = [bool]$r
    Show-MapOverview
    Update-MapSel
}
# 最近改动：读变更日志，看这几天哪些文件夹里新建、改写的文件最多
$script:recentRows = $null; $script:recentNote = ''
function Show-MapRecent {
    $rows = New-Object System.Collections.Generic.List[MapRow]
    $ctl.BtnMapUp.IsEnabled = $false; $ctl.BtnMapAcct.Visibility = 'Collapsed'
    $list = $script:recentRows
    if ($list -and $list.Count -gt 0) {
        $max = [double]$list[0].Bytes; $tot = [double]0; foreach ($x in $list) { $tot += [double]$x.Bytes }
        foreach ($x in $list) {
            $top = -1; $tb = [long]0; for ($i = 0; $i -lt 10; $i++) { if ($x.ByCat[$i] -gt $tb) { $tb = $x.ByCat[$i]; $top = $i } }
            $meta = (T "{0:N0} 个文件新建或改写过") -f $x.Files
            if ($x.Deleted -gt 0) { $meta += (T "，{0:N0} 个删掉了") -f $x.Deleted }
            if ($top -ge 0 -and $tb -ge $x.Bytes * 0.5 -and $x.Bytes -gt 0) { $meta += (T " · 主要是{0}") -f $script:catNames[$top] }
            $meta += (T ' · 双击打开这个文件夹')
            $node = [DiskMap]::Find($script:mapRoot, $x.Path)
            $row = New-MapRow (Split-Path $x.Path -Leaf) $x.Path $x.Bytes $max 0 $false $null $meta 'recent'
            if (-not $row.Name) { $row.Name = $x.Path }
            $row.Node = $node; $row.FileCount = [long]$x.Files; $row.Pct = ''
            $row.SizeText = (T "现在共 {0}") -f (Fmt ([double]$x.Bytes))
            [void]$rows.Add($row)
        }
    }
    $ctl.MapList.ItemsSource = $rows; $script:mapListKey = 'recent'
    $ctl.MapPath.Text = (T '最近改动最多的文件夹')
    $ctl.MapInfo.Text = $script:recentNote
    $ctl.EmptyMap.Visibility = if ($rows.Count -gt 0) { 'Collapsed' } else { 'Visible' }
    if ($rows.Count -eq 0) { $ctl.EmptyMapText.Text = if ($script:recentNote) { $script:recentNote } else { (T '选一个时间段，点「查看」') } }
    $ctl.BtnMapExport.IsEnabled = ($rows.Count -gt 0); $ctl.BtnMapReport.IsEnabled = [bool]$script:mapRoot
    Update-MapSel
}
function Start-MapRecent {
    if ($script:worker -or -not $script:mapRoot) { return }
    $days = 1; $t = $ctl.MapRecentDays.SelectedItem; if ($t) { $days = [int]([string]$t.Tag) }
    if ([string]$script:mapMethod -notlike 'mft*') { $script:recentRows = $null; $script:recentNote = (T '这块盘是逐个文件夹扫描的，没有读文件表，看不了变更日志。打开「快速扫描」再扫一次就可以'); Show-MapRecent; return }
    $sync.Mode = 'recent'; $sync.RecentResult = $null; $sync.RecentNote = ''; $sync.RecentDays = $days
    Start-Op (T '读取变更日志') -NoCard; UI-Busy $true
    $ctl.EmptyMap.Visibility = 'Visible'; $ctl.EmptyMapText.Text = (T '正在读变更日志…'); $ctl.MapList.ItemsSource = $null
    Start-Worker @'
$note = ''
$since = [DateTime]::UtcNow.AddDays(-[double]$arg.Days).ToFileTimeUtc()
$sync.RecentResult = [DiskMap]::RecentDirs($arg.Root, $since, 60, [ref]$note)
$sync.RecentNote = $note
'@ @{ Root = $script:mapRoot.FullPath(); Days = $days }
}
$ctl.BtnMapRecent.Add_Click({ Start-MapRecent })
$ctl.MapRecentDays.Add_SelectionChanged({ if ($script:mapView -eq 'recent' -and $script:mapRoot -and -not $script:worker) { Start-MapRecent } })
$ctl.BtnMapUp.Add_Click({ Go-MapUp })
# 空间明细：已用空间都花在哪，为什么和按文件大小相加对不上（快速扫描读了文件表才有）
function Show-SpaceAcct {
    $r = $script:mapRoot
    if (-not $r -or -not $r.HasDisk) { return }
    $drive = $r.FullPath()
    $total = [double]0; $used = [double]0
    try { $di = New-Object System.IO.DriveInfo $drive; $total = [double]$di.TotalSize; $used = [double]($di.TotalSize - $di.TotalFreeSpace) } catch {}
    $files = [double]$r.UniqueDisk; $mft = [double]$r.MftBytes
    $a = New-Object System.Collections.Generic.List[string]
    $a.Add(((T "· 文件实际占用 {0}：每个文件只算一次，有几个名字的（硬链接）也只算一份") -f (Fmt $files)))
    $svi = [DiskMap]::Find($r, (Join-Path $drive 'System Volume Information'))
    if ($svi -and $svi.Disk -ge 100MB) { $a.Add(((T "　其中系统还原点等（System Volume Information）{0}，在「省空间」里可以查看") -f (Fmt ([double]$svi.Disk)))) }
    $a.Add(((T "· 文件表（MFT）{0}：NTFS 记录每个文件信息的地方，文件越多越大，删了文件也不会变小") -f (Fmt $mft)))
    $rest = $used - $files - $mft
    if ($used -gt 0 -and $rest -ge 0) { $a.Add(((T "· 其他 {0}：NTFS 的日志和变更日志、文件夹的索引、Windows 给系统更新预留的空间（保留的存储）等，不是普通文件") -f (Fmt $rest))) }
    $b = New-Object System.Collections.Generic.List[string]
    $b.Add(((T "· 按文件大小相加（资源管理器的算法）是 {0}") -f (Fmt ([double]$r.Size))))
    if ($r.Linked -gt 0) { $b.Add(((T "· 硬链接：{0} 的文件不止一个名字（大多在 WinSxS 和 System32 里），按名字相加会重复算，盘上只有一份") -f (Fmt ([double]$r.Linked)))) }
    $d = [double]$r.UniqueSize - [double]$r.UniqueDisk
    if ($d -ge 1MB) { $b.Add(((T "· 压缩、稀疏和只在云端的文件：实际占用比文件大小合计少 {0}（已经扣掉了零头按整块分配多占的部分）") -f (Fmt $d))) }
    elseif ($d -le -1MB) { $b.Add(((T "· 文件按整块（簇，通常 4 KB）分配，零头也占一整块：实际占用比文件大小合计多 {0}") -f (Fmt (-$d)))) }
    $text = ((T "{0} 已用 {1}（共 {2}），其中：") -f $drive.TrimEnd('\'), (Fmt $used), (Fmt $total)) + "`n" + ($a -join "`n") + "`n`n" + (T '和「按文件大小相加」的差别：') + "`n" + ($b -join "`n")
    if ($script:mapScanAt) { $text += "`n`n" + ((T "按 {0:HH:mm} 扫描的结果。") -f $script:mapScanAt) }
    Show-Sheet -Title (T '空间明细') -Text $text | Out-Null
}
$ctl.BtnMapAcct.Add_Click({ Show-SpaceAcct })
$ctl.MapGrow.Add_MouseDoubleClick({
    $g = $ctl.MapGrow.SelectedItem
    if (-not $g -or -not $script:mapRoot) { return }
    $node = [DiskMap]::Find($script:mapRoot, [string]$g.Path)
    if (-not $node) { Show-Sheet -Title (T '这次扫描里没有这个文件夹') -Text ((T "{0}`n`n它可能已经被删掉、改了名，或者变得很小。") -f $g.Path) | Out-Null; return }
    $ctl.MapViewDirs.IsChecked = $true
    Show-MapLevel $node
})
# 双击文件夹往里点。在按下左键（第二下）时处理，不等 MouseDoubleClick：复选框模式下按下已经被拦住不让列表选中，
# 那样列表就收不到 MouseDoubleClick 了。双击的是鼠标下面那一行；在复选框上连点两下只是勾两次，右键双击、双击滚动条都不算
function Enter-MapRow($r) {
    if ($r -and $r.Kind -eq 'type') {
        $k = ([string]$r.Path).Substring(5)
        foreach ($it in $ctl.MapType.Items) { if ([string]$it.Tag -eq $k) { $ctl.MapType.SelectedItem = $it } }
        $ctl.MapUnder.IsChecked = $false; $ctl.MapChat.IsChecked = $false
        $ctl.MapViewFiles.IsChecked = $true
        return $true
    }
    if ($r -and $r.Kind -eq 'recent') {
        if ($r.Node) { $ctl.MapViewDirs.IsChecked = $true; Show-MapLevel $r.Node } else { Open-Location $r.Path }
        return $true
    }
    if (-not ($r -and $r.IsDir -and $r.Node)) { return $false }
    if ($script:mapView -ne 'dirs' -and $script:mapView -ne 'tree') { $ctl.MapViewDirs.IsChecked = $true }
    Show-MapLevel $r.Node
    return $true
}
function Update-MapSel {
    $nAll = $ctl.MapList.Items.Count; $nSel = $ctl.MapList.SelectedItems.Count
    $ctl.MapAll.IsEnabled = ($script:mapView -eq 'dirs' -or $script:mapView -eq 'files') -and $nAll -gt 0
    $ctl.MapAll.IsChecked = if ($script:mapView -eq 'grow' -or $nSel -eq 0) { $false } elseif ($nSel -ge $nAll) { $true } else { $null }
    $sel = if ($script:mapView -ne 'grow') { @($ctl.MapList.SelectedItems) } else { @() }
    $r = if ($sel.Count -eq 1) { $sel[0] } else { $null }
    $busy = [bool]$script:worker
    $del = @($sel | Where-Object { -not $_.Locked -and $_.Size -gt 0 })
    $ctl.BtnMapOpen.IsEnabled = [bool]$r -and -not $busy
    $ctl.BtnMapDelete.IsEnabled = ($del.Count -gt 0) -and -not $busy
    $ctl.BtnMapCompress.IsEnabled = [bool]$r -and $r.IsDir -and -not $busy -and -not (Get-CompressBlock $r.Path)
    $ctl.BtnMapMark.IsEnabled = ($del.Count -gt 0)
    $ctl.BtnMapMark.Content = if ($del.Count -gt 0 -and @($del | Where-Object { -not $_.Marked }).Count -eq 0) { (T '从待删清单去掉') } else { (T '加入待删清单') }
    if ($sel.Count -eq 0) {
        $ctl.MapSel.Text = if (Test-CheckMode) { (T '勾选行前面的方框来选中，可以勾一项或多项，再打开位置、压缩或删除；单击行的其他地方不会选中，双击文件夹往里点；按住鼠标上下拖可以一次勾上连着的几行。系统文件夹、软件安装文件夹、C 盘个人文件夹和搬家后的数据带小锁，不能在这里删。') }
                           else { (T '选中一行可以打开位置、压缩或删除；勾选前面的方框，或按住 Ctrl、Shift，可以选多项一起删；按住鼠标（左键或右键）上下拖可以一次选中连着的几行。系统文件夹、软件安装文件夹、C 盘个人文件夹和搬家后的数据带小锁，不能在这里删。') }
        return
    }
    if ($sel.Count -gt 1) {
        $tot = [double]0; foreach ($x in $sel) { $tot += [double]$x.Size }
        $t = (T "已选 {0} 项，共 {1}") -f $sel.Count, (Fmt $tot)
        if ($del.Count -lt $sel.Count) { $t += ((T "（其中 {0} 项带小锁或是链接，不会删）") -f ($sel.Count - $del.Count)) }
        if (Test-CheckMode) { $t += (T '。点行前面的方框取消某一项，按 Esc 全部取消') }
        $ctl.MapSel.Text = $t; return
    }
    $ctl.MapSel.Text = if ($r.Locked) { (T "{0}：不能在这里删（{1}）") -f $r.Name, $r.LockTip } else { "{0}  {1}" -f $r.Name, $r.SizeText }
}
$script:bulkSel = $false
$ctl.MapList.Add_SelectionChanged({ if (-not $script:bulkSel) { Update-MapSel } })
$ctl.MapAll.Add_Click({
    $lv = $ctl.MapList
    if ($lv.Items.Count -gt 0 -and $lv.SelectedItems.Count -ge $lv.Items.Count) { $lv.UnselectAll() } else { $lv.SelectAll() }
    Update-MapSel
})
# ---------- 右键菜单：和下面的按钮做一样的事 ----------
function Invoke-Btn($b) { if ($b -and $b.IsEnabled) { $b.RaiseEvent((New-Object System.Windows.RoutedEventArgs ([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent))) } }
# 右键菜单打开前：照选中的行设好每一项能不能点（返回 $false：没选中，不弹菜单）
# 右键点到的那一行：点在勾着的行上，菜单对全部勾着的行起作用；点在没勾的行上，只对这一行（复选框模式下也不把它勾上）
$script:menuRow = $null; $script:menuRows = @()
function Update-MapMenu {
    if ($script:mapView -eq 'grow') { return $false }
    $r = $script:menuRow
    $rows = @(if ($r -and -not $ctl.MapList.SelectedItems.Contains($r)) { $r } else { $ctl.MapList.SelectedItems })
    $script:menuRows = $rows
    if ($rows.Count -eq 0) { return $false }
    $busy = [bool]$script:worker
    $one = if ($rows.Count -eq 1) { $rows[0] } else { $null }
    $ctl.MmEnter.Visibility = if ($one -and $one.IsDir -and $one.Node) { 'Visible' } else { 'Collapsed' }
    $ctl.MmOpen.IsEnabled = [bool]$one -and -not $busy
    $ctl.MmCopy.IsEnabled = (@($rows | Where-Object { $_.Path }).Count -gt 0)
    $ctl.MmCompress.IsEnabled = [bool]$one -and $one.IsDir -and -not $busy -and -not (Get-CompressBlock $one.Path)
    $nd = @($rows | Where-Object { -not $_.Locked -and $_.Size -gt 0 }).Count
    $ctl.MmDelete.IsEnabled = ($nd -gt 0) -and -not $busy
    $ctl.MmDelete.Header = if ($nd -gt 1) { (T "删除选中的 {0} 项…") -f $nd } else { (T '删除…') }
    $mk = @($rows | Where-Object { -not $_.Locked -and $_.Size -gt 0 -and -not $_.IsSummary })
    $ctl.MmMark.IsEnabled = $mk.Count -gt 0
    $ctl.MmMark.Header = if ($mk.Count -gt 0 -and @($mk | Where-Object { -not $_.Marked }).Count -eq 0) { (T '从待删清单去掉') } else { (T '加入待删清单') }
    return $true
}
$ctl.MapList.Add_ContextMenuOpening({ param($s, $e) if (-not (Update-MapMenu)) { $e.Handled = $true } })
$ctl.MmEnter.Add_Click({ [void](Enter-MapRow @($script:menuRows)[0]) })
$ctl.MmOpen.Add_Click({ $r = @($script:menuRows)[0]; if ($r) { Open-MapRow $r } })
$ctl.MmCompress.Add_Click({ $r = @($script:menuRows)[0]; if ($r -and $r.IsDir) { Start-FolderCompress $r.Path } })
$ctl.MmDelete.Add_Click({ Start-MapDelete @($script:menuRows) })
$ctl.MmCopy.Add_Click({
    $ps = @(@($script:menuRows) | Where-Object { $_.Path } | ForEach-Object { [string]$_.Path })
    if ($ps.Count -gt 0) { try { [System.Windows.Clipboard]::SetText(($ps -join "`r`n")); $ctl.MapSel.Text = (T "已复制 {0} 个路径") -f $ps.Count } catch {} }
})
# ---------- 按住鼠标（左键或右键）上下拖：选中连着的几行（像在资源管理器里拉框）；右键拖的话松开后弹出右键菜单 ----------
# 按住 Ctrl 再拖：在原来选中的基础上加上这一段
function Find-Visual($root, [type]$t) {
    $q = New-Object System.Collections.Queue; $q.Enqueue($root)
    while ($q.Count -gt 0) {
        $v = $q.Dequeue()
        if ($v -is $t) { return $v }
        $n = [System.Windows.Media.VisualTreeHelper]::GetChildrenCount($v)
        for ($k = 0; $k -lt $n; $k++) { $q.Enqueue([System.Windows.Media.VisualTreeHelper]::GetChild($v, $k)) }
    }
    return $null
}
# 纵坐标 y 处是第几行（-1 不在任何一行上）。横坐标取中间，行和行之间的缝上下各挪一点再找
function Get-RowAt($lv, [double]$y) {
    $h = [double]$lv.ActualHeight; if ($h -le 4) { return -1 }
    $yy = [math]::Min([math]::Max($y, 2.0), $h - 2.0)
    foreach ($dy in 0, -3, 3) {
        $pt = New-Object System.Windows.Point ([math]::Max(30.0, [double]$lv.ActualWidth / 2)), ($yy + $dy)
        $hit = $lv.InputHitTest($pt)
        if ($hit -is [System.Windows.DependencyObject]) {
            $c = $null; try { $c = [System.Windows.Controls.ItemsControl]::ContainerFromElement($lv, $hit) } catch {}
            if ($c) { return $lv.ItemContainerGenerator.IndexFromContainer($c) }
        }
    }
    # 拖到了最后一行下面的空白处：算最后一行
    $n = $lv.Items.Count
    if ($n -gt 0) {
        $last = $lv.ItemContainerGenerator.ContainerFromIndex($n - 1)
        if ($last) { try { if ($y -ge $last.TranslatePoint((New-Object System.Windows.Point 0, $last.ActualHeight), $lv).Y) { return $n - 1 } } catch {} }
    }
    return -1
}
$script:rdrag = $null
$script:rdragTimer = New-Object System.Windows.Threading.DispatcherTimer
$script:rdragTimer.Interval = [TimeSpan]::FromMilliseconds(50)
function Set-DragRange($d, [int]$to) {
    $lv = $d.Lv; $items = $lv.Items; $n = $items.Count
    if ($to -lt 0 -or $to -ge $n -or $to -eq $d.Cur -or $d.Anchor -ge $n) { return }
    $lo = [math]::Min([math]::Min($d.Anchor, $d.Cur), $to); $hi = [math]::Min($n - 1, [math]::Max([math]::Max($d.Anchor, $d.Cur), $to))
    $a = [math]::Min($d.Anchor, $to); $b = [math]::Max($d.Anchor, $to)
    $script:bulkSel = $true
    try {
        for ($i = $lo; $i -le $hi; $i++) {
            $it = $items[$i]
            $want = ($i -ge $a -and $i -le $b) -or ($d.Base -and $d.Base.Contains($it))
            $has = $lv.SelectedItems.Contains($it)
            if ($want -and -not $has) { [void]$lv.SelectedItems.Add($it) } elseif ($has -and -not $want) { [void]$lv.SelectedItems.Remove($it) }
        }
    } finally { $script:bulkSel = $false }
    $d.Cur = $to
    Update-MapSel
}
function Start-RowDrag($d) {
    $lv = $d.Lv
    if (-not $script:mapScroller) { $script:mapScroller = Find-Visual $lv ([System.Windows.Controls.ScrollViewer]) }
    # 鼠标交给列表里的滚动区，不交给列表本身：列表自己拿着鼠标时，右键拖会被它放掉，左键拖它会把选中改成鼠标下面的那一行
    $d.Cap = if ($script:mapScroller) { $script:mapScroller } else { $lv }
    $d.Moved = $true
    [void]$d.Cap.CaptureMouse()
    if ($d.Ctrl) { $d.Base = New-Object 'System.Collections.Generic.HashSet[object]'; foreach ($x in @($lv.SelectedItems)) { [void]$d.Base.Add($x) } }
    else {
        $script:bulkSel = $true
        try { $lv.SelectedItems.Clear(); [void]$lv.SelectedItems.Add($lv.Items[$d.Anchor]) } finally { $script:bulkSel = $false }
    }
    $script:rdragTimer.Start()
}
function Stop-RowDrag {
    $d = $script:rdrag; $script:rdrag = $null
    $script:rdragTimer.Stop()
    if ($d -and $d.Moved -and $d.Cap -and $d.Cap.IsMouseCaptured) { $d.Cap.ReleaseMouseCapture() }
}
function Get-DragButton($d) { if ($d.Button -eq 'Left') { [System.Windows.Input.Mouse]::LeftButton } else { [System.Windows.Input.Mouse]::RightButton } }
# 按下的地方在不在行前面的复选框上（在的话交给复选框，不拖选）
function Test-InCheckBox($lv, $el) {
    try {
        for ($v = $el; $v -and -not [object]::ReferenceEquals($v, $lv); $v = [System.Windows.Media.VisualTreeHelper]::GetParent($v)) {
            if ($v -is [System.Windows.Controls.CheckBox]) { return $true }
            if ($v -is [System.Windows.Controls.ListViewItem]) { return $false }
        }
    } catch {}
    return $false
}
# 复选框模式（设置里开着「项目复选框」）：只有点方框才选中、取消。单击行的其他地方不选，双击文件夹照常往里点；
# 按住鼠标上下拖是把拖过的行勾上（加在已勾的上面）；Ctrl 点照常加上或去掉一行；Shift 点是把上次勾的那一行到这一行都勾上；
# 键盘上下键只移动焦点，空格勾上或取消；Esc 全部取消
$script:tickAnchor = -1; $script:kbRow = -1; $script:lastPress = $null
function Test-CheckMode { $win.Resources['MapCkVis'] -eq [System.Windows.Visibility]::Visible -and ($script:mapView -eq 'dirs' -or $script:mapView -eq 'files') }
function Add-MapRange([int]$from, [int]$to) {
    $lv = $ctl.MapList; $n = $lv.Items.Count
    if ($to -lt 0 -or $to -ge $n) { return }
    if ($from -lt 0 -or $from -ge $n) { $from = $to }
    $script:bulkSel = $true
    try { for ($k = [math]::Min($from, $to); $k -le [math]::Max($from, $to); $k++) { $it = $lv.Items[$k]; if (-not $lv.SelectedItems.Contains($it)) { [void]$lv.SelectedItems.Add($it) } } }
    finally { $script:bulkSel = $false }
    $script:tickAnchor = $to
    Update-MapSel
}
# 按在第 i 行上（不是方框）：复选框模式下改成什么样。返回 Handled：不让列表自己去选；Add：接着拖的话加在已选的上面；NoDrag：不拖选
function Invoke-RowPress([int]$i, [string]$button, [bool]$shift, [bool]$ctrl) {
    if (-not (Test-CheckMode)) {
        if ($button -eq 'Left' -and $shift) { return @{ Handled = $false; Add = $false; NoDrag = $true } }   # Windows 列表自己会从上次点的那一行选到这里
        return @{ Handled = $false; Add = $ctrl; NoDrag = $false }
    }
    if ($ctrl) { $script:tickAnchor = $i; return @{ Handled = $false; Add = $true; NoDrag = $false } }   # Ctrl 点：照 Windows 列表加上或去掉这一行
    if ($button -eq 'Left' -and $shift) { Add-MapRange $script:tickAnchor $i; return @{ Handled = $true; Add = $true; NoDrag = $true } }
    return @{ Handled = $true; Add = $true; NoDrag = $false }      # 单击不选；拖到别的行才把拖过的勾上
}
# 点了方框：记下从哪一行接着用 Shift 勾
$ctl.MapList.AddHandler([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent, [System.Windows.RoutedEventHandler]{
    param($s, $e)
    if (-not ($e.OriginalSource -is [System.Windows.Controls.CheckBox])) { return }
    $c = $null; try { $c = [System.Windows.Controls.ItemsControl]::ContainerFromElement($ctl.MapList, $e.OriginalSource) } catch {}
    if ($c) { $script:tickAnchor = $ctl.MapList.ItemContainerGenerator.IndexFromContainer($c) }
})
# 键盘：Esc 全部取消；复选框模式下上下键只移动焦点，空格勾上或取消
$ctl.MapList.Add_PreviewKeyDown({
    param($s, $e)
    if ($e.Key -eq [System.Windows.Input.Key]::Escape -and $s.SelectedItems.Count -gt 0) { $s.UnselectAll(); $e.Handled = $true; return }
    if (-not (Test-CheckMode)) { return }
    if ([System.Windows.Input.Keyboard]::Modifiers -band ([System.Windows.Input.ModifierKeys]::Control -bor [System.Windows.Input.ModifierKeys]::Shift -bor [System.Windows.Input.ModifierKeys]::Alt)) { return }
    $n = $s.Items.Count; if ($n -eq 0) { return }
    $cur = -1; $f = [System.Windows.Input.Keyboard]::FocusedElement
    if ($f -is [System.Windows.Controls.ListViewItem]) { $cur = $s.ItemContainerGenerator.IndexFromContainer($f) }
    elseif ($script:kbRow -ge 0 -and $script:kbRow -lt $n) { $cur = $script:kbRow }
    $k = $e.Key
    if ($k -eq [System.Windows.Input.Key]::Space) {
        if ($cur -ge 0) { $it = $s.Items[$cur]; if ($s.SelectedItems.Contains($it)) { [void]$s.SelectedItems.Remove($it) } else { [void]$s.SelectedItems.Add($it) }; $script:tickAnchor = $cur }
        $e.Handled = $true; return
    }
    $to = if ($k -eq [System.Windows.Input.Key]::Down) { $cur + 1 } elseif ($k -eq [System.Windows.Input.Key]::Up) { [math]::Max(0, $cur - 1) } elseif ($k -eq [System.Windows.Input.Key]::Home) { 0 } elseif ($k -eq [System.Windows.Input.Key]::End) { $n - 1 }
          elseif ($k -eq [System.Windows.Input.Key]::PageDown) { $cur + 10 } elseif ($k -eq [System.Windows.Input.Key]::PageUp) { [math]::Max(0, $cur - 10) } else { -1 }
    if ($to -lt 0) { return }
    $e.Handled = $true
    $to = [math]::Min($n - 1, $to)
    $s.ScrollIntoView($s.Items[$to]); $s.UpdateLayout()
    $c = $s.ItemContainerGenerator.ContainerFromIndex($to); if ($c) { [void]$c.Focus() }
    $script:kbRow = $to
})
# 按下：记下从哪一行开始；真正拖到别的行才算拖选
function Begin-RowDrag($s, $e, [string]$button) {
    Stop-RowDrag
    if (-not ($e.OriginalSource -is [System.Windows.DependencyObject])) { if ($button -eq 'Right') { $script:menuRow = $null }; return }
    if ($button -eq 'Left' -and (Test-InCheckBox $s $e.OriginalSource)) { return }
    $mods = [System.Windows.Input.Keyboard]::Modifiers
    $shift = ($mods -band [System.Windows.Input.ModifierKeys]::Shift) -ne 0
    $ctrl = ($mods -band [System.Windows.Input.ModifierKeys]::Control) -ne 0
    $c = $null; try { $c = [System.Windows.Controls.ItemsControl]::ContainerFromElement($s, $e.OriginalSource) } catch {}
    if ($button -eq 'Right') { $script:menuRow = if ($c) { $c.Content } else { $null } }
    if (-not $c) { return }
    if ($button -eq 'Left') {
        # 双击：Windows 给的点击次数，或者自己算（同一行、在系统设的双击时间内、鼠标没怎么动）
        $pt = $e.GetPosition($s); $row = $c.Content
        $lp = $script:lastPress
        $dbl = $e.ClickCount -ge 2 -or ($lp -and [object]::ReferenceEquals($lp.Row, $row) -and ($e.Timestamp - $lp.Ts) -ge 0 -and ($e.Timestamp - $lp.Ts) -le [System.Windows.Forms.SystemInformation]::DoubleClickTime -and
                                        [math]::Abs($pt.X - $lp.X) -le 6 -and [math]::Abs($pt.Y - $lp.Y) -le 6)
        $script:lastPress = if ($dbl) { $null } else { @{ Row = $row; Ts = $e.Timestamp; X = $pt.X; Y = $pt.Y } }
        if ($dbl) {
            if (Enter-MapRow $row) { $e.Handled = $true }
            elseif ($row -and $row.IsDir) { Write-LogFile ((T "空间地图：双击的「{0}」进不去（扫描结果里没有它的下一层）") -f $row.Name) }
            return
        }
    }
    $i = $s.ItemContainerGenerator.IndexFromContainer($c)
    if ($i -lt 0) { return }
    $p = Invoke-RowPress $i $button $shift $ctrl
    # 不选中；键盘焦点给列表（不给这一行：给行的话列表会把它滚进视野，两下之间行就挪了位置，双击会点到别的行）
    if ($p.Handled) { $e.Handled = $true; $script:kbRow = $i; try { if (-not $s.IsKeyboardFocusWithin) { [void]$s.Focus() } } catch {} }
    if ($p.NoDrag) { return }
    $script:rdrag = @{ Lv = $s; Anchor = $i; Cur = $i; Moved = $false; Ctrl = [bool]$p.Add; Base = $null; Cap = $null; Button = $button }
}
$ctl.MapList.Add_PreviewMouseLeftButtonDown({ param($s, $e) Begin-RowDrag $s $e 'Left' })
$ctl.MapList.Add_PreviewMouseRightButtonDown({ param($s, $e) Begin-RowDrag $s $e 'Right' })
$ctl.MapList.Add_PreviewMouseMove({
    param($s, $e)
    $d = $script:rdrag
    if (-not $d) { return }
    $st = if ($d.Button -eq 'Left') { $e.LeftButton } else { $e.RightButton }
    if ($st -ne [System.Windows.Input.MouseButtonState]::Pressed) { Stop-RowDrag; return }
    $i = Get-RowAt $s ($e.GetPosition($s).Y)
    if (-not $d.Moved) { if ($i -lt 0 -or $i -eq $d.Anchor) { return }; Start-RowDrag $d }
    Set-DragRange $d $i
})
$ctl.MapList.Add_PreviewMouseLeftButtonUp({ if ($script:rdrag -and $script:rdrag.Button -eq 'Left') { Stop-RowDrag } })
$ctl.MapList.Add_PreviewMouseRightButtonUp({ if ($script:rdrag -and $script:rdrag.Button -eq 'Right') { Stop-RowDrag } })
# 拖选中鼠标被别处拿走了（比如切到别的窗口）：停下。列表把鼠标交出来时也会收到这个，那时不算
$ctl.MapList.Add_LostMouseCapture({ param($s, $e) $d = $script:rdrag; if ($d -and $d.Moved -and $d.Cap -and [object]::ReferenceEquals($e.OriginalSource, $d.Cap)) { $script:rdrag = $null; $script:rdragTimer.Stop() } })
# 拖到列表上面或下面：自动滚动，边滚边选
$script:rdragTimer.Add_Tick({
    $d = $script:rdrag
    if (-not $d -or -not $d.Moved) { $script:rdragTimer.Stop(); return }
    if ((Get-DragButton $d) -ne [System.Windows.Input.MouseButtonState]::Pressed) { Stop-RowDrag; return }
    $lv = $d.Lv; $y = [System.Windows.Input.Mouse]::GetPosition($lv).Y; $h = [double]$lv.ActualHeight
    if ($y -ge 0 -and $y -le $h) { return }
    $sv = $script:mapScroller; if (-not $sv) { return }
    $over = if ($y -lt 0) { -$y } else { $y - $h }
    $steps = [math]::Min(4, 1 + [int][math]::Floor($over / 30))
    for ($k = 0; $k -lt $steps; $k++) { if ($y -lt 0) { $sv.LineUp() } else { $sv.LineDown() } }
    $lv.UpdateLayout()
    Set-DragRange $d (Get-RowAt $lv $y)
})
function Csv-Line([object[]]$cells) {
    (@($cells | ForEach-Object { $s = [string]$_; if ($s -match '[",\r\n]') { '"' + $s.Replace('"', '""') + '"' } else { $s } }) -join ',')
}
# ---------- 导出报告：一个独立的网页，浏览器里按 Ctrl+P 可以存成 PDF ----------
function New-MapReport {
    $root = $script:mapRoot
    $H = { param($s) [System.Net.WebUtility]::HtmlEncode([string]$s) }
    $drive = $root.FullPath()
    $total = [double]0; $free = [double]0
    try { $di = New-Object System.IO.DriveInfo $drive; $total = [double]$di.TotalSize; $free = [double]$di.AvailableFreeSpace } catch {}
    $sb = New-Object System.Text.StringBuilder
    $add = { param($s) [void]$sb.Append($s) }
    # 网页里的坐标和宽度一律用小数点（有的系统设置里小数点是逗号，SVG 不认）
    $num = { param($v) ([double]$v).ToString('0.#', [Globalization.CultureInfo]::InvariantCulture) }
    $bar = { param($v, $max) $w = if ($max -gt 0) { [math]::Max(0.5, 100.0 * $v / $max) } else { 0 }; '<div class="bar"><i style="width:{0}%"></i></div>' -f (& $num $w) }
    $title = (T "空间报告：{0}") -f $drive
    & $add ('<!doctype html><html lang="{0}"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><title>{1}</title>' -f $(if ($script:Lang -eq 'en') { 'en' } else { 'zh-CN' }), (& $H $title))
    & $add @"
<style>
:root { --fg:#1d1d1f; --mute:#6e6e73; --line:#e5e5ea; --soft:#f5f5f7; --blue:#0071e3; }
* { box-sizing:border-box; }
body { margin:0; background:#fff; color:var(--fg); font:14px/1.55 "Segoe UI","Microsoft YaHei UI","PingFang SC",sans-serif; }
main { max-width:1040px; margin:0 auto; padding:32px 24px 48px; }
h1 { font-size:26px; margin:0 0 4px; }
h2 { font-size:17px; margin:34px 0 10px; }
.meta { color:var(--mute); margin:0 0 18px; }
.cards { display:grid; grid-template-columns:repeat(auto-fit,minmax(170px,1fr)); gap:10px; margin:14px 0 6px; }
.card { background:var(--soft); border-radius:10px; padding:12px 14px; }
.card b { display:block; font-size:20px; } .card span { color:var(--mute); font-size:12.5px; }
table { width:100%; border-collapse:collapse; }
th, td { text-align:left; padding:7px 8px; border-bottom:1px solid var(--line); vertical-align:middle; }
th { color:var(--mute); font-weight:600; font-size:12.5px; }
td.n, th.n { text-align:right; white-space:nowrap; }
td.p { word-break:break-all; color:var(--mute); font-size:12.5px; }
.bar { background:#eef0f4; border-radius:4px; height:8px; min-width:120px; } .bar i { display:block; height:8px; border-radius:4px; background:var(--blue); }
.up { color:#d70015; font-weight:600; } .down { color:#248a3d; font-weight:600; }
svg { width:100%; height:auto; display:block; border-radius:8px; }
.note { color:var(--mute); font-size:12.5px; margin-top:8px; }
footer { margin-top:40px; color:var(--mute); font-size:12px; border-top:1px solid var(--line); padding-top:12px; }
@media print { main { padding:0; } h2 { break-after:avoid; } tr { break-inside:avoid; } }
</style></head><body><main>
"@
    & $add ('<h1>{0}</h1>' -f (& $H $title))
    $when = if ($script:mapScanAt) { $script:mapScanAt } else { Get-Date }
    & $add ('<p class="meta">{0}</p>' -f (& $H ((T "扫描于 {0:yyyy-MM-dd HH:mm}，扫描到 {1:N0} 个文件") -f $when, $root.Files)))
    & $add '<div class="cards">'
    foreach ($c in @(@((T '磁盘容量'), $total), @((T '已用'), [math]::Max([double]0, $total - $free)), @((T '剩余'), $free), @((T '扫描到的文件一共'), [double]$root.Size))) {
        if ($c[1] -le 0) { continue }
        & $add ('<div class="card"><b>{0}</b><span>{1}</span></div>' -f (& $H (Fmt $c[1])), (& $H $c[0]))
    }
    & $add '</div>'

    # 方块图：第一层文件夹
    $kids = @($root.Kids | Where-Object { -not $_.IsLink -and $_.Size -gt 0 })
    if ($kids.Count -gt 0) {
        & $add ('<h2>{0}</h2>' -f (& $H (T '方块图：第一层文件夹')))
        $W = 1000; $Hh = 440
        $show = @($kids | Select-Object -First 40); $rest = [double]0; foreach ($k in @($kids | Select-Object -Skip 40)) { $rest += [double]$k.Size }
        $own = [double]$root.Own; if ($own -gt 0) { $rest += $own }
        $sizes = @($show | ForEach-Object { [double]$_.Size }); if ($rest -gt 0) { $sizes += $rest }
        $order = @(0..($sizes.Count - 1) | Sort-Object { $sizes[$_] } -Descending)
        $sorted = [double[]]@($order | ForEach-Object { $sizes[$_] })
        $rects = Get-TreeRects $sorted 0 0 $W $Hh
        & $add ('<svg viewBox="0 0 {0} {1}" role="img" aria-label="{2}">' -f $W, $Hh, (& $H (T '方块图：第一层文件夹')))
        for ($q = 0; $q -lt $order.Count; $q++) {
            $i = $order[$q]; $rc = $rects[$q]; if (-not $rc) { continue }
            $isRest = ($i -ge $show.Count)
            $name = if ($isRest) { (T '其他') } else { $show[$i].Name }
            $fill = if ($isRest) { '#c7ccd6' } else { $script:treeColors[$q % $script:treeColors.Count] }
            & $add ('<g><title>{0}  {1}</title><rect x="{2}" y="{3}" width="{4}" height="{5}" rx="3" fill="{6}" stroke="#fff" stroke-width="2"/>' -f (& $H $name), (& $H (Fmt $sorted[$q])), (& $num $rc[0]), (& $num $rc[1]), (& $num $rc[2]), (& $num $rc[3]), $fill)
            if ($rc[2] -gt 70 -and $rc[3] -gt 30) {
                # 估算文字宽度：中日韩文字约 13 像素，其他约 7.5 像素
                $room = $rc[2] - 14; $wsum = 0.0; $cut = $name.Length
                for ($c = 0; $c -lt $name.Length; $c++) { $wsum += $(if ([int][char]$name[$c] -ge 0x2E80) { 13 } else { 7.5 }); if ($wsum -gt $room) { $cut = [math]::Max(1, $c - 1); break } }
                $label = if ($cut -lt $name.Length) { $name.Substring(0, $cut) + '…' } else { $name }
                & $add ('<text x="{0}" y="{1}" fill="#fff" font-size="13" font-weight="600">{2}</text>' -f (& $num ($rc[0] + 7)), (& $num ($rc[1] + 18)), (& $H $label))
                if ($rc[3] -gt 44) { & $add ('<text x="{0}" y="{1}" fill="#fff" font-size="12" opacity=".9">{2}</text>' -f (& $num ($rc[0] + 7)), (& $num ($rc[1] + 35)), (& $H (Fmt $sorted[$q]))) }
            }
            & $add '</g>'
        }
        & $add '</svg>'

        & $add ('<h2>{0}</h2><table><tr><th>{1}</th><th class="n">{2}</th><th class="n">{3}</th><th>{4}</th><th class="n">{5}</th><th class="n">{6}</th></tr>' -f (& $H (T '最占空间的文件夹')), (& $H (T '文件夹')), (& $H (T '大小')), (& $H (T '占比')), '', (& $H (T '文件数')), (& $H (T '最近修改')))
        $max = [double]$kids[0].Size
        foreach ($k in @($kids | Select-Object -First 30)) {
            $w2 = if ($k.LastWrite -gt 0) { try { [DateTime]::FromFileTime($k.LastWrite).ToString('yyyy-MM-dd') } catch { '' } } else { '' }
            & $add ('<tr><td>{0}</td><td class="n">{1}</td><td class="n">{2:0.0}%</td><td>{3}</td><td class="n">{4:N0}</td><td class="n">{5}</td></tr>' -f (& $H $k.Name), (& $H (Fmt $k.Size)), (100.0 * $k.Size / [math]::Max(1, [double]$root.Size)), (& $bar ([double]$k.Size) $max), $k.Files, $w2)
        }
        & $add '</table>'

        # 再往下一层：第二层里最大的
        $g2 = New-Object System.Collections.ArrayList
        foreach ($k in $kids) { foreach ($c in $k.Kids) { if (-not $c.IsLink -and $c.Size -gt 0) { [void]$g2.Add($c) } } }
        $g2s = @($g2 | Sort-Object { [double]$_.Size } -Descending | Select-Object -First 25)
        if ($g2s.Count -gt 0) {
            & $add ('<h2>{0}</h2><table><tr><th>{1}</th><th class="n">{2}</th><th>{3}</th></tr>' -f (& $H (T '再往下一层：最大的文件夹')), (& $H (T '路径')), (& $H (T '大小')), '')
            $max = [double]$g2s[0].Size
            foreach ($c in $g2s) { & $add ('<tr><td class="p">{0}</td><td class="n">{1}</td><td>{2}</td></tr>' -f (& $H $c.FullPath()), (& $H (Fmt $c.Size)), (& $bar ([double]$c.Size) $max)) }
            & $add '</table>'
        }
    }

    # 最大的文件
    $bf = [DiskMap]::FindFiles(1MB, [DateTime]::MaxValue, '', '', $null, 30)
    if ($bf.Files.Count -gt 0) {
        & $add ('<h2>{0}</h2><table><tr><th>{1}</th><th class="n">{2}</th><th class="n">{3}</th></tr>' -f (& $H (T '最大的 30 个文件')), (& $H (T '路径')), (& $H (T '大小')), (& $H (T '最近修改')))
        foreach ($f in $bf.Files) { & $add ('<tr><td class="p">{0}</td><td class="n">{1}</td><td class="n">{2:yyyy-MM-dd}</td></tr>' -f (& $H $f.Path), (& $H (Fmt $f.Size)), $f.Modified) }
        & $add '</table>'
    }

    # 按类型统计：扫描时数过全部文件就用那个，否则只有 1 MB 以上的
    $tr = $script:mapRoot
    if ($tr -and $tr.TypeBytes) {
        $order = @(0..9 | Where-Object { $tr.TypeCount[$_] -gt 0 } | Sort-Object { $tr.TypeBytes[$_] } -Descending)
        if ($order.Count -gt 0) {
            & $add ('<h2>{0}</h2><table><tr><th>{1}</th><th class="n">{2}</th><th class="n">{3}</th><th>{4}</th></tr>' -f (& $H (T '各类文件占多少')), (& $H (T '类型')), (& $H (T '文件数')), (& $H (T '大小')), '')
            $max = [double]$tr.TypeBytes[$order[0]]
            foreach ($i in $order) { & $add ('<tr><td>{0}</td><td class="n">{1:N0}</td><td class="n">{2}</td><td>{3}</td></tr>' -f (& $H $script:catNames[$i]), $tr.TypeCount[$i], (& $H (Fmt ([double]$tr.TypeBytes[$i]))), (& $bar ([double]$tr.TypeBytes[$i]) $max)) }
            & $add '</table>'
        }
    }
    $ext = if ($tr -and $tr.TypeBytes) { @{} } else { [DiskMap]::ExtTotals() }
    if ($ext.Count -gt 0) {
        $names = [ordered]@{ video = (T '视频'); archive = (T '压缩包和安装包'); image = (T '光盘映像和虚拟磁盘'); picture = (T '图片'); music = (T '音乐'); doc = (T '文档'); program = (T '程序和游戏数据'); log = (T '日志、转储和临时文件'); other = (T '其他类型') }
        $of = @{}; foreach ($k in $script:mapTypes.Keys) { foreach ($e in ($script:mapTypes[$k] -split ' ')) { if ($e) { $of[$e.ToLowerInvariant()] = $k } } }
        $sum = @{}; foreach ($k in $names.Keys) { $sum[$k] = @([long]0, [double]0) }
        foreach ($kv in $ext.GetEnumerator()) { $g = $of[([string]$kv.Key).ToLowerInvariant()]; if (-not $g) { $g = 'other' }; $sum[$g][0] += $kv.Value[0]; $sum[$g][1] += [double]$kv.Value[1] }
        $rows = @($names.Keys | Where-Object { $sum[$_][1] -gt 0 } | Sort-Object { $sum[$_][1] } -Descending)
        if ($rows.Count -gt 0) {
            & $add ('<h2>{0}</h2><table><tr><th>{1}</th><th class="n">{2}</th><th class="n">{3}</th><th>{4}</th></tr>' -f (& $H (T '各类文件占多少')), (& $H (T '类型')), (& $H (T '文件数')), (& $H (T '大小')), '')
            $max = [double]$sum[$rows[0]][1]
            foreach ($k in $rows) { & $add ('<tr><td>{0}</td><td class="n">{1:N0}</td><td class="n">{2}</td><td>{3}</td></tr>' -f (& $H $names[$k]), $sum[$k][0], (& $H (Fmt $sum[$k][1])), (& $bar $sum[$k][1] $max)) }
            & $add '</table>'
            & $add ('<p class="note">{0}</p>' -f (& $H (T '只统计扫描时记下的 1 MB 以上的文件。')))
        }
    }

    # 和上次比
    if ($script:growRows -and $script:growRows.Count -gt 0) {
        & $add ('<h2>{0}</h2><table><tr><th>{1}</th><th class="n">{2}</th><th class="n">{3}</th><th class="n">{4}</th></tr>' -f (& $H (T '和上次扫描相比')), (& $H (T '文件夹')), (& $H (T '上次')), (& $H (T '这次')), (& $H (T '变化')))
        foreach ($g in @($script:growRows | Select-Object -First 30)) {
            $cls = if ($g.NowBytes -ge $g.BeforeBytes) { 'up' } else { 'down' }
            & $add ('<tr><td class="p">{0}</td><td class="n">{1}</td><td class="n">{2}</td><td class="n {3}">{4}</td></tr>' -f (& $H $g.Path), (& $H $g.Before), (& $H $g.Now), $cls, (& $H $g.Change))
        }
        & $add '</table>'
        if ($script:growNote) { & $add ('<p class="note">{0}</p>' -f (& $H $script:growNote)) }
    }
    & $add ('<footer>{0}</footer></main></body></html>' -f (& $H ((T "由腾挪 ClearC {0} 生成，{1:yyyy-MM-dd HH:mm}。报告里只有文件夹和文件的名字、大小，不含文件内容。") -f $script:AppVersion, (Get-Date))))
    return $sb.ToString()
}
$ctl.BtnMapReport.Add_Click({
    if (-not $script:mapRoot) { Show-Sheet -Title (T '还没有扫描') -Text (T '先扫描一块盘，再导出报告。') | Out-Null; return }
    $dlg = New-Object Microsoft.Win32.SaveFileDialog
    $dlg.Filter = (T '网页报告') + '|*.html'
    $dlg.FileName = '{0}-{1}-{2:yyyyMMdd-HHmm}.html' -f (T '空间报告'), $script:mapRoot.FullPath().Substring(0, 1), (Get-Date)
    try { $dlg.InitialDirectory = [Environment]::GetFolderPath('Desktop') } catch {}
    if (-not $dlg.ShowDialog($win)) { return }
    $win.Cursor = [System.Windows.Input.Cursors]::Wait
    try { $html = New-MapReport; [IO.File]::WriteAllText($dlg.FileName, $html, (New-Object Text.UTF8Encoding $true)) }
    catch { $win.Cursor = $null; Show-Sheet -Kind warn -Title (T '没能保存') -Text $_.Exception.Message | Out-Null; return }
    finally { $win.Cursor = $null }
    UI-Log ((T "空间地图：报告已保存到 {0}") -f $dlg.FileName)
    $ans = Show-Sheet -Kind done -Title (T '报告已保存') -Text ((T "{0}`n`n用浏览器打开就能看；想要 PDF，在浏览器里按 Ctrl+P，打印机选「另存为 PDF」。") -f $dlg.FileName) -Buttons @((T '打开所在位置'), (T '打开报告')) -Primary (T '打开报告') -Cancel (T '打开所在位置')
    if ($ans -eq (T '打开报告')) { try { Start-Process -FilePath $dlg.FileName } catch { Open-Location $dlg.FileName } }
    elseif ($ans -eq (T '打开所在位置')) { Open-Location $dlg.FileName }
})
$ctl.BtnMapExport.Add_Click({
    $v = $script:mapView
    $list = @(if ($v -eq 'grow') { $script:growRows } else { $ctl.MapList.ItemsSource })
    if (-not $script:mapRoot -or $list.Count -eq 0) { Show-Sheet -Title (T '没有可以导出的内容') -Text (T '先扫描一块盘，再导出看到的列表。') | Out-Null; return }
    $what = switch ($v) { 'files' { (T '找文件') } 'grow' { (T '和上次比') } default { (T '文件夹') } }
    $dlg = New-Object Microsoft.Win32.SaveFileDialog
    $dlg.Filter = (T 'CSV 文件（可以用 Excel 打开）') + '|*.csv'
    $dlg.FileName = '{0}-{1}-{2}-{3:yyyyMMdd-HHmm}.csv' -f (T '空间地图'), $script:mapRoot.FullPath().Substring(0, 1), $what, (Get-Date)
    try { $dlg.InitialDirectory = [Environment]::GetFolderPath('Desktop') } catch {}
    if (-not $dlg.ShowDialog($win)) { return }
    $lines = New-Object System.Collections.Generic.List[string]
    if ($v -eq 'grow') {
        $lines.Add((Csv-Line @((T '文件夹'), (T '上次（字节）'), (T '这次（字节）'), (T '变化（字节）'), (T '上次'), (T '这次'), (T '变化'))))
        foreach ($g in $list) { $lines.Add((Csv-Line @($g.Path, [long]$g.BeforeBytes, [long]$g.NowBytes, [long]($g.NowBytes - $g.BeforeBytes), $g.Before, $g.Now, $g.Change))) }
    } else {
        $lines.Add((Csv-Line @((T '名称'), (T '路径'), (T '类型'), (T '大小（字节）'), (T '大小'), (T '文件数'), (T '最近修改'))))
        foreach ($r in $list) {
            if ($r.IsSummary) { continue }
            $k = if ($r.Kind -eq 'type') { (T '类型') } elseif ($r.Kind -eq 'recent') { (T '最近改动') } elseif ($r.IsDir) { (T '文件夹') } elseif ($r.Node -and $r.Node.IsLink) { (T '链接') } else { (T '文件') }
            $lines.Add((Csv-Line @($r.Name, $r.Path, $k, [long]$r.Size, $r.SizeText, $(if ($r.IsDir) { $r.FileCount } else { '' }), $r.When)))
        }
    }
    try { [IO.File]::WriteAllLines($dlg.FileName, $lines.ToArray(), (New-Object Text.UTF8Encoding $true)) }
    catch { Show-Sheet -Kind warn -Title (T '没能保存') -Text $_.Exception.Message | Out-Null; return }
    UI-Log ((T "空间地图：已导出 {0} 行到 {1}") -f $list.Count, $dlg.FileName)
    $ans = Show-Sheet -Kind done -Title (T '已导出') -Text ((T "{0:N0} 行，已保存到：`n{1}") -f $list.Count, $dlg.FileName) -Buttons @((T '打开所在位置'), (T '好')) -Primary (T '好') -Cancel (T '好')
    if ($ans -eq (T '打开所在位置')) { Open-Location $dlg.FileName }
})
function Open-MapRow($r) { if ($r.IsSummary) { if ($script:mapCur) { Open-Location $script:mapCur.FullPath() } } else { Open-Location $r.Path } }
$ctl.BtnMapOpen.Add_Click({ $r = $ctl.MapList.SelectedItem; if ($r) { Open-MapRow $r } })

# 和上次比：每次扫描存一份快照（带日期，每块盘最多留 40 份），和选定的那一份对比，列出变化最大的文件夹，
# 并用一句话说清多出来的空间主要在哪（Docker、浏览器缓存、某个文件夹……）
function Read-Snapshot([string]$file) {
    $old = @{}; $oldAt = ''; $oldHow = 'walk'; $used = [double]-1
    foreach ($l in [IO.File]::ReadAllLines($file, [Text.Encoding]::UTF8)) {
        if ($l.StartsWith('#method=')) { $oldHow = $l.Substring(8).Trim(); continue }
        if ($l.StartsWith('#used=')) { $used = [double]$l.Substring(6).Trim(); continue }
        if ($l.StartsWith('#')) { $oldAt = $l.TrimStart('#').Trim(); continue }
        $a = $l.Split("`t"); if ($a.Count -eq 2) { $old[$a[0].ToLowerInvariant()] = [double]$a[1] }
    }
    return @{ Map = $old; At = $oldAt; How = $oldHow; Used = $used }
}
# 选「和哪次比」：上一次，或者 N 天前最近的一份（没那么早的就拿最早的）
function Pick-Snapshot([string]$letter, [int]$days) {
    $latest = Join-Path $script:snapDir "$letter-latest.txt"
    if ($days -le 0) { return $(if (Test-Path -LiteralPath $latest) { $latest } else { '' }) }
    $files = @(Get-ChildItem -LiteralPath $script:snapDir -Filter "$letter-2*.txt" -ErrorAction SilentlyContinue | Sort-Object Name)
    if ($files.Count -eq 0) { return $(if (Test-Path -LiteralPath $latest) { $latest } else { '' }) }
    $cut = (Get-Date).AddDays(-$days)
    $pick = $null
    foreach ($f in $files) {
        $t = $null; try { $t = [DateTime]::ParseExact($f.BaseName.Substring(2), 'yyyyMMdd-HHmm', $null) } catch { continue }
        if ($t -le $cut) { $pick = $f } else { break }
    }
    if (-not $pick) { $pick = $files[0] }
    return $pick.FullName
}
function Update-Growth($root) {
    $letter = $root.FullPath().Substring(0, 1).ToUpper()
    New-Item -ItemType Directory -Path $script:snapDir -Force | Out-Null
    $latest = Join-Path $script:snapDir "$letter-latest.txt"
    $snap = [DiskMap]::Snapshot($root, 4, 100MB)
    $script:curSnap = $snap
    # 先和上一次比（界面上默认选的就是它），再把这次存起来
    Compare-Snapshot $root
    $out = New-Object System.Collections.Generic.List[string]
    $out.Add(('#method=' + $(if ([string]$script:mapMethod -like 'mft*') { 'mft' } else { 'walk' })))   # 放在日期前面：旧版本只认最后一个 # 行当日期
    $used = [double]-1; try { $di = New-Object System.IO.DriveInfo ($root.FullPath()); $used = [double]($di.TotalSize - $di.TotalFreeSpace) } catch {}
    if ($used -ge 0) { $out.Add('#used=' + [long]$used) }
    $out.Add(("# {0:yyyy-MM-dd HH:mm}" -f (Get-Date)))
    foreach ($l in $snap) { $out.Add($l) }
    if (Test-Path -LiteralPath $latest) { Copy-Item -LiteralPath $latest -Destination (Join-Path $script:snapDir "$letter-previous.txt") -Force -ErrorAction SilentlyContinue }
    [IO.File]::WriteAllLines($latest, $out.ToArray(), (New-Object Text.UTF8Encoding $false))
    # 带日期的一份：一天最多留一份（同一天的覆盖），总共最多 40 份
    $dated = Join-Path $script:snapDir ("{0}-{1:yyyyMMdd-HHmm}.txt" -f $letter, (Get-Date))
    foreach ($f in @(Get-ChildItem -LiteralPath $script:snapDir -Filter ("{0}-{1:yyyyMMdd}-*.txt" -f $letter, (Get-Date)) -ErrorAction SilentlyContinue)) { Remove-Item -LiteralPath $f.FullName -Force -ErrorAction SilentlyContinue }
    Copy-Item -LiteralPath $latest -Destination $dated -Force -ErrorAction SilentlyContinue
    $all = @(Get-ChildItem -LiteralPath $script:snapDir -Filter "$letter-2*.txt" -ErrorAction SilentlyContinue | Sort-Object Name)
    if ($all.Count -gt 40) { foreach ($f in @($all | Select-Object -First ($all.Count - 40))) { Remove-Item -LiteralPath $f.FullName -Force -ErrorAction SilentlyContinue } }
}
# 多出来（或少掉）的空间主要在哪：从变化最大的文件夹里挑互不包含的几个，认得出的（Docker、WSL、浏览器缓存、Windows 更新……）写名字
function Explain-Growth($items, [double]$totalDelta) {
    $known = @(
        @('\docker\', (T 'Docker 数据')), @('docker-desktop', (T 'Docker 数据')), @('\ext4.vhdx', (T 'WSL 发行版')), @('\packages\canonicalgrouplimited', (T 'WSL 发行版')),
        @('\softwaredistribution', (T 'Windows 更新')), @('\windows.old', 'Windows.old'), @('\$recycle.bin', (T '回收站')), @('\winsxs', (T '组件存储（WinSxS）')),
        @('\user data\', (T '浏览器缓存和数据')), @('\cache', (T '缓存')), @('\temp', (T '临时文件')), @('\steamapps', (T 'Steam 游戏')), @('\appdata\local\packages', (T '应用商店软件')),
        @('\onedrive', 'OneDrive'), @('\xwechat_files', (T '微信数据')), @('\wechat files', (T '微信数据')), @('\tencent files', (T 'QQ 数据')), @('\minidump', (T '蓝屏转储')), @('\memory.dmp', (T '蓝屏转储')),
        @('\node_modules', 'node_modules'), @('\.nuget', (T 'NuGet 包')), @('\jetbrains', (T 'JetBrains 缓存')), @('\videos', (T '视频')), @('\downloads', (T '下载'))
    )
    $sign = if ($totalDelta -ge 0) { 1 } else { -1 }
    $cands = @($items | Where-Object { $_.D * $sign -gt 0 } | Sort-Object { $_.D * $sign } -Descending)
    $picked = New-Object System.Collections.ArrayList
    foreach ($c in $cands) {
        if ($picked.Count -ge 4) { break }
        $p = ([string]$c.P).TrimEnd('\').ToLowerInvariant()
        $dup = $false
        foreach ($q in $picked) { $qp = ([string]$q.P).TrimEnd('\').ToLowerInvariant(); if ($p.StartsWith($qp + '\') -or $qp.StartsWith($p + '\') -or $p -eq $qp) { $dup = $true; break } }
        if ($dup) { continue }
        if ([math]::Abs($c.D) -lt [math]::Max(200MB, [math]::Abs($totalDelta) * 0.08)) { break }
        [void]$picked.Add($c)
    }
    $parts = New-Object System.Collections.Generic.List[string]
    $acc = [double]0
    foreach ($c in $picked) {
        $p = ([string]$c.P).ToLowerInvariant() + '\'
        $name = $null; foreach ($k in $known) { if ($p -like ('*' + $k[0] + '*')) { $name = $k[1]; break } }
        $label = if ($name) { "{0}（{1}）" -f $name, (Shorten ([string]$c.P)) } else { Shorten ([string]$c.P) }
        $parts.Add(("{0} {1}{2}" -f $label, $(if ($c.D -gt 0) { '+' } else { '−' }), (Fmt ([math]::Abs($c.D)))))
        $acc += $c.D
    }
    $rest = $totalDelta - $acc
    if ($parts.Count -gt 0 -and [math]::Abs($rest) -ge 100MB) { $parts.Add(((T "其余 {0}{1}") -f $(if ($rest -gt 0) { '+' } else { '−' }), (Fmt ([math]::Abs($rest))))) }
    return ($parts -join (T '，'))
}
function Compare-Snapshot($root) {
    $script:growRows = New-Object 'System.Collections.ObjectModel.ObservableCollection[GrowRow]'
    $script:growSummary = ''
    $letter = $root.FullPath().Substring(0, 1).ToUpper()
    $days = 0; $t = $ctl.MapGrowBase.SelectedItem; if ($t) { $days = [int]([string]$t.Tag) }
    $file = Pick-Snapshot $letter $days
    $old = @{}; $oldAt = ''; $oldHow = 'walk'; $oldUsed = [double]-1
    if ($file -and (Test-Path -LiteralPath $file)) { $s = Read-Snapshot $file; $old = $s.Map; $oldAt = $s.At; $oldHow = $s.How; $oldUsed = $s.Used }
    $snap = $script:curSnap
    if (-not $snap) { $snap = [DiskMap]::Snapshot($root, 4, 100MB); $script:curSnap = $snap }
    $script:prevSnap = $old
    if ($old.Count -gt 0) {
        $list = New-Object System.Collections.ArrayList
        $seen = @{}
        foreach ($l in $snap) {
            $a = $l.Split("`t"); $k = $a[0].ToLowerInvariant(); $now = [double]$a[1]; $seen[$k] = $true
            $before = if ($old.ContainsKey($k)) { $old[$k] } else { [double]0 }
            $d = $now - $before
            if ([math]::Abs($d) -ge 100MB) { [void]$list.Add(@{ P = $a[0]; B = $before; N = $now; D = $d; Had = $old.ContainsKey($k) }) }
        }
        foreach ($k in $old.Keys) { if (-not $seen.ContainsKey($k) -and $old[$k] -ge 200MB) { [void]$list.Add(@{ P = $k; B = $old[$k]; N = [double]0; D = -$old[$k]; Had = $true }) } }
        # 一句话：已用空间变了多少，主要在哪
        $usedNow = [double]-1; try { $di = New-Object System.IO.DriveInfo ($root.FullPath()); $usedNow = [double]($di.TotalSize - $di.TotalFreeSpace) } catch {}
        $span = ''; try { $t0 = [DateTime]::ParseExact($oldAt, 'yyyy-MM-dd HH:mm', $null); $span = FmtSpan ((Get-Date) - $t0) } catch {}
        $delta = if ($oldUsed -ge 0 -and $usedNow -ge 0) { $usedNow - $oldUsed } else { [double]$root.Size - [double](($old.Values | Measure-Object -Maximum).Maximum) }
        if ($oldUsed -ge 0 -and $usedNow -ge 0) {
            $head = if ($span) { (T "过去 {0}，已用空间{1}{2}") -f $span, $(if ($delta -ge 0) { (T '增加 ') } else { (T '减少 ') }), (Fmt ([math]::Abs($delta))) } else { (T "和 {0} 相比，已用空间{1}{2}") -f $oldAt, $(if ($delta -ge 0) { (T '增加 ') } else { (T '减少 ') }), (Fmt ([math]::Abs($delta))) }
            $why = Explain-Growth $list $delta
            $script:growSummary = $(if ($why) { "{0}{1}{2}" -f $head, (T '，其中 '), $why } else { $head }) + (T '。')
        }
        foreach ($x in @($list | Sort-Object { $_.D } -Descending | Select-Object -First 60)) {
            $g = New-Object GrowRow
            $g.Path = $x.P
            $g.Before = if ($x.Had) { Fmt $x.B } else { (T '不到 100 MB') }
            $g.Now = if ($x.N -gt 0) { Fmt $x.N } else { (T '不到 100 MB') }
            $g.Change = $(if ($x.D -gt 0) { '+' } else { '−' }) + (Fmt ([math]::Abs($x.D)))
            $g.ChangeBrush = if ($x.D -gt 0) { '#D70015' } else { '#248A3D' }
            $g.BeforeBytes = [double]$x.B; $g.NowBytes = [double]$x.N
            $script:growRows.Add($g)
        }
        $script:growNote = if ($script:growRows.Count -gt 0) { ((T "上次扫描在 {0}。红色是变大的，绿色是变小的（只列变化超过 100 MB 的文件夹）") -f $oldAt) } else { ((T "和上次（{0}）相比，没有文件夹变化超过 100 MB") -f $oldAt) }
        # 读文件表能看到逐个扫描进不去的文件夹（比如 System Volume Information），两种方式的结果放在一起比会有出入
        $newHow = if ([string]$script:mapMethod -like 'mft*') { 'mft' } else { 'walk' }
        if ($oldHow -ne $newHow) {
            $script:growNote += $(if ($newHow -eq 'mft') { (T '。这次是直接读文件表，原来进不去的文件夹（比如 System Volume Information）也算进来了，这些文件夹看起来变大不一定是真的变大') } else { (T '。这次是逐个文件夹扫描的，进不去的文件夹没算进来，这些文件夹看起来变小不一定是真的变小') })
        }
    } else { $script:growNote = (T '这是第一次扫描这块盘。下次再扫描，就能看到哪些文件夹变大了') }
    if ($days -gt 0 -and $file) { $script:growNote = ((T "和 {0} 的快照比。") -f (Split-Path $file -Leaf)) + $script:growNote }
}

# 删除：移到回收站或永久删除，都要先勾选确认
$ctl.BtnMapDelete.Add_Click({ Start-MapDelete @($ctl.MapList.SelectedItems) })
# 删除空间地图里的几行（下面的按钮删选中的；右键菜单删右键点到的）
function Start-MapDelete($sel) {
    if ($script:worker) { return }
    $sel = @($sel)
    $rows = @($sel | Where-Object { -not $_.Locked -and $_.Size -gt 0 })
    if ($rows.Count -eq 0) { return }
    foreach ($r in $rows) { $why = Get-DeleteBlock $r.Path; if ($why) { Show-Sheet -Kind warn -Title (T '这一项不能删') -Text ("{0}`n`n{1}" -f $r.Path, $why) | Out-Null; return } }
    # 读文件表能看到没有权限打开的文件夹：打不开的不删（看不到里面有什么）
    foreach ($r in @($rows | Where-Object { $_.IsDir })) {
        $lp = [string]$r.Path; if ($lp.Length -ge 248 -and -not $lp.StartsWith('\\')) { $lp = '\\?\' + $lp }
        $ok = $true; try { $en = [IO.Directory]::EnumerateFileSystemEntries($lp).GetEnumerator(); [void]$en.MoveNext(); $en.Dispose() } catch { $ok = $false }
        if (-not $ok) { Show-Sheet -Kind warn -Title (T '这一项不能删') -Text ("{0}`n`n{1}" -f $r.Path, (T '没有权限打开这个文件夹，看不到里面有什么，不删。')) | Out-Null; return }
    }
    $bytes = [double]0; foreach ($r in $rows) { $bytes += [double]$r.Size }
    # 快速扫描时知道实际占用和硬链接：说清楚真正能腾出多少
    $real = ''
    if ($script:mapRoot -and $script:mapRoot.HasDisk -and (Get-Flag 'MapDisk')) {
        $dk = [double]0; $sh = [double]0; $known = $true
        foreach ($r in $rows) {
            if ($r.Disk -lt 0) { $known = $false; break }
            $dk += [double]$r.Disk
            if ($r.Node) { $sh += [math]::Min([double]$r.Node.Shared, [double]$r.Node.Disk) }
            elseif ($r.Shared) { $sh += [double]$r.Disk }
        }
        if ($known) {
            if ($sh -ge 32MB) { $real += ((T "`n`n按快速扫描的结果，实际能腾出 {0} 到 {1}：其中 {2} 是硬链接，同一份文件在别处还有名字，那些名字还在就不会腾出空间。") -f (Fmt ([math]::Max([double]0, $dk - $sh))), (Fmt $dk), (Fmt $sh)) }
            elseif (($bytes - $dk) -ge 32MB -and $dk -lt $bytes * 0.85) { $real += ((T "`n`n按快速扫描的结果，这些实际只占 {0}（压缩、稀疏或只在云端的文件比文件大小占得少），删掉腾出的是这么多。") -f (Fmt $dk)) }
        }
    }
    $how = (T "「移到回收站」可以恢复，但要清空回收站后才真正腾出空间；「永久删除」马上腾出空间，删了就找不回来。")
    # 是 git 仓库的文件夹：里面没提交、没推送的改动删了就没了（参考 disktree）
    $git = @($rows | Where-Object { $_.IsDir -and ((Test-Path -LiteralPath (Join-Path ([string]$_.Path) '.git')) -or $_.Name -ieq '.git') })
    if ($git.Count -gt 0) { $real += ((T "`n`n注意：其中 {0} 个是 git 仓库（{1}）。没提交、没推送到远程的改动删了就找不回来，先确认都推送过。") -f $git.Count, ((@($git | Select-Object -First 3 | ForEach-Object { $_.Name })) -join (T '、'))) }
    $items = $null
    if ($rows.Count -eq 1) {
        $r = $rows[0]
        $kind = if ($r.IsDir) { (T '文件夹') } else { (T '文件') }
        $title = (T "删除这个{0}（{1}）？") -f $kind, $r.SizeText
        $text = ((T "{0}`n`n「移到回收站」可以恢复，但要清空回收站后才真正腾出空间；「永久删除」马上腾出空间，删了就找不回来。") -f $r.Path) + $real
    } else {
        $title = (T "删除选中的 {0} 项（{1}）？") -f $rows.Count, (Fmt $bytes)
        $text = $how + $real
        if ($sel.Count -gt $rows.Count) { $text += ((T "`n`n另有 {0} 项带小锁或是链接，不会删。") -f ($sel.Count - $rows.Count)) }
        $items = @($rows | Select-Object -First 40 | ForEach-Object { (T "{0}（{1}）") -f $_.Path, $_.SizeText })
        if ($rows.Count -gt 40) { $items += ((T "……另有 {0} 项") -f ($rows.Count - 40)) }
    }
    $ans = Show-Sheet -Kind danger -Title $title -Text $text -Items $items `
        -Confirm (T '我已确认这些资料不再需要，删除不会给我带来损失；因删除造成的后果由我自己承担。') -Buttons @((T '取消'), (T '永久删除'), (T '移到回收站')) -Primary (T '移到回收站') -Cancel (T '取消')
    if ($ans -ne (T '移到回收站') -and $ans -ne (T '永久删除')) { return }
    $sync.Mode = 'mapdel'; $sync.MapDel = $null
    $script:mapDelRows = $rows
    $script:mapDelFree = @{}; foreach ($d in @($rows | ForEach-Object { ([string]$_.Path).Substring(0, 2).ToUpperInvariant() } | Select-Object -Unique)) { $script:mapDelFree[$d] = DriveFree ($d + '\') }
    Start-Op $(if ($rows.Count -eq 1) { (T "删除 {0}") -f $rows[0].Name } else { (T "删除 {0} 项") -f $rows.Count })
    UI-Busy $true
    Start-Worker @'
$res = @{ Ok = New-Object System.Collections.ArrayList; Fail = New-Object System.Collections.ArrayList }
$how = if ($arg.Recycle) { (T '空间地图：移到回收站') } else { (T '空间地图：永久删除') }
$i = 0
foreach ($x in $arg.Items) {
    if (Stopping) { break }
    $i++
    $p = [string]$x.Path
    SetP @{ Steps = $arg.Items.Count; Step = $i; StepName = (Split-Path $p -Leaf); SubKind = 'action'; SubStart = (Get-Date); Detail = $p }
    # 删之前再查一次：个人文件夹、系统位置、软件安装文件夹、搬家后的数据一律不删
    $why = Get-DeleteBlock $p
    if (-not $why -and (IsLink $p)) { $why = (T '这是一个链接（多半是搬家后留下的），删了软件会找不到数据。要处理请到「搬家管理」') }
    if (-not $why) { $up = Get-LinkedAncestor $p; if ($up) { $why = ((T "它所在的文件夹 {0} 已经搬到其他盘了，这份扫描结果过时了，请重新扫描") -f $up) } }
    if ($why) { [void]$res.Fail.Add(((T "{0}：{1}") -f $p, $why)); continue }
    $msg = ''
    if ($arg.Recycle) {
        $why = Test-RecycleOk $p $(if ($x.IsDir) { try { [double][FsTools]::OnDiskTree($p) } catch { [double]$x.Size } } else { [double]$x.Size })
        if ($why) { [void]$res.Fail.Add(((T "{0}：{1}。要删的话选「永久删除」") -f $p, $why)); continue }
        $rc = [FsTools]::Recycle($p, [long]$sync.Hwnd)
        $ok = -not (Test-Path -LiteralPath $p)
        if (-not $ok) { $msg = ((T "没有删掉（代码 {0}，可能文件正被占用，或者在提示里选了取消）") -f $rc) }
    } else {
        if ($x.IsDir -and -not (Test-CmdPathOk $p)) { [void]$res.Fail.Add(((T "{0}：{1}") -f $p, (T '路径里有 % 或引号，为了不删错地方不交给系统命令'))); continue }
        if ($x.IsDir) { & "$sys32\cmd.exe" /c rd /s /q "\\?\$p" 2>$null | Out-Null } else { Remove-Item -LiteralPath $p -Force -ErrorAction SilentlyContinue }
        $ok = -not (Test-Path -LiteralPath $p)
        if (-not $ok) { $msg = (T '没删干净，可能有文件正被占用') }
    }
    OpLog '删除' $how $p ("{0}{1}" -f (GB $x.Size), $(if ($ok) { '' } else { (T '，失败：') + $msg }))
    if ($ok) { [void]$res.Ok.Add($p) } else { [void]$res.Fail.Add(((T "{0}：{1}") -f $p, $msg)) }
}
$sync.MapDel = $res
'@ @{ Items = @($rows | ForEach-Object { @{ Path = [string]$_.Path; IsDir = [bool]$_.IsDir; Size = [double]$_.Size } }); Recycle = ($ans -eq (T '移到回收站')) }
}

# 压缩文件夹（NTFS）：空间地图和「省空间」页共用
function Start-FolderCompress([string]$path) {
    if ($script:worker) { return }
    $why = Get-CompressBlock $path
    if ($why) { Show-Sheet -Kind warn -Title (T '这个文件夹不适合这样压缩') -Text $why | Out-Null; return }
    $ans = Show-Sheet -Title (T '压缩这个文件夹？') -Text ((T "{0}`n`n用 Windows 自带的 NTFS 压缩：文件照常打开、照常修改，只是占的空间变小。文档、代码、日志通常能省一半；照片、视频、压缩包几乎省不了。文件多的话要几分钟。") -f $path) -Buttons @((T '取消'), (T '压缩')) -Primary (T '压缩') -Cancel (T '取消')
    if ($ans -ne (T '压缩')) { return }
    $sync.Mode = 'fcompress'; $sync.FcResult = $null
    Start-Op (T '压缩文件夹')
    UI-Busy $true
    Start-Worker @'
$p = $arg.Path; $cx = $false
SetP @{ Steps = 2; Step = 1; StepName = (T '统计压缩前的实际占用'); SubKind = 'action'; SubStart = (Get-Date); Detail = $p }
$before = [double][FsTools]::OnDiskTree($p)
SetP @{ Step = 2; StepName = (T '压缩'); SubStart = (Get-Date); Detail = ((T "正在压缩 {0}") -f $p) }
if (-not (Test-Path -LiteralPath $p -PathType Container)) { Log ((T "  文件夹不在了：{0}") -f $p) }
else {
    $inside = $false
    try { Set-Location -LiteralPath $p -ErrorAction Stop; $inside = ((Get-Location).ProviderPath.TrimEnd('\') -ieq $p.TrimEnd('\')) } catch { Log ((T "  进不去：{0}") -f $p) }
    if ($inside) {
        $rc = Invoke-Tool "$sys32\compact.exe" @('/c', '/s', '/a', '/i', '/q', '*') $p
        if ($rc.Cancelled) { $cx = $true; Log ((T "  已中途取消：{0}") -f $p) }
        # 虚拟磁盘文件压缩后会变慢、甚至出错，压完再把它们解压回去（中途取消了也要做，这一步不能中断）
        Set-CanCancel $false
        & "$sys32\compact.exe" /u /s /a /i /q '*.vhd' '*.vhdx' '*.avhdx' 2>&1 | Out-Null
        Set-CanCancel $true
    }
}
try { [Environment]::CurrentDirectory = $env:SystemRoot; Set-Location -LiteralPath $env:SystemRoot } catch {}
$after = [double][FsTools]::OnDiskTree($p)
OpLog '压缩' $(if ($cx) { (T '压缩文件夹（NTFS），中途取消') } else { (T '压缩文件夹（NTFS）') }) $p ((T "实际占用 {0} → {1}") -f (GB $before), (GB $after))
$sync.FcResult = @{ Path = $p; Before = $before; After = $after; Cancelled = $cx }
'@ @{ Path = $path }
}
$ctl.BtnMapCompress.Add_Click({ $r = $ctl.MapList.SelectedItem; if ($r -and $r.IsDir) { Start-FolderCompress $r.Path } })

