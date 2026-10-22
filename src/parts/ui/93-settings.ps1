# ------------------------------------------------------------
# 设置：外观、语言、显示哪些内容
# ------------------------------------------------------------
# 可以关掉的页面、左下角的按钮：设置里存关掉了的，逗号隔开
$script:optPages = [ordered]@{ dup = 'SetPageDup'; save = 'SetPageSave'; apps = 'SetPageApps'; health = 'SetPageHealth'; moves = 'SetPageMoves'; auto = 'SetPageAuto'; log = 'SetPageLog' }
$script:optLinks = [ordered]@{ theme = @('SetLinkTheme', 'BtnTheme'); lang = @('SetLinkLang', 'BtnLang'); feedback = @('SetLinkFeedback', 'BtnFeedback'); log = @('SetLinkLog', 'BtnLog') }
# 开关：设置里的名字 → 设置页上的开关（默认都开）
$script:optSwitches = [ordered]@{ PageSub = 'SetPageSub'; MapCheck = 'SetMapCheck'; MapBar = 'SetMapBar'; MapPct = 'SetMapPct'; MapMeta = 'SetMapMeta'; MapDisk = 'SetMapDisk'; MapFastBtn = 'SetMapFastBtn'; MapHealth = 'SetMapHealth' }
function Get-Flag([string]$k) { (Get-Setting $k '1') -ne '0' }
function Get-HiddenSet([string]$k) { $h = @{}; foreach ($x in ((Get-Setting $k '') -split ',')) { $x = $x.Trim(); if ($x) { $h[$x] = $true } }; return $h }
# 三种模式各显示什么：页面、左下角按钮、各页里的高级功能。换模式只改显示，不丢设置
$script:pageLvl = @{ dup = 1; moves = 1; auto = 1; log = 1 }
$script:linkLvl = @{ log = 2 }
$script:appsUpdatesAllowed = $true
function Get-ModeName([int]$m = (Get-Mode)) { switch ($m) { 0 { (T '普通用户') } 1 { (T '工程师') } default { (T '开发者和 IT') } } }
function Apply-Mode {
    $m = Get-Mode
    $v = { param([int]$need) if ($m -ge $need) { [System.Windows.Visibility]::Visible } else { [System.Windows.Visibility]::Collapsed } }
    # 空间地图：找文件、和上次比、导出、压缩是工程师的；快速扫描开关、空间明细是开发者的
    foreach ($n in 'MapViewFiles', 'MapViewGrow', 'MapViewRecent', 'BtnMapExport', 'BtnMapReport', 'BtnMapCompress') { $ctl[$n].Visibility = & $v 1 }
    if ($m -lt 1 -and -not $ctl.MapViewDirs.IsChecked -and -not $ctl.MapViewTree.IsChecked -and -not $ctl.MapViewTypes.IsChecked) { $ctl.MapViewDirs.IsChecked = $true }
    # 省空间
    foreach ($n in 'SaveCardPf', 'SaveCardRp', 'SaveCardFc', 'SaveCardVd', 'SaveCardMerge') { $ctl[$n].Visibility = & $v 1 }
    foreach ($n in 'SaveCardRs', 'SaveCardCs', 'SaveCardDump', 'SaveCardTmp') { $ctl[$n].Visibility = & $v 2 }
    # 软件管理
    $ctl.AppsViewBox.Visibility = & $v 1
    foreach ($n in 'AppsViewStartup', 'AppsViewLeft') { $ctl[$n].Visibility = & $v 1 }
    foreach ($n in 'AppsViewTasks', 'AppsViewMenu') { $ctl[$n].Visibility = & $v 2 }
    if (($m -lt 1 -and -not $ctl.AppsViewApps.IsChecked) -or ($m -lt 2 -and ($ctl.AppsViewTasks.IsChecked -or $ctl.AppsViewMenu.IsChecked))) { $ctl.AppsViewApps.IsChecked = $true }
    $win.Resources['AppMoveVis'] = & $v 1
    $script:appsUpdatesAllowed = ($m -ge 1)
    if ($ctl.BtnAppsUpdates.Visibility -eq 'Visible' -and $m -lt 1) { $ctl.BtnAppsUpdates.Visibility = 'Collapsed' }
    # 清理页、自动提醒、帮助、设置
    $ctl.BtnCleanCustom.Visibility = & $v 2
    $ctl.AutoJunkRow.Visibility = & $v 1
    foreach ($n in 'HealthCardBoot', 'HealthCardCrash', 'HealthCardMon') { $ctl[$n].Visibility = & $v 1 }
    $ctl.BtnSfcRepair.Visibility = & $v 2; $ctl.HealthCardEvents.Visibility = & $v 2
    $ctl.FbCopyDiag.Visibility = & $v 1; $ctl.FbSelfTest.Visibility = & $v 2
    $ctl.SetCardDisplay.Visibility = & $v 1; $ctl.SetCardScan.Visibility = & $v 2
    foreach ($n in 'SetCustomList', 'SetCustomEmpty', 'BtnSetCustomAdd', 'SetExcludeList', 'SetExcludeEmpty', 'BtnSetExcludeAdd', 'SetCustomHead', 'SetCustomNote', 'SetExcludeHead', 'SetExcludeNote') { $ctl[$n].Visibility = & $v 2 }
    $ctl.ModeTag.Text = (Get-ModeName $m) + (T '模式')
    $ctl.SetModeNote.Text = switch ($m) {
        0 { (T '普通用户：清理 C 盘、省空间、空间地图、软件管理、帮助。清理列表里只有常见的缓存和临时文件，删了都会自动重建；有代价的项目仍然默认跳过。') }
        1 { (T '工程师：再加上重复文件、搬家管理、自动提醒、操作日志；空间地图的找文件、和上次比、最近改动、导出；省空间的页面文件、还原点、压缩文件夹、虚拟磁盘；软件管理的开机启动、残留文件夹、检查新版本和搬到其他盘；系统健康的开机用时、蓝屏诊断、活动监控；清理列表里多出开发工具的缓存。') }
        default { (T '开发者和 IT：全部功能。再加上计划任务、右键菜单、保留的存储、组件存储分析、蓝屏转储、临时文件夹位置、自定义清理列表和排除、快速扫描开关、空间明细、检查扫描功能、运行记录、修复系统文件、Windows 事件汇总，以及 Installer 孤儿安装包、事件日志、旧版驱动包、NuGet / Gradle / Maven / JetBrains 缓存这类项目。') }
    }
    $script:setLoading = $true
    try { $ctl.SetModeBasic.IsChecked = ($m -eq 0); $ctl.SetModePro.IsChecked = ($m -eq 1); $ctl.SetModeExpert.IsChecked = ($m -eq 2) } finally { $script:setLoading = $false }
    Apply-Display
    # 正在看的页面在这个模式下没有了：回到清理页
    if ($script:curPage -and $script:pageLvl.ContainsKey($script:curPage) -and $script:pageLvl[$script:curPage] -gt $m) { Show-Page 'clean' }
    if ($script:mapRoot) { try { $ctl.BtnMapAcct.Visibility = if ($script:mapRoot.HasDisk -and $m -ge 2) { 'Visible' } else { 'Collapsed' } } catch {} }
}
function Set-Mode([string]$mode) {
    Set-Setting 'Mode' $mode
    Apply-Mode
    OpLog '系统设置' (T '使用模式') (Get-ModeName) ''
    UI-Log ((T "使用模式：{0}") -f (Get-ModeName))
}
foreach ($rb in @($ctl.SetModeBasic, $ctl.SetModePro, $ctl.SetModeExpert)) {
    $rb.Add_Checked({
        if ($script:setLoading) { return }
        Set-Mode $(if ([object]::ReferenceEquals($this, $ctl.SetModeBasic)) { 'basic' } elseif ([object]::ReferenceEquals($this, $ctl.SetModePro)) { 'pro' } else { 'expert' })
    })
}
$ctl.ModeTag.Add_MouseLeftButtonUp({ Show-Page 'settings'; $ctl.SetScroll.ScrollToTop() })
function Apply-Display {
    $m = Get-Mode
    $vis = { param([bool]$on) if ($on) { [System.Windows.Visibility]::Visible } else { [System.Windows.Visibility]::Collapsed } }
    $win.Resources['SubVis'] = & $vis (Get-Flag 'PageSub')
    $win.Resources['MapCkVis'] = & $vis (Get-Flag 'MapCheck')
    $win.Resources['MapBarVis'] = & $vis (Get-Flag 'MapBar')
    $win.Resources['MapPctVis'] = & $vis (Get-Flag 'MapPct')
    $win.Resources['MapMetaVis'] = & $vis (Get-Flag 'MapMeta')
    $win.Resources['MapHealthVis'] = & $vis (Get-Flag 'MapHealth')
    $ctl.MapFast.Visibility = & $vis ((Get-Flag 'MapFastBtn') -and $m -ge 2)
    $hp = Get-HiddenSet 'HidePages'
    $show = @{}
    foreach ($k in $script:optPages.Keys) { $show[$k] = (-not $hp.ContainsKey($k)) -and (-not $script:pageLvl.ContainsKey($k) -or $script:pageLvl[$k] -le $m); $ctl[$script:pageList[$k][1]].Visibility = & $vis $show[$k] }
    $ctl.NavHeadManage.Visibility = & $vis ($show['moves'] -or $show['auto'] -or $show['log'])
    $hl = Get-HiddenSet 'HideLinks'
    foreach ($k in $script:optLinks.Keys) { $ctl[$script:optLinks[$k][1]].Visibility = & $vis ((-not $hl.ContainsKey($k)) -and (-not $script:linkLvl.ContainsKey($k) -or $script:linkLvl[$k] -le $m)) }
}
# 换了「实际占用和硬链接」这类要重新生成行的设置：当前这一层重新列一遍
function Refresh-MapRows {
    if (-not $script:mapRoot) { return }
    if ($script:mapView -eq 'files') { Show-MapFiles } elseif ($script:mapView -ne 'grow') { Show-MapLevel $(if ($script:mapCur) { $script:mapCur } else { $script:mapRoot }) }
}
$script:setLoading = $false
function Load-Settings {
    $script:setLoading = $true
    try {
        $ctl.SetThemeLight.IsChecked = ($script:themePref -eq 'light'); $ctl.SetThemeDark.IsChecked = ($script:themePref -eq 'dark'); $ctl.SetThemeSystem.IsChecked = ($script:themePref -eq 'system')
        $ctl.SetLangZh.IsChecked = ($script:Lang -ne 'en'); $ctl.SetLangEn.IsChecked = ($script:Lang -eq 'en')
        $hp = Get-HiddenSet 'HidePages'; foreach ($k in $script:optPages.Keys) { $ctl[$script:optPages[$k]].IsChecked = -not $hp.ContainsKey($k) }
        $hl = Get-HiddenSet 'HideLinks'; foreach ($k in $script:optLinks.Keys) { $ctl[$script:optLinks[$k][0]].IsChecked = -not $hl.ContainsKey($k) }
        foreach ($k in $script:optSwitches.Keys) { $ctl[$script:optSwitches[$k]].IsChecked = Get-Flag $k }
        $ctl.SetFast.IsChecked = [bool]$ctl.MapFast.IsChecked
        $ctl.SetLowIo.IsChecked = ((Get-Setting 'LowIo' '0') -eq '1')
        $ctl.SetRecycle.IsChecked = ((Get-Setting 'Recycle' '0') -eq '1')
    } finally { $script:setLoading = $false }
}
function Save-Display {
    Set-Setting 'HidePages' ((@($script:optPages.Keys | Where-Object { -not $ctl[$script:optPages[$_]].IsChecked })) -join ',')
    Set-Setting 'HideLinks' ((@($script:optLinks.Keys | Where-Object { -not $ctl[$script:optLinks[$_][0]].IsChecked })) -join ',')
    foreach ($k in $script:optSwitches.Keys) { Set-Setting $k $(if ($ctl[$script:optSwitches[$k]].IsChecked) { '1' } else { '0' }) }
    Apply-Display
}
foreach ($k in $script:optPages.Keys) { $ctl[$script:optPages[$k]].Add_Click({ if (-not $script:setLoading) { Save-Display } }) }
foreach ($k in $script:optLinks.Keys) { $ctl[$script:optLinks[$k][0]].Add_Click({ if (-not $script:setLoading) { Save-Display } }) }
foreach ($k in $script:optSwitches.Keys) { $ctl[$script:optSwitches[$k]].Add_Click({ if (-not $script:setLoading) { Save-Display; if ([object]::ReferenceEquals($this, $ctl.SetMapDisk)) { Refresh-MapRows } } }) }
$ctl.SetFast.Add_Click({ if (-not $script:setLoading) { Set-FastScan ([bool]$ctl.SetFast.IsChecked) } })
[DupFinder]::LowPriority = ((Get-Setting 'LowIo' '0') -eq '1')
$ctl.SetRecycle.Add_Click({
    if ($script:setLoading) { return }
    $on = [bool]$ctl.SetRecycle.IsChecked
    Set-Setting 'Recycle' $(if ($on) { '1' } else { '0' })
    UI-Log $(if ($on) { (T '删除时先放进回收站：已打开') } else { (T '删除时先放进回收站：已关闭') })
})
$ctl.SetLowIo.Add_Click({
    if ($script:setLoading) { return }
    $on = [bool]$ctl.SetLowIo.IsChecked
    Set-Setting 'LowIo' $(if ($on) { '1' } else { '0' }); [DupFinder]::LowPriority = $on
    UI-Log $(if ($on) { (T '查重复文件时让着其他程序：已打开') } else { (T '查重复文件时让着其他程序：已关闭') })
})
$ctl.BtnSetReset.Add_Click({
    Set-Setting 'HidePages' ''; Set-Setting 'HideLinks' ''
    foreach ($k in $script:optSwitches.Keys) { Set-Setting $k '1' }
    Load-Settings; Apply-Display; Refresh-MapRows
    UI-Log (T '设置：显示内容已恢复默认')
})
$ctl.NavSettings.Add_Click({ $ctl.SetScroll.ScrollToTop() })
# ---------- 清理列表：自己加的文件夹、排除的文件夹 ----------
function Load-CleanLists {
    $c = @(Get-CustomClean); $x = @(Get-ExcludeList)
    $ctl.SetCustomList.ItemsSource = $c; $ctl.SetCustomEmpty.Visibility = if ($c.Count) { 'Collapsed' } else { 'Visible' }
    $ctl.SetExcludeList.ItemsSource = $x; $ctl.SetExcludeEmpty.Visibility = if ($x.Count) { 'Collapsed' } else { 'Visible' }
}
function Save-CleanList([string]$key, [string[]]$items) {
    Set-Setting $key (($items | Where-Object { $_ }) -join '|')
    Load-CleanLists
    # 清理列表变了：扫描结果作废，下次扫描按新的来
    $script:catalog = Get-Catalog
    if ($script:rows -and -not $script:worker) { $ctl.Summary.Text = (T '清理列表改了，请重新扫描。') }
}
function Add-CleanListFolder([bool]$exclude) {
    $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
    $dlg.Description = if ($exclude) { (T '选一个清理时不要碰的文件夹') } else { (T '选一个要清理的文件夹（删里面的东西，文件夹本身保留）') }
    if ($dlg.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) { return }
    $p = $dlg.SelectedPath.TrimEnd('\')
    if ($p -match '\|') { Show-Sheet -Kind warn -Title (T '这个路径用不了') -Text (T '路径里不能有竖线。') | Out-Null; return }
    if (-not $exclude) {
        $why = Get-DeleteBlock $p
        if ($why) { Show-Sheet -Kind warn -Title (T '这个文件夹不能加进清理列表') -Text $why | Out-Null; return }
        foreach ($x in (Get-ExcludeList)) { if ($p -ieq $x -or $p.StartsWith("$x\", [StringComparison]::OrdinalIgnoreCase)) { Show-Sheet -Kind warn -Title (T '这个文件夹在排除列表里') -Text ((T "它在排除的 {0} 里面，先把排除去掉。") -f $x) | Out-Null; return } }
    }
    $key = if ($exclude) { 'Exclude' } else { 'CustomClean' }
    $cur = @(if ($exclude) { Get-ExcludeList } else { Get-CustomClean })
    if ($cur -contains $p) { return }
    Save-CleanList $key ($cur + $p)
    OpLog '系统设置' $(if ($exclude) { (T '排除文件夹') } else { (T '加入清理列表') }) $p ''
    UI-Log ((T "{0}：{1}") -f $(if ($exclude) { (T '排除文件夹') } else { (T '加入清理列表') }), $p)
}
$ctl.BtnSetCustomAdd.Add_Click({ Add-CleanListFolder $false })
$ctl.BtnSetExcludeAdd.Add_Click({ Add-CleanListFolder $true })
$removeHandler = [System.Windows.RoutedEventHandler]{
    param($s, $e)
    $b = $e.OriginalSource
    if (-not ($b -is [System.Windows.Controls.Button]) -or $b.Name -ne 'SetListRemove') { return }
    $p = [string]$b.Tag
    $exclude = [object]::ReferenceEquals($s, $ctl.SetExcludeList)
    $key = if ($exclude) { 'Exclude' } else { 'CustomClean' }
    $cur = @(if ($exclude) { Get-ExcludeList } else { Get-CustomClean })
    Save-CleanList $key @($cur | Where-Object { $_ -ne $p })
    OpLog '系统设置' $(if ($exclude) { (T '取消排除') } else { (T '移出清理列表') }) $p ''
}
$ctl.SetCustomList.AddHandler([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent, $removeHandler)
$ctl.SetExcludeList.AddHandler([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent, $removeHandler)
Load-CleanLists
# 外观、语言：和左下角的按钮共用，换了要重新打开本工具
foreach ($rb in @($ctl.SetThemeLight, $ctl.SetThemeDark, $ctl.SetThemeSystem)) {
    $rb.Add_Checked({
        if ($script:setLoading) { return }
        $to = if ([object]::ReferenceEquals($this, $ctl.SetThemeDark)) { 'dark' } elseif ([object]::ReferenceEquals($this, $ctl.SetThemeSystem)) { 'system' } else { 'light' }
        if (-not (Request-Theme $to)) { Load-Settings }
    })
}
$ctl.SetLangZh.Content = '中文'; $ctl.SetLangEn.Content = 'English'
foreach ($rb in @($ctl.SetLangZh, $ctl.SetLangEn)) {
    $rb.Add_Checked({
        if ($script:setLoading) { return }
        $to = if ([object]::ReferenceEquals($this, $ctl.SetLangEn)) { 'en' } else { 'zh' }
        if ($to -eq $script:Lang -or -not (Request-Lang)) { Load-Settings }
    })
}
Apply-Mode

