# ------------------------------------------------------------
# 设置：外观、语言、显示哪些内容
# ------------------------------------------------------------
# 可以关掉的页面、左下角的按钮：设置里存关掉了的，逗号隔开
$script:optPages = [ordered]@{ dup = 'SetPageDup'; save = 'SetPageSave'; apps = 'SetPageApps'; moves = 'SetPageMoves'; auto = 'SetPageAuto'; log = 'SetPageLog' }
$script:optLinks = [ordered]@{ theme = @('SetLinkTheme', 'BtnTheme'); lang = @('SetLinkLang', 'BtnLang'); feedback = @('SetLinkFeedback', 'BtnFeedback'); log = @('SetLinkLog', 'BtnLog') }
# 开关：设置里的名字 → 设置页上的开关（默认都开）
$script:optSwitches = [ordered]@{ PageSub = 'SetPageSub'; MapCheck = 'SetMapCheck'; MapBar = 'SetMapBar'; MapPct = 'SetMapPct'; MapMeta = 'SetMapMeta'; MapDisk = 'SetMapDisk'; MapFastBtn = 'SetMapFastBtn'; MapHealth = 'SetMapHealth' }
function Get-Flag([string]$k) { (Get-Setting $k '1') -ne '0' }
function Get-HiddenSet([string]$k) { $h = @{}; foreach ($x in ((Get-Setting $k '') -split ',')) { $x = $x.Trim(); if ($x) { $h[$x] = $true } }; return $h }
function Apply-Display {
    $vis = { param([bool]$on) if ($on) { [System.Windows.Visibility]::Visible } else { [System.Windows.Visibility]::Collapsed } }
    $win.Resources['SubVis'] = & $vis (Get-Flag 'PageSub')
    $win.Resources['MapCkVis'] = & $vis (Get-Flag 'MapCheck')
    $win.Resources['MapBarVis'] = & $vis (Get-Flag 'MapBar')
    $win.Resources['MapPctVis'] = & $vis (Get-Flag 'MapPct')
    $win.Resources['MapMetaVis'] = & $vis (Get-Flag 'MapMeta')
    $win.Resources['MapHealthVis'] = & $vis (Get-Flag 'MapHealth')
    $ctl.MapFast.Visibility = & $vis (Get-Flag 'MapFastBtn')
    $hp = Get-HiddenSet 'HidePages'
    foreach ($k in $script:optPages.Keys) { $ctl[$script:pageList[$k][1]].Visibility = & $vis (-not $hp.ContainsKey($k)) }
    $ctl.NavHeadManage.Visibility = & $vis (-not ($hp.ContainsKey('moves') -and $hp.ContainsKey('auto') -and $hp.ContainsKey('log')))
    $hl = Get-HiddenSet 'HideLinks'
    foreach ($k in $script:optLinks.Keys) { $ctl[$script:optLinks[$k][1]].Visibility = & $vis (-not $hl.ContainsKey($k)) }
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
Apply-Display

