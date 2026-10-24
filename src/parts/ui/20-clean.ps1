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
        # 列表刚换过内容时，记下的行可能已经不在界面上了：先问一声，不让它抛异常
        if (-not $sv.IsAncestorOf($c)) { $script:cleanItems = $null; continue }
        try { if ($c.TransformToAncestor($sv).Transform((New-Object System.Windows.Point 0, 0)).Y + 20 -gt $bottom) { $below++ } } catch {}
    }
    $ctl.CleanMoreText.Text = if ($below -gt 0) { (T "下面还有 {0} 项") -f $below } else { (T '下面还有内容') }
    $ctl.CleanMore.Visibility = 'Visible'
}
# ---------- 清理页：一类一个选项卡；表头点「名称」「大小」排序，下拉框只看某一种操作；选项卡和表头滚到顶上就停住 ----------
$script:cleanTab = ''; $script:cleanOp = ''; $script:cleanPinned = $false; $script:cleanGroups = $null
function Update-CleanTabs {
    $ctl.CleanTabs.Children.Clear(); $script:cleanBadge = @{}
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
        $t2 = New-Object System.Windows.Controls.TextBlock; $t2.Text = [string]$cnt[$g]; $t2.Style = $win.FindResource('TabBadgeText'); $script:cleanBadge[$g] = $t2
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
    $script:planSig = ''; Update-CleanSummary   # 选项卡上的「已选 / 一共」
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
    if ($script:cleanBadge.Count) { Update-TabBadges }
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
    $noDest = -not (Test-DestOk)   # 只有 C 盘、或者选的盘拔掉了：要搬的项默认跳过，其余照常清
    foreach ($it in $catalog) {
        $b = $sizes[$it.Idx]
        if (-not $b) { continue }
        if ($it.Lvl -and [int]$it.Lvl -gt $mode) { continue }   # 这个模式下不列（换到更高的模式再扫描就有）
        $r = New-Object RowItem
        $script:rowSig[$it.Idx] = Get-ItemSig $it
        $r.Idx = $it.Idx; $r.Group = $it.G; $r.Name = $it.N; $r.Note = $it.Note; $r.Actions = $it.Actions; $r.Action = $it.Def
        if ($noDest -and $it.Def -eq (T '搬到其他盘')) { $r.Action = (T '跳过'); $r.Status = (T '没有可以搬去的其他硬盘，先跳过'); $r.StatusBrush = '#6E6E73' }
        # 组名「安全清理（缓存、临时文件……）」拆成标题和说明两行显示
        $gt = T ([string]$it.G)
        $gp = $gt.Split([char]0xFF08, 2); if ($gp.Count -lt 2) { $gp = $gt.Split([char]'(', 2) }
        $r.GroupTitle = $gp[0].Trim()
        $r.GroupNote = if ($gp.Count -gt 1) { $gp[1].TrimEnd([char]0xFF09).TrimEnd(')') } else { '' }
        $r.First = -not $seen.ContainsKey($it.G); $seen[$it.G] = $true
        $r.SizeText = if ($b -lt 0) { (T '运行后知道') } else { Fmt $b }
        $r.Bytes = [double]$b
        if ($b -gt 0 -and $r.Action -ne (T '跳过')) { $total += $b }
        $col.Add($r)
    }
    $script:rows = $col
    $ctl.List.ItemsSource = $col   # 不再分组显示：上面的选项卡一次只显示一类（Update-CleanTabs）
    $ctl.EmptyClean.Visibility = if ($col.Count -gt 0) { 'Collapsed' } else { 'Visible' }
    if ($col.Count -eq 0) { $ctl.EmptyCleanText.Text = (T 'C 盘上没找到可以清理的东西') }
    Update-CleanOverview
    Update-ChatCard
    $script:reclaim = $total
    UI-Status
    $ctl.Summary.Text = ((T "共 {0} 项。按当前选择，可释放约 {1}。") -f $col.Count, (GB $total))
}
# 第一次打开扫完：一句结论（一键清理能腾出多少），一个主按钮。点了和「一键清理」一样，会先列出要做的事再确认
$script:firstRun = $false; $script:firstResult = $false
function Show-FirstResult {
    if (-not $script:rows) { return }
    $cat = @{}; foreach ($c in $catalog) { $cat[$c.Idx] = $c }
    $b = [double]0
    foreach ($r in $script:rows) { $a = Get-OneClickAction $cat[$r.Idx]; if ($a -ne (T '跳过') -and $r.Actions -contains $a -and $r.Bytes -gt 0) { $b += $r.Bytes } }
    if ($b -lt 100MB) {
        Show-Sheet -Kind done -Title (T '扫描完了') -Text ((T "C 盘上能放心删的缓存和临时文件不多（{0}）。下面的列表里有每一项的说明；左边的「空间地图」能看到是什么占着 C 盘。") -f (Fmt $b)) | Out-Null
        return
    }
    $go = T '一键清理'
    $ans = Show-Sheet -Kind info -Title ((T "C 盘可以腾出约 {0}") -f (Fmt $b)) `
        -Text (T "都是缓存、临时文件和日志，删了会自动重建；个人文件夹（桌面、文档、下载等）里的东西不碰，聊天记录也不动。`n`n点「一键清理」开始（会先列出要做的事，再确认一次）；想先看看明细，点「先看看」。") `
        -Buttons @((T '先看看'), $go) -Primary $go -Cancel (T '先看看')
    if ($ans -ne $go -or $script:worker) { return }
    Apply-OneClick
    Invoke-RunSelected (T '一键清理')
}
# 聊天记录卡片：一键清理只删不搬，聊天记录占了多少、要不要搬，在这里单独说，按钮只搬这几项
$script:chatIdx = @()
function Update-ChatCard {
    $cat = @{}; foreach ($c in $catalog) { $cat[$c.Idx] = $c }
    $chat = @($script:rows | Where-Object { $c = $cat[$_.Idx]; $c -and $c.Kind -eq 'move' -and $c.Tier -eq 'chat' -and $_.Bytes -gt 0 -and $_.Actions -contains (T '搬到其他盘') })
    $bytes = [double]0; foreach ($r in $chat) { $bytes += $r.Bytes }
    $script:chatIdx = @($chat | ForEach-Object { $_.Idx })
    if ($chat.Count -eq 0 -or $bytes -lt 200MB) { $ctl.ChatCard.Visibility = 'Collapsed'; return }
    $names = @($chat | Sort-Object Bytes -Descending | Select-Object -First 3 | ForEach-Object { (T "{0} {1}") -f $_.Name, (Fmt $_.Bytes) }) -join (T '、')
    $ctl.ChatCardTitle.Text = (T "聊天记录占了 C 盘 {0}") -f (Fmt $bytes)
    if (Test-DestOk) {
        $ctl.ChatCardText.Text = (T "{0}。一键清理只删缓存，不碰它们。搬到 {1} 盘以后，C 盘原位置只留一个链接，聊天记录和文件原样保留，软件照常使用；搬之前要先退出这些聊天软件。") -f $names, (Get-Dest).Substring(0, 1)
        $ctl.BtnChatMove.Visibility = 'Visible'
    } else {
        $ctl.ChatCardText.Text = (T "{0}。一键清理只删缓存，不碰它们。这台电脑没有可以搬去的其他硬盘，接上一块硬盘后可以把它们搬过去。") -f $names
        $ctl.BtnChatMove.Visibility = 'Collapsed'
    }
    $ctl.ChatCard.Visibility = 'Visible'
}
$ctl.BtnChatMove.Add_Click({
    if ($script:worker -or -not $script:chatIdx -or -not $script:rows) { return }
    Invoke-RunSelected (T '搬走聊天记录') -OnlyMove $script:chatIdx
})

# 用户在列表里改了某一行的操作，就重算「可释放约多少」
$script:planSig = ''
function Update-CleanSummary {
    if (-not $script:rows -or $script:worker -or -not $sync.Sizes) { return }
    $sig = ''; foreach ($r in $script:rows) { $sig += [string]$r.Action + '|' }
    if ($sig -eq $script:planSig) { return }
    $script:planSig = $sig
    $pt = Get-PlanTotals $script:rows $sync.Sizes
    $script:reclaim = $pt.Del + $pt.Move
    UI-Status
    # 执行时处理的是所有选项卡里选了的，不只是眼前这一个：合计写清楚删多少、搬多少
    $parts = @()
    if ($pt.Del -gt 0) { $parts += ((T "删除约 {0}") -f (GB $pt.Del)) }
    if ($pt.Move -gt 0) { $parts += ((T "搬走约 {0}") -f (GB $pt.Move)) }
    $ctl.Summary.Text = if ($pt.N -gt 0) { (T "所有选项卡一共选了 {0} 项：{1}。") -f $pt.N, $(if ($parts) { $parts -join (T '，') } else { (T '大小运行后才知道') }) } else { (T '没有选中任何项目。') }
    $ctl.BtnRun.IsEnabled = ($pt.N -gt 0)
    Update-TabBadges $pt
}
# 选项卡上的小数字：选了几项 / 一共几项；「这一类全部跳过」按钮跟着当前选项卡变
function Update-TabBadges($pt) {
    if (-not $pt) { $pt = Get-PlanTotals $script:rows $sync.Sizes }
    foreach ($g in @($script:cleanBadge.Keys)) {
        $x = $pt.Groups[$g]; if (-not $x) { continue }
        $script:cleanBadge[$g].Text = '{0}/{1}' -f $x.Sel, $x.Cnt
    }
    $cur = $pt.Groups[$script:cleanTab]
    $ctl.BtnCleanSkipTab.Visibility = $(if ($cur) { 'Visible' } else { 'Collapsed' })
    $ctl.BtnCleanSkipTab.Content = $(if ($cur -and $cur.Sel -eq 0) { (T '这一类恢复默认') } else { (T '这一类全部跳过') })
}
$script:cleanBadge = @{}
$ctl.BtnCleanSkipTab.Add_Click({
    if (-not $script:rows -or $script:worker) { return }
    $mine = @($script:rows | Where-Object { [string]($_.GroupTitle) -eq $script:cleanTab })
    $skip = T '跳过'
    $any = @($mine | Where-Object { $_.Action -ne $skip }).Count -gt 0
    $cat = @{}; foreach ($c in $catalog) { $cat[$c.Idx] = $c }
    $noDest = -not (Test-DestOk)
    foreach ($r in $mine) {
        if ($any) { $r.Action = $skip }
        else { $d = [string]$cat[$r.Idx].Def; if ($noDest -and $d -eq (T '搬到其他盘')) { $d = $skip }; if (@($r.Actions) -contains $d) { $r.Action = $d } }
    }
    $script:planSig = ''; Update-CleanSummary; Apply-CleanFilter
})

Register-BgJob 'scan' -Cancel look -Stop { $script:oneClickPending = $false } -ReadOnly -Done {
    if ($sync.WasCancelled -or -not $sync.Sizes) {
        $script:oneClickPending = $false
        $sync.Sizes = $script:prevSizes
        End-Op $(if ($sync.WasCancelled) { (T '已中途取消，列表没有更新') } else { (T '没有完成') })
        if ($script:rows) { $ctl.Summary.Text = (T '扫描已取消，下面还是上一次扫描的结果。') }
        else { $ctl.Summary.Text = (T '扫描已取消。点「扫描」重新开始。'); $ctl.EmptyCleanText.Text = (T '扫描已取消。点「扫描」重新开始。') }
    } else {
        Build-Rows $sync.Sizes; End-Op (T '完成')
        if ($script:oneClickPending) { $script:oneClickPending = $false; $script:runAfterScan = $true }
        elseif ($script:firstRun) { $script:firstRun = $false; $script:firstResult = $true }
    }
}
function Do-Scan([switch]$Quiet) {
    $ctl.Summary.Text = (T '正在扫描，一般几秒钟…')
    if (-not $script:rows) { $ctl.EmptyCleanText.Text = (T '正在扫描…') }
    $script:prevSizes = $sync.Sizes   # 扫描中途取消时，列表还用上一次的结果
    Use-BgJob 'scan'; $sync.Sizes = $null
    if (-not $Quiet) { Start-Op (T '扫描可清理项') }
    UI-Busy $true
    Start-Worker @'
$sizes = @{}; $sw = [Diagnostics.Stopwatch]::StartNew(); $times = New-Object System.Collections.ArrayList; $script:walkLog = New-Object System.Collections.ArrayList; $script:linkMemo = @{}
$cat = Get-Catalog; $i = 1; $steps = $cat.Count + 1
[void]$times.Add(@{ N = 'catalog'; Ms = $sw.ElapsedMilliseconds })
SetP @{ Steps = $steps; Step = 1; StepName = (T '读取 C 盘的文件表') }
$t0 = $sw.ElapsedMilliseconds; $tree = Get-SysTree; [void]$times.Add(@{ N = 'MFT'; Ms = $sw.ElapsedMilliseconds - $t0 })
$cat = @($cat | Where-Object { -not $_.Lvl -or [int]$_.Lvl -le [int]$arg.Mode }); $steps = $cat.Count + 1   # 这个模式下不列的不统计（换到更高的模式再扫描就有）
# 要问系统、要等几秒的那几项（安装包、驱动包、传递优化、快捷方式）另外开后台同时问，这边接着读文件表、统计别的
$bg = @{}; foreach ($it in $cat) { if ($it.Bg -and $it.Size) { $bg[[string]$it.Idx] = $it.Size.ToString() } }
$par = Start-Parallel $bg 4
foreach ($it in $cat) { if (Stopping) { break }; if ($par.Run.ContainsKey([string]$it.Idx)) { continue }; $i++; SetP @{ Steps = $steps; Step = $i; StepName = $it.N; SubKind = 'measure'; SubStart = (Get-Date); Detail = (T '统计大小') }; $t0 = $sw.ElapsedMilliseconds; $sizes[$it.Idx] = Measure-Item $it $tree; [void]$times.Add(@{ N = $it.N; Ms = $sw.ElapsedMilliseconds - $t0 }) }
if ($par.Run.Count -gt 0) {
    SetP @{ Steps = $steps; Step = $steps; StepName = (T '等系统回答安装包、驱动包这几项'); SubKind = 'measure'; SubStart = (Get-Date); Detail = (T '统计大小') }
    $t0 = $sw.ElapsedMilliseconds; $got = Wait-Parallel $par 90; [void]$times.Add(@{ N = 'wait for the parallel ones'; Ms = $sw.ElapsedMilliseconds - $t0 })
    foreach ($it in $cat) {
        $k = [string]$it.Idx; if (-not $bg.ContainsKey($k) -or (Stopping)) { continue }
        if ($got.ContainsKey($k)) { $sizes[$it.Idx] = [double]$got[$k].V; [void]$times.Add(@{ N = $it.N + ' (alongside)'; Ms = [double]$got[$k].Ms }) }
        elseif (@($par.Late) -contains $k) { $sizes[$it.Idx] = 0; Log ((T "  {0}：等了一分半钟系统还没回答，这次先不列（下次扫描再问）") -f $it.N); [void]$times.Add(@{ N = $it.N + ' (no answer)'; Ms = 90000 }) }
        else { $t0 = $sw.ElapsedMilliseconds; $sizes[$it.Idx] = Measure-Item $it $tree; [void]$times.Add(@{ N = $it.N; Ms = $sw.ElapsedMilliseconds - $t0 }) }
    }
}
$sync.ScanTimes = $times; $sync.ScanMs = $sw.ElapsedMilliseconds; $sync.ScanWalks = $script:walkLog; $script:walkLog = $null; $script:linkMemo = $null
if (-not (Stopping)) { $sync.Sizes = $sizes }
'@ @{ Mode = (Get-Mode) }
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
    $script:destFilling = $true
    try {
        $ctl.DestPick.Items.Clear()
        $choices = @(Get-DestChoices)
        $auto = $null
        foreach ($c in $choices) {
            $note = if ($c.Auto) { (T '，空间最大') } elseif ($c.Plug) { (T '，移动硬盘') } else { '' }
            $item = New-Object System.Windows.Controls.ComboBoxItem
            $item.Content = (T "{0}    空闲 {1}{2}") -f $c.Path, (Fmt $c.Free), $note; $item.Tag = $c.Path
            [void]$ctl.DestPick.Items.Add($item)
            if ($c.Auto) { $auto = $c }
        }
        if ($script:customDest) {
            $free = DriveFree ($script:customDest.Substring(0, 2))
            $item = New-Object System.Windows.Controls.ComboBoxItem
            $item.Content = (T "{0}    空闲 {1}，自选") -f $script:customDest, (Fmt $free); $item.Tag = $script:customDest
            [void]$ctl.DestPick.Items.Add($item)
        }
        if ($choices.Count -gt 0 -and -not $auto) {
            # 只有移动硬盘：默认先不搬，要搬到移动硬盘得自己从下拉框选
            $item = New-Object System.Windows.Controls.ComboBoxItem
            $item.Content = (T '先不搬（只找到移动硬盘）'); $item.Tag = ''
            $ctl.DestPick.Items.Insert(0, $item)
        }
        if ($ctl.DestPick.Items.Count -eq 0) {
            $item = New-Object System.Windows.Controls.ComboBoxItem
            $item.Content = (T '这台电脑只有 C 盘，没有可以搬去的磁盘'); $item.Tag = ''
            [void]$ctl.DestPick.Items.Add($item)
        }
        $ctl.DestPick.SelectedIndex = 0
        $plugs = @($choices | Where-Object { $_.Plug }).Count
        if ($auto) {
            $ctl.DestHint.Text = (T "已自动选了空闲最多的 {0} 盘（剩 {1}）。也可以从下拉框换一块盘，或点「选择文件夹」。只列本机硬盘：网络盘、网盘、U 盘不能做链接目标。") -f $auto.Drive.Substring(0, 1), (Fmt $auto.Free)
            if ($plugs) { $ctl.DestHint.Text += (T '移动硬盘排在最后，不会自动选：拔掉以后，搬过去的软件会打不开。') }
        } elseif ($plugs) {
            $ctl.DestHint.Text = (T '只找到移动硬盘，所以没有自动选：拔掉以后，搬过去的软件会打不开。这块盘一直插着用的话，可以从下拉框选它；其他清理照常可以做。')
        } else {
            $ctl.DestHint.Text = (T '这台电脑只有 C 盘，不能搬家；其他清理照常可以做。')
        }
        if ($keep) { for ($i = 0; $i -lt $ctl.DestPick.Items.Count; $i++) { if ([string]$ctl.DestPick.Items[$i].Tag -ieq $keep) { $ctl.DestPick.SelectedIndex = $i } } }
        $script:destPrev = $ctl.DestPick.SelectedIndex
    } finally { $script:destFilling = $false }
    Sync-MovesDest
}
function Get-Dest { $i = $ctl.DestPick.SelectedItem; if ($i) { [string]$i.Tag } else { '' } }
# 有没有能用的搬家目标（选了一块盘，而且这块盘现在插着）
function Test-DestOk { $d = Get-Dest; return [bool]($d -and $d.Length -ge 3 -and (Test-Path -LiteralPath $d.Substring(0, 3))) }
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
# 手动选了移动硬盘：先说清楚拔掉以后会怎样。同一块盘这次打开只问一次
$script:plugOk = @{}
$script:destPrev = -1
$script:destFilling = $false
function Confirm-PlugDest([string]$path) {
    if (-not $path -or $path.Length -lt 2) { return $true }
    $d = $path.Substring(0, 2).ToUpperInvariant()
    if ($script:plugOk[$d] -or -not (Test-PluggableDrive $d)) { return $true }
    $go = T '仍然搬到这块盘'
    $r = Show-Sheet -Kind warn -Title (T '搬到移动硬盘？') -Text ((T "{0} 盘接在 USB 这类可以拔插的接口上。搬过去的东西在 C 盘只留一个链接：这块盘拔掉、换了盘符，或者开机时还没认出来，用到这些文件的软件就打不开，聊天软件会像没有记录一样，插回去才恢复。`n`n只有这块盘一直插在这台电脑上时才选它。") -f $d) -Buttons @((T '取消'), $go) -Primary $go -Cancel (T '取消')
    if ($r -eq $go) { $script:plugOk[$d] = $true; return $true }
    return $false
}
$ctl.MovesDest.Add_SelectionChanged({
    if ($script:destSyncing -or $ctl.MovesDest.SelectedIndex -lt 0) { return }
    $script:destSyncing = $true
    try {
        if (Confirm-PlugDest ([string]$ctl.MovesDest.SelectedItem.Tag)) { $ctl.DestPick.SelectedIndex = $ctl.MovesDest.SelectedIndex; $script:destPrev = $ctl.DestPick.SelectedIndex }
        else { $ctl.MovesDest.SelectedIndex = $ctl.DestPick.SelectedIndex }
    } finally { $script:destSyncing = $false }
    Update-CandSel
})
$ctl.DestPick.Add_SelectionChanged({
    if ($script:destSyncing) { return }
    $script:destSyncing = $true
    try {
        if (-not $script:destFilling -and $ctl.DestPick.SelectedIndex -ge 0 -and -not (Confirm-PlugDest (Get-Dest))) { $ctl.DestPick.SelectedIndex = $script:destPrev; return }
        $script:destPrev = $ctl.DestPick.SelectedIndex
        $ctl.MovesDest.SelectedIndex = $ctl.DestPick.SelectedIndex
    } finally { $script:destSyncing = $false }
    if ($script:rows) { Update-ChatCard }   # 卡片上写着搬到哪块盘
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
    if (-not (Confirm-PlugDest $path)) { return }
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

Register-BgJob 'run' -Cancel run -Moves -Done {
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
# $OnlyMove：只搬这几项（聊天记录卡片上的按钮），列表里其他行的选择不管
function Invoke-RunSelected([string]$title = (T '开始处理所选项'), [object[]]$OnlyMove = $null) {
    $plan = @()
    foreach ($r in $script:rows) {
        $act = $r.Action
        if ($OnlyMove) { if ($OnlyMove -notcontains $r.Idx) { continue }; $act = (T '搬到其他盘') }
        if ($act -ne (T '跳过')) {
            $b = if ($sync.Sizes) { [double]$sync.Sizes[$r.Idx] } else { 0 }
            $plan += @{ Idx = $r.Idx; Action = $act; Name = $r.Name; Bytes = [math]::Max([double]0, [double]$b); Sig = $(if ($script:rowSig) { [string]$script:rowSig[$r.Idx] } else { '' }) }
        }
    }
    if (-not $plan) { Show-Sheet -Title (T '没有选中任何操作') -Text (T '在列表里把要处理的项目选成「删除」或「搬到其他盘」，再点「开始处理所选项」。') | Out-Null; return }
    $dest = Get-Dest
    $cat0 = @{}; foreach ($c in $catalog) { $cat0[$c.Idx] = $c }
    $moves = @($plan | Where-Object { $_.Action -eq (T '搬到其他盘') })
    $moveBytes = [double]0; foreach ($x in $moves) { $moveBytes += $x.Bytes }
    if ($moves) {
        if (-not (Test-DestOk)) {
            # 找不到搬家目标：不要整单放弃，问一下要不要先只做删除，要搬的这几项留着不动
            $only = (T '只做删除')
            $rest = @($plan | Where-Object { $_.Action -ne (T '搬到其他盘') })
            $btns = if ($rest.Count) { @((T '取消'), $only) } else { @((T '好')) }
            $ans = Show-Sheet -Kind warn -Title (T '没有可用的搬家目标') -Text ((T "要搬的 {0} 项找不到可以搬去的其他硬盘（这台电脑只有 C 盘，或者选的盘拔掉了）。可以在「搬家目标」里换一块盘；也可以先只做删除，这几项留着不动。") -f $moves.Count) -Items @($moves | ForEach-Object { $_.Name }) -Buttons $btns -Primary $btns[-1] -Cancel $btns[0]
            if ($ans -ne $only) { return }
            foreach ($r in $script:rows) { if ($r.Action -eq (T '搬到其他盘')) { $r.Action = (T '跳过') } }
            $plan = $rest; $moves = @(); $moveBytes = [double]0
        }
    }
    if ($moves) {
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
    if ($moves) {
        $text += ((T "`n`n要搬的东西会放到 {0}。") -f $dest)
        $enc = Get-EncryptionWarning $dest; if ($enc) { $text += "`n`n" + $enc }
        $pw = Get-PowerNote $moveBytes; if ($pw) { $text += "`n`n" + $pw }
    }
    # 有删除项时，必须勾选「确认不会带来损失」才能开始
    $dels = @($plan | Where-Object { $_.Action -eq (T '删除') })
    $ack = ''
    if ($dels) {
        $text += (T "`n`n其中 {0} 项会删除文件，删除后可能无法恢复。请确认这些资料不再需要。") -f $dels.Count
        $careful = @($dels | Where-Object { $cat0[$_.Idx].Careful })
        if ($careful.Count -gt 0) { $text += (T "`n其中 {0} 项是「清后要重建」（{1}）：删了要重新下载或重新生成，第一次打开会慢一点。不想清的，在列表里改成「跳过」。") -f $careful.Count, (@($careful | ForEach-Object { $_.Name }) -join (T '、')) }
        $conf = @($dels | Where-Object { $cat0[$_.Idx].Tier -eq 'confirm' })
        if ($conf.Count -gt 0) { $text += (T "`n其中 {0} 项是「默认不清」里有代价的项目（{1}），请再看一遍说明。") -f $conf.Count, (@($conf | ForEach-Object { $_.Name }) -join (T '、')) }
        if ((Get-Setting 'Recycle' '0') -eq '1') {
            $text += (T "`n按设置，这次删除的文件会先放进回收站，可以从回收站恢复。")
            $acts = @($dels | Where-Object { $cat0[$_.Idx].Act })
            if ($acts.Count -gt 0) { $text += (T "`n但其中 {0} 项（{1}）由系统命令处理，不能放进回收站，会直接删除。") -f $acts.Count, (@($acts | ForEach-Object { $_.Name }) -join (T '、')) }
        }
        $ack = (T '我已确认要删除的内容不再需要，删除不会给我带来损失；因删除造成的后果由我自己承担。')
    }
    # 搬家要关掉的程序（开着的聊天软件、从要搬的文件夹里运行的程序）：先算好，写进同一个确认框，不再一个接一个地问
    $skipped = @(); $skipWho = ''; $allowed = @(); $affected = @(); $who = ''; $closeText = ''
    $chatMoves = @($moves | Where-Object { $cat0[$_.Idx].Apps })
    if ($moves) {
        $appKeys = @($moves | ForEach-Object { @($cat0[$_.Idx].Apps) } | Where-Object { $_ } | Select-Object -Unique)
        $cp = Get-ClosePlan @($moves | ForEach-Object { $cat0[$_.Idx] }) $appKeys
        $allowed = @($cp.Names); $closeText = [string]$cp.Text
        if ($chatMoves) {
            $busy = @(Get-BusyApps @($chatMoves | ForEach-Object { $cat0[$_.Idx].Apps } | Select-Object -Unique))
            if ($busy.Count -gt 0) {
                $who = @($busy | ForEach-Object { T $_ }) -join (T '、')
                $affected = @($chatMoves | Where-Object { $x = $_; @($cat0[$x.Idx].Apps | Where-Object { $busy -contains $_ }).Count -gt 0 })
            }
        }
        if ($closeText) { $text += "`n`n" + ((T "开始后会先替你关掉：{0}（包括屏幕右下角托盘里的）。开着的话文件被占用，搬家不会成功。关之前请确认没有正在发送或下载的文件，没保存的内容先保存；搬完照常打开，聊天记录和文件都在。") -f $closeText) }
    }
    $kind = if ($dels -or $closeText) { 'warn' } else { 'info' }
    $go = if ($closeText) { (T '关掉并开始') } else { (T '开始') }
    $skipBtn = if ($affected.Count) { (T "先不搬{0}的") -f $who } else { '' }
    $btns = @((T '取消')); if ($dels) { $btns += (T '看文件清单') }; if ($skipBtn) { $btns += $skipBtn }; $btns += $go
    while ($true) {
        $ans = Show-Sheet -Kind $kind -Title ((T "执行 {0} 项操作？") -f $plan.Count) -Text $text -Items $items -Buttons $btns -Primary $go -Cancel (T '取消') -Confirm $ack
        if ($ans -eq (T '看文件清单')) { Show-DeletePreview @($dels | ForEach-Object { $cat0[$_.Idx] }); continue }
        if ($skipBtn -and $ans -eq $skipBtn) {
            # 开着的聊天软件这次不关：用到它的那几项这次不搬，其余照做
            $skipIdx = @{}; foreach ($x in $affected) { $skipIdx[$x.Idx] = $true }
            $skipped = @($affected); $skipWho = $who
            $plan = @($plan | Where-Object { -not $skipIdx.ContainsKey($_.Idx) })
            $moves = @($moves | Where-Object { -not $skipIdx.ContainsKey($_.Idx) })
            UI-Log ((T "{0} 没有退出，这次不搬：{1}") -f $who, (($skipped | ForEach-Object { $_.Name }) -join (T '、')))
            if (-not $plan) { return }
            $allowed = @()
            if ($moves) {
                $cp = Get-ClosePlan @($moves | ForEach-Object { $cat0[$_.Idx] }) @($moves | ForEach-Object { @($cat0[$_.Idx].Apps) } | Where-Object { $_ } | Select-Object -Unique)
                $defs = Get-ChatApps
                $allowed = @($cp.Names | Where-Object { $n = $_; -not @($busy | Where-Object { $a = $_; @(@($defs[$a].P) + @($defs[$a].K) | Where-Object { $_ -and $n -like $_ }).Count }).Count })
            }
            break
        }
        if ($ans -ne $go) { return }
        if ($who) { UI-Log ((T "已同意退出 {0}，开始执行后会先关掉它们") -f $who) }
        break
    }

    # 每一行先标「等待」，执行时由后台逐行改成 进行中 / 完成 / 失败
    $sync.Status = [hashtable]::Synchronized(@{}); $sync.StatusVer = 0; $script:statusSeen = -1; $sync.RunSummary = $null; $sync.WaitCount = 0
    $planned = @{}; foreach ($x in $plan) { $planned[$x.Idx] = $true }
    $skipSet = @{}; foreach ($x in $skipped) { $skipSet[$x.Idx] = $true }
    foreach ($r in $script:rows) {
        if ($planned.ContainsKey($r.Idx)) { $r.Status = (T '等待'); $r.StatusBrush = '#6E6E73' }
        elseif ($skipSet.ContainsKey($r.Idx)) { $r.Status = ((T "这次没搬：{0} 没有退出") -f $skipWho); $r.StatusBrush = '#B25000' }
        else { $r.Status = ''; $r.StatusBrush = '#6E6E73' }
    }
    $script:runFreeC0 = [double](FreeC)
    $script:runPlan = $plan
    Use-BgJob 'run'; Start-Op $title; UI-Busy $true
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
    if ($ans -eq (T '打开完整清单')) { [void](Open-AsUser $file) }
}

# 一键清理：先扫描，扫完按 One 字段（没有就用默认）设好每一项，再走同一个执行流程（会弹确认框）
function Apply-OneClick {
    $cat = @{}; foreach ($it in $catalog) { $cat[$it.Idx] = $it }
    foreach ($r in $script:rows) {
        $want = Get-OneClickAction $cat[$r.Idx]   # 只删不搬；有代价的和自己加的文件夹不碰
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

