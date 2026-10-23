# ------------------------------------------------------------
# 第二页：重复文件
# ------------------------------------------------------------
$script:roots = New-Object 'System.Collections.ObjectModel.ObservableCollection[RootItem]'
$ctl.Roots.ItemsSource = $script:roots

function Add-Root($path, $label, $on, $detail, [bool]$removable = $false) {
    if (-not $path) { return }
    if (-not (Test-Path -LiteralPath $path)) { return }
    if (IsLink $path) { return }   # 链接（多半是搬走后留下的）：和它指向的地方是同一份东西，不单独当一个位置
    foreach ($r in $script:roots) { if ($r.Path -ieq $path) { return } }
    $ri = New-Object RootItem
    $ri.Path = $path; $ri.Label = $label; $ri.Enabled = [bool]$on
    $ri.Detail = if ($detail) { $detail } else { $path }
    $ri.Removable = $removable
    $script:roots.Add($ri)
}

$downloads = (Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders' -ErrorAction SilentlyContinue).'{374DE290-123F-4565-9164-39C4925E467B}'
if ($downloads) { $downloads = [Environment]::ExpandEnvironmentVariables($downloads) } else { $downloads = "$env:USERPROFILE\Downloads" }
foreach ($pair in @(
    @((T '桌面'), [Environment]::GetFolderPath('Desktop')),
    @((T '文档'), [Environment]::GetFolderPath('MyDocuments')),
    @((T '下载'), $downloads),
    @((T '图片'), [Environment]::GetFolderPath('MyPictures')),
    @((T '视频'), [Environment]::GetFolderPath('MyVideos')),
    @((T '音乐'), [Environment]::GetFolderPath('MyMusic')))) {
    Add-Root $pair[1] $pair[0] $true $pair[1]
}
foreach ($d in [System.IO.DriveInfo]::GetDrives()) {
    try {
        if ($d.DriveType -eq 'Fixed' -and $d.IsReady -and ($d.Name.TrimEnd('\') -ine $env:SystemDrive)) {
            Add-Root $d.RootDirectory.FullName ((T "整个 {0} 盘") -f $d.Name.Substring(0, 1)) $true ((T "{0}  已用 {1}") -f $d.Name, (Fmt ($d.TotalSize - $d.TotalFreeSpace)))
        }
    } catch {}
}

# ---------- 颜色工具 ----------
function Brush([string]$hex, [string]$role = 'f') { New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color][System.Windows.Media.ColorConverter]::ConvertFromString([Theme]::Map($hex, [char]$role))) }
function Tint([string]$hex, [double]$a) {
    # 把颜色和底色按比例混合，得到选中状态用的淡底色（深色模式和深色卡片混合）
    [Theme]::Tint($hex, $a)
}

# ---------- 文件类型：每类一个颜色，结果列表里用同一个颜色标出文件类型 ----------
$script:typeDefs = @(
    @{ L = (T 'Word 文档');  C = '#2B579A'; E = '.doc .docx .docm .dot .dotx .wps .rtf .odt' }
    @{ L = (T 'Excel 表格'); C = '#217346'; E = '.xls .xlsx .xlsm .xlsb .csv .et .ods' }
    @{ L = (T 'PPT 演示');   C = '#C43E1C'; E = '.ppt .pptx .pptm .pps .ppsx .dps .odp .key' }
    @{ L = 'PDF';        C = '#B30B00'; E = '.pdf .ofd .caj .xps' }
    @{ L = (T '文本');       C = '#5B6573'; E = '.txt .md .markdown .rst' }
    @{ L = (T '电子书');     C = '#8A5A2B'; E = '.epub .mobi .azw .azw3 .djvu' }
    @{ L = (T '照片图片');   C = '#0F8A7E'; E = '.jpg .jpeg .png .gif .bmp .heic .heif .webp .tif .tiff .svg' }
    @{ L = (T 'RAW 原片');   C = '#5C7F1A'; E = '.raw .cr2 .cr3 .nef .arw .dng .orf .rw2 .raf .srw' }
    @{ L = (T '设计稿');     C = '#7A3FC2'; E = '.psd .psb .ai .sketch .fig .xd .cdr .indd' }
    @{ L = (T 'CAD 图纸');   C = '#0B6E99'; E = '.dwg .dxf .step .stp .igs .iges .sldprt .sldasm .slddrw .prt .asm .x_t .x_b .stl .3mf .ipt .iam .catpart .catproduct' }
    @{ L = (T '视频');       C = '#B4235A'; E = '.mp4 .mov .avi .mkv .wmv .flv .m4v .ts .webm .mpg .mpeg .3gp .rmvb' }
    @{ L = (T '音频');       C = '#C27C0E'; E = '.mp3 .wav .flac .m4a .aac .ogg .wma .ape .opus' }
    @{ L = (T '压缩包');     C = '#6B4F3A'; E = '.zip .rar .7z .tar .gz .tgz .bz2 .xz .zst' }
    @{ L = (T '安装包');     C = '#3B4A63'; E = '.exe .msi .msix .appx .apk .dmg .pkg' }
    @{ L = (T '磁盘镜像');   C = '#5B4B8A'; E = '.iso .img .vhd .vhdx .vmdk .wim .esd' }
)
$script:extColor = @{}
foreach ($d in $script:typeDefs) { foreach ($e in ($d.E -split '\s+')) { $script:extColor[$e] = $d.C } }

$chipStyle  = $win.FindResource('Chip')
$radioStyle = $win.FindResource('Seg')
$script:chips = New-Object System.Collections.ArrayList
$script:typeSync = $false
$script:sizeSync = $false

function New-Chip([string]$label, [string]$color, [string]$tip) {
    $b = New-Object System.Windows.Controls.Primitives.ToggleButton
    $b.Content = $label; $b.Style = $chipStyle; $b.ToolTip = $tip
    return $b
}

function Parse-ExtraExt {
    $out = New-Object System.Collections.ArrayList
    foreach ($t in ([string]$ctl.ExtraExt.Text -split '[\s,，;；、]+')) {
        $t = $t.Trim().ToLowerInvariant()
        if (-not $t) { continue }
        if ($t.StartsWith('*')) { $t = $t.Substring(1) }
        if (-not $t.StartsWith('.')) { $t = '.' + $t }
        if ($t -match '^\.[a-z0-9_\-\+]{1,12}$') { [void]$out.Add($t) }
    }
    return ,$out
}
function Any-TypeChip { foreach ($c in $script:chips) { if ($c.Btn.IsChecked) { return $true } }; return $false }

function Reset-Types {
    foreach ($c in $script:chips) { $c.Btn.IsChecked = $false }
    $script:typeSync = $true; $ctl.ExtraExt.Text = ''; $script:typeSync = $false
    $script:typeAll.IsChecked = $true
    Update-FilterSummary
}

# 「全部类型」和具体类型互斥：选了具体类型就取消「全部」，具体类型都取消了就回到「全部」
function Sync-TypeChips($src) {
    $nothing = (-not (Any-TypeChip)) -and ((Parse-ExtraExt).Count -eq 0)
    if ([object]::ReferenceEquals($src, $script:typeAll)) {
        if ($script:typeAll.IsChecked) { Reset-Types; return }
        if ($nothing) { $script:typeAll.IsChecked = $true }
    } else {
        if ($src.IsChecked) { $script:typeAll.IsChecked = $false }
        elseif ($nothing) { $script:typeAll.IsChecked = $true }
    }
    Update-FilterSummary
}

function Get-SelectedExt {
    if ($script:typeAll.IsChecked) { return $null }
    $set = New-Object System.Collections.Generic.List[string]
    foreach ($c in $script:chips) { if ($c.Btn.IsChecked) { foreach ($e in $c.Ext) { $set.Add($e) } } }
    foreach ($e in (Parse-ExtraExt)) { $set.Add($e) }
    return ,$set.ToArray()
}

$script:typeAll = New-Chip (T '全部类型') '#1C2433' (T '不限文件类型')
$script:typeAll.IsChecked = $true
[void]$ctl.TypeChips.Children.Add($script:typeAll)
$script:typeAll.Add_Click({ Sync-TypeChips $this })
foreach ($d in $script:typeDefs) {
    $b = New-Chip $d.L $d.C ($d.E -replace ' ', '  ')
    [void]$ctl.TypeChips.Children.Add($b)
    [void]$script:chips.Add(@{ Btn = $b; Ext = [string[]]($d.E -split '\s+'); Label = $d.L })
    $b.Add_Click({ Sync-TypeChips $this })
}
$ctl.TypeReset.Add_Click({ Reset-Types })
$ctl.ExtraExt.Add_TextChanged({
    if ($script:typeSync) { return }
    if ((Parse-ExtraExt).Count -gt 0) { $script:typeAll.IsChecked = $false }
    elseif (-not (Any-TypeChip)) { $script:typeAll.IsChecked = $true }
    Update-FilterSummary
})

# ---------- 文件大小：常用区间一键选，也可以手填「从…到…」 ----------
$script:sizeDefs = @(
    @{ L = (T '不限');          Min = 0;     Max = 0 }
    @{ L = (T '1 MB 以上');     Min = 1MB;   Max = 0 }
    @{ L = '1–10 MB';       Min = 1MB;   Max = 10MB }
    @{ L = '10–100 MB';     Min = 10MB;  Max = 100MB }
    @{ L = '100 MB–1 GB';   Min = 100MB; Max = 1GB }
    @{ L = (T '1 GB 以上');     Min = 1GB;   Max = 0 }
)
$script:sizeRadios = New-Object System.Collections.ArrayList

function Set-SizeBox($box, $unit, [double]$bytes) {
    if ($bytes -le 0) { $box.Text = ''; return }
    if (($bytes % 1GB) -eq 0)     { $unit.SelectedIndex = 2; $box.Text = [string]($bytes / 1GB) }
    elseif (($bytes % 1MB) -eq 0) { $unit.SelectedIndex = 1; $box.Text = [string]($bytes / 1MB) }
    else                          { $unit.SelectedIndex = 0; $box.Text = [string][math]::Round($bytes / 1KB, 1) }
}
function Apply-SizePreset($btn) {
    foreach ($r in $script:sizeRadios) {
        if ([object]::ReferenceEquals($r.Btn, $btn)) {
            $script:sizeSync = $true
            Set-SizeBox $ctl.SizeMin $ctl.SizeMinUnit $r.Min
            Set-SizeBox $ctl.SizeMax $ctl.SizeMaxUnit $r.Max
            $script:sizeSync = $false
        }
    }
    $ctl.SizeCustomRow.Visibility = 'Collapsed'
    Update-FilterSummary
}
function Read-SizeBox($box, $unit) {
    $t = ([string]$box.Text).Trim()
    if (-not $t) { return [double]0 }
    $v = [double]0
    if (-not [double]::TryParse($t, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$v) -or $v -lt 0) { return $null }
    return $v * @(1KB, 1MB, 1GB)[[math]::Max(0, $unit.SelectedIndex)]
}
function Get-SizeRange {
    $min = Read-SizeBox $ctl.SizeMin $ctl.SizeMinUnit
    $max = Read-SizeBox $ctl.SizeMax $ctl.SizeMaxUnit
    if ($null -eq $min -or $null -eq $max) { return @{ Ok = $false; Err = (T '大小只能填数字，比如 1.5') } }
    if ($max -gt 0 -and $max -lt $min) { return @{ Ok = $false; Err = (T '「到」要比「从」大') } }
    return @{ Ok = $true; Min = $min; Max = $max }
}
function Size-Text([double]$b) {
    $inv = [Globalization.CultureInfo]::InvariantCulture
    if ($b -ge 1GB)     { ($b / 1GB).ToString('0.##', $inv) + ' GB' }
    elseif ($b -ge 1MB) { ($b / 1MB).ToString('0.##', $inv) + ' MB' }
    elseif ($b -ge 1KB) { ($b / 1KB).ToString('0.##', $inv) + ' KB' }
    else { "$([int]$b) B" }
}
function On-SizeEdited {
    if ($script:sizeSync) { return }
    $script:sizeCustom.IsChecked = $true
    Update-FilterSummary
}

foreach ($d in $script:sizeDefs) {
    $rb = New-Object System.Windows.Controls.RadioButton
    $rb.Content = $d.L; $rb.GroupName = 'dupsize'; $rb.Style = $radioStyle
    [void]$ctl.SizeChips.Children.Add($rb)
    [void]$script:sizeRadios.Add(@{ Btn = $rb; Min = [double]$d.Min; Max = [double]$d.Max })
    $rb.Add_Click({ Apply-SizePreset $this })
}
$script:sizeCustom = New-Object System.Windows.Controls.RadioButton
$script:sizeCustom.Content = (T '自定义'); $script:sizeCustom.GroupName = 'dupsize'; $script:sizeCustom.Style = $radioStyle
[void]$ctl.SizeChips.Children.Add($script:sizeCustom)
$script:sizeCustom.Add_Click({ $ctl.SizeCustomRow.Visibility = 'Visible'; [void]$ctl.SizeMin.Focus(); Update-FilterSummary })
foreach ($c in @($ctl.SizeMin, $ctl.SizeMax)) { $c.Add_TextChanged({ On-SizeEdited }) }
foreach ($c in @($ctl.SizeMinUnit, $ctl.SizeMaxUnit)) { $c.Add_SelectionChanged({ On-SizeEdited }) }

# ---------- 条件摘要：收起面板后也能看到当前条件 ----------
function Update-FilterSummary {
    if ($null -eq $script:typeAll -or $null -eq $script:sizeCustom) { return }
    if ($ctl.ModeSimilar.IsChecked) { $types = (T '相似照片') }
    elseif ($script:typeAll.IsChecked) { $types = (T '全部类型') }
    else {
        $names = @($script:chips | Where-Object { $_.Btn.IsChecked } | ForEach-Object { $_.Label })
        $extra = Parse-ExtraExt
        if ($extra.Count -gt 0) { $names += ($extra -join ' ') }
        $types = if ($names.Count -gt 3) { ($names[0..2] -join (T '、')) + ((T " 等 {0} 类") -f $($names.Count)) } else { $names -join (T '、') }
    }
    $r = Get-SizeRange
    if (-not $r.Ok) { $size = (T '大小填写有误') }
    elseif ($r.Min -le 1 -and $r.Max -le 0) { $size = (T '不限大小') }
    elseif ($r.Max -le 0) { $size = (Size-Text $r.Min) + (T ' 以上') }
    elseif ($r.Min -le 1) { $size = (Size-Text $r.Max) + (T ' 以下') }
    else { $size = (T "{0} 到 {1}") -f (Size-Text $r.Min), (Size-Text $r.Max) }
    $ctl.SizeHint.Text = if ($r.Ok) { (T '留空表示不限') } else { $r.Err }
    $ctl.SizeHint.Foreground = if ($r.Ok) { Brush '#86868B' } else { Brush '#D70015' }
    $mode = if ($ctl.ModeName.IsChecked) { (T '文件名和内容都相同') } else { (T '只要内容相同') }
    $mode += if ($ctl.SpeedExact.IsChecked) { (T '，完整比对') } else { (T '，快速比对') }
    $n = @($script:roots | Where-Object { $_.Enabled }).Count
    $ctl.FilterSummary.Text = (T "{0}，{1}，{2}，{3} 个位置") -f $types, $size, $mode, $n
}
foreach ($c in @($ctl.ModeName, $ctl.ModeContent, $ctl.SpeedFast, $ctl.SpeedExact)) { $c.Add_Click({ Update-FilterSummary }) }
# 点胶囊 = 勾选/取消；点自己加的文件夹上的小叉 = 移除
$ctl.Roots.AddHandler([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent, [System.Windows.RoutedEventHandler]{
    param($s, $e)
    $src = $e.OriginalSource
    if ($src -is [System.Windows.Controls.Button] -and $src.Tag -is [RootItem]) { [void]$script:roots.Remove($src.Tag) }
    Update-FilterSummary
})

# 默认：全部类型，1 MB 以上
$script:sizeRadios[1].Btn.IsChecked = $true
Apply-SizePreset $script:sizeRadios[1].Btn

$ctl.BtnAddRoot.Add_Click({
    $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
    $dlg.Description = (T '选择要查找重复文件的文件夹')
    if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        $sp = $dlg.SelectedPath; $nm = Split-Path $sp -Leaf; if (-not $nm) { $nm = $sp }
        Add-Root $sp $nm $true $sp $true; Update-FilterSummary
    }
})

function Build-DupRows($groups, [int]$totalGroups) {
    $protectOn = [bool]$ctl.DupProtect.IsChecked
    $col = New-Object 'System.Collections.ObjectModel.ObservableCollection[DupRow]'
    $byGroup = @{}
    $kept = New-Object System.Collections.Generic.List[DupGroup]
    $gid = 0; $waste = [double]0
    foreach ($g in $groups) {
        if ($g.Files.Count -lt 2) { continue }
        $gid++
        if ($gid -gt 3000) { break }
        $kept.Add($g)
        $meta  = (T "{0} × {1} 份，可释放 {2}") -f (Fmt $g.Size), $g.Files.Count, (Fmt $g.Waste)
        if ($g.Verified) { $badge = (T '已完整比对'); $tip = (T '每个文件都读完了全部内容，内容完全相同。'); $bbg = '#E6F4EA'; $bfg = '#1E7B34' }
        else { $badge = (T '抽样判定'); $tip = (T '文件名、大小和 16 处抽样内容都相同。删除前会逐字节完整比对，有任何不同就不删。'); $bbg = '#EFEFF4'; $bfg = '#6E6E73' }
        $list = New-Object System.Collections.ArrayList
        foreach ($f in $g.Files) {
            $r = New-Object DupRow
            $r.GroupId = $gid; $r.GroupName = $g.Name; $r.GroupMeta = $meta; $r.Verified = $g.Verified
            $r.GroupBadge = $badge; $r.GroupBadgeTip = $tip; $r.GroupBadgeBg = $bbg; $r.GroupBadgeFg = $bfg
            $r.Path = $f.Path; $r.Size = $f.Size
            $r.Dir = [IO.Path]::GetDirectoryName($f.Path).TrimEnd('\') + '\'; $r.FileName = [IO.Path]::GetFileName($f.Path)
            $r.Modified = $f.Modified.ToString('yyyy-MM-dd HH:mm'); $r.ModifiedTicks = $f.Modified.Ticks
            $r.Risk = $f.Risk; $r.HasRisk = -not [string]::IsNullOrEmpty($f.Risk)
            $r.Protected = Test-Personal $f.Path
            $r.CanDelete = -not ($protectOn -and $r.Protected)
            $fx = [IO.Path]::GetExtension($f.Path).ToLowerInvariant()
            $r.TypeBrush = if ($script:extColor.ContainsKey($fx)) { $script:extColor[$fx] } else { '#C7C7CC' }
            $col.Add($r); [void]$list.Add($r)
        }
        $byGroup[$gid] = $list
        $waste += $g.Waste
    }
    $script:dupRows = $col; $script:dupByGroup = $byGroup; $script:dupGroups = $kept; $script:dupWaste = $waste
    $ctl.DupList.ItemsSource = $col
    $ctl.EmptyDup.Visibility = if ($col.Count -gt 0) { 'Collapsed' } else { 'Visible' }
    $ctl.EmptyDupText.Text = (T '没有找到重复文件')
    $view = [System.Windows.Data.CollectionViewSource]::GetDefaultView($col)
    $view.GroupDescriptions.Clear()
    $view.GroupDescriptions.Add((New-Object System.Windows.Data.PropertyGroupDescription 'GroupId'))
    if ($totalGroups -gt 3000) { UI-Log ((T "一共找到 {0} 组，只显示可释放空间最大的前 3000 组。删完这些后再查一次即可看到剩下的。") -f $totalGroups) }
    [DupRow]::Dirty = $false
    Update-DupSummary
}

function Update-DupSummary {
    if (-not $script:dupRows) { $ctl.DupSummary.Text = ''; $ctl.BtnDupDelete.IsEnabled = $false; $ctl.BtnDupMove.IsEnabled = $false; return }
    $n = 0; $b = [double]0
    foreach ($r in $script:dupRows) { if ($r.ToDelete) { $n++; $b += $r.Size } }
    $locked = 0; foreach ($r in $script:dupRows) { if (-not $r.CanDelete) { $locked++ } }
    if ($script:dupRows.Count -eq 0) { $ctl.DupSummary.Text = (T '没有找到重复文件。') }
    else {
        $ctl.DupSummary.Text = ((T "找到 {0} 组重复文件。已勾选 {1} 个，删除后释放 {2}。") -f $script:dupByGroup.Count, $n, (Fmt $b))
        if ($locked -gt 0) { $ctl.DupSummary.Text += ((T " C 盘个人文件夹里的 {0} 个副本受保护，不会删。") -f $locked) }
    }
    $ctl.BtnDupDelete.IsEnabled = ($n -gt 0) -and (-not $script:worker); $ctl.BtnDupMove.IsEnabled = $ctl.BtnDupDelete.IsEnabled
    $ctl.BtnDupMerge.IsEnabled = ($n -gt 0) -and (-not $script:worker)
}

# 每组只留一份，其余全部勾选删除
#   new：留最新的   old：留最早的   c：优先留不在 C 盘上的那份（有多份时留其中最新的）   none：全部取消
function Pick-Dup([string]$mode) {
    foreach ($gid in @($script:dupByGroup.Keys)) {
        $rows = @($script:dupByGroup[$gid])
        if ($mode -eq 'none') { foreach ($r in $rows) { $r.ToDelete = $false }; continue }
        # 受保护的副本（C 盘个人文件夹里的）一律保留；有它在，这一组就已经留了一份
        $locked = @($rows | Where-Object { -not $_.CanDelete })
        if ($locked.Count -gt 0) {
            foreach ($r in $rows) {
                if (-not $r.CanDelete) { $r.ToDelete = $false; continue }
                # 「优先留 C 盘以外的」只删 C 盘上的；其他留法删掉所有能删的
                $onC = $r.Path.StartsWith("$env:SystemDrive\", [StringComparison]::OrdinalIgnoreCase)
                $r.ToDelete = if ($mode -eq 'c') { $onC } else { $true }
            }
            continue
        }
        $pool = $rows
        if ($mode -eq 'c') {
            $notC = @($rows | Where-Object { -not $_.Path.StartsWith("$env:SystemDrive\", [StringComparison]::OrdinalIgnoreCase) })
            if ($notC.Count -gt 0) { $pool = $notC }
        }
        elseif ($mode -eq 'in' -and $script:keepInDir) {
            $inside = @($rows | Where-Object { $_.Path.StartsWith($script:keepInDir, [StringComparison]::OrdinalIgnoreCase) })
            if ($inside.Count -gt 0) { $pool = $inside }
        }
        $keep = if ($mode -eq 'short') { @($pool | Sort-Object { $_.Path.Length }, { $_.Path })[0] } else { @($pool | Sort-Object ModifiedTicks -Descending:($mode -ne 'old'))[0] }
        foreach ($r in $rows) { $r.ToDelete = -not [object]::ReferenceEquals($r, $keep) }
    }
    [DupRow]::Dirty = $false
    Update-DupSummary
}
# 「不删 C 盘个人文件夹里的文件」：默认打开；关掉要先确认
$script:protSync = $false
function Apply-Protect {
    $on = [bool]$ctl.DupProtect.IsChecked
    if ($script:dupRows) {
        foreach ($r in $script:dupRows) {
            $r.CanDelete = -not ($on -and $r.Protected)
            if (-not $r.CanDelete) { $r.ToDelete = $false }
        }
    }
    [DupRow]::Dirty = $false
    Update-DupSummary
}
$ctl.DupProtect.Add_Checked({ if (-not $script:protSync) { Apply-Protect; UI-Log (T '已打开保护：C 盘个人文件夹里的文件不会删除') } })
$ctl.DupProtect.Add_Unchecked({
    if ($script:protSync) { return }
    $ans = Show-Sheet -Kind danger -Title (T '允许删除 C 盘个人文件夹里的文件？') `
        -Text (T '桌面、文档、下载、图片、视频、音乐等文件夹里通常是你自己的资料。关掉保护后，这些位置的重复副本也可能被勾选删除。每组仍会至少保留一份。') `
        -Confirm (T '我已确认删除这些位置的副本不会给我带来损失；因删除造成的后果由我自己承担。') -Buttons @((T '保持保护'), (T '允许删除')) -Primary (T '允许删除') -Cancel (T '保持保护')
    if ($ans -ne (T '允许删除')) { $script:protSync = $true; $ctl.DupProtect.IsChecked = $true; $script:protSync = $false; return }
    Apply-Protect
    UI-Log (T '已关闭保护：C 盘个人文件夹里的重复副本也可以勾选删除（勾选不会自动改变，需要时点「留最新的」等重新勾选）')
})

$ctl.BtnKeepNew.Add_Click({ Pick-Dup 'new' })
$ctl.BtnKeepOld.Add_Click({ Pick-Dup 'old' })
$ctl.BtnPickC.Add_Click({ Pick-Dup 'c' })
$ctl.BtnKeepShort.Add_Click({ Pick-Dup 'short' })
$script:keepInDir = ''
$ctl.BtnKeepIn.Add_Click({
    $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
    $dlg.Description = (T '每组优先保留这个文件夹（含子文件夹）里的那份')
    if ($script:keepInDir) { $dlg.SelectedPath = $script:keepInDir }
    if ($dlg.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) { return }
    $script:keepInDir = $dlg.SelectedPath.TrimEnd('\') + '\'
    Pick-Dup 'in'
    UI-Log ((T "每组优先保留 {0} 里的那份") -f $script:keepInDir)
})
$ctl.BtnPickNone.Add_Click({ Pick-Dup 'none' })

# 「打开位置」按钮：在资源管理器里选中这个文件
$ctl.DupList.AddHandler([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent, [System.Windows.RoutedEventHandler]{
    param($s, $e)
    $btn = $e.OriginalSource
    if ($btn -is [System.Windows.Controls.Button] -and $btn.Tag) {
        Start-Process -FilePath "$env:SystemRoot\explorer.exe" -ArgumentList ("/select,`"{0}`"" -f $btn.Tag)
    }
})

$ctl.ModeSimilar.Add_Checked({ $ctl.SimilarRow.Visibility = 'Visible'; Update-FilterSummary })
$ctl.ModeSimilar.Add_Unchecked({ $ctl.SimilarRow.Visibility = 'Collapsed'; Update-FilterSummary })
$script:dupSimilar = $false
function Start-SimilarScan([string[]]$paths, $range) {
    if (-not ('PhotoHash' -as [type])) { Show-Sheet -Kind warn -Title (T '这台电脑上用不了相似照片') -Text (T '图片解码组件没有加载成功（运行记录里有原因）。') | Out-Null; return }
    $dist = if ($ctl.SimStrict.IsChecked) { 4 } elseif ($ctl.SimLoose.IsChecked) { 12 } else { 8 }
    $script:dupRows = $null; $script:dupByGroup = @{}; $ctl.DupList.ItemsSource = $null
    $ctl.EmptyDup.Visibility = 'Visible'; $ctl.EmptyDupText.Text = (T '正在找照片…')
    $ctl.FilterExpander.IsExpanded = $false
    $sync.Mode = 'similar'; $sync.DupResult = $null; $sync.SimNote = ''
    Start-Op (T '查找相似照片')
    $ctl.DupProgressText.Text = (T '正在找照片…')
    UI-Busy $true
    UI-Log ((T "开始查找相似照片（相差 {0} 位以内）。位置：{1}") -f $dist, ($paths -join (T '；')))
    Start-Worker @'
[PhotoHash]::Cancel = $false
SetP @{ SubKind = 'none'; Detail = (T '列出照片') }
$list = [PhotoHash]::Scan([string[]]$arg.Roots, [long]$arg.Min, [long]$arg.Max, 200000)
$sync.SimSeen = $list.Count
if ($list.Count -ge 200000) { Log (T '照片太多，只看前 200000 张') }
SetP @{ SubKind = 'none'; Detail = ((T "算 {0:N0} 张照片的指纹") -f $list.Count); Steps = $list.Count; Step = 0 }
# 一边算一边报进度：分批
$batch = New-Object System.Collections.Generic.List[PhotoItem]
$k = 0
foreach ($p in $list) {
    $batch.Add($p); $k++
    if ($batch.Count -ge 200) { [PhotoHash]::HashAll($batch); $batch.Clear(); SetP @{ Step = $k }; if (Stopping) { break } }
}
if ($batch.Count -gt 0 -and -not (Stopping)) { [PhotoHash]::HashAll($batch) }
$stopped = [bool](Stopping)
$n = [PhotoHash]::Group($list, [int]$arg.Dist)
$by = @{}
foreach ($p in $list) { if ($p.Bad -or $p.Group -lt 0) { continue }; if (-not $by.ContainsKey($p.Group)) { $by[$p.Group] = New-Object System.Collections.Generic.List[PhotoItem] }; $by[$p.Group].Add($p) }
$groups = New-Object System.Collections.Generic.List[DupGroup]
foreach ($g in $by.Values) {
    if ($g.Count -lt 2) { continue }
    $dg = New-Object DupGroup
    $big = $g | Sort-Object { $_.Size } -Descending | Select-Object -First 1
    $dg.Name = (T "相似照片：{0}") -f [IO.Path]::GetFileName($big.Path); $dg.Size = $big.Size; $dg.Verified = $false
    foreach ($p in ($g | Sort-Object { $_.W * $_.H } -Descending)) {
        $f = New-Object DupFile
        $f.Path = $p.Path; $f.Size = $p.Size; $f.Modified = $p.Modified
        $f.Risk = (T "{0}×{1}，相差 {2} 位。相似不等于相同：先看一眼再决定") -f $p.W, $p.H, ([PhotoHash]::Dist($p.Hash, $big.Hash))
        $dg.Files.Add($f)
    }
    $groups.Add($dg)
}
$sorted = @($groups | Sort-Object { $_.Waste } -Descending)
$sync.DupResult = New-Object System.Collections.Generic.List[DupGroup]
foreach ($g in $sorted) { $sync.DupResult.Add($g) }
$sync.SimNote = (T "看了 {0:N0} 张照片，{1:N0} 张读不了，{2} 组相似{3}") -f $list.Count, [PhotoHash]::Failed, $groups.Count, $(if ($stopped) { (T '（中途停止）') } else { '' })
'@ @{ Roots = [string[]]$paths; Min = [long][math]::Max([double]1, [double]$range.Min); Max = [long]$range.Max; Dist = $dist }
}
$ctl.BtnDupScan.Add_Click({
    $paths = @($script:roots | Where-Object { $_.Enabled } | ForEach-Object { $_.Path })
    if (-not $paths) { Show-Sheet -Title (T '还没选查找位置') -Text (T '请在「查找位置」里至少勾选一个文件夹或磁盘。') | Out-Null; $ctl.FilterExpander.IsExpanded = $true; return }
    $range = Get-SizeRange
    if (-not $range.Ok) { Show-Sheet -Kind warn -Title (T '文件大小填写有误') -Text $range.Err | Out-Null; $ctl.FilterExpander.IsExpanded = $true; return }
    if ($ctl.ModeSimilar.IsChecked) { Start-SimilarScan $paths $range; return }
    $ext = Get-SelectedExt
    $script:dupRows = $null; $script:dupByGroup = @{}; $ctl.DupList.ItemsSource = $null
    $ctl.EmptyDup.Visibility = 'Visible'; $ctl.EmptyDupText.Text = (T '正在查找…')
    $arg = @{
        Roots     = [string[]]$paths
        Min       = [long][math]::Max([double]1, [double]$range.Min)
        Max       = [long]$range.Max
        MatchName = [bool]$ctl.ModeName.IsChecked
        Ext       = $ext
        Exact     = [bool]$ctl.SpeedExact.IsChecked
    }
    $sync.DriveNote = ''
    $ctl.FilterExpander.IsExpanded = $false
    $sync.Mode = 'dup'; $sync.DupResult = $null
    Start-Op (T '查找重复文件')
    $ctl.DupProgressText.Text = (T '正在查找…')
    UI-Busy $true
    UI-Log ((T "开始查找重复文件：{0}。位置：{1}") -f $ctl.FilterSummary.Text, ($paths -join (T '；')))
    Start-Worker @'
$ext = $null; if ($arg.Ext) { $ext = [string[]]$arg.Ext }
# 看每块盘是固态还是机械：固态多线程并行读，机械硬盘单线程顺序读（并行反而让磁头来回跳）
$spec = New-Object System.Collections.ArrayList; $notes = @()
$cpu = [math]::Max(2, [math]::Min(8, [Environment]::ProcessorCount))
$letters = @($arg.Roots | ForEach-Object { if ($_ -match '^([A-Za-z]):') { $matches[1].ToUpper() } } | Sort-Object -Unique)
foreach ($L in $letters) {
    $kind = ''
    try {
        $part = Get-Partition -DriveLetter $L -ErrorAction Stop
        $pd = Get-PhysicalDisk -ErrorAction Stop | Where-Object { $_.DeviceId -eq [string]$part.DiskNumber } | Select-Object -First 1
        if ($pd) { $kind = [string]$pd.MediaType }
    } catch {}
    if ($kind -eq 'SSD' -or $kind -eq 'SCM') { $n = $cpu; $desc = ((T "固态硬盘，{0} 线程并行") -f $n) }
    elseif ($kind -eq 'HDD') { $n = 1; $desc = (T '机械硬盘，单线程按顺序读') }
    else { $n = 2; $desc = (T '类型未知，2 线程') }
    [void]$spec.Add("$($L):=$n"); $notes += "$($L): $desc"
}
if ($notes) { Log ((T "磁盘：") + ($notes -join (T '；'))); $sync.DriveNote = ($notes -join (T '；')) }
$sync.DupResult = [DupFinder]::Find([string[]]$arg.Roots, [long]$arg.Min, [long]$arg.Max, [bool]$arg.MatchName, $ext, [bool]$arg.Exact, [string[]]$spec)
if (-not [DupFinder]::UsedFastEnum) { Log (T '提示：快速列举不可用，已改用普通方式列举文件（结果相同，只是慢一些）。') }
'@ $arg
})

$ctl.BtnDupStop.Add_Click({ [DupFinder]::Cancel = $true; try { [PhotoHash]::Cancel = $true } catch {}; UI-Log (T "正在停止...") })

$ctl.BtnDupDelete.Add_Click({
    $plan = New-Object System.Collections.ArrayList
    $allChecked = 0; $risky = 0; $bytes = [double]0
    foreach ($gid in @($script:dupByGroup.Keys)) {
        $rows = $script:dupByGroup[$gid]
        $del  = @($rows | Where-Object { $_.ToDelete -and $_.CanDelete })
        if ($del.Count -eq 0) { continue }
        if ($del.Count -ge $rows.Count) { $allChecked++; continue }
        $keep = @($rows | Where-Object { -not $_.ToDelete } | ForEach-Object { $_.Path })
        foreach ($r in $del) {
            [void]$plan.Add(@{ Path = $r.Path; Size = $r.Size; Keep = $keep; Verified = $r.Verified; Mtime = $r.ModifiedTicks })
            $bytes += $r.Size
            if ($r.HasRisk) { $risky++ }
        }
    }
    if ($plan.Count -eq 0) {
        if ($allChecked) { Show-Sheet -Kind warn -Title (T '每组至少要留一份') -Text ((T "有 {0} 组把所有副本都勾上了，这些组不会删除。") -f $allChecked) | Out-Null }
        return
    }
    $recycle = [bool]$ctl.DupRecycle.IsChecked
    if ($script:dupSimilar -and -not $recycle) {
        Show-Sheet -Kind warn -Title (T '相似照片只能放进回收站') -Text (T '相似照片不是同一个文件（分辨率、裁剪、压缩都可能不同），删错了没法从另一份恢复，所以只允许放进回收站。已经帮你勾上「放入回收站」。') | Out-Null
        $ctl.DupRecycle.IsChecked = $true; $recycle = $true
    }
    if ($script:dupSimilar) { foreach ($p in $plan) { $p.Similar = $true } }
    $script:lastRecycle = $recycle
    $msg = if ($script:dupSimilar) { (T "这些是相似照片，不是同一个文件：每组至少保留一份没勾选的，勾选的放进回收站。") } else { (T "每组至少保留一份没勾选的。") }
    $msg += if ($recycle) { (T "文件会放进回收站，可以恢复；清空回收站后才真正释放空间。") } else { (T "文件会被永久删除，不能恢复。") }
    if ($allChecked) { $msg += ((T "`n`n另有 {0} 组所有副本都被勾选，这些组会跳过。") -f $allChecked) }
    if ($risky)      { $msg += ((T "`n`n其中 {0} 个文件带有「注意」提示（程序目录或微信数据），请确认确实要删。") -f $risky) }
    $btnDel = if ($recycle) { (T '移到回收站') } else { (T '永久删除') }
    $ack = (T '我已确认这些文件删除后不会给我带来损失；因删除造成的后果由我自己承担。')
    if ((Show-Sheet -Kind danger -Title ((T "删除 {0} 个重复文件，释放 {1}？") -f $plan.Count, (Fmt $bytes)) -Text $msg -Buttons @((T '取消'), $btnDel) -Primary $btnDel -Cancel (T '取消') -Confirm $ack) -ne $btnDel) { return }
    $sync.Mode = 'dupdel'; $sync.DupDeleted = $null
    Start-Op ((T "删除 {0} 个重复文件") -f $plan.Count)
    UI-Busy $true
    UI-Log ((T "开始删除 {0} 个重复文件...") -f $plan.Count)
    Start-Worker @'
Add-Type -AssemblyName Microsoft.VisualBasic
$done = New-Object System.Collections.ArrayList
$i = 0; $total = $arg.Plan.Count; $freed = [double]0; $same = $false
foreach ($p in $arg.Plan) {
    if (Stopping) { break }
    $i++
    SetP @{ Steps = $total; Step = $i; StepName = [IO.Path]::GetFileName($p.Path); SubKind = 'none' }
    # 再保险：保护打开时，C 盘个人文件夹里的文件无论如何不删
    if ($arg.Protect -and (Test-Personal $p.Path)) { Log ((T "  跳过（C 盘个人文件夹，受保护）：{0}") -f $($p.Path)); continue }
    # 删之前再确认一次：要删的文件大小没变，并且至少有一份保留的副本还在、大小相同
    $fi = Get-Item -LiteralPath $p.Path -Force -ErrorAction SilentlyContinue
    if (-not $fi) { [void]$done.Add($p.Path); continue }
    if ($fi.Length -ne $p.Size -or ($p.Mtime -and $fi.LastWriteTime.Ticks -ne [long]$p.Mtime)) { Log ((T "  跳过（文件在扫描后被修改过）：{0}") -f $($p.Path)); continue }
    $kept = $false
    foreach ($k in $p.Keep) {
        $ki = Get-Item -LiteralPath $k -Force -ErrorAction SilentlyContinue
        if (-not $ki) { continue }
        # 保留的那份和要删的其实是同一个文件（硬链接的两个名字，或者经过目录链接的两条路径）：删了就一份都不剩
        if ([FsTools]::SameFile($k, $p.Path)) { Log ((T "  跳过（和保留的那份是同一个文件，只是路径不同）：{0}") -f $($p.Path)); $kept = $false; $same = $true; break }
        if ($p.Similar) { $kept = $true; break }   # 相似照片：保留的那份还在就行（大小本来就不同）
        if ($ki.Length -ne $p.Size) { continue }
        if ($p.Verified) { $kept = $true; break }
        # 抽样判定的组：和保留的那份逐字节比一遍，完全相同才删
        SetP @{ SubKind = 'verify'; Detail = $p.Path }
        if ([DupFinder]::SameContent($k, $p.Path)) { $kept = $true; break }
    }
    SetP @{ SubKind = 'none' }
    if ($same) { $same = $false; continue }
    if (-not $kept -and (Stopping)) { break }   # 核对到一半取消了：这个文件不删
    if (-not $kept) { Log ((T "  没有删除（和保留的那份内容不完全相同，或保留的那份已不在）：{0}") -f $($p.Path)); continue }
    try {
        if ($fi.Attributes -band [IO.FileAttributes]::ReadOnly) { $fi.Attributes = $fi.Attributes -bxor [IO.FileAttributes]::ReadOnly }
        if ($arg.Recycle) {
            $why = Test-RecycleOk $p.Path ([double]$p.Size)
            if ($why) { throw ((T "没有删：{0}") -f $why) }
            $rc = [FsTools]::Recycle($p.Path, [long]$sync.Hwnd)
            if (Test-Path -LiteralPath $p.Path) { throw ((T "没能放进回收站（代码 {0}）：可能回收站放不下或被禁用，这个文件没有删") -f $rc) }
        } else {
            [IO.File]::Delete($p.Path)
        }
        [void]$done.Add($p.Path); $freed += $p.Size
        if ($total -le 200 -or $i % 100 -eq 0) { Log ((T "  [{0}/{1}] 已删除  {2}") -f $i, $total, $p.Path) }
    } catch { Log ((T "  删除失败  {0}：{1}") -f $($p.Path), $($_.Exception.Message)) }
}
Log ((T "删除完成：{0} 个文件，{1}。") -f $done.Count, $(if ($freed -ge 1GB) { "{0:N2} GB" -f ($freed / 1GB) } else { "{0:N1} MB" -f ($freed / 1MB) }))
$sync.DupDeleted = $done
'@ @{ Plan = $plan; Recycle = $recycle; Protect = [bool]$ctl.DupProtect.IsChecked }
})

