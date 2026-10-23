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
    Set-Setting 'Mode' 'expert'; Apply-Mode
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
    $waitUi = {
        param([scriptblock]$cond, [int]$ms)
        $sw = [Diagnostics.Stopwatch]::StartNew()
        do { $f = New-Object System.Windows.Threading.DispatcherFrame; [void]$win.Dispatcher.BeginInvoke([Action]{ $f.Continue = $false }, [System.Windows.Threading.DispatcherPriority]::Background); [System.Windows.Threading.Dispatcher]::PushFrame($f); Start-Sleep -Milliseconds 50 }
        while (-not (& $cond) -and $sw.ElapsedMilliseconds -lt $ms)
        [bool](& $cond)
    }
    # 把一块界面整块画成 PNG，放在报告旁边（GitHub 上的自动测试会一起上传，方便看排版）；画不出来只记一笔，不算失败
    $snap = {
        param($el, [string]$name, [double]$scale = 1)
        try {
            $el.UpdateLayout()
            $w = [math]::Ceiling($el.ActualWidth); $h = [math]::Ceiling($el.ActualHeight)
            if ($w -lt 1 -or $h -lt 1 -or $h -gt 30000) { return }
            $r = New-Object System.Windows.Rect 0, 0, $w, $h
            $vb = New-Object System.Windows.Media.VisualBrush $el
            $vb.ViewboxUnits = [System.Windows.Media.BrushMappingMode]::Absolute; $vb.Viewbox = $r
            $dv = New-Object System.Windows.Media.DrawingVisual
            $dc = $dv.RenderOpen(); $dc.DrawRectangle($win.Background, $null, $r); $dc.DrawRectangle($vb, $null, $r); $dc.Close()
            $bmp = New-Object System.Windows.Media.Imaging.RenderTargetBitmap ([int]($w * $scale)), ([int]($h * $scale)), (96 * $scale), (96 * $scale), ([System.Windows.Media.PixelFormats]::Pbgra32)
            $bmp.Render($dv)
            $enc = New-Object System.Windows.Media.Imaging.PngBitmapEncoder
            $enc.Frames.Add([System.Windows.Media.Imaging.BitmapFrame]::Create($bmp))
            $dir = if ($env:CLEANC_REPORT) { Split-Path ([IO.Path]::GetFullPath($env:CLEANC_REPORT)) } else { $script:appDir }
            $fs = [IO.File]::Create((Join-Path $dir ('uitest-{0}-{1}{2}.png' -f $name, $script:Lang, $(if ([Theme]::Dark) { '-dark' } else { '' }))))
            try { $enc.Save($fs) } finally { $fs.Close() }
        } catch { $L.Add(('note snapshot {0}: {1}' -f $name, $_.Exception.Message)); if ($Error.Count) { $Error.RemoveAt(0) } }
    }
    try {
        & $step 'every page opens' {
            # 「搬家管理」和「软件管理」一打开就在后台开始统计，不在这里点
            foreach ($k in @('clean', 'dup', 'save', 'map', 'auto', 'log', 'help', 'settings')) {
                Show-Page $k; $win.UpdateLayout()
                if ($ctl[$script:pageList[$k][0]].Visibility -ne 'Visible') { throw "page $k not visible" }
            }
        }
        & $step 'help: contents list on the left, only the picked item on the right' {
            Show-Page 'help'; $win.UpdateLayout()
            $navs = @($ctl.HelpNav.Children | Where-Object { $_ -is [System.Windows.Controls.RadioButton] })
            if ($navs.Count -lt 13 -or $script:helpPanes.Count -ne $navs.Count) { throw ('{0} items in the contents, {1} panes' -f $navs.Count, $script:helpPanes.Count) }
            if (@($ctl.HelpNav.Children | Where-Object { $_ -is [System.Windows.Controls.TextBlock] }).Count -lt 4) { throw 'no group headings in the contents' }
            $navs[4].IsChecked = $true; $win.UpdateLayout()
            $vis = @($script:helpPanes.Values | Where-Object { $_.Pane.Visibility -eq 'Visible' })
            if ($vis.Count -ne 1 -or -not [object]::ReferenceEquals($vis[0].Nav, $navs[4])) { throw 'more than one item shown, or not the one picked' }
            & $snap $ctl.PageHelp 'help'
            $was = $script:helpPane
            & $click $ctl.BtnHelpNext; if ($script:helpPane -eq $was -or -not $navs[5].IsChecked) { throw 'next did not move on' }
            & $click $ctl.BtnHelpPrev; if ($script:helpPane -ne $was) { throw 'previous did not come back' }
            # 左下角「使用反馈」直接打开反馈那一项；再点「帮助」回到原来在看的那一项
            & $click $ctl.BtnFeedback; $win.UpdateLayout()
            if ($ctl.FeedbackCard.Visibility -ne 'Visible' -or $script:helpPane -ne 'fb') { throw 'Feedback did not open its item' }
            & $click $ctl.NavHelp; $win.UpdateLayout()
            if ($script:helpPane -ne $was -or $ctl.HelpScroll.VerticalOffset -ne 0) { throw ('Help went to {0}, not back to {1}' -f $script:helpPane, $was) }
            foreach ($k in @($script:helpPanes.Keys)) { Select-HelpPane $k -NoRemember; $win.UpdateLayout(); if ($script:helpPanes[$k].Pane.ActualHeight -lt 60) { throw "item $k looks empty" } }
            $q = @($ctl.HelpFaq.Children)[0]; Select-HelpPane 'faq' -NoRemember; $q.IsExpanded = $true; $win.UpdateLayout(); $q.IsExpanded = $false
            Select-HelpPane $was
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
        & $step 'cleanup list: custom and excluded folders' {
            $d = Join-Path $script:appDir 'uitest-custom'; New-Item -ItemType Directory -Force -Path $d | Out-Null
            [IO.File]::WriteAllBytes((Join-Path $d 'junk.tmp'), (New-Object byte[] 5000))
            Save-CleanList 'CustomClean' @($d)
            if (@($ctl.SetCustomList.ItemsSource).Count -ne 1 -or $ctl.SetCustomEmpty.Visibility -ne 'Collapsed') { throw 'custom list not shown in Settings' }
            $c = @($catalog | Where-Object { $_.Custom })
            if ($c.Count -ne 1 -or (Measure-Item $c[0]) -ne 5000) { throw ("catalog has {0} custom entries" -f $c.Count) }
            Save-CleanList 'Exclude' @($d)
            if ((Measure-Item $c[0]) -ne 0) { throw 'excluded folder still counted' }
            Save-CleanList 'Exclude' @(); Save-CleanList 'CustomClean' @()
            if (@($catalog | Where-Object { $_.Custom }).Count -ne 0 -or $ctl.SetCustomEmpty.Visibility -ne 'Visible') { throw 'custom entry not removed' }
            Remove-Item -LiteralPath $d -Recurse -Force -ErrorAction SilentlyContinue
            & $click $ctl.BtnCleanCustom; $win.UpdateLayout()
            if ($ctl.PageSettings.Visibility -ne 'Visible') { throw 'link did not open Settings' }
        }
        & $step 'editing the cleanup list voids the old scan; one-click skips risky items' {
            $d1 = Join-Path $script:appDir 'uitest-c1'; $d2 = Join-Path $script:appDir 'uitest-c2'
            New-Item -ItemType Directory -Force -Path $d1, $d2 | Out-Null
            foreach ($d in $d1, $d2) { [IO.File]::WriteAllBytes((Join-Path $d 'x.tmp'), (New-Object byte[] 4096)) }
            try {
                Save-CleanList 'CustomClean' @($d1, $d2)
                $sizes = @{}; foreach ($c in $catalog) { $sizes[$c.Idx] = [double]1MB }
                $sync.Sizes = $sizes; Build-Rows $sizes
                if (-not $script:rows -or $script:rows.Count -lt 3) { throw 'no rows' }
                Apply-OneClick
                $bad = @($script:rows | Where-Object { $_.Action -ne (T '跳过') -and (([string]$_.Group).StartsWith('需确认') -or ([string]$_.Group).StartsWith('自定义')) })
                if ($bad.Count) { throw ("one-click picked: {0}" -f (($bad | ForEach-Object { $_.Name }) -join ', ')) }
                if (@($script:rows | Where-Object { $_.Action -eq (T '删除') -and ([string]$_.Group).StartsWith('安全清理') }).Count -lt 3) { throw 'one-click picked no safe items' }
                foreach ($r in $script:rows) { $it = @($catalog | Where-Object { $_.Idx -eq $r.Idx })[0]; if ((Get-ItemSig $it) -ne $script:rowSig[$r.Idx]) { throw ("fingerprint mismatch: {0}" -f $r.Name) } }
                Save-CleanList 'CustomClean' @($d2)
                if ($script:rows -or $sync.Sizes) { throw 'old scan rows still usable after the list changed' }
                Invoke-RunSelected
                if ($script:worker) { throw 'a run started without a fresh scan' }
            } finally {
                Save-CleanList 'CustomClean' @(); $sync.Sizes = $null; $script:rows = $null; $ctl.List.ItemsSource = $null
                Remove-Item -LiteralPath $d1, $d2 -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
        & $step 'reminders: junk limit and cleanup day' {
            Show-Page 'auto'; $win.UpdateLayout()
            $ctl.AutoJunkGB.SelectedIndex = 2; if ((Get-Setting 'JunkGB' '0') -ne '2') { throw 'junk limit not saved' }
            $ctl.AutoCleanWhen.SelectedIndex = 7; if ((Get-Setting 'CleanWhen' '') -ne 'daily') { throw 'cleanup day not saved' }
            $ctl.AutoCleanWhen.SelectedIndex = 0; $ctl.AutoJunkGB.SelectedIndex = 0
        }
        & $step 'apps page: startup, tasks and context menu' {
            $st = @(Get-StartupItems); $tk = @(Get-UserTasks); $cm = @(Get-ContextMenuItems)
            Build-StartRows 'startup' $st; Build-StartRows 'task' $tk; Build-StartRows 'shellex' $cm
            # 列表显示出来（不打开软件页的统计）
            $script:pageLoaded.apps = $true
            Show-Page 'apps'; $ctl.AppsViewStartup.IsChecked = $true; $win.UpdateLayout()
            if ($ctl.StartList.Visibility -ne 'Visible' -or $ctl.AppsList.Visibility -ne 'Collapsed') { throw 'startup view not shown' }
            if (@($ctl.StartList.ItemsSource).Count -ne $st.Count) { throw ("{0} rows for {1} startup items" -f @($ctl.StartList.ItemsSource).Count, $st.Count) }
            $ctl.AppsViewTasks.IsChecked = $true; $win.UpdateLayout()
            if (@($ctl.StartList.ItemsSource).Count -ne $tk.Count) { throw 'task rows differ' }
            $ctl.AppsViewMenu.IsChecked = $true; $win.UpdateLayout()
            if (@($ctl.StartList.ItemsSource).Count -ne $cm.Count) { throw 'context menu rows differ' }
            $ctl.AppsViewApps.IsChecked = $true; $win.UpdateLayout()
            if ($ctl.AppsList.Visibility -ne 'Visible') { throw 'apps view not back' }
            # 开关：在 StartupApproved 里写一个假名字，再删掉，不碰真的启动项
            $ap = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run'
            Set-StartupEnabled $ap 'ClearC-UiTest' $false
            if (Test-StartupEnabled $ap 'ClearC-UiTest') { throw 'disable not recorded' }
            Set-StartupEnabled $ap 'ClearC-UiTest' $true
            if (-not (Test-StartupEnabled $ap 'ClearC-UiTest')) { throw 'enable not recorded' }
            Remove-ItemProperty -LiteralPath $ap -Name 'ClearC-UiTest' -ErrorAction SilentlyContinue
            $script:startRows.Clear()
            "startup {0}, tasks {1}, context menu {2}" -f $st.Count, $tk.Count, $cm.Count
        }
        & $step 'installer orphans are a subset of the cached packages' {
            $all = @(Get-ChildItem -LiteralPath (Join-Path $env:SystemRoot 'Installer') -File -Force -ErrorAction SilentlyContinue | Where-Object { $_.Extension -match '^\.(msi|msp)$' })
            $o = @(Get-InstallerOrphans)
            if ($all.Count -gt 0 -and $o.Count -ge $all.Count) { throw ("all {0} packages look orphaned; the references were not read" -f $all.Count) }
            # 一次问完的结果必须和原来在 PowerShell 里一条一条问的完全一样（同样的注册表位置、同样的接口调用）
            $old = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
            foreach ($root in @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Installer\UserData\*\Products\*\InstallProperties', 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Installer\UserData\*\Patches\*',
                                   'HKLM:\SOFTWARE\Classes\Installer\Patches\*', 'HKCU:\Software\Microsoft\Installer\Patches\*')) {
                foreach ($p in @(Get-ItemProperty -Path $root -ErrorAction SilentlyContinue)) { $v = [string]$p.LocalPackage; if ($v) { [void]$old.Add((Split-Path $v -Leaf)) } }
            }
            $nReg = $old.Count
            $inst = New-Object -ComObject WindowsInstaller.Installer; $t = $inst.GetType()
            foreach ($code in @($t.InvokeMember('Products', 'GetProperty', $null, $inst, $null))) {
                try { $lp = [string]$t.InvokeMember('ProductInfo', 'GetProperty', $null, $inst, @([string]$code, 'LocalPackage')); if ($lp) { [void]$old.Add((Split-Path $lp -Leaf)) } } catch {}
                foreach ($pa in @(@([string]$code, '', 7, 15), @([string]$code, 's-1-1-0', 3, 15))) {
                    try { foreach ($pt in @($t.InvokeMember('PatchesEx', 'GetProperty', $null, $inst, $pa))) { try { $lp = [string]$pt.GetType().InvokeMember('PatchProperty', 'GetProperty', $null, $pt, @('LocalPackage')); if ($lp) { [void]$old.Add((Split-Path $lp -Leaf)) } } catch {} } } catch {}
                }
            }
            $new = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
            $r1 = @([InstallerRefs]::FromRegistry()); foreach ($v in $r1) { [void]$new.Add($v) }
            $nReg2 = $new.Count
            foreach ($v in @([InstallerRefs]::FromInstaller())) { [void]$new.Add($v) }
            if (-not $old.SetEquals($new) -or $nReg -ne $nReg2) { throw ("references differ: before {0} (registry {1}), now {2} (registry {3})" -f $old.Count, $nReg, $new.Count, $nReg2) }
            "{0} of {1} packages; {2} references, the same as asking one by one" -f $o.Count, $all.Count, $new.Count
        }
        & $step 'services and drivers read from the registry cover every program WMI lists' {
            # 判断软件能不能搬时要知道哪些服务、驱动的程序在它的文件夹里：直接读注册表，不能比 WMI 少
            $reg = Get-ServicePaths   # 返回的是一个列表（不要再套 @()，那样会变成只有一项）
            $wmi = @(@(Get-CimInstance -ClassName Win32_Service -ErrorAction Stop) + @(Get-CimInstance -ClassName Win32_SystemDriver -ErrorAction Stop))
            $miss = @(); $n = 0
            foreach ($w in $wmi) {
                $m = [regex]::Match([string]$w.PathName, '(?i)([a-z]:\\[^"]*?\.(exe|sys|dll))')
                if (-not $m.Success) { continue }
                $dir = Split-Path $m.Groups[1].Value -Parent
                if ($dir -match '(?i)^[a-z]:\\windows(\\|$)') { continue }   # 系统自带的不用看（在 Windows 文件夹里，不会是要搬的软件）
                $n++
                if (-not @($reg | Where-Object { ([string]$_.PathName).IndexOf($dir, [StringComparison]::OrdinalIgnoreCase) -ge 0 -or ([string]$_.PathName).IndexOf(($dir -replace '^[A-Za-z]:', ''), [StringComparison]::OrdinalIgnoreCase) -ge 0 }).Count) { $miss += ('{0} ({1})' -f $w.Name, $w.PathName) }
            }
            if ($reg.Count -lt 50 -or $miss.Count) { throw ("registry has {0} entries; missing {1} of {2}: {3}" -f $reg.Count, $miss.Count, $n, (($miss | Select-Object -First 4) -join ' | ')) }
            "{0} services and drivers from the registry; all {1} outside the Windows folder that WMI lists are there" -f $reg.Count, $n
        }
        & $step 'save space: reserved storage, crash dump, temp folder, OneDrive' {
            Show-Page 'save'; $win.UpdateLayout()
            foreach ($n in 'SaveRsState', 'SaveDumpState', 'SaveTmpState') { if (-not [string]$ctl[$n].Text) { throw "$n is empty" } }
            $dm0 = Get-CrashDumpMode
            if ($dm0 -ge 0) {
                Set-CrashDumpMode 3; if ((Get-CrashDumpMode) -ne 3) { throw 'crash dump mode not written' }
                Set-CrashDumpMode $dm0
            }
            $t0 = Get-UserTemp
            Set-UserTemp "$env:SystemDrive\ClearC-UiTest-Temp"
            if ((Get-UserTemp) -ne "$env:SystemDrive\ClearC-UiTest-Temp") { throw 'temp folder not written' }
            Set-UserTemp $t0
            Remove-Item -LiteralPath "$env:SystemDrive\ClearC-UiTest-Temp" -Recurse -Force -ErrorAction SilentlyContinue
            $od = Get-OneDriveInfo
            if ($null -eq $od -or $null -eq $od.Folders) { throw 'OneDrive info missing' }
            $h = Get-DiskHealth $env:SystemDrive
            if ($h -isnot [string]) { throw 'disk health is not text' }
        }
        & $step 'broken shortcuts and leftover folders are detected' {
            $sh = New-Object -ComObject WScript.Shell
            $lnk = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\ClearC-UiTest.lnk'
            New-Item -ItemType Directory -Force -Path (Split-Path $lnk) | Out-Null
            $s = $sh.CreateShortcut($lnk); $s.TargetPath = "$env:SystemDrive\ClearC-UiTest-Missing\x.exe"; $s.Save()
            try {
                $b = @(Get-BrokenShortcuts)
                if (@($b | Where-Object { $_.FullName -ieq $lnk }).Count -ne 1) { throw ("broken shortcut not found among {0}" -f $b.Count) }
            } finally { Remove-Item -LiteralPath $lnk -Force -ErrorAction SilentlyContinue }
            $d = Join-Path $env:LOCALAPPDATA 'ClearCUiTestOrphan'
            New-Item -ItemType Directory -Force -Path $d | Out-Null
            [IO.File]::WriteAllBytes((Join-Path $d 'old.dat'), (New-Object byte[] 2097152))
            $old = (Get-Date).AddDays(-45)
            (Get-Item -LiteralPath (Join-Path $d 'old.dat')).LastWriteTime = $old; (Get-Item -LiteralPath $d).LastWriteTime = $old
            try {
                $o = @(Get-OrphanFolders @(@{ Name = 'Some App'; Publisher = 'Someone'; Location = 'C:\Program Files\Some App' }))
                if (@($o | Where-Object { $_.Path -ieq $d }).Count -ne 1) { throw ("orphan folder not found among {0}" -f $o.Count) }
                Build-StartRows 'leftover' $o
                $row = @($script:startRows['leftover'] | Where-Object { $_.Detail -ieq $d })[0]
                if (-not $row -or $row.ToggleText -ne (T '移到回收站') -or -not $row.Size) { throw 'leftover row not built' }
                $script:startRows.Clear()
            } finally { Remove-Item -LiteralPath $d -Recurse -Force -ErrorAction SilentlyContinue }
        }
        & $step 'disk health cards fill in' {
            $script:pageLoaded.map = $true; Fill-MapDrives
            Show-Page 'map'; $win.UpdateLayout()
            Start-DiskHealth
            if (-not (& $waitUi { -not $script:dhPs } 60000)) { throw 'disk health did not finish' }
            $cards = @($ctl.MapHealth.ItemsSource)
            if ($cards.Count -eq 0) { throw ('no disk cards; ' + [string]$script:dhErr + ' / direct: ' + (Get-DiskHealth $env:SystemDrive)) }
            if (-not $cards[0].HealthText -or -not $cards[0].UsedText -or $cards[0].Model -eq (T '读不到型号和健康信息')) { throw ('card not filled: ' + $cards[0].Model + ' / ' + $cards[0].HealthText) }
            & $snap $ctl.MapHealthBox 'disk-cards' 2
            $ctl.SetMapHealth.IsChecked = $false; & $click $ctl.SetMapHealth; $win.UpdateLayout()
            $hidden = $ctl.MapHealthBox.Visibility -ne 'Visible'
            $ctl.SetMapHealth.IsChecked = $true; & $click $ctl.SetMapHealth; $win.UpdateLayout()
            if (-not $hidden) { throw 'switch did not hide the disk cards' }
        }
        & $step 'modes hide and show features' {
            Set-Mode 'basic'
            if ($ctl.NavDup.Visibility -ne 'Collapsed' -or $ctl.NavLog.Visibility -ne 'Collapsed' -or $ctl.BtnLog.Visibility -ne 'Collapsed') { throw 'basic mode still shows advanced pages' }
            if ($ctl.SaveNavRs.Visibility -ne 'Collapsed' -or $ctl.AppsViewBox.Visibility -ne 'Collapsed' -or $ctl.MapViewFiles.Visibility -ne 'Collapsed' -or $ctl.BtnSetCustomAdd.Visibility -ne 'Collapsed') { throw 'basic mode still shows advanced cards' }
            if ($ctl.NavClean.Visibility -ne 'Visible' -or $ctl.SaveNavCos.Visibility -ne 'Visible' -or $ctl.SaveNavOd.Visibility -ne 'Visible' -or $ctl.NavHealth.Visibility -ne 'Visible' -or $ctl.HTabHw.Visibility -ne 'Visible' -or $ctl.HTabCrash.Visibility -ne 'Visible' -or $ctl.HTabFix.Visibility -ne 'Visible') { throw 'basic mode hides basic things' }
            if ($ctl.HTabBoot.Visibility -ne 'Collapsed' -or $ctl.HTabMon.Visibility -ne 'Collapsed' -or $ctl.HTabEvents.Visibility -ne 'Collapsed') { throw 'basic mode shows advanced health tabs' }
            $basicSteps = @(@($ctl.FixGroups.Items) | ForEach-Object { @($_.Steps) } | ForEach-Object { $_.Id })
            if ($basicSteps -contains 'netreset' -or $basicSteps -contains 'wureset' -or $basicSteps -notcontains 'sfcrepair') { throw ('basic mode repair steps: ' + ($basicSteps -join ',')) }
            if ($ctl.ModeTag.Text -ne ((T '普通用户') + (T '模式'))) { throw ('mode tag: ' + $ctl.ModeTag.Text) }
            Set-Mode 'pro'
            if ($ctl.NavDup.Visibility -ne 'Visible' -or $ctl.AppsViewStartup.Visibility -ne 'Visible' -or $ctl.AppsViewTasks.Visibility -ne 'Collapsed' -or $ctl.SaveNavPf.Visibility -ne 'Visible' -or $ctl.SaveNavRs.Visibility -ne 'Collapsed') { throw 'pro mode wrong' }
            Set-Mode 'expert'
            if ($ctl.AppsViewTasks.Visibility -ne 'Visible' -or $ctl.SaveNavRs.Visibility -ne 'Visible' -or $ctl.BtnLog.Visibility -ne 'Visible' -or $ctl.BtnSetCustomAdd.Visibility -ne 'Visible' -or $ctl.BtnSfcRepair.Visibility -ne 'Visible' -or $ctl.HTabEvents.Visibility -ne 'Visible') { throw 'expert mode wrong' }
            if (@($catalog | Where-Object { [int]$_.Lvl -eq 2 }).Count -lt 5 -or @($catalog | Where-Object { [int]$_.Lvl -eq 1 }).Count -lt 5) { throw 'catalog levels missing' }
        }
        & $step 'cleanup tiers: careful group, delete preview, recycle switch' {
            $care = @($catalog | Where-Object { $_.Careful })
            if ($care.Count -lt 10 -or @($care | Where-Object { -not ([string]$_.G).StartsWith('谨慎清理') }).Count -gt 0) { throw ("careful items: {0}" -f $care.Count) }
            if (@($catalog | Where-Object { $_.N -eq (T '驱动存储里的旧版驱动包') }).Count -ne 1) { throw 'old driver packages item missing' }
            $d = Join-Path $script:appDir 'uitest-preview'; New-Item -ItemType Directory -Path "$d\sub" -Force | Out-Null
            [IO.File]::WriteAllText("$d\a.tmp", ('x' * 3000)); [IO.File]::WriteAllText("$d\sub\b.tmp", ('y' * 5000)); [IO.File]::WriteAllText("$d\keep.txt", 'z')
            try {
                $pv = @(Get-DeletePreview @(@{ N = 'test'; Paths = @($d); Filter = '*.tmp' }) 100)
                if ($pv.Count -ne 1 -or $pv[0].Bytes -ne 3000) { throw ("preview with filter: {0}" -f $pv.Count) }
                $pv = @(Get-DeletePreview @(@{ N = 'test'; Paths = @($d) }) 100)
                if ($pv.Count -ne 3 -or @($pv | Where-Object { $_.IsDir }).Count -ne 1) { throw ("preview: {0}" -f $pv.Count) }
                $n0 = $script:uiSheets.Count
                Show-DeletePreview @(@{ N = 'test'; Paths = @($d) })
                if ($script:uiSheets.Count -le $n0 -or $script:uiSheets[$script:uiSheets.Count - 1] -notmatch 'preview-') { throw 'preview dialog not shown' }
            } finally { Remove-Item -LiteralPath $d -Recurse -Force -ErrorAction SilentlyContinue }
            Show-Page 'settings'; $ctl.SetRecycle.IsChecked = $true; & $click $ctl.SetRecycle
            if ((Get-Setting 'Recycle' '0') -ne '1') { throw 'recycle setting not saved' }
            $ctl.SetRecycle.IsChecked = $false; & $click $ctl.SetRecycle
        }
        & $step 'system health page fills in' {
            Show-Page 'health'
            if (-not (& $waitUi { $script:healthData -ne $null } 90000)) { throw ('health data not read: ' + $ctl.HealthNote.Text) }
            $L.Add(('health: ' + $ctl.HealthNote.Text))
            if ($ctl.HealthCards.Items.Count -lt 3) { throw ("only {0} hardware cards" -f $ctl.HealthCards.Items.Count) }
            $titles = @($ctl.HealthCards.Items | ForEach-Object { $_.Title })
            if ($titles -notcontains (T 'CPU') -or $titles -notcontains (T '内存') -or $titles -notcontains 'Windows') { throw ('cards: ' + ($titles -join ',')) }
            foreach ($c in $ctl.HealthCards.Items) { $L.Add(('  ' + $c.Title + ': ' + (@($c.Chips | ForEach-Object { $_.Text }) -join ' | ') + ' / ' + (@($c.Lines) -join ' / '))) }
            if (-not $ctl.HealthBootText.Text -or -not $ctl.HealthCrashText.Text -or -not $ctl.HealthWinText.Text) { throw 'boot, crash or events text empty' }
            $L.Add(('  boot: ' + $ctl.HealthBootText.Text)); $L.Add(('  crash: ' + $ctl.HealthCrashText.Text)); $L.Add(('  events: ' + $ctl.HealthWinText.Text))
            # 活动监控：采两次样
            Start-Monitor
            if (-not (& $waitUi { $script:monShared -and $script:monShared.Ver -ge 1 } 20000)) { throw 'monitor took no sample' }
            Refresh-Monitor
            if ($ctl.MonList.Items.Count -lt 1) { throw 'monitor list empty' }
            $L.Add(('  monitor: ' + $ctl.MonList.Items.Count + ' rows, top ' + $ctl.MonList.Items[0].Name + ' ' + $ctl.MonList.Items[0].SinceText))
            # 点表头排序：点「内存」从高到低，再点一下从低到高；点「CPU」重新取 CPU 最高的 25 个，按 CPU 从高到低
            Select-HealthTab 'mon'; $win.UpdateLayout()
            $hd = Find-GridHead $ctl.MonList 2
            if (-not $hd) { throw 'memory column header not found' }
            & $click $hd
            if ($script:sortCfg.MonList.Prop -ne 'Ws' -or -not $script:sortCfg.MonList.Desc) { throw 'clicking the memory header did not sort high to low' }
            if (-not (Test-SortedBy @($ctl.MonList.Items) 'Ws' $true)) { throw 'monitor rows not sorted by memory' }
            if ([string]$ctl.MonList.View.Columns[2].Header -notlike '*↓') { throw ('no arrow on the memory header: ' + $ctl.MonList.View.Columns[2].Header) }
            Invoke-HeaderSort 'MonList' '2'
            if (-not (Test-SortedBy @($ctl.MonList.Items) 'Ws' $false) -or [string]$ctl.MonList.View.Columns[2].Header -notlike '*↑') { throw 'second click did not reverse the order' }
            Invoke-HeaderSort 'MonList' '1'
            if ($ctl.MonList.Items.Count -lt 1) { throw 'monitor list empty after sort' }
            if (-not (Test-SortedBy @($ctl.MonList.Items) 'Cpu' $true)) { throw 'monitor rows not sorted by CPU' }
            if ([string]$ctl.MonList.View.Columns[2].Header -like '*↓' -or [string]$ctl.MonList.View.Columns[2].Header -like '*↑') { throw 'old arrow left on the memory header' }
            $L.Add(('  monitor by CPU: ' + (@($ctl.MonList.Items | Select-Object -First 3 | ForEach-Object { $_.Name + ' ' + $_.CpuText }) -join ', ')))
            Reset-ListSort 'MonList' 'Since' $true
            Stop-Monitor
            if ($ctl.BtnMonStop.IsEnabled -or -not $script:monShared.Stop) { throw 'monitor not stopped' }
            if (-not (& $waitUi { -not $script:bg['monitor'] } 15000)) { throw 'monitor thread did not end' }
            # 系统文件检查按钮只是起终端：不点，查它在不在
            if ($ctl.BtnSfcCheck.Visibility -ne 'Visible') { throw 'sfc check button hidden' }
        }
        & $step 'cleanup rows open their folders; drive cards scan; mode card lights up' {
            # 清理页：每一行都能找到要打开的位置（找不到的只能是没有固定位置的系统命令项）
            $withPaths = 0
            foreach ($it in $catalog) { $ps = @(Get-CleanOpenPaths $it); if ($ps.Count -gt 0) { $withPaths++ }; foreach ($p in $ps) { if ($p -notlike 'shell:*' -and -not (Test-Path -LiteralPath $p)) { throw "open path does not exist: $p" } } }
            if ($withPaths -lt 5) { throw "only $withPaths cleanup items have a folder to open" }
            $rb = @($catalog | Where-Object { $_.N -eq (T '清空回收站') })
            if ($rb.Count -and @(Get-CleanOpenPaths $rb[0]) -notcontains 'shell:RecycleBinFolder') { throw 'recycle bin has no location' }
            $script:uiOpened.Clear()
            $row = New-Object RowItem; $row.Idx = @($catalog | Where-Object { @(Get-CleanOpenPaths $_).Count -gt 0 })[0].Idx; $row.Name = 'x'
            Open-CleanRow $row $false
            if ($script:uiOpened.Count -ne 1) { throw ('double-click opened {0} locations' -f $script:uiOpened.Count) }
            # 空间地图：点盘卡片 = 选中并扫描
            Show-Page 'map'; $win.UpdateLayout()
            $cards = @($ctl.MapHealth.ItemsSource)
            if ($cards.Count -gt 0 -and $ctl.MapDrive.Items.Count -gt 0) {
                $script:uiOpened.Clear(); $saved = $script:mapRoot; $script:mapRoot = $null
                try { Select-MapDriveCard ([string]$cards[0].Letter) $true } finally { $script:mapRoot = $saved }
                if (-not ([string]$ctl.MapDrive.SelectedItem.Tag).StartsWith([string]$cards[0].Letter, [StringComparison]::OrdinalIgnoreCase)) { throw 'card click did not select the drive' }
                if (-not $script:worker -and @($script:uiOpened | Where-Object { $_ -like 'scan:*' }).Count -ne 1) { throw 'card click did not start a scan' }
                if (-not $cards[0].Sel) { throw 'selected card is not highlighted' }
            }
            # 模式标签：到设置页，「使用模式」卡片亮起来
            Show-ModeCard; $win.UpdateLayout()
            if ($ctl.PageSettings.Visibility -ne 'Visible') { throw 'mode tag did not open settings' }
            if ($ctl.SetCardMode.ReadLocalValue([System.Windows.Controls.Border]::BackgroundProperty) -eq [System.Windows.DependencyProperty]::UnsetValue) { throw 'mode card not highlighted' }
        }
        & $step 'health tabs, verdicts and repair steps' {
            Show-Page 'health'
            foreach ($k in @($script:healthTabs.Keys)) {
                $ctl[$script:healthTabs[$k][0]].IsChecked = $true; $win.UpdateLayout()
                foreach ($j in @($script:healthTabs.Keys)) { $want = if ($j -eq $k) { 'Visible' } else { 'Collapsed' }; if ($ctl[$script:healthTabs[$j][1]].Visibility -ne $want) { throw "tab ${k}: $j is not $want" } }
                if ($script:healthTab -ne $k) { throw "current tab is $($script:healthTab), not $k" }
                & $snap $ctl.PageHealth ('health-' + $k)
            }
            # 蓝屏和崩溃里的三个小选项卡：点哪个只显示哪个
            Select-HealthTab 'crash'
            foreach ($k in @($script:crashTabs.Keys)) {
                $ctl[$script:crashTabs[$k][0]].IsChecked = $true; $win.UpdateLayout()
                foreach ($j in @($script:crashTabs.Keys)) { $want = if ($j -eq $k) { 'Visible' } else { 'Collapsed' }; if ($ctl[$script:crashTabs[$j][1]].Visibility -ne $want) { throw "crash tab ${k}: $j is not $want" } }
                if ($k -ne 'verdict') { & $snap $ctl.PageHealth ('health-crash-' + $k) }
            }
            Select-CrashTab 'verdict'
            if ($ctl.HealthVerdicts.Items.Count -lt 1) { throw 'no verdict shown' }
            $L.Add(('  verdicts: ' + (@($ctl.HealthVerdicts.Items | ForEach-Object { $_.Title }) -join ' | ')))
            # 后台线程里算出来的文字也要跟着界面语言走
            if ($script:Lang -eq 'en' -and @(@($ctl.HealthVerdicts.Items) + @($ctl.HealthCards.Items) | Where-Object { ([string]$_.Title + [string]$_.Body + [string]$_.Sub) -match '[\u4e00-\u9fff]' }).Count -gt 0) { throw 'background health text is not translated' }
            if ($ctl.FixGroups.Items.Count -lt 8) { throw ('only {0} problem groups' -f $ctl.FixGroups.Items.Count) }
            # 只看的步骤直接运行（自测里只记下来，不开窗口）；会改动的先确认（自测里当作点了取消，所以不会运行）
            $script:uiFixRuns.Clear(); $n0 = $script:uiSheets.Count; $undo0 = Get-Setting 'PowerFixUndo' ''; $fs0 = Get-FastStartup
            foreach ($id in 'sfccheck', 'wureset', 'netreset', 'chkfix', 'sfcrepair', 'diskpower', 'faststartup') { Invoke-FixStep $id }
            if (-not $script:uiFixRuns.Contains('sfccheck')) { throw 'a check step did not run' }
            foreach ($id in 'wureset', 'netreset', 'chkfix', 'sfcrepair') { if ($script:uiFixRuns.Contains($id)) { throw "$id ran without confirmation" } }
            if ($script:uiSheets.Count -lt $n0 + 5) { throw ('changing steps did not all ask first ({0} sheets)' -f ($script:uiSheets.Count - $n0)) }
            if ((Get-Setting 'PowerFixUndo' '') -ne $undo0 -or (Get-FastStartup) -ne $fs0) { throw 'power settings changed without confirmation' }
            # 列表里的按钮点下去走同一套
            Select-HealthTab 'fix'; $script:uiFixRuns.Clear()
            # 左边选「时间不准」那个问题，右边只显示它的修法
            $tg = @(@($ctl.FixGroups.Items) | Where-Object { @($_.Steps | Where-Object { $_.Id -eq 'timecheck' }).Count -gt 0 })[0]
            if (-not $tg) { throw 'no problem group has the clock check' }
            $ctl.FixGroups.SelectedItem = $tg; $win.UpdateLayout()
            if (-not [object]::ReferenceEquals($ctl.FixDetail.Content, $tg)) { throw 'the detail pane does not show the selected problem' }
            $q = New-Object System.Collections.Queue; $q.Enqueue($ctl.FixDetail); $hit = $null
            while ($q.Count -gt 0 -and -not $hit) { $v = $q.Dequeue(); if ($v -is [System.Windows.Controls.Button] -and [string]$v.Tag -eq 'timecheck') { $hit = $v; break }; for ($i = 0; $i -lt [System.Windows.Media.VisualTreeHelper]::GetChildrenCount($v); $i++) { $q.Enqueue([System.Windows.Media.VisualTreeHelper]::GetChild($v, $i)) } }
            if (-not $hit) { throw 'repair button not found in the list' }
            & $click $hit
            if (-not $script:uiFixRuns.Contains('timecheck')) { throw 'clicking a repair button did nothing' }
            # 按建议处理：先把要做的列出来确认（自测里当作取消），所以什么都不改；硬盘驱动指南、厂商下载页只显示
            $fake = @{ Id = 'uitest'; Level = 'red'; Title = 'uitest'; Body = ''; Fixes = @(); Plan = @('diskpower', 'faststartup', 'datetime'); Todo = @('x') }
            $keepV = $script:healthData.Verdicts; $script:healthData.Verdicts = @($keepV) + @($fake); $n1 = $script:uiSheets.Count; $script:uiFixRuns.Clear()
            try { Invoke-RepairPlan 'uitest' } finally { $script:healthData.Verdicts = $keepV }
            if ($script:uiSheets.Count -ne $n1 + 1 -or $script:uiFixRuns.Count -ne 0) { throw 'fix-as-suggested did not ask first, or ran something' }
            if ((Get-Setting 'PowerFixUndo' '') -ne $undo0 -or (Get-FastStartup) -ne $fs0) { throw 'power settings changed by fix-as-suggested without confirmation' }
            Show-AhciGuide; Open-VendorPage
            if (-not @($script:uiFixRuns | Where-Object { $_ -like 'vendor:http*' }).Count) { throw 'vendor page has no link' }
            $L.Add(('  vendor: ' + @($script:uiFixRuns | Where-Object { $_ -like 'vendor:*' })[0]))
            # 报告文字
            $rep = Get-HealthReportText $script:healthData
            if ($rep.Length -lt 200 -or $rep -notmatch [regex]::Escape((T '诊断结论'))) { throw 'report text too short' }
            Select-HealthTab 'hw'
        }
        & $step 'list headers sort; cleanup tabs, action filter and sticky bar; filter, save and reminder tabs' {
            # 清理页：用假的大小排一个列表（不扫描），至少两类
            $sizes = @{}; $i = 0
            foreach ($it in @($catalog | Where-Object { -not $_.Lvl -or [int]$_.Lvl -le (Get-Mode) })) { $i++; $sizes[$it.Idx] = [double](($i * 7919) % 997 + 1) * 1MB }
            Show-Page 'clean'; Build-Rows $sizes; $win.UpdateLayout()
            $groups = @($script:cleanGroups.Order)
            if ($groups.Count -lt 2) { throw ('only {0} groups' -f $groups.Count) }
            if ($ctl.CleanTabs.Children.Count -ne $groups.Count) { throw ('{0} tabs for {1} groups' -f $ctl.CleanTabs.Children.Count, $groups.Count) }
            $bad = @(@($ctl.List.Items) | Where-Object { $_.GroupTitle -ne $groups[0] }).Count
            if ($ctl.List.Items.Count -lt 1 -or $bad -gt 0) { throw 'first tab does not show only the first group' }
            $ctl.CleanTabs.Children[1].IsChecked = $true; $win.UpdateLayout()
            if (@(@($ctl.List.Items) | Where-Object { $_.GroupTitle -ne $groups[1] }).Count -gt 0 -or $ctl.List.Items.Count -ne $script:cleanGroups.Cnt[$groups[1]]) { throw 'second tab does not show the second group' }
            # 表头「大小」：从大到小；只看「跳过」以后还是按大小排
            $bs = @(Find-Buttons $ctl.CleanHead | Where-Object { [string]$_.Tag -eq 'List|size' })[0]
            if (-not $bs) { throw 'size header button not found' }
            & $click $bs; $win.UpdateLayout()
            if (-not (Test-SortedBy @($ctl.List.Items) 'Bytes' $true)) { throw 'cleanup rows not sorted by size' }
            if ([string]$bs.Content -notlike '*↓') { throw 'no arrow on the size header' }
            # 下拉框只看某一种操作：用这一类第一行的操作
            $ctl.CleanTabs.Children[0].IsChecked = $true; $win.UpdateLayout()
            $op = [string]$ctl.List.Items[0].Action
            $opItem = @($ctl.CleanOpFilter.Items | Where-Object { [string]$_.Tag -eq $op })[0]
            if (-not $opItem) { throw ('no filter entry for "{0}"' -f $op) }
            $ctl.CleanOpFilter.SelectedItem = $opItem; $win.UpdateLayout()
            $n = $ctl.List.Items.Count
            $want = @($script:rows | Where-Object { $_.GroupTitle -eq $groups[0] -and $_.Action -eq $op }).Count
            if ($n -ne $want -or @(@($ctl.List.Items) | Where-Object { $_.Action -ne $op -or $_.GroupTitle -ne $groups[0] }).Count -gt 0) { throw ('action filter shows {0} rows, expected {1}' -f $n, $want) }
            if (-not (Test-SortedBy @($ctl.List.Items) 'Bytes' $true)) { throw 'action filter lost the sort order' }
            $L.Add(('  cleanup: {0} groups; "{1}" filtered to "{2}" shows {3} rows, still largest first' -f $groups.Count, $groups[0], $op, $n))
            $ctl.CleanOpFilter.SelectedIndex = 0; $win.UpdateLayout()
            if ($ctl.List.Items.Count -ne $script:cleanGroups.Cnt[$groups[0]]) { throw 'all actions does not show the whole group again' }
            # 「名称」：A 到 Z；再点两下回到本来的顺序
            $bn = @(Find-Buttons $ctl.CleanHead | Where-Object { [string]$_.Tag -eq 'List|name' })[0]
            & $click $bn; if (-not (Test-SortedBy @($ctl.List.Items) 'Name' $false)) { throw 'cleanup rows not sorted by name' }
            & $click $bn; & $click $bn
            if ($script:sortCfg.List.Prop) { throw 'third click did not go back to the original order' }
            # 选项卡和表头：往下滚以后停在顶上（列表要够长才滚得动）
            $ctl.CleanScroll.ScrollToTop(); $win.UpdateLayout(); [void](& $waitUi { $false } 150)
            $y0 = (Get-CleanSlotPos).Y; $t0 = $ctl.CleanBar.Margin.Top
            if ([math]::Abs($y0 - $t0) -gt 1) { throw ('bar is not over its slot at the top: slot {0}, bar {1}' -f $y0, $t0) }
            & $snap $ctl.PageClean 'clean-tabs'
            if ($ctl.CleanScroll.ScrollableHeight -gt $y0 + 20) {
                $ctl.CleanScroll.ScrollToVerticalOffset($y0 + 200); $win.UpdateLayout(); [void](& $waitUi { $false } 150)
                $p = Get-CleanSlotPos
                if ($p.Y -ge 0 -or [math]::Abs($ctl.CleanBar.Margin.Top) -gt 0.5) { throw ('bar did not stick: slot {0}, bar {1}' -f $p.Y, $ctl.CleanBar.Margin.Top) }
                $L.Add(('  sticky bar: slot at {0:N0}, scrolled to {1:N0}, bar stays at {2:N0}, {3:N0} px tall' -f $y0, $ctl.CleanScroll.VerticalOffset, $ctl.CleanBar.Margin.Top, $ctl.CleanBar.ActualHeight))
                & $snap $ctl.PageClean 'clean-sticky'
                # 停在顶上时换类：列表从头显示
                $ctl.CleanTabs.Children[1].IsChecked = $true; $win.UpdateLayout()
                $p = Get-CleanSlotPos
                if ([math]::Abs($p.Y) -gt 1.5 -and $ctl.CleanScroll.VerticalOffset -lt $ctl.CleanScroll.ScrollableHeight - 1) { throw ('switching tabs while stuck did not show the list from the top: slot at {0}' -f $p.Y) }
            } else { $L.Add(('  sticky bar: page not tall enough to scroll ({0:N0})' -f $ctl.CleanScroll.ScrollableHeight)) }
            $script:rows = $null; $script:cleanOp = ''; $ctl.List.ItemsSource = $null; Update-CleanOverview
            if ($ctl.CleanBar.Visibility -ne 'Collapsed') { throw 'tabs still shown without rows' }
            # 重复文件：查找条件的选项卡，开始查找时收起
            Show-Page 'dup'
            Set-DupFilterOpen $true 'type'; $win.UpdateLayout()
            if ($ctl.DPaneType.Visibility -ne 'Visible' -or $ctl.DPaneRoots.Visibility -ne 'Collapsed' -or -not $ctl.DTabType.IsChecked) { throw 'file type tab not shown' }
            Set-DupFilterOpen $false
            if ($ctl.DupFilterBody.Visibility -ne 'Collapsed' -or $ctl.DTabType.IsChecked) { throw 'filter options did not fold' }
            $ctl.DTabSize.IsChecked = $true
            if ($ctl.DupFilterBody.Visibility -ne 'Visible' -or $ctl.DPaneSize.Visibility -ne 'Visible') { throw 'clicking a folded tab did not open it' }
            if (-not $ctl.DTabRootsVal.Text -or -not $ctl.DTabTypeVal.Text -or -not $ctl.DTabSizeVal.Text -or -not $ctl.DTabModeVal.Text) { throw 'tab values empty' }
            $L.Add(('  duplicate options: {0} | {1} | {2} | {3}' -f $ctl.DTabRootsVal.Text, $ctl.DTabTypeVal.Text, $ctl.DTabSizeVal.Text, $ctl.DTabModeVal.Text))
            & $snap $ctl.PageDup 'dup-tabs'
            Set-DupFilterOpen $true 'roots'
            # 省空间：左边目录点哪项，右边只显示那一项
            Show-Page 'save'
            foreach ($g in $script:saveGroups.Keys) { foreach ($k in $script:saveGroups[$g]) {
                if ($ctl['SaveNav' + $k].Visibility -ne 'Visible') { continue }
                $ctl['SaveNav' + $k].IsChecked = $true
                $shown = @(foreach ($g2 in $script:saveGroups.Keys) { foreach ($x in $script:saveGroups[$g2]) { if ($ctl['SaveCard' + $x].Visibility -eq 'Visible') { $x } } })
                if ($shown.Count -ne 1 -or $shown[0] -ne $k) { throw ("save nav ${k}: shows " + ($shown -join ',')) }
            } }
            $ctl.SaveNavPf.IsChecked = $true; & $snap $ctl.PageSave 'save-nav'
            # 自动提醒：三个选项卡
            Show-Page 'auto'
            foreach ($k in @($script:autoTabs.Keys)) {
                $ctl[$script:autoTabs[$k][0]].IsChecked = $true
                foreach ($j in @($script:autoTabs.Keys)) { $want = if ($j -eq $k) { 'Visible' } else { 'Collapsed' }; if ($ctl[$script:autoTabs[$j][1]].Visibility -ne $want) { throw "auto tab ${k}: $j is not $want" } }
            }
            Select-AutoTab 'remind'
            # 操作日志：点「时间」从早到晚，再点一下从晚到早
            Show-Page 'log'; $win.UpdateLayout()
            if ($ctl.LogList.Items.Count -gt 1) {
                $hd = Find-GridHead $ctl.LogList 0; if (-not $hd) { throw 'log time header not found' }
                $was = $script:sortCfg.LogList.Desc
                & $click $hd
                if ($script:sortCfg.LogList.Desc -eq $was -or -not (Test-SortedBy @($ctl.LogList.Items) 'When' $script:sortCfg.LogList.Desc)) { throw 'log not re-sorted by time' }
                Reset-ListSort 'LogList' 'When' $true
                if (-not (Test-SortedBy @($ctl.LogList.Items) 'When' $true)) { throw 'log not back to newest first' }
            }
        }
        & $step 'apps: tick several, uninstall one after another, disable or recycle several at once' {
            # 假的软件列表：两个只有卸载命令的软件（自测里卸载程序不真的打开）
            $fake = @(
                @{ Name = 'ClearC UiTest A'; Publisher = 'Test'; Version = '1'; Location = ''; Uninstall = 'cmd.exe /c exit'; Kind = 'win32'; Package = ''; Size = 3MB; Measured = $true; Date = '20240101'; LocReg = $false },
                @{ Name = 'ClearC UiTest B'; Publisher = 'Test'; Version = '1'; Location = ''; Uninstall = 'cmd.exe /c exit'; Kind = 'win32'; Package = ''; Size = 2MB; Measured = $true; Date = '20240102'; LocReg = $false },
                @{ Name = 'ClearC UiTest C'; Publisher = 'Test'; Version = '1'; Location = ''; Uninstall = 'cmd.exe /c exit'; Kind = 'win32'; Package = ''; Size = 1MB; Measured = $true; Date = '20240103'; LocReg = $false })
            $keepRows = $script:appRows
            try {
                $script:pageLoaded.apps = $true; Show-Page 'apps'; $ctl.AppsViewApps.IsChecked = $true
                Build-AppRows $fake; $win.UpdateLayout()
                $rows = @($ctl.AppsList.Items)
                if ($rows.Count -ne 3) { throw ('{0} app rows' -f $rows.Count) }
                $rows[0].Picked = $true; $rows[2].Picked = $true; Update-PickBar
                if ($ctl.AppsPickBar.Visibility -ne 'Visible' -or $ctl.BtnPickUninstall.Visibility -ne 'Visible' -or $null -ne $ctl.AppsPickAll.IsChecked) { throw 'pick bar not shown for two ticked apps' }
                $L.Add(('  apps picked: ' + $ctl.AppsPickText.Text))
                # 全选、全部取消
                $ctl.AppsPickAll.IsChecked = $true; & $click $ctl.AppsPickAll
                if (@($rows | Where-Object { $_.Picked }).Count -ne 3) { throw 'select all did not tick every app' }
                $ctl.AppsPickAll.IsChecked = $false; & $click $ctl.AppsPickAll
                if (@($rows | Where-Object { $_.Picked }).Count -ne 0 -or $ctl.AppsPickBar.Visibility -ne 'Collapsed') { throw 'untick all left something ticked' }
                # 卸载：先列出来确认（自测里当作取消），所以什么都不打开
                $rows[0].Picked = $true; $rows[1].Picked = $true
                $n0 = $script:uiSheets.Count; $script:uiFixRuns.Clear()
                Start-BatchUninstall
                if ($script:uiSheets.Count -ne $n0 + 1 -or $script:uq -or @($script:uiFixRuns | Where-Object { $_ -like 'uninstall:*' }).Count) { throw 'batch uninstall did not ask first, or started anyway' }
                # 排队：一个走完才开下一个，走完收尾
                $script:uq = @{ Win32 = @($rows[0], $rows[1]); I = -1; Proc = $null; At = (Get-Date); ExitAt = $null; Done = 0; Fail = (New-Object System.Collections.ArrayList); Stop = $false; Total = 2 }
                Step-UninstQueue
                if (@($script:uiFixRuns) -join '|' -ne ('uninstall:' + $rows[0].Name) -or $ctl.AppsBatchBox.Visibility -ne 'Visible') { throw ('first uninstaller: ' + (@($script:uiFixRuns) -join '|')) }
                Step-UninstQueue; Step-UninstQueue
                if (@($script:uiFixRuns) -join '|' -ne ('uninstall:' + $rows[0].Name + '|uninstall:' + $rows[1].Name) -or $script:uq -or $ctl.AppsBatchBox.Visibility -ne 'Collapsed') { throw ('queue order: ' + (@($script:uiFixRuns) -join '|')) }
                if (@($rows | Where-Object { $_.Picked }).Count -ne 0) { throw 'ticks left after the batch' }
            } finally { $script:uq = $null; $script:uqTimer.Stop(); $script:appRows = $keepRows; $ctl.AppsList.ItemsSource = $null; $ctl.AppsBatchBox.Visibility = 'Collapsed' }
            # 开机启动：一次禁用几个也先确认
            $ap = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run'
            $sr = @(foreach ($i in 1..2) { $r = New-Object StartRow; $r.Kind = 'startup'; $r.Name = "ClearC UiTest $i"; $r.Key1 = $ap; $r.Key2 = "ClearC-UiTest-$i"; $r.Enabled = $true; $r.Open = ''; $r })
            $script:startRows['startup'] = New-Object System.Collections.Generic.List[StartRow]; foreach ($r in $sr) { $script:startRows['startup'].Add($r) }
            $ctl.AppsViewStartup.IsChecked = $true; $win.UpdateLayout()
            foreach ($r in $sr) { $r.Picked = $true }; Update-PickBar
            if ($ctl.BtnPickDisable.Visibility -ne 'Visible' -or -not $ctl.BtnPickDisable.IsEnabled -or $ctl.BtnPickEnable.IsEnabled) { throw 'disable / enable buttons wrong for two enabled items' }
            $n0 = $script:uiSheets.Count; Start-BatchToggle $false
            if ($script:uiSheets.Count -ne $n0 + 1 -or @($sr | Where-Object { -not $_.Enabled }).Count) { throw 'batch disable did not ask first, or changed something' }
            # 残留文件夹：一次移到回收站几个，也先确认
            $lr = @(foreach ($i in 1..2) { $r = New-Object StartRow; $r.Kind = 'leftover'; $r.Name = "leftover $i"; $r.Detail = (Join-Path ([IO.Path]::GetTempPath()) "clearc-uitest-left-$i"); $r.Key2 = '1048576'; $r.Size = '1 MB'; $r.Open = ''; $r })
            $script:startRows['leftover'] = New-Object System.Collections.Generic.List[StartRow]; foreach ($r in $lr) { $script:startRows['leftover'].Add($r) }
            $ctl.AppsViewLeft.IsChecked = $true; $win.UpdateLayout()
            foreach ($r in $lr) { $r.Picked = $true }; Update-PickBar
            if ($ctl.BtnPickRecycle.Visibility -ne 'Visible') { throw 'recycle button not shown for leftovers' }
            $n0 = $script:uiSheets.Count; Start-BatchLeftover
            if ($script:uiSheets.Count -ne $n0 + 1 -or $script:worker) { throw 'batch recycle did not ask first, or started anyway' }
            $script:startRows.Clear(); $ctl.StartList.ItemsSource = $null; $ctl.AppsViewApps.IsChecked = $true; Update-PickBar
        }
        & $step 'settings and moves have a contents list; tree items are indented' {
            Show-Page 'settings'
            foreach ($g in $script:setGroups.Keys) { foreach ($k in $script:setGroups[$g]) {
                if ($ctl['SetNav' + $k].Visibility -ne 'Visible') { continue }
                $ctl['SetNav' + $k].IsChecked = $true
                $shown = @(foreach ($x in $script:setCards.Keys) { if ($ctl[$script:setCards[$x]].Visibility -eq 'Visible') { $x } })
                if ($shown.Count -ne 1 -or $shown[0] -ne $k) { throw ("settings nav ${k}: shows " + ($shown -join ',')) }
            } }
            & $snap $ctl.PageSettings 'settings-nav'
            Show-ModeCard
            if ($ctl.SetCardMode.Visibility -ne 'Visible' -or -not $ctl.SetNavMode.IsChecked) { throw 'mode tag did not open the mode section' }
            # 不打开搬家管理页（一打开就会在后台统计），只点目录
            $ctl.MNavApp.IsChecked = $true
            if ($script:candGroup -ne 'app' -or $script:movesTab -ne 'cand') { throw 'moves nav did not pick the app group' }
            if ($script:candRows) { if (@(@($ctl.CandList.Items) | Where-Object { $_.Group -ne 'app' }).Count) { throw 'other groups still listed' } }
            $ctl.MovesTabDone.IsChecked = $true
            if ($ctl.MovesCard.Visibility -ne 'Visible') { throw 'moved list not shown' }
            $ctl.MovesTabCand.IsChecked = $true
            if ($script:candGroup -ne '') { throw 'all candidates not back' }
        }
        & $step 'space map: back and forward, clickable path, delete list, worth a look, colours by kind' {
            $d = Join-Path ([IO.Path]::GetTempPath()) ('clearc-uitest-map-' + [guid]::NewGuid().ToString('N').Substring(0, 6))
            New-Item -ItemType Directory -Force -Path "$d\a\.git", "$d\b\node_modules\x" | Out-Null
            [IO.File]::WriteAllText("$d\a\f1.bin", ('x' * 3000)); [IO.File]::WriteAllText("$d\b\node_modules\x\m.js", ('y' * 5000)); [IO.File]::WriteAllText("$d\b\keep.txt", 'z')
            $keepRoot = $script:mapRoot; $keepCur = $script:mapCur
            try {
                $t2 = [DiskMap]::Scan($d, 2); [DiskMap]::Use($t2); $script:mapRoot = $t2; $script:mapCur = $t2; Reset-MapHistory
                Show-Page 'map'; $ctl.MapViewDirs.IsChecked = $true; Show-MapLevel $t2; $win.UpdateLayout()
                if ($ctl.MapCrumbs.Visibility -ne 'Visible' -or $ctl.MapCrumbs.Children.Count -lt 1) { throw 'no clickable path' }
                $nb = [DiskMap]::Find($t2, "$d\b"); $nn = [DiskMap]::Find($t2, "$d\b\node_modules")
                Show-MapLevel $nb; Show-MapLevel $nn
                Move-MapHistory -1; if (-not [object]::ReferenceEquals($script:mapCur, $nb)) { throw 'back did not return to b' }
                Move-MapHistory -1; if (-not [object]::ReferenceEquals($script:mapCur, $t2)) { throw 'back did not return to the top' }
                Move-MapHistory 1; if (-not [object]::ReferenceEquals($script:mapCur, $nb) -or -not $ctl.BtnMapFwd.IsEnabled) { throw 'forward did not go to b' }
                $cb = @($ctl.MapCrumbs.Children | Where-Object { $_ -is [System.Windows.Controls.Button] })[0]
                & $click $cb; if (-not [object]::ReferenceEquals($script:mapCur, $t2)) { throw 'clicking the path did not go up' }
                $hits = @([DiskMap]::Named($t2, [string[]]$script:worthNames, 1, 10))
                if (-not @($hits | Where-Object { $_.Name -eq 'node_modules' }).Count) { throw 'worth-a-look did not find node_modules' }
                # 待删清单：放进 a；再放 b 里面的 node_modules；再放 b，node_modules 合进 b
                $ra = @($ctl.MapList.Items | Where-Object { $_.Name -eq 'a' })[0]
                [void](Add-MapMarks @($ra))
                if ($script:mapMarks.Count -ne 1 -or -not $ra.Marked -or $ctl.MapMarkBar.Visibility -ne 'Visible') { throw 'mark a failed' }
                Show-MapLevel $nb; $rn = @($ctl.MapList.Items | Where-Object { $_.Name -eq 'node_modules' })[0]; [void](Add-MapMarks @($rn))
                Show-MapLevel $t2; $rb = @($ctl.MapList.Items | Where-Object { $_.Name -eq 'b' })[0]; [void](Add-MapMarks @($rb))
                if ($script:mapMarks.Count -ne 2 -or $script:mapMarks.Contains((Get-MarkKey $rn))) { throw ('marks: ' + (@($script:mapMarks.Keys) -join ', ')) }
                if (-not @($ctl.MapList.Items | Where-Object { $_.Name -eq 'a' })[0].Marked) { throw 'marked row not flagged after coming back' }
                $L.Add(('  delete list: ' + $ctl.MapMarkText.Text))
                $n0 = $script:uiSheets.Count; Start-MapDelete @($script:mapMarks.Values)
                if ($script:uiSheets.Count -ne $n0 + 1 -or $script:worker) { throw 'deleting the list did not ask first' }
                if ($script:uiSheets[$script:uiSheets.Count - 1] -notmatch 'git') { throw 'no warning about the git checkout' }
                Clear-MapMarks
                if ($ctl.MapMarkBar.Visibility -ne 'Collapsed' -or $ra.Marked -or @($ctl.MapList.Items | Where-Object { $_.Marked }).Count) { throw 'clear left marks' }
                # 方块图：按类型上色，下面有图例
                $ctl.MapViewTree.IsChecked = $true; $win.UpdateLayout(); Draw-MapTree
                if ($ctl.MapTreeLegend.Children.Count -lt 1) { throw 'no treemap legend' }
                $ctl.MapViewDirs.IsChecked = $true
            } finally {
                Clear-MapMarks; Reset-MapHistory
                $script:mapRoot = $keepRoot; $script:mapCur = $keepCur; if ($keepRoot) { [DiskMap]::Use($keepRoot) }
                Remove-Item -LiteralPath $d -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
        & $step 'similar photos and keep rules' {
            if (-not ('PhotoHash' -as [type])) { throw 'PhotoHash did not compile' }
            # 放在临时文件夹里：本工具自己的文件夹（appDir）在重复文件里是删不得的，勾不上
            $d = Join-Path ([IO.Path]::GetTempPath()) ('clearc-uitest-photos-' + [guid]::NewGuid().ToString('N').Substring(0, 6)); New-Item -ItemType Directory -Path "$d\sub" -Force | Out-Null
            # 画三张图：渐变图、它的缩小版（相似）、另一张方格图（不相似）
            $draw = { param([string]$file, [int]$w, [int]$h, [bool]$checker)
                $dv = New-Object System.Windows.Media.DrawingVisual
                $dc = $dv.RenderOpen()
                if ($checker) { for ($x = 0; $x -lt 8; $x++) { for ($y = 0; $y -lt 8; $y++) { $c = if (($x + $y) % 2 -eq 0) { [System.Windows.Media.Brushes]::Black } else { [System.Windows.Media.Brushes]::White }; $dc.DrawRectangle($c, $null, (New-Object System.Windows.Rect ($x * $w / 8), ($y * $h / 8), ($w / 8), ($h / 8))) } } }
                else { $br = New-Object System.Windows.Media.LinearGradientBrush ([System.Windows.Media.Colors]::Black), ([System.Windows.Media.Colors]::White), 0; $dc.DrawRectangle($br, $null, (New-Object System.Windows.Rect 0, 0, $w, $h)); $dc.DrawEllipse([System.Windows.Media.Brushes]::Red, $null, (New-Object System.Windows.Point ($w * 0.3), ($h * 0.6)), ($w * 0.15), ($h * 0.15)) }
                $dc.Close()
                $rt = New-Object System.Windows.Media.Imaging.RenderTargetBitmap $w, $h, 96, 96, ([System.Windows.Media.PixelFormats]::Pbgra32); $rt.Render($dv)
                $enc = New-Object System.Windows.Media.Imaging.PngBitmapEncoder; $enc.Frames.Add([System.Windows.Media.Imaging.BitmapFrame]::Create($rt))
                $fs = [IO.File]::Create($file); try { $enc.Save($fs) } finally { $fs.Dispose() }
            }
            & $draw "$d\a.png" 640 480 $false; & $draw "$d\sub\a-small.png" 160 120 $false; & $draw "$d\other.png" 640 480 $true
            try {
                $w1 = 0; $h1 = 0; $ha = [PhotoHash]::Hash("$d\a.png", [ref]$w1, [ref]$h1); $hb = [PhotoHash]::Hash("$d\sub\a-small.png", [ref]$w1, [ref]$h1); $hc = [PhotoHash]::Hash("$d\other.png", [ref]$w1, [ref]$h1)
                $dab = [PhotoHash]::Dist($ha, $hb); $dac = [PhotoHash]::Dist($ha, $hc)
                $L.Add(("photo hash: a~small {0} bits, a~other {1} bits" -f $dab, $dac))
                if ($dab -gt 6 -or $dac -lt 12) { throw ("hash distances a~small {0}, a~other {1}" -f $dab, $dac) }
                $list = [PhotoHash]::Scan([string[]]@($d), 1, 0, 1000); [PhotoHash]::HashAll($list)
                if ($list.Count -ne 3) { throw ("scan found {0} photos" -f $list.Count) }
                $ng = [PhotoHash]::Group($list, 8)
                $byG = @{}; foreach ($p in $list) { $byG[$p.Group] = [int]$byG[$p.Group] + 1 }
                if (@($byG.Values | Where-Object { $_ -eq 2 }).Count -ne 1 -or $ng -ne 2) { throw ("groups: {0}" -f (($list | ForEach-Object { $_.Path + '=' + $_.Group }) -join ', ')) }
                # 走一遍真正的查找（后台线程）
                Show-Page 'dup'; $ctl.ModeSimilar.IsChecked = $true
                if ($ctl.SimilarRow.Visibility -ne 'Visible') { throw 'similarity row hidden' }
                Start-SimilarScan @($d) @{ Ok = $true; Min = 1; Max = 0 }
                if (-not (& $waitUi { -not $script:worker } 60000)) { throw 'similar scan did not finish' }
                if (-not $script:dupRows -or $script:dupRows.Count -ne 2 -or -not $script:dupSimilar) { throw ("similar rows: {0}" -f $(if ($script:dupRows) { $script:dupRows.Count } else { 0 })) }
                if (@($script:dupRows | Where-Object { $_.ToDelete }).Count -ne 0) { throw 'similar photos were auto-checked' }
                if ($script:dupRows[0].Path -ne "$d\a.png" -or -not $script:dupRows[0].HasRisk) { throw 'largest photo not first, or no note' }
                # 留法：路径最短的、某个文件夹里的
                Pick-Dup 'short'
                if (-not $script:dupRows[1].ToDelete -or $script:dupRows[0].ToDelete) { throw 'keep shortest path wrong' }
                $script:keepInDir = "$d\sub\"; Pick-Dup 'in'
                if (-not $script:dupRows[0].ToDelete -or $script:dupRows[1].ToDelete) { throw 'keep in folder wrong' }
                $script:keepInDir = ''
                # 相似照片：不能合并，永久删除会被改成回收站
                $n0 = $script:uiSheets.Count; & $click $ctl.BtnDupMerge
                if ($script:uiSheets.Count -le $n0) { throw 'merge of similar photos not refused' }
                $ctl.DupRecycle.IsChecked = $false; $n0 = $script:uiSheets.Count; & $click $ctl.BtnDupDelete
                if (-not $ctl.DupRecycle.IsChecked -or $script:uiSheets.Count -lt $n0 + 2) { throw 'delete of similar photos did not force the recycle bin' }
                if ($script:worker) { throw 'delete started although the dialog was cancelled' }
                $ctl.DupRecycle.IsChecked = $true
            } finally { $ctl.ModeName.IsChecked = $true; $script:dupRows = $null; $script:dupByGroup = @{}; $script:dupSimilar = $false; $ctl.DupList.ItemsSource = $null; Remove-Item -LiteralPath $d -Recurse -Force -ErrorAction SilentlyContinue }
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
        & $step 'with check boxes only the box selects' {
            $lv = $ctl.MapList; $lv.UnselectAll(); $win.UpdateLayout()
            if ($lv.Items.Count -lt 8) { throw 'too few rows' }
            if (-not (Test-CheckMode)) { throw 'check box mode is off' }
            $p = Invoke-RowPress 3 'Left' $false $false
            if (-not $p.Handled -or $lv.SelectedItems.Count -ne 0) { throw 'a click on a row (not the box) would select it' }
            foreach ($q in 0, 2) {
                $k = Find-Visual ($lv.ItemContainerGenerator.ContainerFromIndex($q)) ([System.Windows.Controls.CheckBox])
                $k.IsChecked = $true; $k.RaiseEvent((New-Object System.Windows.RoutedEventArgs ([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
            }
            $p = Invoke-RowPress 4 'Left' $false $false
            if (-not $p.Handled -or $lv.SelectedItems.Count -ne 2) { throw ("clicking a row after ticking: {0} selected, expected the 2 ticked" -f $lv.SelectedItems.Count) }
            $p = Invoke-RowPress 5 'Right' $false $false
            if (-not $p.Handled -or $lv.SelectedItems.Count -ne 2) { throw 'a right click selected the row' }
            $script:menuRow = $lv.Items[5]
            if (-not (Update-MapMenu) -or @($script:menuRows).Count -ne 1 -or -not [object]::ReferenceEquals(@($script:menuRows)[0], $lv.Items[5])) { throw 'the menu is not for the right-clicked row only' }
            $script:menuRow = $lv.Items[2]; [void](Update-MapMenu)
            if (@($script:menuRows).Count -ne 2) { throw 'the menu on a ticked row is not for all ticked rows' }
            $script:menuRow = $null
            $p = Invoke-RowPress 6 'Left' $true $false
            if ($lv.SelectedItems.Count -ne 6) { throw ("shift-click: {0} selected, expected 6" -f $lv.SelectedItems.Count) }
            $p = Invoke-RowPress 7 'Left' $false $false
            if (-not $p.Add -or $p.NoDrag) { throw 'dragging from a row would not add to the ticks' }
            Refresh-MapRows; $win.UpdateLayout()
            if ($lv.SelectedItems.Count -ne 6) { throw ("refreshing the list kept {0} of 6" -f $lv.SelectedItems.Count) }
            $src = [System.Windows.PresentationSource]::FromVisual($lv)
            if ($src) {
                $ka = New-Object System.Windows.Input.KeyEventArgs ([System.Windows.Input.Keyboard]::PrimaryDevice), $src, 0, ([System.Windows.Input.Key]::Escape)
                $ka.RoutedEvent = [System.Windows.Input.Keyboard]::PreviewKeyDownEvent
                $lv.RaiseEvent($ka)
                if ($lv.SelectedItems.Count -ne 0) { throw 'Esc did not clear the ticks' }
            }
        }
        & $step 'real mouse: click, double-click, check box' {
            # 用真的鼠标点（SetCursorPos + mouse_event）。窗口先挪到屏幕上、放在最前面；这台机器收不到模拟的鼠标就跳过
            if (-not ('UiInput' -as [type])) { Add-Type -TypeDefinition 'using System; using System.Runtime.InteropServices; public static class UiInput { [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y); [DllImport("user32.dll")] public static extern void mouse_event(uint f, uint dx, uint dy, uint d, UIntPtr e); }' }
            $pump = { param([int]$ms) $sw = [Diagnostics.Stopwatch]::StartNew(); while ($sw.ElapsedMilliseconds -lt $ms) { $f = New-Object System.Windows.Threading.DispatcherFrame; [void]$win.Dispatcher.BeginInvoke([Action]{ $f.Continue = $false }, [System.Windows.Threading.DispatcherPriority]::Background); [System.Windows.Threading.Dispatcher]::PushFrame($f); Start-Sleep -Milliseconds 15 } }
            $at = { param($el, [int]$times)
                $pt = $el.PointToScreen((New-Object System.Windows.Point ([double]$el.ActualWidth / 2), ([double]$el.ActualHeight / 2)))
                [void][UiInput]::SetCursorPos([int]$pt.X, [int]$pt.Y); Start-Sleep -Milliseconds 80; & $pump 120
                for ($q = 0; $q -lt $times; $q++) { [UiInput]::mouse_event(2, 0, 0, 0, [UIntPtr]::Zero); Start-Sleep -Milliseconds 25; [UiInput]::mouse_event(4, 0, 0, 0, [UIntPtr]::Zero); Start-Sleep -Milliseconds 40 }
                & $pump 500
            }
            $lv = $ctl.MapList
            $x0 = $win.Left; $y0 = $win.Top
            try {
                $win.Left = 0; $win.Top = 0; $win.Topmost = $true; $win.Activate() | Out-Null; & $pump 400
                Show-MapLevel $tree; $lv.UnselectAll(); $win.UpdateLayout(); & $pump 200
                $k0 = Find-Visual ($lv.ItemContainerGenerator.ContainerFromIndex(0)) ([System.Windows.Controls.CheckBox])
                & $at $k0 1
                if ($lv.SelectedItems.Count -ne 1) { $L.Add('       (real mouse input does not reach the window on this machine; skipped)'); return }
                if (-not $k0.IsMouseOver) { throw 'the pointer on the check box is not seen as over it' }
                $t1 = Find-Visual ($lv.ItemContainerGenerator.ContainerFromIndex(1)) ([System.Windows.Controls.TextBlock])
                & $at $t1 1
                if ($lv.SelectedItems.Count -ne 1) { throw ("a click on a row's name changed the selection to {0}" -f $lv.SelectedItems.Count) }
                & $at $k0 2
                if ($lv.SelectedItems.Count -ne 1 -or -not [object]::ReferenceEquals($script:mapCur, $tree)) { throw 'a double click on the check box did something else than tick twice' }
                $di = -1; for ($q = 0; $q -lt $lv.Items.Count; $q++) { $r = $lv.Items[$q]; if ($r.IsDir -and $r.Node) { $di = $q; break } }
                if ($di -lt 0) { throw 'no folder row to double-click' }
                $lv.ScrollIntoView($lv.Items[$di]); $win.UpdateLayout(); & $pump 200
                $want = $lv.Items[$di].Node
                $td = Find-Visual ($lv.ItemContainerGenerator.ContainerFromIndex($di)) ([System.Windows.Controls.TextBlock])
                & $at $td 2
                if (-not [object]::ReferenceEquals($script:mapCur, $want)) { throw ("double-click did not open the folder (now at {0})" -f $script:mapCur.FullPath()) }
                # 关掉复选框再试一次：单击选中，双击照样进
                Show-MapLevel $tree; $win.Resources['MapCkVis'] = [System.Windows.Visibility]::Collapsed; $lv.UnselectAll(); $win.UpdateLayout(); & $pump 200
                $t1 = Find-Visual ($lv.ItemContainerGenerator.ContainerFromIndex(1)) ([System.Windows.Controls.TextBlock])
                & $at $t1 1
                if ($lv.SelectedItems.Count -ne 1) { throw 'without check boxes a click does not select the row' }
                $lv.ScrollIntoView($lv.Items[$di]); $win.UpdateLayout(); & $pump 200
                $td = Find-Visual ($lv.ItemContainerGenerator.ContainerFromIndex($di)) ([System.Windows.Controls.TextBlock])
                & $at $td 2
                if (-not [object]::ReferenceEquals($script:mapCur, $want)) { throw 'without check boxes double-click did not open the folder' }
            } finally {
                $win.Resources['MapCkVis'] = [System.Windows.Visibility]::Visible
                $win.Topmost = $false; $win.Left = $x0; $win.Top = $y0
                Show-MapLevel $tree; $lv.UnselectAll(); $win.UpdateLayout()
            }
        }
        & $step 'select all' {
            $lv = $ctl.MapList
            & $click $ctl.MapAll; if ($lv.SelectedItems.Count -ne $lv.Items.Count -or $ctl.MapAll.IsChecked -ne $true) { throw 'not all selected' }
            & $click $ctl.MapAll; if ($lv.SelectedItems.Count -ne 0 -or $ctl.MapAll.IsChecked -ne $false) { throw 'not all cleared' }
        }
        & $step 'left and right drag select a run of rows' {
            $lv = $ctl.MapList; $n = $lv.Items.Count; $win.UpdateLayout()   # 列表刚换过内容：先排好版，行才生成出来
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
            $lv = $ctl.MapList; $lv.UnselectAll(); $script:menuRow = $null
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
        & $step 'file types view' {
            $ctl.MapViewTypes.IsChecked = $true; $win.UpdateLayout()
            if ($ctl.MapList.Items.Count -lt 1) { throw 'no type rows' }
            $sum = [long]0; foreach ($r in $ctl.MapList.Items) { $sum += $r.FileCount }
            if ($sum -ne $tree.Files) { throw ("type counts {0} != files {1}" -f $sum, $tree.Files) }
            $first = $ctl.MapList.Items[0]
            if (-not (Enter-MapRow $first)) { throw 'type row does not open the file search' }
            if (-not $ctl.MapViewFiles.IsChecked -or [string]$ctl.MapType.SelectedItem.Tag -ne ([string]$first.Path).Substring(5)) { throw 'file search not set to that type' }
            if ($ctl.MapOwner.Items.Count -lt 2 -and $ctl.MapList.Items.Count -gt 0) { throw 'no owners listed' }
            $ctl.MapSort.SelectedIndex = 1; $win.UpdateLayout()
            if ($ctl.MapList.Items.Count -gt 1 -and [string]$ctl.MapList.Items[0].When -lt [string]$ctl.MapList.Items[1].When) { throw 'not sorted by date' }
            $ctl.MapSort.SelectedIndex = 0; $ctl.MapType.SelectedIndex = 0
        }
        & $step 'treemap and list are linked' {
            $ctl.MapViewDirs.IsChecked = $true; Show-MapLevel $tree
            $ctl.MapViewTree.IsChecked = $true; $win.UpdateLayout(); [void](& $waitUi { $ctl.MapTree.Children.Count -gt 0 } 3000)
            if ($ctl.MapList.Visibility -ne 'Visible' -or $ctl.MapTree.Children.Count -lt 1) { throw 'treemap without the list' }
            $row = $ctl.MapList.Items[0]
            $ctl.MapList.SelectedItems.Clear(); $ctl.MapList.SelectedItem = $row; $win.UpdateLayout()
            $blk = $null; foreach ($b in $ctl.MapTree.Children) { if ([object]::ReferenceEquals($b.Tag, $row)) { $blk = $b } }
            if (-not $blk) { throw 'no block for the first row' }
            if ($blk.BorderBrush.Color.A -eq 0) { throw 'selected row not outlined on the treemap' }
            # 点第二块：列表里选中的换成它
            $blk2 = $null; foreach ($b in $ctl.MapTree.Children) { if ($b.Tag -and -not [object]::ReferenceEquals($b.Tag, $row)) { $blk2 = $b; break } }
            if ($blk2) {
                $ev = New-Object System.Windows.Input.MouseButtonEventArgs ([System.Windows.Input.Mouse]::PrimaryDevice), 0, ([System.Windows.Input.MouseButton]::Left)
                $ev.RoutedEvent = [System.Windows.UIElement]::MouseLeftButtonDownEvent
                $blk2.RaiseEvent($ev); $win.UpdateLayout()
                if (-not [object]::ReferenceEquals($ctl.MapList.SelectedItem, $blk2.Tag)) { throw 'clicking a block did not select the row' }
                if ($blk.BorderBrush.Color.A -ne 0 -or $blk2.BorderBrush.Color.A -eq 0) { throw 'outline did not move to the clicked block' }
            }
            $ctl.MapViewDirs.IsChecked = $true
        }
        if ($env:CLEANC_SHOTS -eq '1') {
            & $step 'screenshots for the README' {
                $root = $win.Content
                $win.Width = 1240; $win.Height = 860
                $shot = { param([string]$n) $win.UpdateLayout(); [void](& $waitUi { $false } 300); & $snap $root ('shot-' + $n) 2 }
                # 清理 C 盘：真的扫一遍（只统计大小，不删东西）
                Show-Page 'clean'; $tsc = [Diagnostics.Stopwatch]::StartNew(); & $click $ctl.BtnScan
                if (-not (& $waitUi { -not $script:worker } 150000)) { throw 'cleanup scan did not finish' }
                $L.Add(("timing cleanup scan (first, this mode): {0:N1} s, inside the worker {1:N1} s; {2}" -f ($tsc.ElapsedMilliseconds / 1000), ([double]$sync.ScanMs / 1000), ((@(@($sync.ScanTimes) | Sort-Object { - [double]$_.Ms } | Select-Object -First 5) | ForEach-Object { '{0} {1:N0} ms' -f $_.N, [double]$_.Ms }) -join '; ')))
                if (-not $script:rows) { throw 'cleanup scan found nothing' }
                $ctl.OpPanel.Visibility = 'Collapsed'; & $shot 'clean'
                # 空间地图：扫整个 C 盘
                Show-Page 'map'; $ctl.MapViewDirs.IsChecked = $true
                foreach ($it in $ctl.MapDrive.Items) { if ([string]$it.Tag -ieq "$env:SystemDrive\") { $ctl.MapDrive.SelectedItem = $it } }
                Start-MapScan "$env:SystemDrive\"
                if (-not (& $waitUi { -not $script:worker } 120000)) { throw 'space map scan did not finish' }
                if (-not $script:mapRoot -or [object]::ReferenceEquals($script:mapRoot, $tree)) { throw 'space map has no scan of the drive' }
                $ctl.OpPanel.Visibility = 'Collapsed'; & $shot 'map'
                if ($ctl.MapOverview.Visibility -ne 'Visible' -or -not $ctl.MapOvPct.Text) { throw 'drive overview missing' }
                $ctl.MapViewTree.IsChecked = $true; & $shot 'map-tree'
                $ctl.MapViewTypes.IsChecked = $true; & $shot 'map-types'
                if ($ctl.MapList.Items.Count -lt 3) { throw 'type statistics missing for the drive' }
                # 最近改动：读变更日志（要文件表在内存里）
                $ctl.MapViewRecent.IsChecked = $true; Start-MapRecent
                if (-not (& $waitUi { -not $script:worker } 90000)) { throw 'recent changes did not finish' }
                $L.Add(("recent changes: {0} folders; {1}" -f @($script:recentRows).Count, $script:recentNote))
                if ([string]$script:mapMethod -like 'mft*' -and @($script:recentRows).Count -lt 1 -and $script:recentNote -notmatch 'USN') { throw ('no recent changes: ' + $script:recentNote) }
                & $shot 'map-recent'
                # 再扫一次：和上次比要能说出增长在哪
                Start-MapScan "$env:SystemDrive\"
                if (-not (& $waitUi { -not $script:worker } 120000)) { throw 'second space map scan did not finish' }
                $ctl.OpPanel.Visibility = 'Collapsed'
                $ctl.MapViewGrow.IsChecked = $true; $win.UpdateLayout()
                $L.Add('growth: ' + $script:growSummary)
                if (-not $script:growSummary) { throw 'no growth summary after the second scan' }
                $ctl.MapGrowBase.SelectedIndex = 5; $win.UpdateLayout()
                if ($script:growNote -notmatch '\d{8}-\d{4}') { throw ('baseline note: ' + $script:growNote) }
                $ctl.MapGrowBase.SelectedIndex = 0
                $ctl.MapViewDirs.IsChecked = $true
                Show-Page 'save'; $ctl.SaveScroll.ScrollToTop(); & $shot 'save'
                Show-Page 'dup'; & $shot 'dup'
                Show-Page 'settings'; & $shot 'settings'
                # 帮助：快速上手，再看「空间地图」那一项
                Show-Page 'help'; $hp0 = $script:helpPane; Select-HelpPane 'start' -NoRemember; & $shot 'help'
                Select-HelpPane 's3' -NoRemember; & $shot 'help-map'
                # 每一项完整的样子（不只是窗口里看得到的那一截）
                foreach ($pk in @('start', 's9', 's0', 's3', 'faq')) { Select-HelpPane $pk -NoRemember; $win.UpdateLayout(); [void](& $waitUi { $false } 200); & $snap $script:helpPanes[$pk].Pane ('pane-' + $pk) 1 }
                Select-HelpPane $hp0 -NoRemember; Show-Page 'clean'
            }
        }
        # 各种扫描用了多久（CLEANC_SPEED=1 时；开发者和 IT 模式，只统计不删）：报告里以 timing 开头的几行
        if ($env:CLEANC_SPEED -eq '1') {
            & $step 'speed: how long each scan takes (developer mode, nothing is deleted)' {
                $keepMode = Get-Setting 'Mode' 'basic'; $script:speedStuck = $false
                $tm = {
                    param([string]$name, [scriptblock]$go, [int]$limit)
                    $sync.PhaseTimes = $null
                    $t = [Diagnostics.Stopwatch]::StartNew(); & $go
                    $ok = & $waitUi { -not $script:worker } $limit
                    $L.Add(("timing {0}: {1:N1} s{2}" -f $name, ($t.ElapsedMilliseconds / 1000), $(if ($ok) { '' } else { (' (did not finish; at step {0}: {1} / {2})' -f $sync.P.Step, $sync.P.StepName, $sync.P.Detail) })))
                    if (-not $ok) { Set-CancelFlags; [void](& $waitUi { -not $script:worker } 60000); $script:speedStuck = $true }
                    if ($sync.PhaseTimes) { $L.Add(('timing     ' + ((@($sync.PhaseTimes) | ForEach-Object { '{0} {1:N0} ms' -f $_.N, [double]$_.Ms }) -join '; '))) }
                }
                $wk = {
                    param([string]$label)
                    $a = if ($sync.WEngine -and $sync.WCall) { ([datetime]$sync.WEngine - [datetime]$sync.WCall).TotalSeconds } else { -1 }
                    $b = if ($sync.WReady -and $sync.WEngine) { ([datetime]$sync.WReady - [datetime]$sync.WEngine).TotalSeconds } else { -1 }
                    $L.Add(("timing   {0}: worker start {1:N2} s, drive threads {2:N2} s" -f $label, $a, $b))
                }
                $top = {
                    param([string]$label)
                    & $wk $label
                    $L.Add(("timing   {0}: inside the worker {1:N1} s" -f $label, ([double]$sync.ScanMs / 1000)))
                    foreach ($x in @(@($sync.ScanTimes) | Sort-Object { - [double]$_.Ms } | Select-Object -First 14)) { $L.Add(("timing     {0,7:N0} ms  {1}" -f [double]$x.Ms, $x.N)) }
                    $w = @($sync.ScanWalks)
                    if ($w.Count) { $L.Add(("timing     walked {0} folders, {1:N0} ms; slowest: {2}" -f $w.Count, [double](($w | ForEach-Object { [double]$_.Ms } | Measure-Object -Sum).Sum), ((@($w | Sort-Object { - [double]$_.Ms } | Select-Object -First 6 | ForEach-Object { '{0} {1} ms' -f $_.Path, $_.Ms })) -join '; '))) }
                }
                try {
                    Set-Setting 'Mode' 'expert'
                    Show-Page 'clean'
                    & $tm 'cleanup scan (developer mode)' { Do-Scan } 240000; & $top 'cleanup'
                    & $tm 'cleanup scan again' { Do-Scan } 240000; & $top 'again'
                    & $tm 'apps list' { Load-Apps } 240000; & $wk 'apps'
                    & $tm 'leftover folders' { Load-StartRows 'leftover' } 240000
                    & $tm 'startup items' { Load-StartRows 'startup' } 60000
                    & $tm 'scheduled tasks' { Load-StartRows 'task' } 60000
                    & $tm 'context menu' { Load-StartRows 'shellex' } 60000
                    & $tm 'move candidates' { Start-CandScan } 240000
                    & $tm 'space map C: (again)' { Start-MapScan "$env:SystemDrive\" } 240000
                    $th = [Diagnostics.Stopwatch]::StartNew(); Load-Health
                    $hok = & $waitUi { $ctl.BtnHealthRefresh.IsEnabled } 180000
                    $L.Add(("timing system health: {0:N1} s (reported {1}){2}" -f ($th.ElapsedMilliseconds / 1000), $(if ($script:healthData) { $script:healthData.Secs } else { '?' }), $(if ($hok) { '' } else { ' (did not finish)' })))
                    if ($script:healthData -and $script:healthData.PartMs) { $pm = $script:healthData.PartMs; $L.Add(('timing     ' + ((@($pm.Keys) | Sort-Object { - [double]$pm[$_] } | ForEach-Object { '{0} {1:N0} ms' -f $_, [double]$pm[$_] }) -join '; '))) }
                    # 重复文件：在 Program Files 里几个装了很多大文件的文件夹里找（只找不删；整个 Program Files 逐个列举在测试机上要好几分钟）
                    [DupFinder]::Cancel = $false
                    $droots = @(@("$env:ProgramFiles\dotnet", "$env:ProgramFiles\Android", "${env:ProgramFiles(x86)}\Android", "${env:ProgramFiles(x86)}\Windows Kits", "$env:ProgramFiles\Java") | Where-Object { Test-Path -LiteralPath $_ })
                    if ($droots.Count -eq 0) { $droots = @($env:ProgramFiles) }
                    $td = [Diagnostics.Stopwatch]::StartNew()
                    $dg = [DupFinder]::Find([string[]]$droots, [long]1MB, [long]0, $false, $null, $false, [string[]]@('C:=4'))
                    $L.Add(("timing duplicates in {0} folders under Program Files (1 MB+): {1:N1} s, {2} groups" -f $droots.Count, ($td.ElapsedMilliseconds / 1000), @($dg).Count))
                    $dph = { "timing     list {0:N1} s ({1:N0} files); quick {2:N1} s ({3:N0} files, {4}); deep {5:N1} s ({6:N0} files, {7})" -f ([DupFinder]::ListMs / 1000), [DupFinder]::FilesSeen, ([DupFinder]::QuickMs / 1000), [DupFinder]::QuickFiles, (Fmt ([double][DupFinder]::QuickBytes)), ([DupFinder]::DeepMs / 1000), [DupFinder]::DeepFiles, (Fmt ([double][DupFinder]::DeepBytes)) }
                    $L.Add((& $dph))
                    # 同样的查找，这次从 C 盘的文件表列出文件：结果必须和逐个文件夹列举的完全一样
                    $ct = [DiskMap]::GetTree($env:SystemDrive, [DirStat]::ThreadsFor($env:SystemDrive), $false, $false)
                    $td2 = [Diagnostics.Stopwatch]::StartNew()
                    $dg2 = [DupFinder]::Find([string[]]$droots, [long]1MB, [long]0, $false, $null, $false, [string[]]@('C:=4'), [DmNode[]]@($ct))
                    $L.Add(("timing duplicates again, listed from the file table ({0} of {1} places): {2:N1} s, {3} groups" -f [DupFinder]::FromTreeRoots, $droots.Count, ($td2.ElapsedMilliseconds / 1000), @($dg2).Count))
                    $L.Add((& $dph))
                    $p1 = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase); foreach ($g in @($dg)) { foreach ($f in $g.Files) { [void]$p1.Add([string]$f.Path) } }
                    $p2 = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase); foreach ($g in @($dg2)) { foreach ($f in $g.Files) { [void]$p2.Add([string]$f.Path) } }
                    if ([DupFinder]::FromTreeRoots -ne $droots.Count -or -not $p1.SetEquals($p2)) {
                        $only1 = @($p1 | Where-Object { -not $p2.Contains($_) } | Select-Object -First 4); $only2 = @($p2 | Where-Object { -not $p1.Contains($_) } | Select-Object -First 4)
                        throw ("file-table listing differs: {0} vs {1} files; only walking: {2}; only the file table: {3}" -f $p1.Count, $p2.Count, ($only1 -join ' | '), ($only2 -join ' | '))
                    }
                    $tw = [Diagnostics.Stopwatch]::StartNew(); $wb = [DirStat]::Measure("$env:SystemRoot\System32")
                    $L.Add(("timing walk System32: {0:N1} s, {1}" -f ($tw.ElapsedMilliseconds / 1000), (Fmt $wb)))
                    if ($script:speedStuck) { throw 'a scan did not finish in time (see the timing lines)' }
                } finally { Set-Setting 'Mode' $keepMode }
            }
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

