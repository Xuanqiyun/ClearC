# ------------------------------------------------------------
# 操作日志
# ------------------------------------------------------------
$script:logCatLook = @{
    '删除' = @('#FDECEE', '#D70015'); '搬运' = @('#E8F1FC', '#0062C4'); '合并' = @('#E6F4EA', '#1E7B34'); '压缩' = @('#F3EAFD', '#7A3FC2')
    '卸载' = @('#FFF1E6', '#B25000'); '系统设置' = @('#EFEFF4', '#3A3A3C'); '日志' = @('#EFEFF4', '#6E6E73')
}
function Read-OpLog {
    $rows = New-Object System.Collections.Generic.List[LogRow]
    if (-not (Test-Path -LiteralPath $script:opLogDir)) { return ,$rows }
    $inv = [Globalization.CultureInfo]::InvariantCulture
    foreach ($f in @(Get-ChildItem -LiteralPath $script:opLogDir -Filter '操作日志-*.txt' -File -ErrorAction SilentlyContinue | Sort-Object Name -Descending)) {
        $lines = [IO.File]::ReadAllLines($f.FullName, [Text.Encoding]::UTF8)
        for ($i = $lines.Count - 1; $i -ge 0; $i--) {
            $l = $lines[$i]
            if (-not $l -or $l.StartsWith('#')) { continue }
            $a = $l.Split("`t")
            if ($a.Count -lt 3) { continue }
            $t = [datetime]::MinValue
            [void][datetime]::TryParseExact($a[0], 'yyyy-MM-dd HH:mm:ss', $inv, 'None', [ref]$t)
            $r = New-Object LogRow
            $r.Time = $a[0]; $r.When = $t; $r.Cat = $a[1]; $r.CatText = T $a[1]; $r.What = $a[2]
            $r.Target = if ($a.Count -gt 3) { $a[3] } else { '' }
            $r.Detail = if ($a.Count -gt 4) { $a[4] } else { '' }
            $lk = $script:logCatLook[$r.Cat]; if (-not $lk) { $lk = @('#EFEFF4', '#6E6E73') }
            $r.CatBg = $lk[0]; $r.CatFg = $lk[1]
            $rows.Add($r)
        }
    }
    return ,$rows
}
$script:logAll = $null
function Selected-Tag($panel) { foreach ($c in $panel.Children) { if ($c.IsChecked) { return [string]$c.Tag } }; return '' }
function Filter-Log {
    if ($null -eq $script:logAll) { return }
    $cat = Selected-Tag $ctl.LogCats
    $days = [int](Selected-Tag $ctl.LogRange)
    $since = if ($days -gt 0) { (Get-Date).AddDays(-$days) } else { [datetime]::MinValue }
    $q = ([string]$ctl.LogSearch.Text).Trim()
    $col = New-Object System.Collections.Generic.List[LogRow]
    foreach ($r in $script:logAll) {
        if ($cat -and $r.Cat -ne $cat) { continue }
        if ($r.When -lt $since) { continue }
        if ($q -and ($r.What + ' ' + $r.Target + ' ' + $r.Detail).IndexOf($q, [StringComparison]::OrdinalIgnoreCase) -lt 0) { continue }
        $col.Add($r)
    }
    $ctl.LogList.ItemsSource = $col
    $ctl.LogCount.Text = (T "{0:N0} 条") -f $col.Count
    $ctl.EmptyLog.Visibility = if ($col.Count -gt 0) { 'Collapsed' } else { 'Visible' }
    $ctl.EmptyLogText.Text = if ($script:logAll.Count -eq 0) { (T '还没有操作记录。删除、搬运等操作做完后会出现在这里') } else { (T '没有符合条件的记录') }
}
$script:logKeepSync = $false
function Update-LogKeepNote {
    $m = Get-LogMonths
    $keepText = switch ($m) { 0 { (T '永久保存') } 1 { (T '1 个月') } 3 { (T '3 个月') } 6 { (T '半年') } 12 { (T '1 年') } 24 { (T '2 年') } default { ((T "{0} 个月") -f $m) } }
    $cut = (Get-Date).Date.AddMonths(-$m)
    $lines = @(
        ((T "·  日志是普通的 txt 文件，放在 {0}，每个月一个，可以用记事本直接打开。") -f $script:opLogDir)
        (T '·  删除、搬运、合并、压缩、卸载和系统设置的每一次改动都会记下来：什么时间、做了什么、对哪个文件或文件夹、结果怎样。只记操作，不保存文件内容。')
    )
    if ($m -gt 0) { $lines += ((T "·  当前保存 {0}：每次打开本工具时，会自动删除 {1:yyyy-MM-dd}（{0}前）之前的记录，删掉后找不回来。") -f $keepText, $cut) }
    else { $lines += (T '·  当前设置为永久保存：记录不会自动删除，日志文件会越来越多（通常每月几十 KB 到几 MB）。') }
    $ctl.LogKeepNote.Text = $lines -join "`n"
}
function Load-Log {
    $script:logKeepSync = $true
    $m = Get-LogMonths
    for ($i = 0; $i -lt $ctl.LogKeep.Items.Count; $i++) { if ([string]$ctl.LogKeep.Items[$i].Tag -eq [string]$m) { $ctl.LogKeep.SelectedIndex = $i } }
    $script:logKeepSync = $false
    Update-LogKeepNote
    $script:logAll = Read-OpLog
    Filter-Log
}
foreach ($c in @($ctl.LogCats.Children) + @($ctl.LogRange.Children)) { $c.Add_Checked({ Filter-Log }) }
$ctl.LogSearch.Add_TextChanged({ Filter-Log })
$ctl.BtnLogRefresh.Add_Click({ Load-Log })
$ctl.BtnLogOpenDir.Add_Click({ New-Item -ItemType Directory -Path $script:opLogDir -Force | Out-Null; Open-Location $script:opLogDir })
$ctl.LogKeep.Add_SelectionChanged({
    if ($script:logKeepSync -or -not $ctl.LogKeep.SelectedItem) { return }
    $new = [int]$ctl.LogKeep.SelectedItem.Tag; $old = Get-LogMonths
    if ($new -eq $old) { return }
    if ($new -gt 0 -and ($old -eq 0 -or $new -lt $old)) {
        $cut = (Get-Date).Date.AddMonths(-$new)
        $ans = Show-Sheet -Kind warn -Title ((T "保存时间改成「{0}」？") -f $ctl.LogKeep.SelectedItem.Content) -Text ((T "{0:yyyy-MM-dd} 之前的操作记录会马上删除，删掉后找不回来。") -f $cut) -Buttons @((T '取消'), (T '改')) -Primary (T '改') -Cancel (T '取消')
        if ($ans -ne (T '改')) { Load-Log; return }
    }
    Set-Setting 'LogMonths' ([string]$new)
    OpLog '日志' (T '修改日志保存时间') ([string]$ctl.LogKeep.SelectedItem.Content) ''
    $n = Prune-OpLog $new
    if ($n -gt 0) { OpLog '日志' (T '删除超过保存时间的旧记录') '' ((T "{0} 条") -f $n) }
    Load-Log
})

