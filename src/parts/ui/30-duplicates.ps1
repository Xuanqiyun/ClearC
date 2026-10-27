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
        if ($d.DriveType -eq 'Fixed' -and $d.IsReady -and ($d.Name.TrimEnd('\') -ine $env:SystemDrive) -and -not [FsTools]::IsSubst($d.Name)) {
            Add-Root $d.RootDirectory.FullName ((T "整个 {0} 盘") -f $d.Name.Substring(0, 1)) $true ((T "{0}  已用 {1}") -f $d.Name, (Fmt (Get-DriveUse $d.Name).Used))
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
    $hashSeedOn = [bool]($ctl.ModeHash.IsChecked -and $script:hashSeed)
    if ($ctl.ModeSimilar.IsChecked) { $types = (T '相似照片') }
    elseif ($hashSeedOn) { $types = (T '不限类型') }
    elseif ($script:typeAll.IsChecked) { $types = (T '全部类型') }
    else {
        $names = @($script:chips | Where-Object { $_.Btn.IsChecked } | ForEach-Object { $_.Label })
        $extra = Parse-ExtraExt
        if ($extra.Count -gt 0) { $names += ($extra -join ' ') }
        $types = if ($names.Count -gt 3) { ($names[0..2] -join (T '、')) + ((T " 等 {0} 类") -f $($names.Count)) } else { $names -join (T '、') }
    }
    $r = Get-SizeRange
    if ($hashSeedOn) { $size = (T '和所选文件一样大') }
    elseif (-not $r.Ok) { $size = (T '大小填写有误') }
    elseif ($r.Min -le 1 -and $r.Max -le 0) { $size = (T '不限大小') }
    elseif ($r.Max -le 0) { $size = (Size-Text $r.Min) + (T ' 以上') }
    elseif ($r.Min -le 1) { $size = (Size-Text $r.Max) + (T ' 以下') }
    else { $size = (T "{0} 到 {1}") -f (Size-Text $r.Min), (Size-Text $r.Max) }
    $ctl.SizeHint.Text = if ($r.Ok) { (T '留空表示不限') } else { $r.Err }
    $ctl.SizeHint.Foreground = if ($r.Ok) { Brush '#6E6E73' } else { Brush '#D70015' }
    if ($ctl.ModeHash.IsChecked) { $mode = if ($hashSeedOn) { (T '按所选文件的 SHA-256') } else { (T '按哈希值') } }
    else {
        $mode = if ($ctl.ModeName.IsChecked) { (T '文件名和内容都相同') } else { (T '只要内容相同') }
        $mode += if ($ctl.SpeedExact.IsChecked) { (T '，完整比对') } else { (T '，快速比对') }
    }
    $n = @($script:roots | Where-Object { $_.Enabled }).Count
    $ctl.FilterSummary.Text = (T "{0}，{1}，{2}，{3} 个位置") -f $types, $size, $mode, $n
    # 选项卡上直接写着现在的条件：收起来也看得到
    $ctl.DTabRootsVal.Text = (T "{0} 个") -f $n
    $ctl.DTabTypeVal.Text = $types
    $ctl.DTabSizeVal.Text = $size
    if ($ctl.ModeHash.IsChecked) { $ctl.DTabModeVal.Text = (T '按哈希查') + (T ' · ') + $(if ($hashSeedOn) { (T '选了文件') } else { $alg = ''; if ([DupFinder]::ParseHash([string]$ctl.HashText.Text, [ref]$alg)) { Get-HashAlgoName $alg } else { (T '还没填') } }); return }
    $ctl.DTabModeVal.Text = $(if ($ctl.ModeSimilar.IsChecked) { (T '相似照片') } elseif ($ctl.ModeName.IsChecked) { (T '名字和内容') } else { (T '只看内容') }) + (T ' · ') + $(if ($ctl.ModeSimilar.IsChecked) { $(if ($ctl.SimStrict.IsChecked) { (T '几乎一样') } elseif ($ctl.SimLoose.IsChecked) { (T '大致相似') } else { (T '相似') }) } elseif ($ctl.SpeedExact.IsChecked) { (T '完整比对') } else { (T '快速') })
}
# ---------- 查找条件的选项卡：点一个打开那一类；再点一下（或点「收起」）收起来；开始查找时自动收起 ----------
$script:dupPanes = [ordered]@{ roots = @('DTabRoots', 'DPaneRoots'); type = @('DTabType', 'DPaneType'); size = @('DTabSize', 'DPaneSize'); mode = @('DTabMode', 'DPaneMode') }
$script:dupPane = 'roots'; $script:dupTabQuiet = $false; $script:dupTabWas = $false
function Set-DupFilterOpen([bool]$open, [string]$pane = '') {
    if ($pane -and $script:dupPanes.Contains($pane)) { $script:dupPane = $pane }
    $ctl.DupFilterBody.Visibility = $(if ($open) { 'Visible' } else { 'Collapsed' })
    $script:dupTabQuiet = $true
    try {
        foreach ($k in $script:dupPanes.Keys) {
            $ctl[$script:dupPanes[$k][1]].Visibility = $(if ($k -eq $script:dupPane) { 'Visible' } else { 'Collapsed' })
            $ctl[$script:dupPanes[$k][0]].IsChecked = ($open -and $k -eq $script:dupPane)   # 收起时一个都不选中，看得出是收着的
        }
    } finally { $script:dupTabQuiet = $false }
    $ctl.DupFilterToggle.Content = $(if ($open) { (T '收起') } else { (T '展开条件') })
}
foreach ($k in $script:dupPanes.Keys) {
    $rb = $ctl[$script:dupPanes[$k][0]]; $rb.Tag = $k
    $rb.Add_Checked({ if ($script:dupTabQuiet) { return }; Set-DupFilterOpen $true ([string]$this.Tag) })
    # 点已经打开的那个选项卡：收起来
    $rb.Add_PreviewMouseLeftButtonDown({ $script:dupTabWas = [bool]$this.IsChecked -and $ctl.DupFilterBody.Visibility -eq 'Visible' })
    $rb.Add_Click({ if ($script:dupTabWas) { Set-DupFilterOpen $false }; $script:dupTabWas = $false })
}
$ctl.DupFilterToggle.Add_Click({ Set-DupFilterOpen ($ctl.DupFilterBody.Visibility -ne 'Visible') })
foreach ($c in @($ctl.ModeName, $ctl.ModeContent, $ctl.SpeedFast, $ctl.SpeedExact, $ctl.SimStrict, $ctl.SimNormal, $ctl.SimLoose)) { $c.Add_Click({ Update-FilterSummary }) }
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

function Build-DupRows($groups, [int]$totalGroups, [string]$HashAlgo = '', [string]$HashValue = '') {
    $protectOn = [bool]$ctl.DupProtect.IsChecked
    $script:dupHash = [bool]$HashAlgo; $script:dupHashAlgo = $HashAlgo
    $col = New-Object 'System.Collections.ObjectModel.ObservableCollection[DupRow]'
    $byGroup = @{}
    $kept = New-Object System.Collections.Generic.List[DupGroup]
    $gid = 0; $waste = [double]0
    foreach ($g in $groups) {
        if ($g.Files.Count -lt 2 -and -not ($HashAlgo -and $g.Files.Count -eq 1)) { continue }
        $gid++
        if ($gid -gt 3000) { break }
        $kept.Add($g)
        $meta  = if ($g.Files.Count -eq 1) { (T "{0}，只找到这一个") -f (Fmt $g.Size) } else { (T "{0} × {1} 份，可释放 {2}") -f (Fmt $g.Size), $g.Files.Count, (Fmt $g.Waste) }
        if ($HashAlgo) { $badge = (T "{0} 一致") -f $HashAlgo; $tip = (T "{0}：{1}`n每个文件都整个读过，哈希完全一样。") -f $HashAlgo, $HashValue; $bbg = '#E6F4EA'; $bfg = '#1E7B34' }
        elseif ($g.Verified) { $badge = (T '已完整比对'); $tip = (T '每个文件都读完了全部内容，内容完全相同。'); $bbg = '#E6F4EA'; $bfg = '#1E7B34' }
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
            $why = Get-DupBlock $f.Path $r.Protected
            if ($why) { $r.Blocked = $true; $r.Risk = $why; $r.HasRisk = $true }
            $r.CanDelete = -not $r.Blocked -and -not ($protectOn -and $r.Protected)
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
    elseif ($script:dupHash) {
        $ctl.DupSummary.Text = ((T "按 {0} 找到 {1} 个内容完全一样的文件。已勾选 {2} 个，删除后释放 {3}。") -f $script:dupHashAlgo, $script:dupRows.Count, $n, (Fmt $b))
        if ($locked -gt 0) { $ctl.DupSummary.Text += ((T " C 盘个人文件夹里的 {0} 个副本受保护，不会删。") -f $locked) }
    }
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
            $r.CanDelete = -not $r.Blocked -and -not ($on -and $r.Protected)
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

# ---------- 按哈希查：选一个文件找它的副本，或者粘贴 MD5 / SHA-1 / SHA-256 找内容对得上的文件 ----------
# 只是查找：结果放进同一个列表，删不删照旧走重复文件的删除流程（每组至少留一份、删前逐字节核对）
$script:hashSeed = ''; $script:hashSetting = $false
function Get-HashAlgoName([string]$a) { if ($a -eq 'MD5') { 'MD5' } elseif ($a -eq 'SHA1') { 'SHA-1' } else { 'SHA-256' } }
function Update-HashInfo {
    $gray = Brush '#6E6E73'
    if ($script:hashSeed) {
        $sz = [double]0; try { $sz = [double](Get-Item -LiteralPath $script:hashSeed -ErrorAction Stop).Length } catch {}
        $ctl.HashInfo.Text = (T "按这个文件找：{0}（{1}）。开始查找时先算它的 SHA-256，再在查找位置里找一样大、内容完全一样的文件，类型和大小条件不管。") -f $script:hashSeed, (Fmt $sz)
        $ctl.HashInfo.Foreground = $gray; return
    }
    $txt = [string]$ctl.HashText.Text
    if (-not $txt.Trim()) { $ctl.HashInfo.Text = (T '粘贴一个 MD5、SHA-1 或 SHA-256，或者选一个文件。粘贴哈希时不知道文件多大，查找位置里符合类型和大小条件的文件都要整个读一遍，条件越窄越快。'); $ctl.HashInfo.Foreground = $gray; return }
    $alg = ''; $h = [DupFinder]::ParseHash($txt, [ref]$alg)
    if ($h) { $ctl.HashInfo.Text = (T "认出是 {0}：{1}") -f (Get-HashAlgoName $alg), $h; $ctl.HashInfo.Foreground = $gray }
    else { $ctl.HashInfo.Text = (T '没认出哈希值：MD5 是 32 位、SHA-1 是 40 位、SHA-256 是 64 位十六进制。'); $ctl.HashInfo.Foreground = Brush '#D70015' }
}
# 自己改了框里的字：不再按选的文件找
$ctl.HashText.Add_TextChanged({ if ($script:hashSetting) { return }; $script:hashSeed = ''; Update-HashInfo; Update-FilterSummary })
$ctl.BtnHashPick.Add_Click({
    $dlg = New-Object Microsoft.Win32.OpenFileDialog
    $dlg.Title = (T '选一个文件，找它的副本'); $dlg.CheckFileExists = $true; $dlg.Multiselect = $false
    if (-not $dlg.ShowDialog($win)) { return }
    Set-HashSeed $dlg.FileName
})
function Set-HashSeed([string]$path) {
    $script:hashSetting = $true; try { $ctl.HashText.Text = '' } finally { $script:hashSetting = $false }
    $script:hashSeed = $path
    Update-HashInfo; Update-FilterSummary
}
$ctl.ModeHash.Add_Checked({
    $ctl.HashRow.Visibility = 'Visible'; $ctl.SpeedRow.Visibility = 'Collapsed'
    $ctl.DupModeNote.Text = (T '按哈希查只是查找：找到的文件放进下面的列表，删不删由你决定；删除前照样逐字节核对，每组至少留一份。')
    Update-HashInfo; Update-FilterSummary
})
$ctl.ModeHash.Add_Unchecked({
    $ctl.HashRow.Visibility = 'Collapsed'; $ctl.SpeedRow.Visibility = 'Visible'
    $ctl.DupModeNote.Text = (T '快速模式下大文件只抽样读约 1 MB；删除前都会逐字节完整核对，有任何不同就不删。')
    Update-FilterSummary
})
function Start-HashLookup([string[]]$paths, $range) {
    $seed = [string]$script:hashSeed; $txt = [string]$ctl.HashText.Text
    if ($seed -and -not (Test-Path -LiteralPath $seed -PathType Leaf)) {
        Show-Sheet -Kind warn -Title (T '选的文件找不到了') -Text $seed | Out-Null
        $script:hashSeed = ''; Update-HashInfo; Update-FilterSummary; return
    }
    $min = [long][math]::Max([double]1, [double]$range.Min)
    if ($seed) { try { $min = [long](Get-Item -LiteralPath $seed -ErrorAction Stop).Length } catch {} }
    else {
        $alg = ''
        if (-not [DupFinder]::ParseHash($txt, [ref]$alg)) { Show-Sheet -Title (T '还没有要查的哈希') -Text (T '粘贴一个 MD5、SHA-1 或 SHA-256，或者点「选一个文件…」。') | Out-Null; Set-DupFilterOpen $true 'mode'; return }
    }
    $script:dupRows = $null; $script:dupByGroup = @{}; $ctl.DupList.ItemsSource = $null
    $ctl.EmptyDup.Visibility = 'Visible'; $ctl.EmptyDupText.Text = (T '正在查找…')
    $arg = @{
        Roots = [string[]]$paths
        Text  = $txt
        Seed  = $seed
        Min   = $min
        Max   = [long]$range.Max
        Ext   = $(if ($seed) { $null } else { Get-SelectedExt })
    }
    $sync.DriveNote = ''
    Set-DupFilterOpen $false
    Use-BgJob 'duphash'; $sync.DupResult = $null
    Start-Op (T '按哈希查文件')
    $ctl.DupProgressText.Text = (T '正在查找…')
    UI-Busy $true
    UI-Log ((T "开始按哈希查文件：{0}。位置：{1}") -f $(if ($seed) { $seed } else { $txt.Trim() }), ($paths -join (T '；')))
    Start-Worker @'
$ext = $null; if ($arg.Ext) { $ext = [string[]]$arg.Ext }
$plan = Get-DupReadPlan ([string[]]$arg.Roots) ([long]$arg.Min)
$sync.DupResult = [DupFinder]::FindByHash([string[]]$arg.Roots, [string]$arg.Text, [string]$arg.Seed, [long]$arg.Min, [long]$arg.Max, $ext, $plan.Spec, $plan.Trees)
'@ $arg
}
Register-BgJob 'duphash' -Cancel look -Stop { [DupFinder]::Cancel = $true } -ReadOnly -Done {
    $script:dupSimilar = $false
    $res = $sync.DupResult
    $stopped = [DupFinder]::Cancel
    $err = [string][DupFinder]::LookupError
    $alg = Get-HashAlgoName ([string][DupFinder]::LookupAlgo); $hv = [string][DupFinder]::LookupHash
    $n = 0; if ($res -and $res.Count -gt 0) { $n = $res[0].Files.Count }
    if ($err) {
        $why = switch ($err) {
            'nohash' { (T '没认出哈希值：MD5 是 32 位、SHA-1 是 40 位、SHA-256 是 64 位十六进制。') }
            'empty'  { (T '选的是空文件：空文件内容都一样，不用查。') }
            'algo'   { (T "这台电脑的安全策略不允许用 {0}（FIPS），请换成 SHA-256 再查。") -f $alg }
            default  { (T '选的文件读不了：可能正被别的程序独占，或者没有权限。') }
        }
        End-Op (T '没有查')
        Build-DupRows @() 0
        $ctl.DupProgressText.Text = $why
        Show-Sheet -Kind warn -Title (T '没有查') -Text $why | Out-Null
        return
    }
    # 选了文件：把算出来的 SHA-256 填进框里，可以复制（仍然按这个文件找）
    if ($script:hashSeed -and $hv) { $script:hashSetting = $true; try { $ctl.HashText.Text = $hv } finally { $script:hashSetting = $false } }
    $ctl.DupProgressText.Text = ((T "{0}看过 {1:N0} 个文件夹、{2:N0} 个文件，{3} 一样的有 {4} 个。") -f $(if ($stopped) { (T '已停止。') } else { (T '查找完成。') }), [DupFinder]::DirsSeen, [DupFinder]::FilesSeen, $alg, $n)
    End-Op $(if ($stopped) { ((T "已停止，找到 {0} 个") -f $n) } else { ((T "完成，找到 {0} 个") -f $n) })
    if ($res) { Build-DupRows $res $res.Count $alg $hv } else { Build-DupRows @() 0 $alg $hv }
    if ($n -eq 0) { $ctl.EmptyDupText.Text = (T '查找位置里没有内容对得上的文件') }
    elseif ($n -ge 2) { UI-Log (T '没有自动勾选：要删多余的，用上面「每组只留一份」的按钮勾选，或者自己勾。') }
}
$script:dupSimilar = $false
Register-BgJob 'similar' -Cancel look -ReadOnly -Done {
    $res = $sync.DupResult
    $cnt = if ($res) { $res.Count } else { 0 }
    $script:dupSimilar = $true
    $ctl.DupProgressText.Text = [string]$sync.SimNote
    End-Op ((T "完成，{0} 组相似照片") -f $cnt)
    if ($res) { Build-DupRows $res $cnt } else { Build-DupRows @() 0 }
    if ($script:dupRows -and $script:dupRows.Count -gt 0) {
        Pick-Dup 'none'
        UI-Log (T '相似照片不是同一个文件：没有自动勾选。每组第一张是分辨率最高的，看过以后自己勾要处理的；只能放进回收站或归档，不能永久删除，也不能合并。')
    } elseif (-not $sync.WasCancelled) { $ctl.EmptyDupText.Text = (T '没有找到相似的照片') }
}
function Start-SimilarScan([string[]]$paths, $range) {
    if (-not (Initialize-PhotoHash)) { Show-Sheet -Kind warn -Title (T '这台电脑上用不了相似照片') -Text (T '图片解码组件没有加载成功（运行记录里有原因）。') | Out-Null; return }
    $dist = if ($ctl.SimStrict.IsChecked) { 4 } elseif ($ctl.SimLoose.IsChecked) { 12 } else { 8 }
    $script:dupRows = $null; $script:dupByGroup = @{}; $ctl.DupList.ItemsSource = $null
    $ctl.EmptyDup.Visibility = 'Visible'; $ctl.EmptyDupText.Text = (T '正在找照片…')
    Set-DupFilterOpen $false
    Use-BgJob 'similar'; $sync.DupResult = $null; $sync.SimNote = ''
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
Register-BgJob 'dup' -Cancel look -Stop { [DupFinder]::Cancel = $true } -ReadOnly -Done {
    $script:dupSimilar = $false
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
$ctl.BtnDupScan.Add_Click({
    $paths = @($script:roots | Where-Object { $_.Enabled } | ForEach-Object { $_.Path })
    if (-not $paths) { Show-Sheet -Title (T '还没选查找位置') -Text (T '请在「查找位置」里至少勾选一个文件夹或磁盘。') | Out-Null; Set-DupFilterOpen $true 'roots'; return }
    $range = Get-SizeRange
    if (-not $range.Ok) { Show-Sheet -Kind warn -Title (T '文件大小填写有误') -Text $range.Err | Out-Null; Set-DupFilterOpen $true 'size'; return }
    if ($ctl.ModeSimilar.IsChecked) { Start-SimilarScan $paths $range; return }
    if ($ctl.ModeHash.IsChecked) { Start-HashLookup $paths $range; return }
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
    Set-DupFilterOpen $false
    Use-BgJob 'dup'; $sync.DupResult = $null
    Start-Op (T '查找重复文件')
    $ctl.DupProgressText.Text = (T '正在查找…')
    UI-Busy $true
    UI-Log ((T "开始查找重复文件：{0}。位置：{1}") -f $ctl.FilterSummary.Text, ($paths -join (T '；')))
    Start-Worker @'
$ext = $null; if ($arg.Ext) { $ext = [string[]]$arg.Ext }
# 每块盘几个线程读、能直接用的文件表（见引擎里的 Get-DupReadPlan，按哈希查也用它）
$plan = Get-DupReadPlan ([string[]]$arg.Roots) ([long]$arg.Min)
$sync.DupResult = [DupFinder]::Find([string[]]$arg.Roots, [long]$arg.Min, [long]$arg.Max, [bool]$arg.MatchName, $ext, [bool]$arg.Exact, $plan.Spec, $plan.Trees)
if ([DupFinder]::FromTreeRoots -gt 0) { Log ((T "{0} 个查找位置从文件表里列出文件（不用逐个文件夹去看）") -f [DupFinder]::FromTreeRoots) }
if (-not [DupFinder]::UsedFastEnum) { Log (T '提示：快速列举不可用，已改用普通方式列举文件（结果相同，只是慢一些）。') }
'@ $arg
})

$ctl.BtnDupStop.Add_Click({ [DupFinder]::Cancel = $true; try { [PhotoHash]::Cancel = $true } catch {}; UI-Log (T "正在停止...") })

Register-BgJob 'dupdel' -Cancel dupdel -Stop { [DupFinder]::Cancel = $true } -Done {
    $moveMode = ($sync.Mode -eq 'dupmove')
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
    if ($moveMode) {
        $cx = [bool]$sync.WasCancelled
        End-Op ($(if ($cx) { (T "已中途取消，归档了 {0} 个文件") } else { (T "完成，归档了 {0} 个文件") }) -f $nDel)
        UI-Log ((T "归档完成：{0} 个文件已搬到 {1}") -f $nDel, $sync.DupMoveDest)
    } else {
        $bin = if ($script:lastRecycle) { (T "`n`n文件在回收站里，清空回收站后才真正释放磁盘空间。") } else { '' }
        $binShort = if ($script:lastRecycle) { (T '文件在回收站里，清空回收站后才真正释放空间。') } else { '' }
        $cx = [bool]$sync.WasCancelled
        End-Op ($(if ($cx) { (T "已中途取消，删除了 {0} 个文件") } else { (T "完成，删除了 {0} 个文件") }) -f $nDel) -KeepCard -headline ($(if ($cx) { (T "已中途取消：删除了 {0} 个重复文件，剩下的没删。{1}") } else { (T "删除了 {0} 个重复文件。{1}") }) -f $nDel, $binShort) -reportLines @(,@((T '没删的（内容和保留的那份不完全相同，或文件被占用）记在左下角的「运行记录」里。'), '#6E6E73', $false))
        try { [System.Media.SystemSounds]::Asterisk.Play() } catch {}
        if (-not $cardWasOpen) { $script:pendingDialog = @{ Title = $(if ($cx) { (T '已中途取消') } else { (T '删除完成') }); Kind = 'done'; Text = ((T "删除了 {0} 个重复文件，共用时 {1}。{2}`n`n没删的（内容和保留的那份不完全相同，或文件被占用）记在「运行记录」里。") -f $nDel, (FmtSpan $script:lastElapsed), $bin) } }
    }
}
$ctl.BtnDupDelete.Add_Click({
    $plan = New-Object System.Collections.ArrayList
    $allChecked = 0; $risky = 0; $bytes = [double]0
    foreach ($gid in @($script:dupByGroup.Keys)) {
        $rows = $script:dupByGroup[$gid]
        $del  = @($rows | Where-Object { $_.ToDelete -and $_.CanDelete })
        if ($del.Count -eq 0) { continue }
        if ($del.Count -ge $rows.Count) { $allChecked++; continue }
        $keep = @($rows | Where-Object { -not $_.ToDelete } | ForEach-Object { $_.Path })
        $keepTicks = @{}; foreach ($kr in @($rows | Where-Object { -not $_.ToDelete })) { $keepTicks[[string]$kr.Path] = [long]$kr.ModifiedTicks }
        foreach ($r in $del) {
            [void]$plan.Add(@{ Path = $r.Path; Size = $r.Size; Keep = $keep; KeepTicks = $keepTicks; Verified = $r.Verified; Mtime = $r.ModifiedTicks })
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
    if ((Show-Sheet -Kind danger -Title ((T "删除 {0} 个重复文件，释放 {1}？") -f $plan.Count, (Fmt $bytes)) -Text $msg -Buttons @((T '取消'), $btnDel) -Primary $btnDel -Destructive $(if ($recycle) { '' } else { $btnDel }) -Cancel (T '取消') -Confirm $ack) -ne $btnDel) { return }
    Use-BgJob 'dupdel'; $sync.DupDeleted = $null
    Start-Op ((T "删除 {0} 个重复文件") -f $plan.Count)
    UI-Busy $true
    UI-Log ((T "开始删除 {0} 个重复文件...") -f $plan.Count)
    Start-Worker @'
Add-Type -AssemblyName Microsoft.VisualBasic
$done = New-Object System.Collections.ArrayList
$i = 0; $total = $arg.Plan.Count; $freed = [double]0; $same = $false
$how = if ($arg.Recycle) { (T '重复文件：移到回收站') } else { (T '重复文件：永久删除') }
foreach ($p in $arg.Plan) {
    if (Stopping) { break }
    $i++
    SetP @{ Steps = $total; Step = $i; StepName = [IO.Path]::GetFileName($p.Path); SubKind = 'none' }
    # 再保险：保护打开时，C 盘个人文件夹里的文件无论如何不删
    if ($arg.Protect -and (Test-Personal $p.Path)) { Log ((T "  跳过（C 盘个人文件夹，受保护）：{0}") -f $($p.Path)); continue }
    $why = Get-DupBlock $p.Path (Test-Personal $p.Path)
    if ($why) { Log ((T "  跳过（{0}）：{1}") -f $why, $p.Path); continue }
    # 删之前再确认一次：要删的文件大小没变，并且至少有一份保留的副本还在、大小相同
    $fi = Get-Item -LiteralPath $p.Path -Force -ErrorAction SilentlyContinue
    if (-not $fi) { [void]$done.Add($p.Path); continue }
    if ($fi.Length -ne $p.Size -or ($p.Mtime -and $fi.LastWriteTime.Ticks -ne [long]$p.Mtime)) { Log ((T "  跳过（文件在扫描后被修改过）：{0}") -f $($p.Path)); continue }
    $kept = $false; $keepAt = ''
    foreach ($k in $p.Keep) {
        $ki = Get-Item -LiteralPath $k -Force -ErrorAction SilentlyContinue
        if (-not $ki) { continue }
        # 保留的那份和要删的其实是同一个文件（硬链接的两个名字，或者经过目录链接的两条路径）：删了就一份都不剩
        if ([FsTools]::SameFile($k, $p.Path)) { Log ((T "  跳过（和保留的那份是同一个文件，只是路径不同）：{0}") -f $($p.Path)); $kept = $false; $same = $true; break }
        if ($p.Similar) { $kept = $true; $keepAt = $k; break }   # 相似照片：保留的那份还在就行（大小本来就不同）
        if ($ki.Length -ne $p.Size) { continue }
        # 保留的那份在扫描后被改过（大小没变也算）：它已经不是那份内容了，不能拿它当保留
        if ($p.KeepTicks -and $p.KeepTicks.ContainsKey([string]$k) -and $ki.LastWriteTime.Ticks -ne [long]$p.KeepTicks[[string]$k]) { continue }
        if ($p.Verified) { $kept = $true; $keepAt = $k; break }
        # 抽样判定的组：和保留的那份逐字节比一遍，完全相同才删
        SetP @{ SubKind = 'verify'; Detail = $p.Path }
        if ([DupFinder]::SameContent($k, $p.Path)) { $kept = $true; $keepAt = $k; break }
    }
    SetP @{ SubKind = 'none' }
    if ($same) { $same = $false; continue }
    if (-not $kept -and (Stopping)) { break }   # 核对到一半取消了：这个文件不删
    if (-not $kept) { Log ((T "  没有删除（和保留的那份内容不完全相同，或保留的那份已不在）：{0}") -f $($p.Path)); continue }
    # 删除本身（再查一遍删不删得、放不放得进回收站、删完核对、写操作日志）都在 Invoke-SafeRemove 里
    $r = Invoke-SafeRemove -Item $fi -Scope dup -How $(if ($arg.Recycle) { 'recycle' } else { 'delete' }) -Bytes ([double]$p.Size) -AllowPersonal:(-not $arg.Protect) `
        -What $how -Detail ((T "{0}，保留的那份：{1}") -f (GB $p.Size), $keepAt)
    if ($r.Ok) {
        [void]$done.Add($p.Path); $freed += $p.Size
        if ($total -le 200 -or $i % 100 -eq 0) { Log ((T "  [{0}/{1}] 已删除  {2}") -f $i, $total, $p.Path) }
    } else { Log ((T "  删除失败  {0}：{1}") -f $($p.Path), $r.Why) }
}
Log ((T "删除完成：{0} 个文件，{1}。") -f $done.Count, $(if ($freed -ge 1GB) { "{0:N2} GB" -f ($freed / 1GB) } else { "{0:N1} MB" -f ($freed / 1MB) }))
$sync.DupDeleted = $done
'@ @{ Plan = $plan; Recycle = $recycle; Protect = [bool]$ctl.DupProtect.IsChecked }
})

