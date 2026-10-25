'@

# ---------- 界面语言：设置里的 Lang=zh / en；没设过就跟系统显示语言走（中文系统用中文，其他用英文） ----------
function Get-UiLang {
    try {
        $f = Join-Path $env:LOCALAPPDATA 'CleanC\settings.txt'
        if (Test-Path -LiteralPath $f) { foreach ($l in [IO.File]::ReadAllLines($f, [Text.Encoding]::UTF8)) { if ($l -match '^\s*Lang\s*=\s*(zh|en)\s*$') { return $matches[1] } } }
    } catch {}
    if ([Globalization.CultureInfo]::CurrentUICulture.Name -like 'zh*') { return 'zh' }
    return 'en'
}
$script:Lang = Get-UiLang
$script:L10n = $null
if ($script:Lang -eq 'en') {
    $script:L10n = New-Object 'System.Collections.Generic.Dictionary[string,string]'
    $unesc = { param($x) $x.Replace('\\', [string][char]1).Replace('\t', "`t").Replace('\r', "`r").Replace('\n', "`n").Replace([string][char]1, '\') }
    foreach ($l in ($script:l10nData -split "`r?`n")) {
        $i = $l.IndexOf("`t"); if ($i -le 0) { continue }
        $script:L10n[(& $unesc $l.Substring(0, $i))] = (& $unesc $l.Substring($i + 1))
    }
}
try { [L10n]::Map = $script:L10n } catch {}

Invoke-Expression $engine
$catalog = Get-Catalog

# ---------- 外观：浅色 / 深色 / 跟随系统。存在设置里，换了以后重新打开本工具生效 ----------
$script:themePref = Get-Setting 'Theme' 'light'
$script:sysDark = $false
try { $script:sysDark = ((Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' -Name AppsUseLightTheme -ErrorAction Stop).AppsUseLightTheme -eq 0) } catch {}
[Theme]::Dark = ($script:themePref -eq 'dark') -or ($script:themePref -eq 'system' -and $script:sysDark)
try { [RowTheme]::Map = [Delegate]::CreateDelegate([Func[string, char, string]], [Theme].GetMethod('Map')) } catch {}

# ============================================================
# 定时任务调用的两种模式（不打开主窗口）：
#   /check      检查 C 盘剩余空间，低于设定值时在右下角提醒（每天最多一次）
#   /autoclean  每周自动清理一次「安全清理」里的缓存，做完在右下角告诉你
# ============================================================
function Show-Toast([string]$Title, [string]$Text, [string[]]$Buttons = @((T '好')), [int]$AutoClose = 0) {
    $x = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        WindowStyle="None" AllowsTransparency="True" Background="Transparent" ResizeMode="NoResize" ShowInTaskbar="True" Topmost="True"
        SizeToContent="Height" Width="400" FontFamily="Segoe UI, Microsoft YaHei UI" FontSize="13" Foreground="#1D1D1F" Title="腾挪 ClearC">
  <Border Margin="14" Background="White" CornerRadius="14" BorderBrush="#D9D9DE" BorderThickness="1" Padding="20,16,20,14">
    <Border.Effect><DropShadowEffect BlurRadius="24" ShadowDepth="6" Direction="270" Opacity="0.22"/></Border.Effect>
    <StackPanel>
      <StackPanel Orientation="Horizontal" Margin="0,0,0,8">
        <Border Width="22" Height="22" CornerRadius="6" Background="#0071E3">
          <TextBlock Text="&#xEDA2;" FontFamily="Segoe Fluent Icons, Segoe MDL2 Assets" FontSize="12" Foreground="White" HorizontalAlignment="Center" VerticalAlignment="Center"/>
        </Border>
        <TextBlock Text="腾挪 ClearC" Foreground="#6E6E73" FontSize="12" VerticalAlignment="Center" Margin="8,0,0,0"/>
      </StackPanel>
      <TextBlock x:Name="TTitle" FontSize="15" FontWeight="SemiBold" TextWrapping="Wrap"/>
      <TextBlock x:Name="TText" Margin="0,6,0,0" Foreground="#3A3A3C" TextWrapping="Wrap" LineHeight="20"/>
      <StackPanel x:Name="TButtons" Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,14,0,0"/>
    </StackPanel>
  </Border>
</Window>
'@
    $x = $x.Replace('腾挪 ClearC', (T '腾挪 ClearC'))
    $w = [Windows.Markup.XamlReader]::Parse([Theme]::Xaml($x))
    $w.FindName('TTitle').Text = $Title
    $w.FindName('TText').Text = $Text
    $script:toastResult = ''
    $panel = $w.FindName('TButtons')
    for ($i = 0; $i -lt $Buttons.Count; $i++) {
        $b = New-Object System.Windows.Controls.Button
        $b.Content = $Buttons[$i]; $b.Tag = $Buttons[$i]; $b.MinWidth = 76
        $b.Padding = New-Object System.Windows.Thickness 14, 6, 14, 6; $b.Margin = New-Object System.Windows.Thickness 8, 0, 0, 0
        $b.Cursor = [System.Windows.Input.Cursors]::Hand
        if ($i -eq $Buttons.Count - 1) { $b.Background = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromRgb(0, 0x71, 0xE3)); $b.Foreground = [System.Windows.Media.Brushes]::White; $b.BorderThickness = 0 }
        $b.Add_Click({ $script:toastResult = [string]$this.Tag; [System.Windows.Window]::GetWindow($this).Close() })
        [void]$panel.Children.Add($b)
    }
    $w.Add_MouseLeftButtonDown({ try { $this.DragMove() } catch {} })
    $w.Add_Loaded({
        $wa = [System.Windows.SystemParameters]::WorkArea
        $this.Left = $wa.Right - $this.ActualWidth - 4
        $this.Top = $wa.Bottom - $this.ActualHeight - 4
    })
    if ($AutoClose -gt 0) {
        $script:toastWin = $w
        $t = New-Object System.Windows.Threading.DispatcherTimer
        $t.Interval = [TimeSpan]::FromSeconds($AutoClose)
        $t.Add_Tick({ $this.Stop(); try { $script:toastWin.Close() } catch {} })
        $t.Start()
    }
    [void]$w.ShowDialog()
    return $script:toastResult
}

$script:mode = [string]$env:CLEANC_ARGS
if ($script:mode -match '(?i)/check') {
    Add-History
    $gb = 20; [void][int]::TryParse((Get-Setting 'RemindGB' '20'), [ref]$gb)
    $free = [double](FreeC)
    $today = (Get-Date).ToString('yyyy-MM-dd')
    $shown = $false
    if ($free -lt $gb * 1GB -and (Get-Setting 'LastRemind' '') -ne $today) {
        Set-Setting 'LastRemind' $today; $shown = $true
        $ans = Show-Toast -Title ((T "C 盘只剩 {0} 了") -f (GB $free)) -Text ((T "低于你设定的 {0} GB。打开腾挪 ClearC，看看能清掉或搬走什么？`n（在工具的「自动提醒」页可以关掉这个提醒）") -f $gb) -Buttons @((T '稍后'), (T '打开腾挪 ClearC'))
        if ($ans -eq (T '打开腾挪 ClearC') -and $env:CLEANC_SELF) { Start-Process -FilePath $env:CLEANC_SELF }
    }
    # 可以清理的垃圾超过设定值时也提醒（每天最多一次；只统计「安全清理」里的缓存，不碰任何东西）
    $jgb = 0; [void][int]::TryParse((Get-Setting 'JunkGB' '0'), [ref]$jgb)
    if (-not $shown -and $jgb -gt 0 -and (Get-Setting 'LastJunkRemind' '') -ne $today) {
        try { [Diagnostics.Process]::GetCurrentProcess().PriorityClass = 'BelowNormal' } catch {}
        $junk = [double]0
        foreach ($it in (Get-Catalog)) {
            if ($it.Kind -ne 'cache' -or $it.Def -ne 'delete' -or $it.Act -or $it.Tier -ne 'safe') { continue }
            $junk += [double](Measure-Item $it)
        }
        if ($junk -ge $jgb * 1GB) {
            Set-Setting 'LastJunkRemind' $today
            $ans = Show-Toast -Title ((T "C 盘上有约 {0} 可以清理") -f (GB $junk)) -Text ((T "临时文件、缓存和日志加起来超过了你设定的 {0} GB。打开腾挪 ClearC 清一清？`n（在工具的「自动提醒」页可以改界限或关掉这个提醒）") -f $jgb) -Buttons @((T '稍后'), (T '打开腾挪 ClearC'))
            if ($ans -eq (T '打开腾挪 ClearC') -and $env:CLEANC_SELF) { Start-Process -FilePath $env:CLEANC_SELF }
        }
    }
    $global:CLEANC_UI_SHOWN = $true
    return
}
# 界面自测（给自动测试用）：照常打开窗口，点一遍界面功能，对话框一律当作点了「取消」，做完自己关掉
$script:uiTest = [bool]($script:mode -match '(?i)/uitest')
# 这个 exe 是什么时候构建的（同一个版本号可能构建过好几次，反馈问题时好对上）
$script:AppBuild = ''
try {
    if ($script:AppBuildStamp) { $script:AppBuild = '{0:yyyy-MM-dd HH:mm}' -f ([DateTime]::Parse($script:AppBuildStamp, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AdjustToUniversal -bor [Globalization.DateTimeStyles]::AssumeUniversal)).ToLocalTime() }
    elseif ($script:selfScript -and (Test-Path -LiteralPath $script:selfScript)) { $script:AppBuild = '{0:yyyy-MM-dd HH:mm}' -f (Get-Item -LiteralPath $script:selfScript).LastWriteTime }   # 直接运行脚本：用脚本的修改时间
} catch {}
$script:uiSheets = New-Object System.Collections.Generic.List[string]
if ($script:mode -match '(?i)/selftest') {
    Init-DriveThreads
    [DiskMap]::MftOff = ((Get-Setting 'FastScan' '1') -eq '0')
    $r = Invoke-SelfTest $script:AppVersion
    $file = if ($env:CLEANC_REPORT) { [IO.Path]::GetFullPath($env:CLEANC_REPORT) } else { Join-Path $script:appDir 'selftest.txt' }
    $dir = Split-Path $file
    try { if ($dir) { New-Item -ItemType Directory -Force -Path $dir | Out-Null } } catch {}
    try { [IO.File]::WriteAllText($file, (@($r.Lines) -join "`r`n"), (New-Object Text.UTF8Encoding $true)) } catch {}
    if (-not $env:CLEANC_QUIET) {
        $ans = Show-Toast -Title (T '扫描功能检查完了') -Text ((T "{0} 项正常，{1} 项提醒，{2} 项有问题") -f $r.Res.Pass, $r.Res.Warn, $r.Res.Fail) -Buttons @((T '好'), (T '打开结果'))
        if ($ans -eq (T '打开结果')) { [void](Open-AsUser $file) }
    }
    $global:CLEANC_EXIT = [int]$r.Res.Fail
    $global:CLEANC_UI_SHOWN = $true
    return
}
if ($script:mode -match '(?i)/autoclean') {
    if (-not (Enter-BusyLock)) { OpLog '删除' (T '这次自动清理跳过：本工具的窗口里正在删除或搬家') '' (T '下次到时间再做'); $global:CLEANC_UI_SHOWN = $true; return }
    [void](Prune-OpLog (Get-LogMonths))
    [void][FsTools]::KeepAwake($true)   # 清完之前电脑不睡着（进程结束时自动放开）
    $r = Invoke-AutoClean
    Add-History
    OpLog '删除' (T '每周自动清理完成') '' ((T "C 盘多出 {0}；{1}") -f (GB $r.Freed), ($r.Items -join (T '；')))
    [void](Show-Toast -Title (T '每周自动清理完成') -Text ((T "C 盘多出 {0}。只清了临时文件、缓存和日志，没有碰任何个人文件。每一项都记在「操作日志」里。") -f (GB $r.Freed)) -Buttons @((T '好')) -AutoClose 30)
    $global:CLEANC_UI_SHOWN = $true
    return
}

# ============================================================
# 界面
# ============================================================
# 只开一个窗口：已经开着的话，把那个窗口拉到前面，这一个直接退出（两个窗口同时删、同时搬会互相打架）。
# 已经有一个在运行、却一直没有窗口（卡住了，比如上次被杀毒软件拦在一半）：不悄悄退出，说清楚，问要不要结束它再打开
$script:uiMutex = $null
# 正在运行的其他 ClearC 界面：按 exe 里的产品名认（文件改过名、新旧版本都认得出），定时任务在后台跑的（/check、/autoclean）不算
function Get-OtherClearC {
    $out = @()
    $me = [Diagnostics.Process]::GetCurrentProcess()
    foreach ($p in @(Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.Id -ne $me.Id -and ($_.ProcessName -like 'ClearC*' -or $_.ProcessName -like 'CleanC*' -or $_.ProcessName -eq $me.ProcessName) })) {
        $prod = ''; try { $prod = [string]$p.MainModule.FileVersionInfo.ProductName } catch {}
        if ($prod -notmatch 'ClearC') { continue }
        $cmd = ''; try { $cmd = [string](Get-CimInstance Win32_Process -Filter ('ProcessId={0}' -f $p.Id) -ErrorAction Stop).CommandLine } catch {}
        if ($cmd -match '(?i)\s/(check|autoclean|selftest)\b') { continue }
        $out += $p
    }
    return ,$out
}
# 结束卡住的本工具：只在用户点了「是」以后，只结束 Get-OtherClearC 认出来的那几个（它们都没有窗口）
function Stop-StaleInstance($procs) {
    foreach ($p in @($procs)) { try { $p.Kill(); [void]$p.WaitForExit(10000) } catch {} }
}
if (-not $script:uiTest) {
    $first = $true
    try { $script:uiMutex = [System.Threading.Mutex]::new($true, 'Local\ClearC-UI', [ref]$first) } catch { $first = $true }
    if (-not $first) {
        $others = @(Get-OtherClearC)
        # 刚双击过一次、那一个还在启动：等它的窗口出来，最多 20 秒
        $until = (Get-Date).AddSeconds(20); $shown = $null
        while ($true) {
            foreach ($p in $others) { try { $p.Refresh(); if (-not $p.HasExited -and $p.MainWindowHandle -ne [IntPtr]::Zero) { $shown = $p } } catch {} }
            if ($shown -or (Get-Date) -ge $until -or @($others | Where-Object { -not $_.HasExited }).Count -eq 0) { break }
            Start-Sleep -Milliseconds 500
        }
        if ($shown) {
            try { [Microsoft.VisualBasic.Interaction]::AppActivate($shown.Id) } catch {}
            $global:CLEANC_UI_SHOWN = $true
            return
        }
        # 等的时候那一个自己退出了：接着打开
        $got = $false
        try { $got = $script:uiMutex.WaitOne(0) } catch [System.Threading.AbandonedMutexException] { $got = $true } catch {}
        if (-not $got) {
            Close-Splash
            $title = (T '腾挪 ClearC')
            $alive = @($others | Where-Object { -not $_.HasExited })
            if ($alive.Count -eq 0) {
                [void][System.Windows.MessageBox]::Show((T '腾挪 ClearC 已经开着一个（可能在别的窗口后面）。如果找不到它，重启电脑后再打开。'), $title, 'OK', 'Information')
                $global:CLEANC_UI_SHOWN = $true
                return
            }
            # 那一个正拿着删除、搬家的锁：可能正在删或搬，结束会停在一半
            $busy = $false
            try { $bm = New-Object System.Threading.Mutex($false, 'Local\ClearC-Busy'); try { if ($bm.WaitOne(0)) { $bm.ReleaseMutex() } else { $busy = $true } } catch [System.Threading.AbandonedMutexException] { try { $bm.ReleaseMutex() } catch {} }; $bm.Dispose() } catch {}
            $text = (T "上一次打开的腾挪 ClearC 还在后台运行，但一直没有窗口，多半是卡住了（比如被杀毒软件拦在了一半）。`n`n要结束它，再重新打开吗？")
            if ($busy) { $text += "`n`n" + (T '它可能正在删除或搬家，现在结束会停在一半；下次打开时会说明停在哪一步，可以接着做完或撤回。不着急的话，可以先等几分钟再试。') }
            $ans = [System.Windows.MessageBox]::Show($text, $title, 'YesNo', 'Warning', 'No')
            if ([string]$ans -ne 'Yes') { $global:CLEANC_UI_SHOWN = $true; return }
            Stop-StaleInstance $alive
            try { $got = $script:uiMutex.WaitOne(10000) } catch [System.Threading.AbandonedMutexException] { $got = $true } catch {}
            if (-not $got) {
                [void][System.Windows.MessageBox]::Show((T '没能结束上一次的腾挪 ClearC。重启电脑后再打开。'), $title, 'OK', 'Warning')
                $global:CLEANC_UI_SHOWN = $true
                return
            }
            Write-LogFile ('ended {0} ClearC process(es) that had no window, after the user agreed' -f $alive.Count)
            Show-Splash
        }
    }
}
# 重新打开本工具（换外观、换语言）之前先放开：不然新开的那个以为已经有窗口开着，直接退出
function Exit-UiLock { if ($script:uiMutex) { try { $script:uiMutex.ReleaseMutex() } catch {}; try { $script:uiMutex.Dispose() } catch {}; $script:uiMutex = $null } }
[xml]$xaml = @"
