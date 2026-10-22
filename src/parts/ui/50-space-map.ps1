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
    $r.Name = $name; $r.Path = $path; $r.Size = [long]$size; $r.SizeText = Fmt $size; $r.IsDir = $isDir; $r.Node = $node; $r.Meta = $meta; $r.Disk = -1
    $r.Bar = if ($max -gt 0) { [math]::Max([double]2, 160.0 * $size / $max) } else { 0 }
    if ($size -le 0) { $r.Bar = 0 }
    $r.Pct = if ($parent -gt 0) { "{0:N1}%" -f (100.0 * $size / $parent) } else { '' }
    switch ($kind) {
        'dir'  { $r.Glyph = [string][char]0xE8B7; $r.GlyphBrush = '#0A84FF' }
        'link' { $r.Glyph = [string][char]0xE71B; $r.GlyphBrush = '#8E8E93' }
        'more' { $r.Glyph = [string][char]0xE712; $r.GlyphBrush = '#8E8E93' }
        default { $r.Glyph = [string][char]0xE8A5; $r.GlyphBrush = '#8E8E93' }
    }
    $why = if ($path) { Get-DeleteBlock $path } else { '' }
    if (-not $why -and $path -and (Test-ChatPath $path)) { $why = (T '聊天记录里的文件只能查看和打开位置；要腾地方，到「搬家管理」把整个聊天记录搬到其他盘') }
    $r.Locked = [bool]$why; $r.LockTip = $why
    return $r
}
# 路径在不在某个聊天软件的聊天记录文件夹里（这些只看不删，要腾地方就整体搬家）
function Test-ChatPath([string]$path) {
    if ($null -eq $script:chatDirs) {
        $script:chatDirs = New-Object System.Collections.Generic.List[string]
        foreach ($c in $catalog) {
            if (-not ([string]$c.G).StartsWith('聊天软件') -or -not $c.Paths) { continue }
            foreach ($p in $c.Paths) { if ($p) { foreach ($it in @(Get-Item -Path $p -Force -ErrorAction SilentlyContinue)) { if ($it.PSIsContainer) { $script:chatDirs.Add($it.FullName.TrimEnd('\')) } } } }
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
function Show-MapLevel($node) {
    if (-not $node) { return }
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
            if ($dn) { $fm += Get-DiskNote ([double]$f.Size) $fd 0 $true }
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
    $ctl.MapPath.Text = $path
    $ctl.MapInfo.Text = (T "这一层共 {0}，{1:N0} 个文件{2}") -f (Fmt $node.Size), $node.Files, $(if ($script:mapScanAt) { (T " · 扫描于 {0:HH:mm}（{1}）") -f $script:mapScanAt, $script:mapHow } else { '' })
    $ctl.BtnMapAcct.Visibility = if ($script:mapRoot -and $script:mapRoot.HasDisk) { 'Visible' } else { 'Collapsed' }
    $ctl.BtnMapUp.IsEnabled = ($null -ne $node.Parent)
    $ctl.EmptyMap.Visibility = if ($rows.Count -gt 0) { 'Collapsed' } else { 'Visible' }
    if ($rows.Count -eq 0) { $ctl.EmptyMapText.Text = (T '这个文件夹是空的') }
    $ctl.BtnMapExport.IsEnabled = ($rows.Count -gt 0)
    $ctl.BtnMapReport.IsEnabled = $true
    if ($script:mapView -eq 'tree') { Draw-MapTree }
    Update-MapSel
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
        $bg = if (-not $row) { '#C7CCD6' } elseif ($row.IsDir) { $script:treeColors[$i % $script:treeColors.Count] } else { '#8E99AD' }
        $b.Background = Brush $bg 'b'
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
            $b.Add_MouseLeftButtonDown({
                param($s, $e)
                $r = $s.Tag
                if ($e.ClickCount -ge 2) { if ($r.IsDir -and $r.Node) { Show-MapLevel $r.Node }; $e.Handled = $true; return }
                if ($script:treeSel) { $script:treeSel.BorderBrush = Brush '#00000000' }
                $script:treeSel = $s; $s.BorderBrush = Brush '#1D1D1F' 'd'
                $ctl.MapList.SelectedItems.Clear(); $ctl.MapList.SelectedItem = $r
            })
        }
        [void]$cv.Children.Add($b)
    }
}
$ctl.MapTree.Add_SizeChanged({ if ($script:mapView -eq 'tree') { Draw-MapTree } })
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
}
$script:mapFindMax = 500
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
            foreach ($it in @(Get-Item -Path $p -Force -ErrorAction SilentlyContinue)) {
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
    $rows = New-Object System.Collections.Generic.List[MapRow]
    $f = Get-MapFilter
    if ($f.Chat) { $res = [DiskMap]::FindFilesIn($f.Min, $f.Before, $f.Exts, $f.Name, $f.Chat.Nodes.ToArray(), $script:mapFindMax) }
    else { $res = [DiskMap]::FindFiles($f.Min, $f.Before, $f.Exts, $f.Name, $f.Under, $script:mapFindMax) }
    $max = if ($res.Files.Count -gt 0) { [double]$res.Files[0].Size } else { 0 }
    $tot = if ($script:mapRoot) { [double]$script:mapRoot.Size } else { 0 }
    $dn = (Get-Flag 'MapDisk') -and $script:mapRoot -and $script:mapRoot.HasDisk
    foreach ($x in $res.Files) {
        $p = $x.Path
        $fm = (T "{0} · 修改于 {1:yyyy-MM-dd}") -f (Split-Path $p -Parent), $x.Modified
        if ($dn) { $fm += Get-DiskNote ([double]$x.Size) ([double]$x.Disk) $(if ($x.Shared) { [double]$x.Size } else { 0 }) $true }
        $row = New-MapRow $x.Name $p $x.Size $max $tot $false $null $fm 'file'
        $row.When = '{0:yyyy-MM-dd HH:mm}' -f $x.Modified
        $row.Disk = [long]$x.Disk; $row.Shared = [bool]$x.Shared
        # 聊天记录里的文件只看不删：要腾地方就整体搬家
        if ($f.Chat) { $row.Locked = $true; $row.LockTip = (T '聊天记录里的文件只能查看和打开位置；要腾地方，到「搬家管理」把整个聊天记录搬到其他盘') }
        [void]$rows.Add($row)
    }
    $ctl.MapList.ItemsSource = $rows
    $head = (T "找到 {0:N0} 个文件，共 {1}") -f $res.Count, (Fmt $res.Bytes)
    if ($res.Count -gt $rows.Count) { $head += ((T "，下面列出最大的 {0:N0} 个") -f $rows.Count) }
    $ctl.MapPath.Text = $head
    $where = if ($f.Under) { $f.Under.FullPath() } elseif ($script:mapRoot) { $script:mapRoot.FullPath() } else { '' }
    $ctl.MapInfo.Text = (T "在 {0} 里找，只能找到扫描时记下的 1 MB 以上的文件") -f $where
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
    $ctl.MapGrow.Visibility = if ($grow) { 'Visible' } else { 'Collapsed' }
    $ctl.MapTree.Visibility = if ($tree) { 'Visible' } else { 'Collapsed' }
    $ctl.MapList.Visibility = if ($grow -or $tree) { 'Collapsed' } else { 'Visible' }
    if (-not $script:mapRoot) { return }
    if ($v -eq 'dirs' -or $tree) { Show-MapLevel $(if ($script:mapCur) { $script:mapCur } else { $script:mapRoot }) }
    elseif ($v -eq 'files') { Show-MapFiles }
    else {
        $ctl.MapGrow.ItemsSource = $script:growRows
        $ctl.BtnMapUp.IsEnabled = $false
        $ctl.BtnMapAcct.Visibility = 'Collapsed'
        $has = $script:growRows -and $script:growRows.Count -gt 0
        $ctl.EmptyMap.Visibility = if ($has) { 'Collapsed' } else { 'Visible' }
        $ctl.EmptyMapText.Text = $script:growNote
        $ctl.MapPath.Text = (T '和上次扫描相比')
        $ctl.MapInfo.Text = $script:growNote + $(if ($has) { (T ' 双击一行可以跳到这个文件夹。') } else { '' })
        $ctl.BtnMapExport.IsEnabled = [bool]$has
        Update-MapSel
    }
}
$ctl.MapViewDirs.Add_Checked({ Set-MapView 'dirs' })
$ctl.MapViewTree.Add_Checked({ Set-MapView 'tree' })
$ctl.MapViewFiles.Add_Checked({ Set-MapView 'files' })
$ctl.MapViewGrow.Add_Checked({ Set-MapView 'grow' })
$ctl.BtnMapUp.Add_Click({ if ($script:mapCur -and $script:mapCur.Parent) { Show-MapLevel $script:mapCur.Parent } })
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
$ctl.MapList.Add_MouseDoubleClick({
    $r = $ctl.MapList.SelectedItem
    if ($r -and $r.IsDir -and $r.Node) {
        if ($script:mapView -ne 'dirs') { $ctl.MapViewDirs.IsChecked = $true }
        Show-MapLevel $r.Node
    }
})
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
    if ($sel.Count -eq 0) { $ctl.MapSel.Text = (T '选中一行可以打开位置、压缩或删除；勾选前面的方框，或按住 Ctrl、Shift，可以选多项一起删；按住右键上下拖可以一次选中连着的几行。系统文件夹、软件安装文件夹、C 盘个人文件夹和搬家后的数据带小锁，不能在这里删。'); return }
    if ($sel.Count -gt 1) {
        $tot = [double]0; foreach ($x in $sel) { $tot += [double]$x.Size }
        $t = (T "已选 {0} 项，共 {1}") -f $sel.Count, (Fmt $tot)
        if ($del.Count -lt $sel.Count) { $t += ((T "（其中 {0} 项带小锁或是链接，不会删）") -f ($sel.Count - $del.Count)) }
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
function Update-MapMenu {
    $sel = @($ctl.MapList.SelectedItems)
    if ($sel.Count -eq 0 -or $script:mapView -eq 'grow') { return $false }
    $one = if ($sel.Count -eq 1) { $sel[0] } else { $null }
    $ctl.MmEnter.Visibility = if ($one -and $one.IsDir -and $one.Node) { 'Visible' } else { 'Collapsed' }
    $ctl.MmOpen.IsEnabled = $ctl.BtnMapOpen.IsEnabled
    $ctl.MmCopy.IsEnabled = (@($sel | Where-Object { $_.Path }).Count -gt 0)
    $ctl.MmCompress.IsEnabled = $ctl.BtnMapCompress.IsEnabled
    $ctl.MmDelete.IsEnabled = $ctl.BtnMapDelete.IsEnabled
    $nd = @($sel | Where-Object { -not $_.Locked -and $_.Size -gt 0 }).Count
    $ctl.MmDelete.Header = if ($nd -gt 1) { (T "删除选中的 {0} 项…") -f $nd } else { (T '删除…') }
    return $true
}
$ctl.MapList.Add_ContextMenuOpening({ param($s, $e) if (-not (Update-MapMenu)) { $e.Handled = $true } })
$ctl.MmEnter.Add_Click({ $r = $ctl.MapList.SelectedItem; if ($r -and $r.IsDir -and $r.Node) { if ($script:mapView -ne 'dirs') { $ctl.MapViewDirs.IsChecked = $true }; Show-MapLevel $r.Node } })
$ctl.MmOpen.Add_Click({ Invoke-Btn $ctl.BtnMapOpen })
$ctl.MmCompress.Add_Click({ Invoke-Btn $ctl.BtnMapCompress })
$ctl.MmDelete.Add_Click({ Invoke-Btn $ctl.BtnMapDelete })
$ctl.MmCopy.Add_Click({
    $ps = @($ctl.MapList.SelectedItems | Where-Object { $_.Path } | ForEach-Object { [string]$_.Path })
    if ($ps.Count -gt 0) { try { [System.Windows.Clipboard]::SetText(($ps -join "`r`n")); $ctl.MapSel.Text = (T "已复制 {0} 个路径") -f $ps.Count } catch {} }
})
# ---------- 按住右键上下拖：选中连着的几行（像在资源管理器里拉框）；松开后弹出右键菜单 ----------
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
function Start-RightDrag($d) {
    $lv = $d.Lv
    if (-not $script:mapScroller) { $script:mapScroller = Find-Visual $lv ([System.Windows.Controls.ScrollViewer]) }
    # 鼠标交给列表里的滚动区（不是列表本身：列表自己拿着鼠标、左键又没按着时会把鼠标放掉）
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
function Stop-RightDrag {
    $d = $script:rdrag; $script:rdrag = $null
    $script:rdragTimer.Stop()
    if ($d -and $d.Moved -and $d.Cap -and $d.Cap.IsMouseCaptured) { $d.Cap.ReleaseMouseCapture() }
}
$ctl.MapList.Add_PreviewMouseRightButtonDown({
    param($s, $e)
    Stop-RightDrag
    if (-not ($e.OriginalSource -is [System.Windows.DependencyObject])) { return }
    $c = $null; try { $c = [System.Windows.Controls.ItemsControl]::ContainerFromElement($s, $e.OriginalSource) } catch {}
    if (-not $c) { return }
    $i = $s.ItemContainerGenerator.IndexFromContainer($c)
    if ($i -lt 0) { return }
    $ctrl = ([System.Windows.Input.Keyboard]::Modifiers -band [System.Windows.Input.ModifierKeys]::Control) -ne 0
    $script:rdrag = @{ Lv = $s; Anchor = $i; Cur = $i; Moved = $false; Ctrl = $ctrl; Base = $null; Cap = $null }
})
$ctl.MapList.Add_PreviewMouseMove({
    param($s, $e)
    $d = $script:rdrag
    if (-not $d) { return }
    if ($e.RightButton -ne [System.Windows.Input.MouseButtonState]::Pressed) { Stop-RightDrag; return }
    $i = Get-RowAt $s ($e.GetPosition($s).Y)
    if (-not $d.Moved) { if ($i -lt 0 -or $i -eq $d.Anchor) { return }; Start-RightDrag $d }
    Set-DragRange $d $i
})
$ctl.MapList.Add_PreviewMouseRightButtonUp({ Stop-RightDrag })
$ctl.MapList.Add_LostMouseCapture({ $d = $script:rdrag; if ($d -and $d.Moved -and $d.Cap -and -not $d.Cap.IsMouseCaptured) { $script:rdrag = $null; $script:rdragTimer.Stop() } })
# 拖到列表上面或下面：自动滚动，边滚边选
$script:rdragTimer.Add_Tick({
    $d = $script:rdrag
    if (-not $d -or -not $d.Moved) { $script:rdragTimer.Stop(); return }
    if ([System.Windows.Input.Mouse]::RightButton -ne [System.Windows.Input.MouseButtonState]::Pressed) { Stop-RightDrag; return }
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

    # 按类型统计
    $ext = [DiskMap]::ExtTotals()
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
            $k = if ($r.IsDir) { (T '文件夹') } elseif ($r.Node -and $r.Node.IsLink) { (T '链接') } else { (T '文件') }
            $lines.Add((Csv-Line @($r.Name, $r.Path, $k, [long]$r.Size, $r.SizeText, $(if ($r.IsDir) { $r.FileCount } else { '' }), $r.When)))
        }
    }
    try { [IO.File]::WriteAllLines($dlg.FileName, $lines.ToArray(), (New-Object Text.UTF8Encoding $true)) }
    catch { Show-Sheet -Kind warn -Title (T '没能保存') -Text $_.Exception.Message | Out-Null; return }
    UI-Log ((T "空间地图：已导出 {0} 行到 {1}") -f $list.Count, $dlg.FileName)
    $ans = Show-Sheet -Kind done -Title (T '已导出') -Text ((T "{0:N0} 行，已保存到：`n{1}") -f $list.Count, $dlg.FileName) -Buttons @((T '打开所在位置'), (T '好')) -Primary (T '好') -Cancel (T '好')
    if ($ans -eq (T '打开所在位置')) { Open-Location $dlg.FileName }
})
$ctl.BtnMapOpen.Add_Click({ $r = $ctl.MapList.SelectedItem; if ($r) { if ($r.IsSummary) { if ($script:mapCur) { Open-Location $script:mapCur.FullPath() } } else { Open-Location $r.Path } } })

# 和上次比：把这次扫描的快照和上次的对比，列出变化最大的文件夹
function Update-Growth($root) {
    $script:growRows = New-Object 'System.Collections.ObjectModel.ObservableCollection[GrowRow]'
    $letter = $root.FullPath().Substring(0, 1).ToUpper()
    New-Item -ItemType Directory -Path $script:snapDir -Force | Out-Null
    $latest = Join-Path $script:snapDir "$letter-latest.txt"
    $old = @{}; $oldAt = ''; $oldHow = 'walk'
    if (Test-Path -LiteralPath $latest) {
        foreach ($l in [IO.File]::ReadAllLines($latest, [Text.Encoding]::UTF8)) {
            if ($l.StartsWith('#method=')) { $oldHow = $l.Substring(8).Trim(); continue }
            if ($l.StartsWith('#')) { $oldAt = $l.TrimStart('#').Trim(); continue }
            $a = $l.Split("`t"); if ($a.Count -eq 2) { $old[$a[0].ToLowerInvariant()] = [double]$a[1] }
        }
    }
    $snap = [DiskMap]::Snapshot($root, 4, 100MB)
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
    $out = New-Object System.Collections.Generic.List[string]
    $out.Add(('#method=' + $(if ([string]$script:mapMethod -like 'mft*') { 'mft' } else { 'walk' })))   # 放在日期前面：旧版本只认最后一个 # 行当日期
    $out.Add(("# {0:yyyy-MM-dd HH:mm}" -f (Get-Date)))
    foreach ($l in $snap) { $out.Add($l) }
    if (Test-Path -LiteralPath $latest) { Copy-Item -LiteralPath $latest -Destination (Join-Path $script:snapDir "$letter-previous.txt") -Force -ErrorAction SilentlyContinue }
    [IO.File]::WriteAllLines($latest, $out.ToArray(), (New-Object Text.UTF8Encoding $true))
}

# 删除：移到回收站或永久删除，都要先勾选确认
$ctl.BtnMapDelete.Add_Click({
    if ($script:worker) { return }
    $sel = @($ctl.MapList.SelectedItems)
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
        $rc = [FsTools]::Recycle($p, [long]$sync.Hwnd)
        $ok = -not (Test-Path -LiteralPath $p)
        if (-not $ok) { $msg = ((T "没有删掉（代码 {0}，可能文件正被占用，或者在提示里选了取消）") -f $rc) }
    } else {
        if ($x.IsDir) { & "$sys32\cmd.exe" /c rd /s /q "\\?\$p" 2>$null | Out-Null } else { Remove-Item -LiteralPath $p -Force -ErrorAction SilentlyContinue }
        $ok = -not (Test-Path -LiteralPath $p)
        if (-not $ok) { $msg = (T '没删干净，可能有文件正被占用') }
    }
    OpLog '删除' $how $p ("{0}{1}" -f (GB $x.Size), $(if ($ok) { '' } else { (T '，失败：') + $msg }))
    if ($ok) { [void]$res.Ok.Add($p) } else { [void]$res.Fail.Add(((T "{0}：{1}") -f $p, $msg)) }
}
$sync.MapDel = $res
'@ @{ Items = @($rows | ForEach-Object { @{ Path = [string]$_.Path; IsDir = [bool]$_.IsDir; Size = [double]$_.Size } }); Recycle = ($ans -eq (T '移到回收站')) }
})

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

