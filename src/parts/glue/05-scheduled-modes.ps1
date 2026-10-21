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
    if ($free -lt $gb * 1GB -and (Get-Setting 'LastRemind' '') -ne $today) {
        Set-Setting 'LastRemind' $today
        $ans = Show-Toast -Title ((T "C 盘只剩 {0} 了") -f (GB $free)) -Text ((T "低于你设定的 {0} GB。打开腾挪 ClearC，看看能清掉或搬走什么？`n（在工具的「自动提醒」页可以关掉这个提醒）") -f $gb) -Buttons @((T '稍后'), (T '打开腾挪 ClearC'))
        if ($ans -eq (T '打开腾挪 ClearC') -and $env:CLEANC_SELF) { Start-Process -FilePath $env:CLEANC_SELF }
    }
    $global:CLEANC_UI_SHOWN = $true
    return
}
if ($script:mode -match '(?i)/selftest') {
    Init-DriveThreads
    [DiskMap]::MftOff = ((Get-Setting 'FastScan' '1') -eq '0')
    $r = Invoke-SelfTest $script:AppVersion
    $file = if ($env:CLEANC_REPORT) { $env:CLEANC_REPORT } else { Join-Path $script:appDir 'selftest.txt' }
    try { New-Item -ItemType Directory -Force -Path (Split-Path $file) | Out-Null; [IO.File]::WriteAllText($file, (@($r.Lines) -join "`r`n"), (New-Object Text.UTF8Encoding $true)) } catch {}
    if (-not $env:CLEANC_QUIET) {
        $ans = Show-Toast -Title (T '扫描功能检查完了') -Text ((T "{0} 项正常，{1} 项提醒，{2} 项有问题") -f $r.Res.Pass, $r.Res.Warn, $r.Res.Fail) -Buttons @((T '好'), (T '打开结果'))
        if ($ans -eq (T '打开结果')) { Start-Process -FilePath "$env:SystemRoot\System32\notepad.exe" -ArgumentList ('"{0}"' -f $file) }
    }
    $global:CLEANC_EXIT = [int]$r.Res.Fail
    $global:CLEANC_UI_SHOWN = $true
    return
}
if ($script:mode -match '(?i)/autoclean') {
    [void](Prune-OpLog (Get-LogMonths))
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
[xml]$xaml = @"
