# ------------------------------------------------------------
# 界面自测（/uitest）：给 GitHub 上的自动测试用，在真的 Windows 上把新加的界面功能点一遍
# ------------------------------------------------------------
function Invoke-UiTest {
    $L = New-Object System.Collections.Generic.List[string]
    $script:uiFail = 0
    $Error.Clear()
    $L.Add(("ClearC UI test {0}  {1:yyyy-MM-dd HH:mm:ss}" -f $script:AppVersion, (Get-Date)))
    # 设置先存一份，测完原样放回去
    $setBak = $null; try { if (Test-Path -LiteralPath $script:settingsFile) { $setBak = [IO.File]::ReadAllBytes($script:settingsFile) } } catch {}
    $fast0 = [bool]$ctl.MapFast.IsChecked
    $step = {
        param([string]$name, [scriptblock]$body)
        $e0 = $Error.Count; $why = $null
        # 检查不通过时 throw 一句说明；代码出了异常也会到这里
        try { $null = & $body } catch { $why = [string]$_.Exception.Message; if ($_.InvocationInfo -and $_.FullyQualifiedErrorId -ne $why) { $why += ' @ ' + ([string]$_.InvocationInfo.PositionMessage).Split([char]10)[0] } }
        # 新增的错误里，找不到文件、外部命令往错误输出写的提示、剪贴板打不开这类（代码里本来就允许的）不算
        $bad = @(); for ($q = 0; $q -lt [math]::Min($Error.Count - $e0, 50); $q++) {
            $x = $Error[$q]; $id = if ($x -is [System.Management.Automation.ErrorRecord]) { [string]$x.FullyQualifiedErrorId + ' ' + [string]$x.CategoryInfo.Category } else { [string]$x.GetType().Name }
            if ($id -notmatch 'NotFound|ObjectNotFound|PathNotFound|ItemNotFound|UnauthorizedAccess|PermissionDenied|NativeCommandError|RemoteException|Clipboard|CLIPBRD|800401D0') { $bad += ([string]$x) + $(if ($x.InvocationInfo) { ' @ ' + ([string]$x.InvocationInfo.PositionMessage).Split([char]10)[0] } else { '' }) }
        }
        if (-not $why -and $bad.Count -gt 0) { $why = 'errors: ' + (($bad | Select-Object -First 3) -join ' | ') }
        if ($why) { $L.Add("FAIL ${name}: $why"); $script:uiFail++ } else { $L.Add("ok   $name") }
    }
    $click = { param($b) $b.RaiseEvent((New-Object System.Windows.RoutedEventArgs ([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent))) }
    try {
        & $step 'every page opens' {
            # 「搬家管理」和「软件管理」一打开就在后台开始统计，不在这里点
            foreach ($k in @('clean', 'dup', 'save', 'map', 'auto', 'log', 'help', 'settings')) {
                Show-Page $k; $win.UpdateLayout()
                if ($ctl[$script:pageList[$k][0]].Visibility -ne 'Visible') { throw "page $k not visible" }
            }
        }
        & $step 'help: back to the top after Feedback' {
            Show-Page 'help'; $win.UpdateLayout()
            & $click $ctl.BtnFeedback; $win.UpdateLayout()
            $down = $ctl.HelpScroll.VerticalOffset
            & $click $ctl.NavHelp; $win.UpdateLayout()
            if ($down -le 0) { throw 'Feedback did not scroll down' }
            if ($ctl.HelpScroll.VerticalOffset -ne 0) { throw ("still at {0} after clicking Help" -f $ctl.HelpScroll.VerticalOffset) }
        }
        & $step 'settings page shows the current settings' {
            Show-Page 'settings'
            if (-not $ctl.SetMapCheck.IsChecked -and (Get-Flag 'MapCheck')) { throw 'item check box switch not loaded' }
            if ([bool]$ctl.SetFast.IsChecked -ne [bool]$ctl.MapFast.IsChecked) { throw 'fast scan switches differ' }
            if ([string]$ctl.SetLangZh.Content -ne '中文' -or [string]$ctl.SetLangEn.Content -ne 'English') { throw 'language names missing' }
        }
        & $step 'display switches hide and show' {
            $pairs = @(@('SetMapCheck', 'MapCkVis'), @('SetMapBar', 'MapBarVis'), @('SetMapPct', 'MapPctVis'), @('SetMapMeta', 'MapMetaVis'), @('SetPageSub', 'SubVis'))
            foreach ($p in $pairs) {
                $ctl[$p[0]].IsChecked = $false; & $click $ctl[$p[0]]
                if ($win.Resources[$p[1]] -ne [System.Windows.Visibility]::Collapsed) { throw "$($p[0]) did not hide $($p[1])" }
                $ctl[$p[0]].IsChecked = $true; & $click $ctl[$p[0]]
                if ($win.Resources[$p[1]] -ne [System.Windows.Visibility]::Visible) { throw "$($p[0]) did not show $($p[1]) again" }
            }
            $ctl.SetMapFastBtn.IsChecked = $false; & $click $ctl.SetMapFastBtn
            if ($ctl.MapFast.Visibility -ne 'Collapsed') { throw 'fast scan switch still shown' }
            $ctl.SetMapFastBtn.IsChecked = $true; & $click $ctl.SetMapFastBtn
            if ($ctl.Hint.Visibility -ne 'Visible') { throw 'page description hidden' }
        }
        & $step 'pages and buttons can be hidden' {
            foreach ($n in 'SetPageMoves', 'SetPageAuto', 'SetPageLog', 'SetLinkLog') { $ctl[$n].IsChecked = $false; & $click $ctl[$n] }
            if ($ctl.NavMoves.Visibility -ne 'Collapsed' -or $ctl.NavLog.Visibility -ne 'Collapsed') { throw 'pages still listed' }
            if ($ctl.NavHeadManage.Visibility -ne 'Collapsed') { throw 'empty group heading still shown' }
            if ($ctl.BtnLog.Visibility -ne 'Collapsed') { throw 'run log button still shown' }
            & $click $ctl.BtnSetReset
            if ($ctl.NavMoves.Visibility -ne 'Visible' -or $ctl.NavHeadManage.Visibility -ne 'Visible' -or $ctl.BtnLog.Visibility -ne 'Visible') { throw 'reset did not show them again' }
            if (-not $ctl.SetPageMoves.IsChecked) { throw 'reset did not update the switches' }
        }
        & $step 'fast scan and low priority switches' {
            Set-FastScan $false; if (-not [DiskMap]::MftOff -or $ctl.SetFast.IsChecked) { throw 'fast scan off not applied' }
            Set-FastScan $true; if ([DiskMap]::MftOff -or -not $ctl.MapFast.IsChecked) { throw 'fast scan on not applied' }
            $ctl.SetLowIo.IsChecked = $true; & $click $ctl.SetLowIo; if (-not [DupFinder]::LowPriority) { throw 'low priority not applied' }
            $ctl.SetLowIo.IsChecked = $false; & $click $ctl.SetLowIo; if ([DupFinder]::LowPriority) { throw 'low priority not cleared' }
        }
        & $step 'appearance change asks first' {
            $n0 = $script:uiSheets.Count
            if (Request-Theme $(if ($script:themePref -eq 'dark') { 'light' } else { 'dark' })) { throw 'theme changed without confirmation' }
            if ($script:uiSheets.Count -le $n0) { throw 'no confirmation asked' }
        }
        & $step 'restore points card' {
            Show-Page 'save'
            $sw = [Diagnostics.Stopwatch]::StartNew()
            # 在另一个线程里读：等它读完（界面照常响应）
            while ($script:rpPs -and $sw.ElapsedMilliseconds -lt 30000) { $f = New-Object System.Windows.Threading.DispatcherFrame; [void]$win.Dispatcher.BeginInvoke([Action]{ $f.Continue = $false }, [System.Windows.Threading.DispatcherPriority]::Background); [System.Windows.Threading.Dispatcher]::PushFrame($f); Start-Sleep -Milliseconds 50 }
            $t = [string]$ctl.SaveRpState.Text
            if (-not $t -or $t -eq (T '当前：正在读取…')) { throw ("not filled in: {0}" -f $t) }
        }
        # 空间地图：用一个小文件夹扫出来的树
        $tree = [DiskMap]::Scan("$env:SystemRoot\INF", 2)      # 每台 Windows 都有，文件和子文件夹都不少
        & $step 'space map rows' {
            [DiskMap]::Use($tree); $script:mapRoot = $tree; $script:mapCur = $tree; $script:mapScanAt = Get-Date; $script:mapHow = 'test'
            Show-Page 'map'; $ctl.MapViewDirs.IsChecked = $true; Show-MapLevel $tree; $win.UpdateLayout()
            if ($ctl.MapList.Items.Count -lt 2) { throw ("only {0} rows" -f $ctl.MapList.Items.Count) }
            if ($ctl.BtnMapAcct.Visibility -ne 'Collapsed') { throw 'space breakdown shown for a folder scan' }
        }
        & $step 'item check boxes select rows' {
            $lv = $ctl.MapList; $lv.UnselectAll(); $win.UpdateLayout()
            $c0 = $lv.ItemContainerGenerator.ContainerFromIndex(0); $c1 = $lv.ItemContainerGenerator.ContainerFromIndex(1)
            if (-not $c0 -or -not $c1) { throw 'rows not generated' }
            $k0 = Find-Visual $c0 ([System.Windows.Controls.CheckBox]); $k1 = Find-Visual $c1 ([System.Windows.Controls.CheckBox])
            if (-not $k0) { throw 'no check box in the row' }
            if (-not $k0.IsVisible) { throw 'check box not visible' }
            $k0.IsChecked = $true; $k1.IsChecked = $true
            if ($lv.SelectedItems.Count -ne 2) { throw ("{0} selected after ticking 2" -f $lv.SelectedItems.Count) }
            if ($null -ne $ctl.MapAll.IsChecked) { throw 'select all is not partly checked' }
            $k0.IsChecked = $false
            if ($lv.SelectedItems.Count -ne 1) { throw 'unticking did not unselect' }
            $lv.SelectedItem = $lv.Items[0]; $win.UpdateLayout()
            if (-not $k0.IsChecked -or $k1.IsChecked) { throw 'check boxes do not follow the selection' }
            $ctl.SetMapCheck.IsChecked = $false; & $click $ctl.SetMapCheck; $win.UpdateLayout()
            $hidden = -not $k0.IsVisible
            $ctl.SetMapCheck.IsChecked = $true; & $click $ctl.SetMapCheck; $win.UpdateLayout()
            if (-not $hidden) { throw 'switch did not hide the check boxes' }
        }
        & $step 'ticked rows are kept when clicking another row' {
            $lv = $ctl.MapList; $lv.UnselectAll(); $win.UpdateLayout()
            if ($lv.Items.Count -lt 8) { throw 'too few rows' }
            foreach ($q in 0, 2) {
                $k = Find-Visual ($lv.ItemContainerGenerator.ContainerFromIndex($q)) ([System.Windows.Controls.CheckBox])
                $k.IsChecked = $true; $k.RaiseEvent((New-Object System.Windows.RoutedEventArgs ([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
            }
            if (-not (Test-TickMode)) { throw 'ticking did not start tick mode' }
            Invoke-TickClick 4 $false
            if ($lv.SelectedItems.Count -ne 3) { throw ("clicking a row after ticking: {0} selected, expected 3" -f $lv.SelectedItems.Count) }
            Invoke-TickClick 6 $true
            if ($lv.SelectedItems.Count -ne 5) { throw ("shift-click after ticking: {0} selected, expected 5" -f $lv.SelectedItems.Count) }
            Refresh-MapRows
            if ($lv.SelectedItems.Count -ne 5) { throw ("refreshing the list kept {0} of 5" -f $lv.SelectedItems.Count) }
            $src = [System.Windows.PresentationSource]::FromVisual($lv)
            if ($src) {
                $ka = New-Object System.Windows.Input.KeyEventArgs ([System.Windows.Input.Keyboard]::PrimaryDevice), $src, 0, ([System.Windows.Input.Key]::Escape)
                $ka.RoutedEvent = [System.Windows.Input.Keyboard]::PreviewKeyDownEvent
                $lv.RaiseEvent($ka)
                if ($lv.SelectedItems.Count -ne 0 -or (Test-TickMode)) { throw 'Esc did not clear the ticks' }
            }
        }
        & $step 'select all' {
            $lv = $ctl.MapList
            & $click $ctl.MapAll; if ($lv.SelectedItems.Count -ne $lv.Items.Count -or $ctl.MapAll.IsChecked -ne $true) { throw 'not all selected' }
            & $click $ctl.MapAll; if ($lv.SelectedItems.Count -ne 0 -or $ctl.MapAll.IsChecked -ne $false) { throw 'not all cleared' }
        }
        & $step 'left and right drag select a run of rows' {
            $lv = $ctl.MapList; $n = $lv.Items.Count
            if ($n -lt 3) { throw 'too few rows' }
            if ((Get-RowAt $lv 6) -ne 0) { throw ("row at the top is {0}" -f (Get-RowAt $lv 6)) }
            $lv.UnselectAll()
            foreach ($btn in 'Right', 'Left') {
                $lv.UnselectAll()
                $d = @{ Lv = $lv; Anchor = 0; Cur = 0; Moved = $false; Ctrl = $false; Base = $null; Cap = $null; Button = $btn }; $script:rdrag = $d
                Start-RowDrag $d; Set-DragRange $d 2
                if ($lv.SelectedItems.Count -ne 3) { throw ("{0}: {1} selected for rows 0-2" -f $btn, $lv.SelectedItems.Count) }
                Set-DragRange $d 1
                if ($lv.SelectedItems.Count -ne 2) { throw "${btn}: dragging back did not shrink the selection" }
                Stop-RowDrag
                if ($script:rdrag) { throw "${btn}: drag not stopped" }
                $lv.UnselectAll(); [void]$lv.SelectedItems.Add($lv.Items[$n - 1])
                $d = @{ Lv = $lv; Anchor = 0; Cur = 0; Moved = $false; Ctrl = $true; Base = $null; Cap = $null; Button = $btn }; $script:rdrag = $d
                Start-RowDrag $d; Set-DragRange $d 1; Stop-RowDrag
                if ($lv.SelectedItems.Count -ne 3) { throw ("{0} with Ctrl: {1} selected, expected 3" -f $btn, $lv.SelectedItems.Count) }
            }
            $c0 = $lv.ItemContainerGenerator.ContainerFromIndex(0); $k0 = Find-Visual $c0 ([System.Windows.Controls.CheckBox]); $t0 = Find-Visual $c0 ([System.Windows.Controls.TextBlock])
            if (-not (Test-InCheckBox $lv (Find-Visual $k0 ([System.Windows.Controls.Border])))) { throw 'a press on the check box would start a drag' }
            if ($t0 -and (Test-InCheckBox $lv $t0)) { throw 'a press on the name is taken for the check box' }
        }
        & $step 'right-click menu' {
            $lv = $ctl.MapList; $lv.UnselectAll()
            if (Update-MapMenu) { throw 'menu would open with nothing selected' }
            $lv.SelectAll()
            if (-not (Update-MapMenu)) { throw 'menu would not open' }
            $lv.ContextMenu.PlacementTarget = $lv; $lv.ContextMenu.IsOpen = $true; $win.UpdateLayout(); $lv.ContextMenu.IsOpen = $false
            $lv.UnselectAll(); $lv.SelectedItem = $lv.Items[0]; [void](Update-MapMenu)
            if ($ctl.MmEnter.Visibility -ne 'Visible' -and $lv.Items[0].IsDir) { throw 'Open folder missing for a folder' }
            $want = [string]$lv.Items[0].Path
            $ctl.MmCopy.RaiseEvent((New-Object System.Windows.RoutedEventArgs ([System.Windows.Controls.MenuItem]::ClickEvent)))
            # 剪贴板偶尔被别的程序占着打不开：读不到就不算这一项
            $got = ''; try { $got = [string][System.Windows.Clipboard]::GetText() } catch {}
            if ($got -and $got -ne $want) { throw ("copy path: clipboard has {0}, expected {1}" -f $got, $want) }
        }
        & $step 'size on disk notes' {
            $t = Get-DiskNote 2GB 200MB 1GB $false
            if ($t -notmatch [regex]::Escape((Fmt 1GB)) -or $t -notmatch [regex]::Escape((Fmt 200MB))) { throw "note: $t" }
            if (Get-DiskNote 100MB 100MB 0 $false) { throw 'note for an ordinary folder' }
            $tree.HasDisk = $true; $tree.UniqueSize = $tree.Size; $tree.UniqueDisk = $tree.Size; $tree.MftBytes = 64MB
            Show-MapLevel $tree
            if ($ctl.BtnMapAcct.Visibility -ne 'Visible') { throw 'space breakdown link hidden' }
            $n0 = $script:uiSheets.Count; & $click $ctl.BtnMapAcct
            if ($script:uiSheets.Count -le $n0 -or $script:uiSheets[$script:uiSheets.Count - 1] -notmatch 'MFT') { throw 'space breakdown not shown' }
        }
        & $step 'other map views' {
            $ctl.MapViewTree.IsChecked = $true; $win.UpdateLayout()
            $ctl.MapViewFiles.IsChecked = $true; $win.UpdateLayout()
            $ctl.MapViewGrow.IsChecked = $true; $win.UpdateLayout()
            if ($ctl.MapAll.IsEnabled) { throw 'select all enabled in the comparison view' }
            $ctl.MapViewTree.IsChecked = $true
            if ($ctl.MapAll.IsEnabled) { throw 'select all enabled in the treemap' }
            $ctl.MapViewDirs.IsChecked = $true
        }
    } catch { $L.Add('FAIL test run: ' + $_.Exception.Message); $script:uiFail++ }
    finally {
        try { if ($setBak) { [IO.File]::WriteAllBytes($script:settingsFile, $setBak) } elseif (Test-Path -LiteralPath $script:settingsFile) { Remove-Item -LiteralPath $script:settingsFile -Force } } catch {}
        try { [DiskMap]::MftOff = -not $fast0; [DupFinder]::LowPriority = ((Get-Setting 'LowIo' '0') -eq '1') } catch {}
    }
    $L.Add(("dialogs that would have opened: {0}" -f $script:uiSheets.Count))
    $L.Add(("summary: {0} failed" -f $script:uiFail))
    $file = if ($env:CLEANC_REPORT) { [IO.Path]::GetFullPath($env:CLEANC_REPORT) } else { Join-Path $script:appDir 'uitest.txt' }
    try { [IO.File]::WriteAllText($file, (@($L) -join "`r`n"), (New-Object Text.UTF8Encoding $true)) } catch {}
    $global:CLEANC_EXIT = [int]$script:uiFail
    $script:uiDone = $true
    if ($script:worker) { Set-CancelFlags; $script:closeWhenDone = $true }   # 还有后台在做：停在安全的地方再关
    $win.Close()
}

