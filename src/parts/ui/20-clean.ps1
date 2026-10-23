# ------------------------------------------------------------
# 第一页：清理 C 盘
# ------------------------------------------------------------
# 列表上方的总览：「扫描到 23 项，分 4 类：安全清理 9 项、……」
function Update-CleanOverview {
    $col = $script:rows
    Update-CleanTabs
    if (-not $col -or $col.Count -eq 0) { $ctl.CleanOverview.Visibility = 'Collapsed'; Update-CleanMore; return }
    $order = New-Object System.Collections.Generic.List[string]; $cnt = @{}
    foreach ($r in $col) { if (-not $cnt.ContainsKey($r.GroupTitle)) { $order.Add($r.GroupTitle); $cnt[$r.GroupTitle] = 0 }; $cnt[$r.GroupTitle]++ }
    $parts = @($order | ForEach-Object { (T "{0} {1} 项") -f $_, $cnt[$_] })
    $ctl.CleanOverviewText.Text = (T "扫描到 {0} 项，分成 {1} 类：{2}。点下面的选项卡切换类别，点「名称」「大小」排序，右边的下拉框可以只看某一种操作。每一项都可以单独选「删除」「搬走」或「跳过」；「执行所选操作」会处理所有类别。双击一行打开它所在的文件夹，右键可以复制路径。") -f $col.Count, $order.Count, ($parts -join (T '、'))
    $ctl.CleanOverview.Visibility = 'Visible'
    $script:cleanItems = $null
    $ctl.CleanScroll.ScrollToTop()
    $ctl.CleanScroll.UpdateLayout()
    Update-CleanMore
}
# ---------- 清理页：双击一行打开它的文件夹，右键打开全部位置或复制路径（只看不改，方便把文件拷出来分析） ----------
# 没有固定路径、由系统命令处理的几项，指到 Windows 存放它们的地方
function Get-CleanExtraPaths([string]$n) {
    $m = @{
        (T '清空回收站') = @('shell:RecycleBinFolder')
        (T 'Windows 传递优化缓存') = @("$env:SystemRoot\SoftwareDistribution\DeliveryOptimization", "$env:SystemRoot\ServiceProfiles\NetworkService\AppData\Local\Microsoft\Windows\DeliveryOptimization\Cache")
        (T '重建 Windows 搜索索引') = @("$env:ProgramData\Microsoft\Search\Data\Applications\Windows")
        (T 'Windows Installer 孤儿安装包') = @("$env:SystemRoot\Installer")
        (T '驱动存储里的旧版驱动包') = @("$env:SystemRoot\System32\DriverStore\FileRepository")
        (T '开始菜单里失效的快捷方式') = @("$env:APPDATA\Microsoft\Windows\Start Menu\Programs", "$env:ProgramData\Microsoft\Windows\Start Menu\Programs")
        (T 'Windows 事件日志') = @("$env:SystemRoot\System32\winevt\Logs")
        (T 'WinSxS 组件清理 (DISM)') = @("$env:SystemRoot\WinSxS")
    }
    if ($m.ContainsKey($n)) { return $m[$n] } else { return @() }
}
# 一行对应的、现在确实存在的位置（带 * 的展开成真实的文件夹，最多 30 个）
function Get-CleanOpenPaths($it) {
    $out = New-Object System.Collections.Generic.List[string]
    if (-not $it) { return @() }   # 不用 ,数组：调用处都是 @(Get-CleanOpenPaths …)，那样会套一层
    foreach ($p in (@($it.Paths) + @(Get-CleanExtraPaths ([string]$it.N)))) {
        if (-not $p) { continue }
        $p = [Environment]::ExpandEnvironmentVariables([string]$p)
        if ($p -like 'shell:*') { if (-not $out.Contains($p)) { $out.Add($p) }; continue }
        $cands = if ($p -match '[\*\?]') { @(Get-PathItems $p | Select-Object -First 30 | ForEach-Object { $_.FullName }) } else { @($p) }
        foreach ($c in $cands) { if ($c -and -not $out.Contains($c) -and (Test-Path -LiteralPath $c)) { $out.Add($c) } }
        if ($out.Count -ge 30) { break }
    }
    return $out.ToArray()
}
function Get-CleanRowFrom($src) {
    $v = $src
    while ($v -and $v -isnot [System.Windows.Controls.ListViewItem]) {
        if ($v -is [System.Windows.Controls.ListBox] -and $v -isnot [System.Windows.Controls.ListView]) { return $null }   # 点在「删除 / 跳过」上
        if ($v -is [System.Windows.Controls.Primitives.ScrollBar]) { return $null }
        $v = if ($v -is [System.Windows.Media.Visual] -or $v -is [System.Windows.Media.Media3D.Visual3D]) { [System.Windows.Media.VisualTreeHelper]::GetParent($v) } else { $null }
    }
    if ($v -and $v.DataContext -is [RowItem]) { return $v.DataContext }
    return $null
}
function Get-CleanItemOf($row) { if (-not $row) { return $null }; foreach ($c in $catalog) { if ($c.Idx -eq $row.Idx) { return $c } }; return $null }
function Open-CleanPath([string]$p) {
    if ($script:uiTest) { $script:uiOpened.Add($p); return }
    if ($p -like 'shell:*') { Start-Process -FilePath "$env:SystemRoot\explorer.exe" -ArgumentList $p } else { Open-Location $p }
}
$script:uiOpened = New-Object System.Collections.Generic.List[string]
$script:cleanMenuRow = $null
function Open-CleanRow($row, [bool]$all) {
    $it = Get-CleanItemOf $row
    $ps = @(Get-CleanOpenPaths $it)
    if ($ps.Count -eq 0) { Show-Sheet -Title ([string]$row.Name) -Text (T '这一项现在没有可以打开的文件夹：要么已经清空了，要么是由系统命令处理、没有固定的位置。') | Out-Null; return }
    if (-not $all) { Open-CleanPath $ps[0]; if ($ps.Count -gt 1) { UI-Log ((T "「{0}」还有 {1} 个位置，右键可以全部打开") -f $row.Name, ($ps.Count - 1)) }; return }
    foreach ($p in ($ps | Select-Object -First 8)) { Open-CleanPath $p }
    if ($ps.Count -gt 8) { UI-Log ((T "「{0}」一共 {1} 个位置，打开了前 8 个；全部路径可以右键「复制路径」") -f $row.Name, $ps.Count) }
}
$ctl.List.Add_MouseDoubleClick({
    param($s, $e)
    if ($e.ChangedButton -ne [System.Windows.Input.MouseButton]::Left) { return }
    $row = Get-CleanRowFrom $e.OriginalSource
    if ($row) { $e.Handled = $true; Open-CleanRow $row $false }
})
$ctl.List.Add_ContextMenuOpening({
    param($s, $e)
    $row = Get-CleanRowFrom $e.OriginalSource
    if (-not $row) { $e.Handled = $true; return }
    $script:cleanMenuRow = $row
    $n = @(Get-CleanOpenPaths (Get-CleanItemOf $row)).Count
    $ctl.CmOpen.IsEnabled = $n -gt 0; $ctl.CmCopy.IsEnabled = $n -gt 0
    $ctl.CmOpenAll.Visibility = $(if ($n -gt 1) { 'Visible' } else { 'Collapsed' })
    $ctl.CmOpenAll.Header = (T "打开全部位置（{0} 个）") -f $n
})
$ctl.CmOpen.Add_Click({ if ($script:cleanMenuRow) { Open-CleanRow $script:cleanMenuRow $false } })
$ctl.CmOpenAll.Add_Click({ if ($script:cleanMenuRow) { Open-CleanRow $script:cleanMenuRow $true } })
$ctl.CmCopy.Add_Click({
    if (-not $script:cleanMenuRow) { return }
    $ps = @(Get-CleanOpenPaths (Get-CleanItemOf $script:cleanMenuRow) | Where-Object { $_ -notlike 'shell:*' })
    if ($ps.Count -gt 0) { try { [System.Windows.Clipboard]::SetText(($ps -join "`r`n")); UI-Log ((T "已复制 {0} 个路径") -f $ps.Count) } catch {} }
})
# 下面还有没看到的内容时，底部浮一个「下面还有 N 项」
function Update-CleanMore {
    $sv = $ctl.CleanScroll
    $left = [double]$sv.ScrollableHeight - [double]$sv.VerticalOffset
    if (-not $script:rows -or $script:rows.Count -eq 0 -or $left -lt 30) { $ctl.CleanMore.Visibility = 'Collapsed'; return }
    # 数一数还有几行在可视区下面（列表的行在第一次需要时从界面树里找出来，之后直接用）
    if (-not $script:cleanItems -or $script:cleanItems.Count -ne $ctl.List.Items.Count) {
        $found = New-Object System.Collections.Generic.List[object]
        $stack = New-Object System.Collections.Generic.Stack[object]; $stack.Push($ctl.List)
        while ($stack.Count -gt 0) {
            $v = $stack.Pop()
            if ($v -is [System.Windows.Controls.ListViewItem]) { $found.Add($v); continue }
            $n = [System.Windows.Media.VisualTreeHelper]::GetChildrenCount($v)
            for ($i = 0; $i -lt $n; $i++) { $stack.Push([System.Windows.Media.VisualTreeHelper]::GetChild($v, $i)) }
        }
        $script:cleanItems = $found
    }
    $below = 0
    $bottom = [double]$sv.ViewportHeight
    foreach ($c in $script:cleanItems) {
        try { if ($c.TransformToAncestor($sv).Transform((New-Object System.Windows.Point 0, 0)).Y + 20 -gt $bottom) { $below++ } } catch {}
    }
    $ctl.CleanMoreText.Text = if ($below -gt 0) { (T "下面还有 {0} 项") -f $below } else { (T '下面还有内容') }
    $ctl.CleanMore.Visibility = 'Visible'
}
# ---------- 清理页：一类一个选项卡；表头点「名称」「大小」排序，下拉框只看某一种操作；选项卡和表头滚到顶上就停住 ----------
$script:cleanTab = ''; $script:cleanOp = ''; $script:cleanPinned = $false; $script:cleanGroups = $null
function Update-CleanTabs {
    $ctl.CleanTabs.Children.Clear()
    $col = $script:rows
    $has = [bool]($col -and $col.Count -gt 0)
    foreach ($n in 'CleanBar', 'CleanBarSlot', 'CleanListCard') { $ctl[$n].Visibility = $(if ($has) { 'Visible' } else { 'Collapsed' }) }
    $script:cleanItems = $null
    if (-not $has) { return }
    $order = New-Object System.Collections.Generic.List[string]; $cnt = @{}; $bytes = @{}; $note = @{}
    foreach ($r in $col) {
        $g = [string]$r.GroupTitle
        if (-not $cnt.ContainsKey($g)) { $order.Add($g); $cnt[$g] = 0; $bytes[$g] = [double]0; $note[$g] = [string]$r.GroupNote }
        $cnt[$g]++; if ($r.Bytes -gt 0) { $bytes[$g] += $r.Bytes }
    }
    $script:cleanGroups = @{ Order = $order; Cnt = $cnt; Bytes = $bytes; Note = $note }
    if (-not $order.Contains($script:cleanTab)) { $script:cleanTab = $order[0] }
    $seg = $win.FindResource('Seg')
    foreach ($g in $order) {
        $rb = New-Object System.Windows.Controls.RadioButton
        $rb.GroupName = 'cleantab'; $rb.Style = $seg; $rb.Tag = $g
        $sp = New-Object System.Windows.Controls.StackPanel; $sp.Orientation = 'Horizontal'
        $t1 = New-Object System.Windows.Controls.TextBlock; $t1.Text = $g
        $t2 = New-Object System.Windows.Controls.TextBlock; $t2.Text = [string]$cnt[$g]; $t2.Style = $win.FindResource('TabBadgeText')
        $bd = New-Object System.Windows.Controls.Border; $bd.Style = $win.FindResource('TabBadge'); $bd.Child = $t2
        [void]$sp.Children.Add($t1); [void]$sp.Children.Add($bd); $rb.Content = $sp
        if ($ctl.CleanTabs.Children.Count -eq 0) { $rb.Uid = 'first' }
        if ($note[$g]) { $rb.ToolTip = $note[$g] }
        $rb.IsChecked = ($g -eq $script:cleanTab)
        $rb.Add_Checked({ Select-CleanTab ([string]$this.Tag) })
        [void]$ctl.CleanTabs.Children.Add($rb)
    }
    # 操作下拉框：这次扫描里出现过的操作
    $ops = New-Object System.Collections.Generic.List[string]
    foreach ($r in $col) { foreach ($a in @($r.Actions)) { if ($a -and -not $ops.Contains([string]$a)) { $ops.Add([string]$a) } } }
    if ($script:cleanOp -and -not $ops.Contains($script:cleanOp)) { $script:cleanOp = '' }
    $script:cleanOpLoading = $true
    try {
        $ctl.CleanOpFilter.Items.Clear()
        $it = New-Object System.Windows.Controls.ComboBoxItem; $it.Content = (T '全部操作'); $it.Tag = ''; [void]$ctl.CleanOpFilter.Items.Add($it)
        foreach ($a in $ops) { $it = New-Object System.Windows.Controls.ComboBoxItem; $it.Content = (T "只看「{0}」") -f $a; $it.Tag = $a; [void]$ctl.CleanOpFilter.Items.Add($it) }
        foreach ($it in $ctl.CleanOpFilter.Items) { if ([string]$it.Tag -eq $script:cleanOp) { $ctl.CleanOpFilter.SelectedItem = $it } }
    } finally { $script:cleanOpLoading = $false }
    Apply-CleanFilter
}
# 只显示选中的那一类、选中的那种操作；排序（表头）不变
function Apply-CleanFilter {
    $cfg = $script:sortCfg['List']
    if ($cfg) { $cfg.Filter = [Predicate[object]]{ param($o) ([string]$o.GroupTitle -eq $script:cleanTab) -and (-not $script:cleanOp -or [string]$o.Action -eq $script:cleanOp) } }
    Apply-ListSort 'List'
    $script:cleanItems = $null
    $n = $ctl.List.Items.Count
    $ctl.CleanFilterEmpty.Visibility = $(if ($script:rows -and $script:rows.Count -gt 0 -and $n -eq 0) { 'Visible' } else { 'Collapsed' })
    $gi = $script:cleanGroups
    if ($gi -and $gi.Cnt.ContainsKey($script:cleanTab)) {
        $ctl.CleanTabNote.Text = [string]$gi.Note[$script:cleanTab]
        $ctl.CleanTabNote.Visibility = $(if ($ctl.CleanTabNote.Text) { 'Visible' } else { 'Collapsed' })
        $ctl.CleanTabInfo.Text = $(if ($script:cleanOp) { (T "显示 {0} / {1} 项") -f $n, $gi.Cnt[$script:cleanTab] } else { (T "{0} 项，约 {1}") -f $gi.Cnt[$script:cleanTab], (Fmt $gi.Bytes[$script:cleanTab]) })
    }
}
function Get-CleanSlotPos { try { return $ctl.CleanBarSlot.TransformToAncestor($ctl.CleanHost).Transform((New-Object System.Windows.Point 0, 0)) } catch { return $null } }
function Select-CleanTab([string]$g) {
    if ($g -eq $script:cleanTab) { return }
    $p = Get-CleanSlotPos; $pinned = $p -and $p.Y -lt 0
    $script:cleanTab = $g
    foreach ($rb in $ctl.CleanTabs.Children) { if ([string]$rb.Tag -eq $g -and -not $rb.IsChecked) { $rb.IsChecked = $true } }
    Apply-CleanFilter
    # 选项卡停在顶上时换类：列表从头显示（紧贴在选项卡下面），不用再往上找
    if ($pinned) { $ctl.CleanScroll.UpdateLayout(); $p = Get-CleanSlotPos; if ($p) { $ctl.CleanScroll.ScrollToVerticalOffset([math]::Max([double]0, $ctl.CleanScroll.VerticalOffset + $p.Y)) } }
}
# 浮着的那一排跟着占位的位置走；占位滚出顶边以后就停在顶上
function Update-CleanBar {
    if ($ctl.CleanBar.Visibility -ne 'Visible') { return }
    $p = Get-CleanSlotPos; if (-not $p) { return }
    $w = [double]$ctl.CleanBarSlot.ActualWidth
    if ($w -gt 0 -and -not ($ctl.CleanBar.Width -eq $w)) { $ctl.CleanBar.Width = $w }
    $top = [math]::Max([double]0, [double]$p.Y)
    $m = $ctl.CleanBar.Margin
    if ($m.Left -ne $p.X -or $m.Top -ne $top) { $ctl.CleanBar.Margin = New-Object System.Windows.Thickness $p.X, $top, 0, 0 }
    $h = [double]$ctl.CleanBar.ActualHeight
    if ($h -gt 0 -and -not ($ctl.CleanBarSlot.Height -eq $h)) { $ctl.CleanBarSlot.Height = $h }
    $pin = [double]$p.Y -lt 0
    if ($pin -ne $script:cleanPinned) {
        $script:cleanPinned = $pin
        $ctl.CleanBar.Effect = if ($pin) { $fx = New-Object System.Windows.Media.Effects.DropShadowEffect; $fx.BlurRadius = 10; $fx.ShadowDepth = 2; $fx.Direction = 270; $fx.Opacity = 0.14; $fx } else { $null }
    }
}
$ctl.CleanBar.Add_SizeChanged({ Update-CleanBar })
# 鼠标在选项卡和表头上滚轮：照样滚下面的列表
$ctl.CleanBar.Add_PreviewMouseWheel({ param($s, $e) if ($ctl.CleanOpFilter.IsDropDownOpen) { return }; $ctl.CleanScroll.ScrollToVerticalOffset($ctl.CleanScroll.VerticalOffset - $e.Delta * 0.4); $e.Handled = $true })
$ctl.CleanOpFilter.Add_SelectionChanged({
    if ($script:cleanOpLoading) { return }
    $it = $ctl.CleanOpFilter.SelectedItem
    $script:cleanOp = if ($it) { [string]$it.Tag } else { '' }
    Apply-CleanFilter
})
function Build-Rows($sizes) {
    $col = New-Object 'System.Collections.ObjectModel.ObservableCollection[RowItem]'
    $script:rowSig = @{}
    $total = [double]0
    $seen = @{}
    $mode = Get-Mode
    foreach ($it in $catalog) {
        $b = $sizes[$it.Idx]
        if (-not $b) { continue }
        if ($it.Lvl -and [int]$it.Lvl -gt $mode) { continue }   # 这个模式下不列（换到更高的模式再扫描就有）
        $r = New-Object RowItem
        $script:rowSig[$it.Idx] = Get-ItemSig $it
        $r.Idx = $it.Idx; $r.Group = $it.G; $r.Name = $it.N; $r.Note = $it.Note; $r.Actions = $it.Actions; $r.Action = $it.Def
        # 组名「安全清理（缓存、临时文件……）」拆成标题和说明两行显示
        $gt = T ([string]$it.G)
        $gp = $gt.Split([char]0xFF08, 2); if ($gp.Count -lt 2) { $gp = $gt.Split([char]'(', 2) }
        $r.GroupTitle = $gp[0].Trim()
        $r.GroupNote = if ($gp.Count -gt 1) { $gp[1].TrimEnd([char]0xFF09).TrimEnd(')') } else { '' }
        $r.First = -not $seen.ContainsKey($it.G); $seen[$it.G] = $true
        $r.SizeText = if ($b -lt 0) { (T '运行后知道') } else { Fmt $b }
        $r.Bytes = [double]$b
        if ($b -gt 0 -and $it.Def -ne (T '跳过')) { $total += $b }
        $col.Add($r)
    }
    $script:rows = $col
    $ctl.List.ItemsSource = $col   # 不再分组显示：上面的选项卡一次只显示一类（Update-CleanTabs）
    $ctl.EmptyClean.Visibility = if ($col.Count -gt 0) { 'Collapsed' } else { 'Visible' }
    if ($col.Count -eq 0) { $ctl.EmptyCleanText.Text = (T 'C 盘上没找到可以清理的东西') }
    Update-CleanOverview
    $script:reclaim = $total
    UI-Status
    $ctl.Summary.Text = ((T "共 {0} 项。按当前选择，可释放约 {1}。") -f $col.Count, (GB $total))
}

# 用户在列表里改了某一行的操作，就重算「可释放约多少」
$script:planSig = ''
function Update-CleanSummary {
    if (-not $script:rows -or $script:worker -or -not $sync.Sizes) { return }
    $tot = [double]0; $n = 0; $sig = ''
    foreach ($r in $script:rows) {
        $sig += [string]$r.Action
        if ($r.Action -ne (T '跳过')) { $n++; $b = [double]$sync.Sizes[$r.Idx]; if ($b -gt 0) { $tot += $b } }
    }
    if ($sig -eq $script:planSig) { return }
    $script:planSig = $sig
    $script:reclaim = $tot
    UI-Status
    $ctl.Summary.Text = if ($n -gt 0) { (T "已选 {0} 项，可释放约 {1}。") -f $n, (GB $tot) } else { (T '没有选中任何项目。') }
    $ctl.BtnRun.IsEnabled = ($n -gt 0)
}

function Do-Scan([switch]$Quiet) {
    $ctl.Summary.Text = (T '正在扫描，大目录可能要一两分钟…')
    if (-not $script:rows) { $ctl.EmptyCleanText.Text = (T '正在扫描…') }
    $script:prevSizes = $sync.Sizes   # 扫描中途取消时，列表还用上一次的结果
    $sync.Mode = 'scan'; $sync.Sizes = $null
    if (-not $Quiet) { Start-Op (T '扫描可清理项') }
    UI-Busy $true
    Start-Worker @'
$sizes = @{}
$cat = Get-Catalog; $i = 1; $steps = $cat.Count + 1
SetP @{ Steps = $steps; Step = 1; StepName = (T '读取 C 盘的文件表') }
$tree = Get-SysTree
foreach ($it in $cat) { if (Stopping) { break }; $i++; SetP @{ Steps = $steps; Step = $i; StepName = $it.N; SubKind = 'measure'; SubStart = (Get-Date); Detail = (T '统计大小') }; $sizes[$it.Idx] = Measure-Item $it $tree }
if (-not (Stopping)) { $sync.Sizes = $sizes }
'@ $null
}

$ctl.BtnScan.Add_Click({ UI-Log (T "开始扫描..."); Do-Scan })
$ctl.BtnCleanCustom.Add_Click({ Show-Page 'settings'; Select-SetSection 'Clean'; $ctl.SetScroll.ScrollToTop() })

$ctl.BtnHogs.Add_Click({
    Show-Page 'map'
    if ($ctl.MapDrive.Items.Count -gt 0) { foreach ($it in $ctl.MapDrive.Items) { if ([string]$it.Tag -ieq "$env:SystemDrive\") { $ctl.MapDrive.SelectedItem = $it } } }
    if (-not $script:worker -and -not $script:mapRoot) { Start-MapScan "$env:SystemDrive\" }
})

# ---------- 搬家目标：列出 C 盘以外的本机硬盘，按空闲从大到小，默认选第一个 ----------
$script:customDest = $null
function DriveTypeOf([string]$d) { try { [string](New-Object System.IO.DriveInfo $d).DriveType } catch { 'Unknown' } }
function Fill-DestChoices([string]$keep) {
    if (-not $keep) { $keep = Get-Dest }
    $ctl.DestPick.Items.Clear()
    $drives = @([IO.DriveInfo]::GetDrives() | Where-Object {
        try { $_.DriveType -eq 'Fixed' -and $_.IsReady -and ($_.Name.TrimEnd('\') -ine $env:SystemDrive) } catch { $false } } |
        Sort-Object AvailableFreeSpace -Descending)
    $first = $true
    foreach ($d in $drives) {
        $path = Join-Path $d.RootDirectory.FullName 'CDriveMoved'
        $label = (T "{0}    空闲 {1}{2}") -f $path, (Fmt $d.AvailableFreeSpace), $(if ($first) { (T '，空间最大') } else { '' })
        $item = New-Object System.Windows.Controls.ComboBoxItem
        $item.Content = $label; $item.Tag = $path
        [void]$ctl.DestPick.Items.Add($item)
        $first = $false
    }
    if ($script:customDest) {
        $free = DriveFree ($script:customDest.Substring(0, 2))
        $item = New-Object System.Windows.Controls.ComboBoxItem
        $item.Content = (T "{0}    空闲 {1}，自选") -f $script:customDest, (Fmt $free); $item.Tag = $script:customDest
        [void]$ctl.DestPick.Items.Add($item)
    }
    if ($ctl.DestPick.Items.Count -eq 0) {
        $item = New-Object System.Windows.Controls.ComboBoxItem
        $item.Content = (T '这台电脑只有 C 盘，没有可以搬去的磁盘'); $item.Tag = ''
        [void]$ctl.DestPick.Items.Add($item)
    }
    $ctl.DestPick.SelectedIndex = 0
    if ($drives.Count -gt 0) {
        $ctl.DestHint.Text = (T "已自动选了空闲最多的 {0} 盘（剩 {1}）。也可以从下拉框换一块盘，或点「选择文件夹」。只列本机硬盘：网络盘、网盘、U 盘不能做链接目标。") -f $drives[0].Name.Substring(0, 1), (Fmt $drives[0].AvailableFreeSpace)
    } else {
        $ctl.DestHint.Text = (T '这台电脑只有 C 盘，不能搬家；其他清理照常可以做。')
    }
    if ($keep) { for ($i = 0; $i -lt $ctl.DestPick.Items.Count; $i++) { if ([string]$ctl.DestPick.Items[$i].Tag -ieq $keep) { $ctl.DestPick.SelectedIndex = $i } } }
    Sync-MovesDest
}
function Get-Dest { $i = $ctl.DestPick.SelectedItem; if ($i) { [string]$i.Tag } else { '' } }
# 「搬家管理」页也有一个搬家目标下拉框，和这里的是同一个选择
$script:destSyncing = $false
function Sync-MovesDest {
    $script:destSyncing = $true
    try {
        $ctl.MovesDest.Items.Clear()
        foreach ($i in $ctl.DestPick.Items) { $n = New-Object System.Windows.Controls.ComboBoxItem; $n.Content = $i.Content; $n.Tag = $i.Tag; [void]$ctl.MovesDest.Items.Add($n) }
        $ctl.MovesDest.SelectedIndex = $ctl.DestPick.SelectedIndex
    } finally { $script:destSyncing = $false }
}
$ctl.MovesDest.Add_SelectionChanged({
    if ($script:destSyncing -or $ctl.MovesDest.SelectedIndex -lt 0) { return }
    $script:destSyncing = $true
    try { $ctl.DestPick.SelectedIndex = $ctl.MovesDest.SelectedIndex } finally { $script:destSyncing = $false }
    Update-CandSel
})
$ctl.DestPick.Add_SelectionChanged({
    if ($script:destSyncing) { return }
    $script:destSyncing = $true
    try { $ctl.MovesDest.SelectedIndex = $ctl.DestPick.SelectedIndex } finally { $script:destSyncing = $false }
})
$ctl.BtnDestBrowse.Add_Click({
    $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
    $dlg.Description = (T '选择搬家目标文件夹（要在 C 盘以外的本机硬盘上）')
    if ($dlg.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) { return }
    $path = $dlg.SelectedPath.TrimEnd('\')
    if ($path.Length -lt 2 -or $path.Substring(0, 2) -ieq $env:SystemDrive) { Show-Sheet -Kind warn -Title (T '请选 C 盘以外的位置') -Text (T '搬到 C 盘自己身上腾不出空间。') | Out-Null; return }
    if ((DriveTypeOf ($path.Substring(0, 2))) -ne 'Fixed') { Show-Sheet -Kind warn -Title (T '只能选本机硬盘') -Text (T '网络盘、网盘和 U 盘不能做链接目标，拔掉或断网后软件会找不到数据。') | Out-Null; return }
    if ($path.Length -le 2) { $path = $path.Substring(0, 2) + '\CDriveMoved' }   # 选了整个盘（E:\），就在盘下建 CDriveMoved
    $risky = @(@(Get-CustomClean) + @($env:TEMP, $env:TMP, "$env:SystemRoot\Temp") | Where-Object { $_ } | ForEach-Object { [Environment]::ExpandEnvironmentVariables([string]$_).TrimEnd('\') })
    foreach ($r in $risky) { if ($path -ieq $r -or $path.StartsWith($r + '\', [StringComparison]::OrdinalIgnoreCase)) { Show-Sheet -Kind warn -Title (T '这里不能放搬过去的数据') -Text ((T "{0} 在 {1} 里面。那是清理列表里的文件夹或临时文件夹，清理时会被清空，搬过去的数据会一起被删。请换一个位置。") -f $path, $r) | Out-Null; return } }
    $script:customDest = $path
    Fill-DestChoices $path
})

# 搬家前要关掉的程序：Names 交给后台（只关这些），Text 给人看（聊天软件写软件名，其余写进程名）
function Get-ClosePlan($items, [string[]]$appKeys) {
    $names = @(Get-KillPreview $items)
    $friendly = @(); $covered = @{}
    if ($appKeys) {
        $defs = Get-ChatApps
        foreach ($a in @(Get-BusyApps $appKeys)) {
            $friendly += (T $a)
            foreach ($n in $names) { foreach ($pat in (@($defs[$a].P) + @($defs[$a].K))) { if ($pat -and $n -like $pat) { $covered[$n] = $true } } }
        }
    }
    foreach ($n in $names) { if (-not $covered.ContainsKey($n)) { $friendly += $n } }
    return @{ Names = $names; Text = (@($friendly | Select-Object -Unique) -join (T '、')) }
}
# 这些聊天软件里哪些正开着：先按进程名找，对不上再看程序所在的文件夹（例如 ...\DingDing\...）
function Get-BusyApps([string[]]$apps) {
    $def = Get-ChatApps
    $procs = @(Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.Id -ne $PID })
    $names = @()
    foreach ($a in $apps) {
        $d = $def[$a]; if (-not $d) { continue }
        $hit = $false
        foreach ($pat in $d.P) { if (@($procs | Where-Object { $_.Name -like $pat }).Count -gt 0) { $hit = $true; break } }
        if (-not $hit -and $d.Dirs) { foreach ($pp in $procs) { if (PathHasAny ([string]$pp.Path) $d.Dirs) { $hit = $true; break } } }
        if ($hit) { $names += $a }
    }
    return ,$names
}

function Invoke-RunSelected([string]$title = (T '执行所选操作')) {
    $plan = @()
    foreach ($r in $script:rows) {
        if ($r.Action -ne (T '跳过')) {
            $b = if ($sync.Sizes) { [double]$sync.Sizes[$r.Idx] } else { 0 }
            $plan += @{ Idx = $r.Idx; Action = $r.Action; Name = $r.Name; Bytes = [math]::Max([double]0, [double]$b); Sig = $(if ($script:rowSig) { [string]$script:rowSig[$r.Idx] } else { '' }) }
        }
    }
    if (-not $plan) { Show-Sheet -Title (T '没有选中任何操作') -Text (T '在列表里把要处理的项目选成「删除」或「搬到其他盘」，再点「执行所选操作」。') | Out-Null; return }
    $dest = Get-Dest
    $cat0 = @{}; foreach ($c in $catalog) { $cat0[$c.Idx] = $c }
    $moves = @($plan | Where-Object { $_.Action -eq (T '搬到其他盘') })
    $moveBytes = [double]0; foreach ($x in $moves) { $moveBytes += $x.Bytes }
    if ($moves) {
        if (-not $dest -or -not (Test-Path ($dest.Substring(0, 3)))) { Show-Sheet -Kind warn -Title (T '没有可用的搬家目标') -Text (T '请在「搬家目标」里选一个 C 盘以外的本机硬盘。') | Out-Null; return }
        $destFree = DriveFree ($dest.Substring(0, 2))
        # 上次没搬完留下的副本会直接接着用，只补差异；这种情况下由搬家时逐个文件夹核对空间
        $reuseAny = $false
        foreach ($x in $moves) {
            foreach ($pth in @($cat0[$x.Idx].Paths)) {
                if ($reuseAny -or -not $pth -or -not (Test-Path -LiteralPath $pth) -or (IsLink $pth)) { continue }
                if ((Find-MoveDest $pth $dest).Reuse) { $reuseAny = $true }
            }
        }
        if (-not $reuseAny -and $destFree -lt $moveBytes * 1.05) {
            Show-Sheet -Kind warn -Title ((T "{0} 盘放不下") -f $dest.Substring(0, 1)) -Text ((T "{0} 只剩 {1}，要搬的东西有 {2}。请换一个目标，或少选几项搬家。") -f $dest.Substring(0, 2), (GB $destFree), (GB $moveBytes)) | Out-Null; return
        }
    }
    $total = [double]0; foreach ($x in $plan) { $total += $x.Bytes }
    $items = @($plan | ForEach-Object { (T "{0}　{1}") -f $_.Action, $_.Name })
    $text = (T "涉及约 {0}。大文件夹搬家可能要几十分钟，进度会显示在窗口中间，做完会告诉你结果。") -f (GB $total)
    if ($moves) { $text += ((T "`n`n要搬的东西会放到 {0}。") -f $dest) }
    # 有删除项时，必须勾选「确认不会带来损失」才能开始
    $dels = @($plan | Where-Object { $_.Action -eq (T '删除') })
    $ack = ''
    if ($dels) {
        $text += (T "`n`n其中 {0} 项会删除文件，删除后可能无法恢复。请确认这些资料不再需要。") -f $dels.Count
        $careful = @($dels | Where-Object { $cat0[$_.Idx].Careful })
        if ($careful.Count -gt 0) { $text += (T "`n其中 {0} 项是「谨慎清理」（{1}）：删了要重新下载或重新生成，第一次打开会慢一点。不想清的，在列表里改成「跳过」。") -f $careful.Count, (@($careful | ForEach-Object { $_.Name }) -join (T '、')) }
        $conf = @($dels | Where-Object { ([string]$cat0[$_.Idx].G).StartsWith('需确认') })
        if ($conf.Count -gt 0) { $text += (T "`n其中 {0} 项是「需确认」的高风险项目（{1}），请再看一遍说明。") -f $conf.Count, (@($conf | ForEach-Object { $_.Name }) -join (T '、')) }
        if ((Get-Setting 'Recycle' '0') -eq '1') {
            $text += (T "`n按设置，这次删除的文件会先放进回收站，可以从回收站恢复。")
            $acts = @($dels | Where-Object { $cat0[$_.Idx].Act })
            if ($acts.Count -gt 0) { $text += (T "`n但其中 {0} 项（{1}）由系统命令处理，不能放进回收站，会直接删除。") -f $acts.Count, (@($acts | ForEach-Object { $_.Name }) -join (T '、')) }
        }
        $ack = (T '我已确认要删除的内容不再需要，删除不会给我带来损失；因删除造成的后果由我自己承担。')
    }
    $kind = if ($dels) { 'warn' } else { 'info' }
    $btns = if ($dels) { @((T '取消'), (T '看文件清单'), (T '开始')) } else { @((T '取消'), (T '开始')) }
    while ($true) {
        $ans = Show-Sheet -Kind $kind -Title ((T "执行 {0} 项操作？") -f $plan.Count) -Text $text -Items $items -Buttons $btns -Primary (T '开始') -Cancel (T '取消') -Confirm $ack
        if ($ans -eq (T '看文件清单')) { Show-DeletePreview @($dels | ForEach-Object { $cat0[$_.Idx] }); continue }
        if ($ans -ne (T '开始')) { return }
        break
    }

    # 要搬聊天软件的数据时，先看它们是不是开着：开着的话文件被占用，搬不成功，必须先退出
    $skipped = @(); $skipWho = ''
    $chatMoves = @($moves | Where-Object { $cat0[$_.Idx].Apps })
    if ($chatMoves) {
        $need = @($chatMoves | ForEach-Object { $cat0[$_.Idx].Apps } | Select-Object -Unique)
        $busy = Get-BusyApps $need
        if ($busy.Count -gt 0) {
            $who = @($busy | ForEach-Object { T $_ }) -join (T '、')
            $affected = @($chatMoves | Where-Object { $x = $_; @($cat0[$x.Idx].Apps | Where-Object { $busy -contains $_ }).Count -gt 0 })
            $ans = Show-Sheet -Kind warn -Title ((T "需要先退出{0}") -f $who) `
                -Text ((T "{0}正在使用要搬的文件夹。不退出的话里面的文件一直被占用，搬家不会成功。`n`n点「退出并继续」会替你关掉它们（包括右下角托盘里的）。退出前请确认没有正在发送或下载的文件。搬完后照常打开即可，聊天记录和文件都在。") -f $who) `
                -Items @($affected | ForEach-Object { $_.Name }) -Buttons @((T '取消'), (T '这次不搬这几项'), (T '退出并继续')) -Primary (T '退出并继续') -Cancel (T '取消')
            if ($ans -eq (T '取消')) { return }
            if ($ans -eq (T '这次不搬这几项')) {
                $skipIdx = @{}; foreach ($x in $affected) { $skipIdx[$x.Idx] = $true }
                $skipped = @($affected); $skipWho = $who
                $plan = @($plan | Where-Object { -not $skipIdx.ContainsKey($_.Idx) })
                $moves = @($moves | Where-Object { -not $skipIdx.ContainsKey($_.Idx) })
                UI-Log ((T "{0} 没有退出，这次不搬：{1}") -f $who, (($skipped | ForEach-Object { $_.Name }) -join (T '、')))
                if (-not $plan) { return }
            } else {
                UI-Log ((T "已同意退出 {0}，开始执行后会先关掉它们") -f $who)
            }
        }
    }
    # 搬家时还会关掉的其他程序（后台进程、从要搬的文件夹里运行的程序）：先说清楚，确认后后台只关这些
    $allowed = @()
    if ($moves) {
        $cp = Get-ClosePlan @($moves | ForEach-Object { $cat0[$_.Idx] }) @($moves | ForEach-Object { @($cat0[$_.Idx].Apps) } | Where-Object { $_ } | Select-Object -Unique)
        $agreed = @{}; if ($chatMoves -and $busy) { $defs = Get-ChatApps; foreach ($a in $busy) { foreach ($n in $cp.Names) { foreach ($pat in (@($defs[$a].P) + @($defs[$a].K))) { if ($pat -and $n -like $pat) { $agreed[$n] = $true } } } } }
        $extra = @($cp.Names | Where-Object { -not $agreed.ContainsKey($_) })
        $allowed = @($cp.Names)
        if ($extra.Count -gt 0) {
            $ans = Show-Sheet -Kind warn -Title (T '搬家时还要关掉这些程序') -Text ((T "这些程序正在使用要搬的文件夹：{0}。不关掉的话文件被占用，这几项搬不成。`n`n点「关掉并继续」会替你关掉它们，没保存的内容请先保存；点「不关」就先不碰它们，这几项复制好后会停在最后一步，下次再搬很快。") -f ($extra -join (T '、'))) `
                -Buttons @((T '取消'), (T '不关'), (T '关掉并继续')) -Primary (T '关掉并继续') -Cancel (T '取消')
            if ($ans -eq (T '取消')) { return }
            if ($ans -eq (T '不关')) { $allowed = @($cp.Names | Where-Object { $agreed.ContainsKey($_) }) }
        }
    }
    # 每一行先标「等待」，执行时由后台逐行改成 进行中 / 完成 / 失败
    $sync.Status = [hashtable]::Synchronized(@{}); $sync.StatusVer = 0; $script:statusSeen = -1; $sync.RunSummary = $null; $sync.WaitCount = 0
    $planned = @{}; foreach ($x in $plan) { $planned[$x.Idx] = $true }
    $skipSet = @{}; foreach ($x in $skipped) { $skipSet[$x.Idx] = $true }
    foreach ($r in $script:rows) {
        if ($planned.ContainsKey($r.Idx)) { $r.Status = (T '等待'); $r.StatusBrush = '#86868B' }
        elseif ($skipSet.ContainsKey($r.Idx)) { $r.Status = ((T "这次没搬：{0} 没有退出") -f $skipWho); $r.StatusBrush = '#B25000' }
        else { $r.Status = ''; $r.StatusBrush = '#86868B' }
    }
    $script:runFreeC0 = [double](FreeC)
    $script:runPlan = $plan
    $sync.Mode = 'run'; Start-Op $title; UI-Busy $true
    if ($moves) { UI-Log ((T "搬家目标：{0}") -f $dest) }
    UI-Log ((T "开始执行 {0} 项...") -f $plan.Count)
    Start-Worker @'
$plan = $arg.Plan; $dest = $arg.Dest
$cat = @{}; foreach ($it in (Get-Catalog)) { $cat[$it.Idx] = $it }
$ordered = @($plan | Where-Object { -not $cat[$_.Idx].Last }) + @($plan | Where-Object { $cat[$_.Idx].Last })
$si = 0
$summary = New-Object System.Collections.ArrayList
$handled = @{}
foreach ($p in $ordered) {
    if (Stopping) { break }
    $si++
    $it = $cat[$p.Idx]
    # 这一行显示的和后台找到的不是同一项（扫描后改过清理列表）：不动它
    if (-not $it -or -not $p.Sig -or (Get-ItemSig $it) -ne $p.Sig) {
        $t = (T '列表在扫描后变了，没有处理，请重新扫描')
        SetStatus $p.Idx $t 'skip'; Log ("  {0}：{1}" -f $p.Name, $t)
        [void]$summary.Add(((T "{0} {1}：{2}") -f '·', $p.Name, $t)); $handled[$p.Idx] = $true
        continue
    }
    SetP @{ Steps = $ordered.Count; Step = $si; StepName = ("{0} {1}" -f $p.Action, $it.N); StepIdx = $p.Idx; StepNote = $it.Note; MoveItem = $false
            SubKind = 'none'; SubDone = [double]0; SubTotal = [double]$p.Bytes; SubStart = (Get-Date); Detail = '' }
    SetStatus $p.Idx (T '进行中…') 'run'
    Log ("[{0}] {1}" -f $p.Action, $it.N)
    $res = @{}
    try {
        if ($p.Action -eq (T '搬到其他盘')) {
            New-Item -ItemType Directory -Path $dest -Force | Out-Null
            $it.Restrict = $true; $it.Allowed = @($arg.Allowed)
            Invoke-Move $it $dest $res
            if ($res.Wait -gt 0) { $sync.WaitCount = [int]$sync.WaitCount + $res.Wait }
            $rt = Move-ResultText $res; $t = $rt[0]; $k = $rt[1]
        } else {
            Invoke-Delete $it $res
            if ($res.Cancelled) { $t = (T "中途取消：清理了一部分，释放 {0}") -f (GB $res.Freed); $k = 'warn' }
            else {
                $t = if ($it.Act -and -not $it.Paths) { (T "已完成，释放 {0}") -f (GB $res.Freed) } else { (T "已清理，释放 {0}") -f (GB $res.Freed) }
                $k = 'ok'
            }
        }
    } catch { $t = (T "出错：") + $_.Exception.Message; $k = 'fail'; Log "  $t" }
    SetStatus $p.Idx $t $k
    $mark = switch ($k) { 'ok' { '✓' } 'warn' { '!' } 'fail' { '✗' } default { '·' } }
    [void]$summary.Add(((T "{0} {1}：{2}") -f $mark, $it.N, $t))
    $handled[$p.Idx] = $true
}
if ($sync.WasCancelled) {
    foreach ($p in $ordered) {
        if ($handled.ContainsKey($p.Idx)) { continue }
        SetStatus $p.Idx (T '已取消，没有处理') 'skip'
        [void]$summary.Add(((T "{0} {1}：{2}") -f '·', $cat[$p.Idx].N, (T '已取消，没有处理')))
    }
}
$sync.RunSummary = $summary
if ($sync.WasCancelled) { Log ((T "已中途取消。C 盘现在剩余 {0}") -f (GB (FreeC))) } else { Log ((T "全部完成。C 盘现在剩余 {0}") -f (GB (FreeC))) }
'@ @{ Plan = $plan; Dest = $dest; Allowed = $allowed }
}
$ctl.BtnRun.Add_Click({ Invoke-RunSelected })
# 删除前看清单：列出要删的文件和文件夹（最大的 60 个），完整清单写进一个文本文件
function Show-DeletePreview($items) {
    $list = $null
    try { $list = @(Get-DeletePreview $items 20000) } catch { $list = @() }
    $sorted = @($list | Sort-Object { $_.Bytes } -Descending)
    $tot = [double]0; foreach ($x in $sorted) { $tot += $x.Bytes }
    $lines = @($sorted | Select-Object -First 60 | ForEach-Object { "{0}  {1}{2}" -f (Fmt $_.Bytes), $_.Path, $(if ($_.IsDir) { (T '（整个文件夹）') } else { '' }) })
    $file = ''
    try {
        New-Item -ItemType Directory -Path $script:opLogDir -Force | Out-Null
        $file = Join-Path $script:opLogDir ("preview-{0:yyyyMMdd-HHmmss}.txt" -f (Get-Date))
        $all = New-Object System.Collections.Generic.List[string]
        $all.Add(((T "删除前的文件清单 {0:yyyy-MM-dd HH:mm}，{1:N0} 项，共 {2}") -f (Get-Date), $sorted.Count, (Fmt $tot)))
        foreach ($x in $sorted) { $all.Add(("{0}`t{1}`t{2}`t{3}" -f [long]$x.Bytes, $(if ($x.IsDir) { 'D' } else { 'F' }), $x.Item, $x.Path)) }
        [IO.File]::WriteAllLines($file, $all.ToArray(), (New-Object Text.UTF8Encoding $true))
    } catch { $file = '' }
    $text = (T "按现在的选择会删掉 {0:N0} 项，共 {1}{2}。下面是最大的 {3} 项；整个文件夹的按文件夹算一项。") -f $sorted.Count, (Fmt $tot), $(if ($list.Count -ge 20000) { (T '（只看了前 20000 项）') } else { '' }), [math]::Min(60, $sorted.Count)
    if ($file) { $text += (T "`n完整清单已存到：{0}") -f $file }
    $b = if ($file) { @((T '打开完整清单'), (T '好')) } else { @((T '好')) }
    $ans = Show-Sheet -Title (T '删除前的文件清单') -Text $text -Items $lines -Buttons $b -Primary (T '好') -Cancel (T '好')
    if ($ans -eq (T '打开完整清单')) { try { Start-Process $file } catch {} }
}

# 一键清理：先扫描，扫完按 One 字段（没有就用默认）设好每一项，再走同一个执行流程（会弹确认框）
function Apply-OneClick {
    $cat = @{}; foreach ($it in $catalog) { $cat[$it.Idx] = $it }
    foreach ($r in $script:rows) {
        $it = $cat[$r.Idx]
        $want = if ($it.One) { $it.One } else { $it.Def }
        if (([string]$it.G).StartsWith('需确认') -or $it.Custom) { $want = (T '跳过') }   # 有代价的和自己加的文件夹：一键清理一律不碰
        if ($r.Actions -contains $want) { $r.Action = $want }
    }
}
$script:oneClickPending = $false
$script:runAfterScan = $false
$ctl.BtnOneClick.Add_Click({
    Show-Page 'clean'
    $script:oneClickPending = $true
    UI-Log (T '一键清理：先扫描...')
    Do-Scan
})

