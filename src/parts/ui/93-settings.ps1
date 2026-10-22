# ------------------------------------------------------------
# 设置：外观、语言、显示哪些内容
# ------------------------------------------------------------
# 可以关掉的页面、左下角的按钮：设置里存关掉了的，逗号隔开
$script:optPages = [ordered]@{ dup = 'SetPageDup'; save = 'SetPageSave'; apps = 'SetPageApps'; moves = 'SetPageMoves'; auto = 'SetPageAuto'; log = 'SetPageLog' }
$script:optLinks = [ordered]@{ theme = @('SetLinkTheme', 'BtnTheme'); lang = @('SetLinkLang', 'BtnLang'); feedback = @('SetLinkFeedback', 'BtnFeedback'); log = @('SetLinkLog', 'BtnLog') }
# 开关：设置里的名字 → 设置页上的开关（默认都开）
$script:optSwitches = [ordered]@{ PageSub = 'SetPageSub'; MapCheck = 'SetMapCheck'; MapBar = 'SetMapBar'; MapPct = 'SetMapPct'; MapMeta = 'SetMapMeta'; MapDisk = 'SetMapDisk'; MapFastBtn = 'SetMapFastBtn' }
function Get-Flag([string]$k) { (Get-Setting $k '1') -ne '0' }
function Get-HiddenSet([string]$k) { $h = @{}; foreach ($x in ((Get-Setting $k '') -split ',')) { $x = $x.Trim(); if ($x) { $h[$x] = $true } }; return $h }
function Apply-Display {
    $vis = { param([bool]$on) if ($on) { [System.Windows.Visibility]::Visible } else { [System.Windows.Visibility]::Collapsed } }
    $win.Resources['SubVis'] = & $vis (Get-Flag 'PageSub')
    $win.Resources['MapCkVis'] = & $vis (Get-Flag 'MapCheck')
    $win.Resources['MapBarVis'] = & $vis (Get-Flag 'MapBar')
    $win.Resources['MapPctVis'] = & $vis (Get-Flag 'MapPct')
    $win.Resources['MapMetaVis'] = & $vis (Get-Flag 'MapMeta')
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

