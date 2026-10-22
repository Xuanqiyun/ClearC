# ------------------------------------------------------------
# 第一页：清理 C 盘
# ------------------------------------------------------------
# 列表上方的总览：「扫描到 23 项，分 4 类：安全清理 9 项、……」
function Update-CleanOverview {
    $col = $script:rows
    if (-not $col -or $col.Count -eq 0) { $ctl.CleanOverview.Visibility = 'Collapsed'; Update-CleanMore; return }
    $order = New-Object System.Collections.Generic.List[string]; $cnt = @{}
    foreach ($r in $col) { if (-not $cnt.ContainsKey($r.GroupTitle)) { $order.Add($r.GroupTitle); $cnt[$r.GroupTitle] = 0 }; $cnt[$r.GroupTitle]++ }
    $parts = @($order | ForEach-Object { (T "{0} {1} 项") -f $_, $cnt[$_] })
    $ctl.CleanOverviewText.Text = (T "扫描到 {0} 项，分成 {1} 类：{2}。每一项都可以单独选「删除」「搬走」或「跳过」，往下滚动查看全部。") -f $col.Count, $order.Count, ($parts -join (T '、'))
    $ctl.CleanOverview.Visibility = 'Visible'
    $script:cleanItems = $null
    $ctl.CleanScroll.ScrollToTop()
    $ctl.CleanScroll.UpdateLayout()
    Update-CleanMore
}
# 下面还有没看到的内容时，底部浮一个「下面还有 N 项」
function Update-CleanMore {
    $sv = $ctl.CleanScroll
    $left = [double]$sv.ScrollableHeight - [double]$sv.VerticalOffset
    if (-not $script:rows -or $script:rows.Count -eq 0 -or $left -lt 30) { $ctl.CleanMore.Visibility = 'Collapsed'; return }
    # 数一数还有几行在可视区下面（列表的行在第一次需要时从界面树里找出来，之后直接用）
    if (-not $script:cleanItems -or $script:cleanItems.Count -ne $script:rows.Count) {
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
function Build-Rows($sizes) {
    $col = New-Object 'System.Collections.ObjectModel.ObservableCollection[RowItem]'
    $total = [double]0
    $seen = @{}
    $mode = Get-Mode
    foreach ($it in $catalog) {
        $b = $sizes[$it.Idx]
        if (-not $b) { continue }
        if ($it.Lvl -and [int]$it.Lvl -gt $mode) { continue }   # 这个模式下不列（换到更高的模式再扫描就有）
        $r = New-Object RowItem
        $r.Idx = $it.Idx; $r.Group = $it.G; $r.Name = $it.N; $r.Note = $it.Note; $r.Actions = $it.Actions; $r.Action = $it.Def
        # 组名「安全清理（缓存、临时文件……）」拆成标题和说明两行显示
        $gt = T ([string]$it.G)
        $gp = $gt.Split([char]0xFF08, 2); if ($gp.Count -lt 2) { $gp = $gt.Split([char]'(', 2) }
        $r.GroupTitle = $gp[0].Trim()
        $r.GroupNote = if ($gp.Count -gt 1) { $gp[1].TrimEnd([char]0xFF09).TrimEnd(')') } else { '' }
        $r.First = -not $seen.ContainsKey($it.G); $seen[$it.G] = $true
        $r.SizeText = if ($b -lt 0) { (T '运行后知道') } else { Fmt $b }
        if ($b -gt 0 -and $it.Def -ne (T '跳过')) { $total += $b }
        $col.Add($r)
    }
    $script:rows = $col
    $ctl.List.ItemsSource = $col
    $view = [System.Windows.Data.CollectionViewSource]::GetDefaultView($col)
    $view.GroupDescriptions.Clear()
    $view.GroupDescriptions.Add((New-Object System.Windows.Data.PropertyGroupDescription 'Group'))
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
$ctl.BtnCleanCustom.Add_Click({ Show-Page 'settings'; $ctl.SetScroll.UpdateLayout(); $ctl.SetCleanCard.BringIntoView() })

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
            $plan += @{ Idx = $r.Idx; Action = $r.Action; Name = $r.Name; Bytes = [math]::Max([double]0, [double]$b) }
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
        $ack = (T '我已确认要删除的内容不再需要，删除不会给我带来损失；因删除造成的后果由我自己承担。')
    }
    $kind = if ($dels) { 'warn' } else { 'info' }
    if ((Show-Sheet -Kind $kind -Title ((T "执行 {0} 项操作？") -f $plan.Count) -Text $text -Items $items -Buttons @((T '取消'), (T '开始')) -Primary (T '开始') -Cancel (T '取消') -Confirm $ack) -ne (T '开始')) { return }

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

# 一键清理：先扫描，扫完按 One 字段（没有就用默认）设好每一项，再走同一个执行流程（会弹确认框）
function Apply-OneClick {
    $cat = @{}; foreach ($it in $catalog) { $cat[$it.Idx] = $it }
    foreach ($r in $script:rows) {
        $it = $cat[$r.Idx]
        $want = if ($it.One) { $it.One } else { $it.Def }
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

