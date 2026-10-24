# ------------------------------------------------------------
# 搬家管理
# ------------------------------------------------------------
$script:moveRows = $null
function Load-Moves {
    $script:movedTargets = $null
    $col = New-Object 'System.Collections.ObjectModel.ObservableCollection[MoveRow]'
    foreach ($rec in (Get-MoveRecords)) {
        $st = Get-MoveState $rec
        if ($st.State -eq 'gone') { continue }
        $r = New-Object MoveRow
        $r.Name = $rec.Name; $r.Src = $rec.Src; $r.Dst = $rec.Dst; $r.State = $st.State
        $r.Status = $st.Text; $r.StatusBrush = $st.Brush
        $r.CanBack = ($st.State -eq 'ok'); $r.CanDrop = ($st.State -eq 'pending')
        $r.CanFix = (($st.State -eq 'broken' -and $st.Fix) -or $st.State -eq 'nosrc'); $r.FixTarget = [string]$st.Fix
        if (-not (Test-Path -LiteralPath $r.Dst)) { $r.SizeText = '—' }
        $col.Add($r)
    }
    $script:moveRows = $col
    $ctl.MovesList.ItemsSource = $col
    $ctl.EmptyMoves.Visibility = if ($col.Count -gt 0) { 'Collapsed' } else { 'Visible' }
    Set-NavCount 'MovesTabDone' $col.Count
    Set-DoneInfo $(if ($col.Count -gt 0) { (T "共 {0} 个文件夹，正在统计大小…") -f $col.Count } else { (T '还没有搬过文件夹。') })
    if ($col.Count -gt 0 -and -not $script:worker) {
        $sync.Mode = 'movesize'
        UI-Busy $true
        Start-Worker @'
$tot = [double]0; $n = 0
foreach ($r in $arg.Rows) {
    if (-not (Test-Path -LiteralPath $r.Dst)) { continue }
    $b = Est-Bytes $r.Dst (Get-DriveTree $r.Dst)   # 目标盘的文件表读一次，所有搬走的文件夹都从里面查
    $r.Size = [long]$b; $r.SizeText = GB $b
    if ($r.State -eq 'ok') { $tot += $b; $n++ }
}
$sync.MoveTotal = @{ Bytes = $tot; Count = $n }
'@ @{ Rows = @($col) }
    }
    elseif ($script:candPending -and -not $script:worker) { Start-CandScan }
}
# ---------- 可以搬的：C 盘上还没搬的聊天记录、装在 C 盘的软件、其他大文件夹 ----------
$script:candRows = $null; $script:candList = $null; $script:candScanned = $false; $script:candPending = $false; $script:runAfterCand = $false
$script:movesTab = 'cand'; $script:candInfo = ''; $script:doneInfo = ''; $script:storeChat = @(); $script:candSeen = -1
function Set-DoneInfo([string]$t) { $script:doneInfo = $t; if ($script:movesTab -eq 'done') { $ctl.MovesInfo.Text = $t } }
function Set-CandInfo([string]$t) { $script:candInfo = $t; if ($script:movesTab -eq 'cand') { $ctl.MovesInfo.Text = $t } }
function Set-MovesTab([string]$t) {
    $script:movesTab = $t
    $c = ($t -eq 'cand')
    $ctl.CandList.Visibility = if ($c) { 'Visible' } else { 'Collapsed' }
    $ctl.EmptyCand.Visibility = if ($c -and -not ($script:candRows -and $script:candRows.Count -gt 0)) { 'Visible' } else { 'Collapsed' }
    $ctl.MovesCard.Visibility = if ($c) { 'Collapsed' } else { 'Visible' }
    Update-HeadVis
    $ctl.CandBar.Visibility = if ($c) { 'Visible' } else { 'Collapsed' }
    $ctl.CandStore.Visibility = if ($c -and @($script:storeChat).Count -gt 0) { 'Visible' } else { 'Collapsed' }
    $ctl.MovesInfo.Text = if ($c) { $script:candInfo } else { $script:doneInfo }
    # 别处搬过、搬回过东西以后，切回来时重新看一遍
    if ($c -and -not $script:candScanned -and -not $script:worker -and $ctl.PageMoves.Visibility -eq 'Visible') { Start-CandScan }
}
# 目录上的数字
function Set-NavCount([string]$name, [int]$n) {
    $ctl[$name + 'N'].Text = [string]$n
    $ctl[$name + 'B'].Visibility = if ($n -gt 0) { 'Visible' } else { 'Collapsed' }
}
# 「可以搬的」下面一次只看一类：聊天记录、装在 C 盘的软件、其他可搬的文件夹、不适合搬的软件（空 = 全部）
$script:candGroup = ''
function Set-CandGroup([string]$g) {
    $script:candGroup = $g
    $cfg = $script:sortCfg['CandList']
    if ($cfg) { $cfg.Filter = if ($g) { [Predicate[object]]{ param($o) [string]$o.Group -eq $script:candGroup } } else { $null } }
    Apply-ListSort 'CandList'
    $ctl.BtnCandAll.IsEnabled = ($g -ne 'other' -and $g -ne 'blocked')
    if ($script:movesTab -ne 'cand') { Set-MovesTab 'cand' }
}
$ctl.MovesTabCand.Add_Checked({ Set-CandGroup '' })
foreach ($n in 'MNavChat', 'MNavApp', 'MNavOther', 'MNavBlocked') { $ctl[$n].Add_Checked({ Set-CandGroup ([string]$this.Tag) }) }
$ctl.MovesTabDone.Add_Checked({ Set-MovesTab 'done' })

function Start-CandScan {
    if ($script:worker) { return }
    $script:candPending = $false; $script:candScanned = $true
    $ctl.CandList.ItemsSource = $null; $script:candRows = $null
    $ctl.EmptyCandText.Text = (T '正在看 C 盘上还有什么能搬…')
    if ($script:movesTab -eq 'cand') { $ctl.EmptyCand.Visibility = 'Visible' }
    Set-CandInfo (T '正在看 C 盘上还有什么能搬，统计大小要一会儿…')
    foreach ($k in 'MovesTabCand', 'MNavChat', 'MNavApp', 'MNavOther', 'MNavBlocked') { Set-NavCount $k 0 }
    $sync.Mode = 'movescan'; $sync.CandResult = $null; $sync.CandStore = $null
    Start-Op (T '看看 C 盘上还有什么能搬') -NoCard
    UI-Busy $true
    Start-Worker @'
$out = New-Object System.Collections.ArrayList
Start-Phases
# 系统服务和驱动（WMI）、已装的软件、应用商店里的聊天软件：另外开后台同时读，这边先统计聊天记录这些
$par = Start-Parallel ([ordered]@{ svc = 'Get-ServicePaths'; apps = 'Get-InstalledApps -NoStore'; store = 'Get-StoreChatApps' }) 3
$cat = @(Get-Catalog | Where-Object { ($_.Kind -eq 'move' -or $_.Kind -eq 'flex') -and $_.Paths })
Mark-Phase 'catalog'
# 上次搬了一半的（目标盘上已经有副本），这次再搬只补差异
$partial = @{}
foreach ($root in (All-MoveRoots)) { foreach ($pr in (Read-MoveMapPairs $root)) { $partial[([string]$pr[0]).TrimEnd('\').ToLowerInvariant()] = $true } }
$catKeys = @()
$steps = $cat.Count + 3; $step = 1
SetP @{ Steps = $steps; Step = 1; StepName = (T '读取 C 盘的文件表') }
$tree = Get-SysTree
Mark-Phase 'MFT'
foreach ($c in $cat) {
    if (Stopping) { break }
    $step++
    SetP @{ Steps = $steps; Step = $step; StepName = $c.N; SubKind = 'measure'; SubStart = (Get-Date); Detail = (T '统计大小') }
    $paths = @(); $bytes = [double]0; $isPartial = $false
    foreach ($p in $c.Paths) {
        if (-not $p) { continue }
        $catKeys += $p.TrimEnd('\').ToLowerInvariant()
        if (-not $p.StartsWith("$env:SystemDrive\", [StringComparison]::OrdinalIgnoreCase)) { continue }   # 比如「文档」已经改到 D 盘
        if (-not (Test-Path -LiteralPath $p -PathType Container)) { continue }
        if ($c.NoOneDrive -and $p -like '*OneDrive*') { continue }
        if ((IsLink $p) -or (Get-LinkedAncestor $p)) { continue }
        $b = Est-Bytes $p $tree
        if (Stopping) { break }
        $paths += $p; $bytes += $b
        if ($partial.ContainsKey($p.TrimEnd('\').ToLowerInvariant())) { $isPartial = $true }
    }
    if ($sync.WasCancelled) { break }
    if (-not $paths -or $bytes -lt 1MB) { continue }
    [void]$out.Add(@{ Type = 'cat'; Idx = $c.Idx; Name = $c.N; G = $c.G; Paths = $paths; Bytes = $bytes; Note = $c.Note; Apps = @($c.Apps); Partial = $isPartial; Measured = $true })
}
if (-not $sync.WasCancelled) {
    $step++
    SetP @{ Step = $step; StepName = (T '读取装在 C 盘的软件'); SubKind = 'action'; SubStart = (Get-Date); Detail = (T '读取已安装的软件和系统服务') }
    Mark-Phase 'chat and other folders'
    $got = Wait-Parallel $par
    Mark-Phase 'wait for services, apps, Store'
    if ($script:phList) { foreach ($k in @($got.Keys)) { [void]$script:phList.Add(@{ N = "$k (alongside)"; Ms = [double]$got[$k].Ms }) } }
    $apps = if ($got.ContainsKey('apps')) { $got.apps.V } else { Get-InstalledApps -NoStore }
    $svc = if ($got.ContainsKey('svc')) { $got.svc.V } else { Get-ServicePaths }
    $sd = $env:SystemDrive
    $onC = @($apps | Where-Object { $_.Location -and $_.Location.StartsWith("$sd\", [StringComparison]::OrdinalIgnoreCase) })
    $step++; $n = 0; $seenLoc = @{}
    foreach ($a in $onC) {
        if (Stopping) { break }
        $n++
        $loc = ([string]$a.Location).TrimEnd('\')
        if ($seenLoc.ContainsKey($loc.ToLowerInvariant())) { continue }   # 注册表里同一个文件夹登记了两次
        $seenLoc[$loc.ToLowerInvariant()] = $true
        if (-not (Test-Path -LiteralPath $loc -PathType Container)) { continue }
        if ((IsLink $loc) -or (Get-LinkedAncestor $loc)) { continue }
        # 和「聊天记录」等项目是同一个文件夹（或互相包含）的，只列一次
        $lk = $loc.ToLowerInvariant(); $dup = $false
        foreach ($k in $catKeys) { if ($lk -eq $k -or $lk.StartsWith($k + '\') -or $k.StartsWith($lk + '\')) { $dup = $true; break } }
        if ($dup) { continue }
        SetP @{ StepName = ((T "检查软件：{0}") -f $a.Name); SubKind = 'measure'; SubStart = (Get-Date); Detail = ((T "{0} / {1}") -f $n, $onC.Count) }
        $why = Get-AppMoveBlock $a $apps $svc
        $bytes = [double]$a.Est; $measured = $false
        if (-not $why) { $bytes = Est-Bytes $loc $tree; $measured = $true; if (Stopping) { break } }
        if ($bytes -lt 1MB) { continue }
        [void]$out.Add(@{ Type = 'app'; Idx = 0; Name = $a.Name; Location = $loc; Paths = @($loc); Bytes = $bytes; Publisher = $a.Publisher; Version = $a.Version
            Block = $why; Partial = $partial.ContainsKey($lk); Measured = $measured })
    }
    Mark-Phase 'apps on C:'
    if (-not $sync.WasCancelled) { $sync.CandStore = if ($got.ContainsKey('store')) { @($got.store.V) } else { Get-StoreChatApps } }
} else { [void](Wait-Parallel $par) }
End-Phases
$sync.CandResult = $out
'@ $null
}

function Build-CandRows($list) {
    $script:candList = $list
    $col = New-Object 'System.Collections.ObjectModel.ObservableCollection[CandRow]'
    $gText = @{
        app     = (T '装在 C 盘的软件（整个安装文件夹搬走，快捷方式、卸载和自动更新照常可用，不用重装）')
        blocked = (T '不适合搬的软件（原因写在每一项下面；不用的可以到「软件管理」里卸载）')
    }
    $order = @{ chat = 0; app = 1; other = 2; blocked = 3 }
    $chatG = $null
    foreach ($c in $catalog) { if ($c.Apps) { $chatG = $c.G; break } }
    $items = @()
    foreach ($x in @($list)) {
        $g = if ($x.Type -eq 'app') { if ($x.Block) { 'blocked' } else { 'app' } } elseif ($x.G -eq $chatG) { 'chat' } else { 'other' }
        if ($g -eq 'blocked' -and [double]$x.Bytes -lt 100MB) { continue }
        $items += [pscustomobject]@{ O = $order[$g]; B = [double]$x.Bytes; G = $g; X = $x }
    }
    $seen = @{}
    foreach ($e in @($items | Sort-Object @{ Expression = 'O' }, @{ Expression = 'B'; Descending = $true })) {
        $g = $e.G; $x = $e.X
        $r = New-Object CandRow
        $r.Type = $x.Type; $r.Idx = [int]$x.Idx; $r.Name = $x.Name; $r.Size = [long]$x.Bytes
        $r.Key = if ($x.Type -eq 'app') { 'a:' + $x.Location.ToLowerInvariant() } else { 'c:' + $x.Idx }
        $r.SizeText = $(if ($x.Measured) { '' } else { (T '约 ') }) + (Fmt ([double]$x.Bytes))
        $r.PathText = (@($x.Paths) -join (T '；'))
        $r.Location = if ($x.Type -eq 'app') { $x.Location } else { [string]@($x.Paths)[0] }
        $r.Apps = [string[]]@($x.Apps)
        $r.CanMove = ($g -ne 'blocked'); $r.Partial = [bool]$x.Partial
        if ($x.Type -eq 'app') {
            $meta = @(); if ($x.Publisher) { $meta += $x.Publisher }; if ($x.Version) { $meta += ((T '版本 ') + $x.Version) }
            $r.Note = if ($x.Block) { [string]$x.Block } else { $meta -join ' · ' }
        } else { $r.Note = [string]$x.Note }
        if ($x.Partial -and $r.CanMove) { $r.Status = (T '上次已经复制过一部分，这次只补有变化的文件'); $r.StatusBrush = '#0A6ED1' }
        $gt = if ($g -eq 'chat' -or $g -eq 'other') { T ([string]$x.G) } else { $gText[$g] }
        $gp = $gt.Split([char]0xFF08, 2); if ($gp.Count -lt 2) { $gp = $gt.Split([char]'(', 2) }
        $r.Group = $g; $r.GroupOrder = [int]$order[$g]; $r.GroupTitle = $gp[0].Trim()
        $r.GroupNote = if ($gp.Count -gt 1) { $gp[1].TrimEnd([char]0xFF09).TrimEnd(')') } else { '' }
        $r.First = -not $seen.ContainsKey($g); $seen[$g] = $true
        $col.Add($r)
    }
    $script:candRows = $col
    $ctl.CandList.ItemsSource = $col
    $view = [System.Windows.Data.CollectionViewSource]::GetDefaultView($col)
    $view.GroupDescriptions.Clear()
    $view.GroupDescriptions.Add((New-Object System.Windows.Data.PropertyGroupDescription 'Group'))
    Update-CandInfo
}
function Update-CandInfo {
    $rows = @(); if ($script:candRows) { $rows = @($script:candRows | Where-Object { $_.CanMove }) }
    $tot = [double]0; foreach ($r in $rows) { $tot += [double]$r.Size }
    $nChat = @($rows | Where-Object { $_.Group -eq 'chat' }).Count; $nApp = @($rows | Where-Object { $_.Group -eq 'app' }).Count; $nOther = @($rows | Where-Object { $_.Group -eq 'other' }).Count
    $parts = @()
    if ($nChat) { $parts += ((T "聊天记录 {0} 项") -f $nChat) }
    if ($nApp) { $parts += ((T "软件 {0} 个") -f $nApp) }
    if ($nOther) { $parts += ((T "其他文件夹 {0} 项") -f $nOther) }
    if ($rows.Count -gt 0) {
        Set-CandInfo ((T "C 盘上还能搬走约 {0}：{1}。勾选后点右下角「搬到其他盘」。") -f (Fmt $tot), ($parts -join (T '、')))
    } else {
        Set-CandInfo (T 'C 盘上没找到还能搬的东西。')
    }
    Set-NavCount 'MovesTabCand' $rows.Count
    $all = @(); if ($script:candRows) { $all = @($script:candRows) }
    foreach ($p in @(@('MNavChat', 'chat'), @('MNavApp', 'app'), @('MNavOther', 'other'), @('MNavBlocked', 'blocked'))) {
        $c = @($all | Where-Object { $_.Group -eq $p[1] }).Count
        Set-NavCount $p[0] $c
        # 这一类没有东西就不列（正在看的那一类除外）
        $ctl[$p[0]].Visibility = if ($c -gt 0 -or $script:candGroup -eq $p[1]) { 'Visible' } else { 'Collapsed' }
    }
    $has = $script:candRows -and $script:candRows.Count -gt 0
    $ctl.EmptyCandText.Text = (T 'C 盘上没找到还能搬的东西：聊天记录和软件要么已经搬走，要么不在 C 盘。')
    if ($script:movesTab -eq 'cand') { $ctl.EmptyCand.Visibility = if ($has) { 'Collapsed' } else { 'Visible' } }
    Update-CandSel
}
function Update-CandSel {
    $sel = @(); if ($script:candRows) { $sel = @($script:candRows | Where-Object { $_.Checked -and $_.CanMove }) }
    $tot = [double]0; foreach ($r in $sel) { $tot += [double]$r.Size }
    $ctl.CandSel.Text = if ($sel.Count -gt 0) { (T "已选 {0} 项，约 {1}。") -f $sel.Count, (Fmt $tot) } else { (T '勾选要搬的项目。') }
    $ctl.BtnCandMove.IsEnabled = ($sel.Count -gt 0) -and -not $script:worker -and [bool](Get-Dest)
}
# 全选：聊天记录和软件（正在看其中一类时只选这一类）；「其他可搬的文件夹」要看清说明自己勾
$ctl.BtnCandAll.Add_Click({ if ($script:candRows) { foreach ($r in $script:candRows) { if ($r.CanMove -and $r.Group -ne 'other' -and (-not $script:candGroup -or $r.Group -eq $script:candGroup)) { $r.Checked = $true } } }; Update-CandSel })
$ctl.BtnCandNone.Add_Click({ if ($script:candRows) { foreach ($r in $script:candRows) { $r.Checked = $false } }; Update-CandSel })
$ctl.BtnCandStore.Add_Click({ [void](Open-AsUser 'ms-settings:appsfeatures') })
$ctl.CandList.AddHandler([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent, [System.Windows.RoutedEventHandler]{
    param($s, $e)
    $b = $e.OriginalSource
    if (-not ($b -is [System.Windows.Controls.Button]) -or -not ($b.Tag -is [CandRow])) { return }
    if ($b.Name -eq 'CandOpen') { Open-Location $b.Tag.Location }
})
# 按住鼠标左键上下拖：拖过的行一起勾上（从没勾的行开始拖）或一起取消（从勾着的行开始拖），像在资源管理器里拉框；
# 按在方框、「打开」按钮、滚动条上照常用；拖到列表上面或下面会自动滚动；不能搬的行不动
$script:cdrag = $null
$script:cdragTimer = New-Object System.Windows.Threading.DispatcherTimer
$script:cdragTimer.Interval = [TimeSpan]::FromMilliseconds(50)
# 纵坐标 y 处是哪一行（返回这一行的数据；分组标题、空白处返回 $null）
function Get-CandRowAt([double]$y) {
    $lv = $ctl.CandList; $h = [double]$lv.ActualHeight; if ($h -le 4) { return $null }
    $yy = [math]::Min([math]::Max($y, 2.0), $h - 2.0)
    foreach ($dy in 0, -4, 4) {
        $hit = $lv.InputHitTest((New-Object System.Windows.Point ([math]::Max(40.0, [double]$lv.ActualWidth / 2)), ($yy + $dy)))
        if ($hit -is [System.Windows.DependencyObject]) {
            $c = $null; try { $c = [System.Windows.Controls.ItemsControl]::ContainerFromElement($lv, $hit) } catch {}
            if ($c -is [System.Windows.Controls.ListViewItem]) { return $c.Content }
        }
    }
    return $null
}
function Get-CandIndex($items, $row) { for ($k = 0; $k -lt $items.Count; $k++) { if ([object]::ReferenceEquals($items[$k], $row)) { return $k } }; return -1 }
function Set-CandRange($d, $row) {
    if (-not $row) { return }
    $i = Get-CandIndex $d.Items $row
    if ($i -lt 0 -or $i -eq $d.Cur) { return }
    $a = [math]::Min($d.Anchor, $i); $b = [math]::Max($d.Anchor, $i)
    for ($k = 0; $k -lt $d.Items.Count; $k++) {
        $r = $d.Items[$k]; if (-not $r.CanMove) { continue }
        $want = if ($k -ge $a -and $k -le $b) { [bool]$d.Want } else { [bool]$d.Snap[$k] }
        if ([bool]$r.Checked -ne $want) { $r.Checked = $want }
    }
    $d.Cur = $i
    Update-CandSel
}
function Stop-CandDrag {
    $d = $script:cdrag; $script:cdrag = $null
    $script:cdragTimer.Stop()
    if ($d -and $d.Cap -and $d.Cap.IsMouseCaptured) { $d.Cap.ReleaseMouseCapture() }
}
$ctl.CandList.Add_PreviewMouseLeftButtonDown({
    param($s, $e)
    Stop-CandDrag
    $src = $e.OriginalSource
    if ($src -isnot [System.Windows.DependencyObject]) { return }
    try {
        for ($v = $src; $v -and -not [object]::ReferenceEquals($v, $s); $v = [System.Windows.Media.VisualTreeHelper]::GetParent($v)) {
            if ($v -is [System.Windows.Controls.Primitives.ButtonBase] -or $v -is [System.Windows.Controls.Primitives.ScrollBar]) { return }   # 方框、按钮、滚动条照常用
            if ($v -is [System.Windows.Controls.ListViewItem]) { break }
        }
    } catch { return }
    $c = $null; try { $c = [System.Windows.Controls.ItemsControl]::ContainerFromElement($s, $src) } catch {}
    if ($c -isnot [System.Windows.Controls.ListViewItem]) { return }
    $r = $c.Content; if (-not $r -or -not $r.CanMove) { return }
    $items = [object[]]@($s.Items)
    $script:cdrag = @{ Items = $items; Anchor = (Get-CandIndex $items $r); Cur = (Get-CandIndex $items $r); Moved = $false; Want = -not [bool]$r.Checked; Snap = $null; Cap = $null }
})
$ctl.CandList.Add_PreviewMouseMove({
    param($s, $e)
    $d = $script:cdrag
    if (-not $d) { return }
    if ($e.LeftButton -ne [System.Windows.Input.MouseButtonState]::Pressed) { Stop-CandDrag; return }
    $r = Get-CandRowAt ($e.GetPosition($s).Y)
    if (-not $d.Moved) {
        if (-not $r -or (Get-CandIndex $d.Items $r) -eq $d.Anchor) { return }
        $d.Moved = $true
        $d.Snap = [bool[]]@($d.Items | ForEach-Object { [bool]$_.Checked })
        # 鼠标交给列表里的滚动区：拖到列表外面也收得到；起点这一行先跟着变
        $d.Cap = Find-Visual $s ([System.Windows.Controls.ScrollViewer]); if (-not $d.Cap) { $d.Cap = $s }
        [void]$d.Cap.CaptureMouse()
        $a = $d.Items[$d.Anchor]; if ([bool]$a.Checked -ne [bool]$d.Want) { $a.Checked = [bool]$d.Want }
        $script:cdragTimer.Start()
    }
    Set-CandRange $d $r
})
$ctl.CandList.Add_PreviewMouseLeftButtonUp({ if ($script:cdrag) { Stop-CandDrag } })
$ctl.CandList.Add_LostMouseCapture({ param($s, $e) $d = $script:cdrag; if ($d -and $d.Moved -and $d.Cap -and [object]::ReferenceEquals($e.OriginalSource, $d.Cap)) { $script:cdrag = $null; $script:cdragTimer.Stop() } })
$script:cdragTimer.Add_Tick({
    $d = $script:cdrag
    if (-not $d -or -not $d.Moved) { $script:cdragTimer.Stop(); return }
    if ([System.Windows.Input.Mouse]::LeftButton -ne [System.Windows.Input.MouseButtonState]::Pressed) { Stop-CandDrag; return }
    $lv = $ctl.CandList; $y = [System.Windows.Input.Mouse]::GetPosition($lv).Y; $h = [double]$lv.ActualHeight
    if ($y -ge 0 -and $y -le $h) { return }
    $sv = $d.Cap; if ($sv -isnot [System.Windows.Controls.ScrollViewer]) { return }
    $over = if ($y -lt 0) { -$y } else { $y - $h }
    $steps = [math]::Min(4, 1 + [int][math]::Floor($over / 30))
    for ($k = 0; $k -lt $steps; $k++) { if ($y -lt 0) { $sv.LineUp() } else { $sv.LineDown() } }
    $lv.UpdateLayout()
    Set-CandRange $d (Get-CandRowAt $y)
})
$ctl.BtnCandMove.Add_Click({ Start-MoveMany })

# 勾选的一起搬：先确认（列出每一项、要关掉的软件），再逐项复制、核对、换成链接
function Start-MoveMany {
    if ($script:worker) { Show-Sheet -Title (T '请等当前操作做完') -Text (T '另一个操作还在进行中。') | Out-Null; return }
    $sel = @(); if ($script:candRows) { $sel = @($script:candRows | Where-Object { $_.Checked -and $_.CanMove }) }
    if ($sel.Count -eq 0) { return }
    $dest = Get-Dest
    if (-not $dest) { Show-Sheet -Kind warn -Title (T '没有可用的搬家目标') -Text (T '这台电脑没有 C 盘以外的硬盘，或者还没选搬家目标。') | Out-Null; return }
    $total = [double]0; $need = [double]0; foreach ($r in $sel) { $total += [double]$r.Size; if (-not $r.Partial) { $need += [double]$r.Size } }
    $free = DriveFree ($dest.Substring(0, 2))
    if ($free -gt 0 -and $free -lt $need + 1GB) {
        Show-Sheet -Kind warn -Title (T '目标盘放不下') -Text ((T "选中的一共约 {0}，{1} 只剩 {2}。少选几项，或者换一块空间更大的盘。") -f (Fmt $total), $dest.Substring(0, 2), (Fmt $free)) | Out-Null; return
    }
    # 给资源管理器装了右键菜单之类组件的软件，文件夹一直被占着，搬不了
    $exMods = @(); foreach ($p in @(Get-Process -Name explorer -ErrorAction SilentlyContinue)) { try { foreach ($m in $p.Modules) { $exMods += [string]$m.FileName } } catch {} }
    $blocked = @()
    foreach ($r in @($sel | Where-Object { $_.Type -eq 'app' })) {
        $pre = $r.Location.TrimEnd('\') + '\'
        if (@($exMods | Where-Object { $_.StartsWith($pre, [StringComparison]::OrdinalIgnoreCase) }).Count -gt 0) { $blocked += $r }
    }
    foreach ($r in $blocked) { $r.Checked = $false; $r.Status = (T '不适合搬：它给资源管理器装了右键菜单之类的组件，文件夹一直被占着'); $r.StatusBrush = '#B25000' }
    if ($blocked.Count -gt 0) { $sel = @($sel | Where-Object { $blocked -notcontains $_ }) }
    if ($sel.Count -eq 0) { Show-Sheet -Kind warn -Title (T '选中的软件不适合搬') -Text (T '它们给资源管理器装了右键菜单之类的组件，桌面和文件夹窗口一直开着这些文件，文件夹被占着，搬不了。') | Out-Null; return }
    $total = [double]0; foreach ($r in $sel) { $total += [double]$r.Size }
    # 要先关掉的软件
    $cat0 = @{}; foreach ($c in $catalog) { $cat0[$c.Idx] = $c }
    $need = @($sel | Where-Object { $_.Type -eq 'cat' } | ForEach-Object { @($cat0[$_.Idx].Apps) } | Where-Object { $_ } | Select-Object -Unique)
    $pv = @($sel | ForEach-Object { if ($_.Type -eq 'app') { @{ Kill = @(); KillDirs = @(); Paths = @($_.Location) } } else { $cat0[$_.Idx] } })
    $cp = Get-ClosePlan $pv $need
    $who = $cp.Text
    $text = (T "把下面 {0} 项搬到 {1}，一共约 {2}。每一项都先复制、核对两边一致，再把 C 盘上的原位置换成链接，删掉 C 盘上的那份；软件照常使用，以后可以在「已经搬走的」里搬回 C 盘。") -f $sel.Count, $dest, (Fmt $total)
    if ($who) { $text += ((T "`n`n{0} 正在运行，搬之前会替你关掉（包括屏幕右下角托盘里的）。没保存的内容请先保存。") -f $who) }
    $text += (T "`n`n要注意：目标盘要一直接着；不要删除、改名或移动目标盘上的 CDriveMoved 文件夹。")
    $enc = Get-EncryptionWarning $dest; if ($enc) { $text += "`n`n" + $enc }
    $pw = Get-PowerNote $total; if ($pw) { $text += "`n`n" + $pw }
    $items = @($sel | ForEach-Object { (T "{0}（{1}）") -f $_.Name, $_.SizeText })
    $btn = if ($who) { (T '关掉并搬走') } else { (T '搬到其他盘') }
    if ((Show-Sheet -Title ((T "把 {0} 项搬到其他盘？") -f $sel.Count) -Text $text -Items $items -Buttons @((T '取消'), $btn) -Primary $btn -Cancel (T '取消')) -ne $btn) { return }
    if ($script:worker) { return }
    $plan = @(); foreach ($r in $sel) { $plan += @{ Key = $r.Key; Type = $r.Type; Idx = $r.Idx; Name = $r.Name; Location = $r.Location; Bytes = [double]$r.Size; Note = $r.Note } }
    $allowed = @($cp.Names)
    $sync.Status = [hashtable]::Synchronized(@{}); $sync.StatusVer = 0; $script:statusSeen = -1; $script:candSeen = -1; $sync.WaitCount = 0
    foreach ($r in $sel) { $r.Status = (T '等待'); $r.StatusBrush = '#86868B' }
    $script:runPlan = @($plan | ForEach-Object { @{ Idx = $_.Key; Name = $_.Name } })
    $script:mmFreeC0 = [double](FreeC)
    $sync.Mode = 'movemany'; $sync.MmRes = $null
    Start-Op ((T "搬 {0} 项到其他盘") -f $plan.Count); UI-Busy $true
    UI-Log ((T "搬家目标：{0}") -f $dest)
    Start-Worker @'
$dest = $arg.Dest
New-Item -ItemType Directory -Path $dest -Force | Out-Null
$cat = @{}; foreach ($it in (Get-Catalog)) { $cat[$it.Idx] = $it }
$summary = New-Object System.Collections.ArrayList
$doneKeys = New-Object System.Collections.ArrayList
$handled = @{}; $moved = [double]0; $i = 0
foreach ($p in $arg.Plan) {
    if (Stopping) { break }
    $i++
    SetP @{ Steps = $arg.Plan.Count; Step = $i; StepName = $p.Name; StepIdx = $p.Key; StepNote = $p.Note; MoveItem = $false
            SubKind = 'none'; SubDone = [double]0; SubTotal = [double]$p.Bytes; SubStart = (Get-Date); Detail = '' }
    SetStatus $p.Key (T '进行中…') 'run'
    Log ("[{0}] {1}" -f (T '搬到其他盘'), $p.Name)
    $res = @{ Done = 0; Fail = 0; Wait = 0; Moved = [double]0; Dest = @(); Msgs = @() }
    try {
        if ($p.Type -eq 'app') {
            $item = @{ N = $p.Name; Paths = @($p.Location); Apps = @(); Kill = @(); KillDirs = @()
                BusyHint = (T '还有程序开着里面的文件。请退出这个软件（包括屏幕右下角托盘里的图标），关掉打开着这个文件夹的窗口，再搬一次；已经复制好的部分下次直接用，很快') }
            $item.Restrict = $true; $item.Allowed = @($arg.Allowed)
            Invoke-AppMove $item $dest $res
        } else {
            $it = $cat[[int]$p.Idx]; $it.Restrict = $true; $it.Allowed = @($arg.Allowed)
            Invoke-Move $it $dest $res
        }
        if ($res.Wait -gt 0) { $sync.WaitCount = [int]$sync.WaitCount + $res.Wait }
        $rt = Move-ResultText $res; $t = $rt[0]; $k = $rt[1]
    } catch { $t = (T "出错：") + $_.Exception.Message; $k = 'fail'; Log "  $t" }
    SetStatus $p.Key $t $k
    $mark = switch ($k) { 'ok' { '✓' } 'warn' { '!' } 'fail' { '✗' } default { '·' } }
    [void]$summary.Add(((T "{0} {1}：{2}") -f $mark, $p.Name, $t))
    $handled[$p.Key] = $true
    if ($res.Done -gt 0) { $moved += [double]$res.Moved; if ($k -eq 'ok') { [void]$doneKeys.Add($p.Key) } }
}
if ($sync.WasCancelled) {
    foreach ($p in $arg.Plan) {
        if ($handled.ContainsKey($p.Key)) { continue }
        SetStatus $p.Key (T '已取消，没有处理') 'skip'
        [void]$summary.Add(((T "{0} {1}：{2}") -f '·', $p.Name, (T '已取消，没有处理')))
    }
}
$sync.MmRes = @{ Summary = $summary; Done = $doneKeys; Moved = $moved }
'@ @{ Plan = $plan; Dest = $dest; Allowed = $allowed }
}

$ctl.BtnMovesRefresh.Add_Click({ if (-not $script:worker) { $script:candPending = $true; Load-Moves } })
$ctl.MovesList.AddHandler([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent, [System.Windows.RoutedEventHandler]{
    param($s, $e)
    $b = $e.OriginalSource
    if (-not ($b -is [System.Windows.Controls.Button]) -or -not ($b.Tag -is [MoveRow])) { return }
    $r = $b.Tag
    if ($script:worker) { Show-Sheet -Title (T '请等当前操作做完') -Text (T '另一个操作还在进行中。') | Out-Null; return }
    switch ($b.Name) {
        'MvOpen' { if (Test-Path -LiteralPath $r.Dst) { Open-Location $r.Dst } else { Open-Location $r.Src } }
        'MvFix' {
            $t = if ($r.FixTarget) { $r.FixTarget } else { $r.Dst }
            if ((Show-Sheet -Title (T '修复链接？') -Text ((T "让 C 盘上的 {0} 重新指向 {1}。修好后软件就能照常找到数据。") -f $r.Src, $t) -Buttons @((T '取消'), (T '修复')) -Primary (T '修复') -Cancel (T '取消')) -ne (T '修复')) { return }
            $res = @{}; Invoke-FixLink $r.Src $t $res
            if ($res.Ok) { Show-Sheet -Kind done -Title (T '链接已修复') -Text ("{0} → {1}" -f $r.Src, $t) | Out-Null } else { Show-Sheet -Kind warn -Title (T '没修好') -Text $res.Msg | Out-Null }
            Load-Moves
        }
        'MvDrop' {
            $ans = Show-Sheet -Kind danger -Title ((T "删除多余的副本（{0}）？") -f $r.SizeText) `
                -Text ((T "C 盘上的原文件夹 {0} 还在，软件用的是它；目标盘上的 {1} 是上次没搬完留下的副本。删掉它可以腾出目标盘的空间，C 盘不受影响。") -f $r.Src, $r.Dst) `
                -Confirm (T '我已确认 C 盘上的原文件夹还在，删掉这份副本不会给我带来损失。') -Buttons @((T '取消'), (T '删除副本')) -Primary (T '删除副本') -Cancel (T '取消')
            if ($ans -ne (T '删除副本')) { return }
            $sync.Mode = 'movedrop'; $sync.MoveRes = $null
            Start-Op (T '删除多余的副本'); UI-Busy $true
            Start-Worker @'
SetP @{ Steps = 1; Step = 1; StepName = $arg.Rec.Dst; SubKind = 'action'; SubStart = (Get-Date) }
$res = @{}; Invoke-DropCopy $arg.Rec $res; $sync.MoveRes = $res
'@ @{ Rec = @{ Src = $r.Src; Dst = $r.Dst } }
        }
        'MvBack' {
            $free = [double](FreeC)
            $text = (T "把 {0} 复制回 C 盘的 {1}，核对一致后拆掉链接、换回真正的文件夹，最后删除目标盘上的那份。`n`nC 盘现在剩 {2}，这个文件夹约 {3}。") -f $r.Dst, $r.Src, (GB $free), $r.SizeText
            if ((Show-Sheet -Title ((T "把「{0}」搬回 C 盘？") -f $r.Name) -Text $text -Buttons @((T '取消'), (T '搬回')) -Primary (T '搬回') -Cancel (T '取消')) -ne (T '搬回')) { return }
            $rec = @{ Src = $r.Src; Dst = $r.Dst; Idx = 0 }; $apps = @()
            foreach ($c in $catalog) { if (@($c.Paths) -contains $r.Src) { $rec.Idx = $c.Idx; $apps = @($c.Apps) } }
            $cItem = @{ Kill = @(); KillDirs = @() }; foreach ($c in $catalog) { if ($c.Idx -eq $rec.Idx -and $rec.Idx) { $cItem = $c } }
            $cp = Get-ClosePlan @(@{ Kill = @($cItem.Kill); KillDirs = @($cItem.KillDirs); Paths = @($r.Src, $r.Dst) }) $apps
            $rec.Restrict = $true; $rec.Allowed = @($cp.Names)
            $inside = @($cp.Names)
            if ($inside.Count -gt 0 -and $cp.Text) { $inside = @($cp.Text) }
            if (-not $apps -and $inside.Count -gt 0) {
                $who = $inside -join (T '、')
                if ((Show-Sheet -Kind warn -Title ((T "需要先退出{0}") -f $who) -Text ((T "{0} 正在从这个文件夹运行，不退出的话没法搬回。点「退出并继续」会替你关掉它们（没保存的内容请先保存）。") -f $who) -Buttons @((T '取消'), (T '退出并继续')) -Primary (T '退出并继续') -Cancel (T '取消')) -ne (T '退出并继续')) { return }
            }
            if ($apps) {
                $busy = Get-BusyApps $apps
                if ($busy.Count -gt 0 -or $cp.Names.Count -gt 0) {
                    $who = $cp.Text
                    if ((Show-Sheet -Kind warn -Title ((T "需要先退出{0}") -f $who) -Text ((T "{0} 正在使用这个文件夹，不退出的话没法搬回。点「退出并继续」会替你关掉它们。") -f $who) -Buttons @((T '取消'), (T '退出并继续')) -Primary (T '退出并继续') -Cancel (T '取消')) -ne (T '退出并继续')) { return }
                }
            }
            $sync.Mode = 'moveback'; $sync.MoveRes = $null
            Start-Op ((T "搬回 C 盘：{0}") -f $r.Name); UI-Busy $true
            Start-Worker @'
SetP @{ Steps = 1; Step = 1; StepName = $arg.Rec.Src }
$res = @{}; Invoke-MoveBack $arg.Rec $res; $sync.MoveRes = $res
'@ @{ Rec = $rec }
        }
    }
})

