"@

# 对话框（代替系统消息框）：圆角白卡片，主窗口同时压暗
$script:sheetXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        WindowStyle="None" AllowsTransparency="True" Background="Transparent" ResizeMode="NoResize" ShowInTaskbar="False"
        SizeToContent="Height" Width="500" WindowStartupLocation="CenterOwner"
        FontFamily="Segoe UI, Microsoft YaHei UI" FontSize="13" Foreground="#1D1D1F" UseLayoutRounding="True" TextOptions.TextFormattingMode="Display">
  <Border Margin="20,14,20,28" Background="White" CornerRadius="14" BorderBrush="#D9D9DE" BorderThickness="1">
    <Border.Effect><DropShadowEffect BlurRadius="34" ShadowDepth="8" Direction="270" Opacity="0.24"/></Border.Effect>
    <StackPanel Margin="26,24,26,20">
      <Grid Width="44" Height="44" HorizontalAlignment="Left" Margin="0,0,0,14">
        <Ellipse x:Name="SIconBg" Fill="#E8F1FC"/>
        <TextBlock x:Name="SIconGlyph" FontFamily="Segoe Fluent Icons, Segoe MDL2 Assets" FontSize="20" Foreground="#0071E3"
                   HorizontalAlignment="Center" VerticalAlignment="Center" Text="&#xE946;"/>
      </Grid>
      <TextBlock x:Name="STitle" FontSize="17" FontWeight="SemiBold" TextWrapping="Wrap" TextOptions.TextFormattingMode="Ideal"/>
      <TextBlock x:Name="SText" Margin="0,8,0,0" Foreground="#3A3A3C" TextWrapping="Wrap" LineHeight="21"/>
      <Border x:Name="SListBox" Margin="0,14,0,0" Background="#F5F5F7" CornerRadius="9" Padding="14,9" Visibility="Collapsed">
        <ScrollViewer MaxHeight="230" VerticalScrollBarVisibility="Auto">
          <TextBlock x:Name="SList" LineHeight="22" TextWrapping="Wrap"/>
        </ScrollViewer>
      </Border>
      <Border x:Name="SAckBox" Margin="0,16,0,0" Background="#FFF6F6" BorderBrush="#F3C4C8" BorderThickness="1" CornerRadius="9" Padding="12,10" Visibility="Collapsed">
        <CheckBox x:Name="SAck" VerticalContentAlignment="Top">
          <TextBlock x:Name="SAckText" TextWrapping="Wrap" Foreground="#1D1D1F" LineHeight="20"/>
        </CheckBox>
      </Border>
      <StackPanel x:Name="SButtons" Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,22,0,0"/>
    </StackPanel>
  </Border>
</Window>
'@

if ($script:Lang -eq 'en') {
    # 换成英文的帮助页
    try {
        $ns = New-Object System.Xml.XmlNamespaceManager $xaml.NameTable
        $ns.AddNamespace('w', 'http://schemas.microsoft.com/winfx/2006/xaml/presentation'); $ns.AddNamespace('x', 'http://schemas.microsoft.com/winfx/2006/xaml')
        $old = $xaml.SelectSingleNode("//w:Grid[@x:Name='PageHelp']", $ns)
        $frag = [xml]("<R xmlns='http://schemas.microsoft.com/winfx/2006/xaml/presentation' xmlns:x='http://schemas.microsoft.com/winfx/2006/xaml'>" + $script:helpEnXaml + '</R>')
        $new = $frag.DocumentElement.SelectSingleNode("w:Grid[@x:Name='PageHelp']", $ns)
        if ($old -and $new) { [void]$old.ParentNode.ReplaceChild($xaml.ImportNode($new, $true), $old) }
    } catch {}
    # 英文词更长：重复文件页左边那一列标签放宽一点
    foreach ($cd in $xaml.SelectNodes("//*[local-name()='ColumnDefinition' and @Width='92']")) { $cd.SetAttribute('Width', '108') }
    # 其余文字逐个查表
    $attrs = @('Text', 'Content', 'ToolTip', 'Header', 'Title')
    foreach ($el in $xaml.SelectNodes('//*')) {
        foreach ($a in @($el.Attributes)) {
            # 触发器里和数据比较的值（比如行的操作「删除」）也要换成同样的英文，否则颜色等样式对不上
            $use = ($attrs -contains $a.LocalName) -or ($a.LocalName -eq 'Value' -and (($el.LocalName -eq 'Setter' -and ($attrs -contains [string]$el.GetAttribute('Property'))) -or $el.LocalName -in @('Condition', 'DataTrigger', 'Trigger')))
            if ($use -and $a.Value -and -not $a.Value.StartsWith('{')) { $a.Value = T $a.Value }
            elseif ($use -and $a.Value -like "*StringFormat='{}{0} 项'*") { $a.Value = $a.Value.Replace("{}{0} 项", '{}' + (T '{0} 项')) }
        }
        foreach ($c in @($el.ChildNodes)) { if ($c.NodeType -eq 'Text' -and $c.Value) { $c.Value = T $c.Value } }
    }
}
$win = $null; $script:themeFail = ''
if ([Theme]::Dark) {
    # 深色版本万一打不开，就用浅色打开（不然连换回浅色的按钮都看不到）
    try { $win = [Windows.Markup.XamlReader]::Parse([Theme]::Xaml($xaml.OuterXml)) } catch { $script:themeFail = $_.Exception.Message; [Theme]::Dark = $false; $win = $null }
}
if (-not $win) { $win = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $xaml)) }
# 深色的窗口标题栏
$win.Add_SourceInitialized({ try { [Theme]::DarkTitle((New-Object System.Windows.Interop.WindowInteropHelper $win).Handle) } catch {} })
$script:tUi = $script:startClock.Elapsed.TotalSeconds
$ctl = @{}
foreach ($n in 'NavSave','NavMap','NavApps','NavMoves','NavAuto','NavLog','PageMap','PageSave','PageApps','PageMoves','PageAuto','PageLog','BtnDupMerge',
               'MapDrive','BtnMapStop','BtnMapScan','MapViewDirs','MapViewFiles','MapViewGrow','BtnMapUp','MapPath','MapInfo','MapList','MapGrow','EmptyMap','EmptyMapText','BtnMapOpen','BtnMapCompress','BtnMapDelete','MapSel',
               'SaveScroll','BtnSaveRefresh','BtnCosOff','BtnCosOn','SaveCosState','SavePfState','SavePfDrive','BtnPfMove','BtnPfAuto','SaveHibState','BtnHibReduced','BtnHibOff','BtnHibFull','BtnFolderCompress','SaveFcState','VdList','VdEmpty','BtnGoDup',
               'BtnAppsRefresh','AppsAll','AppsC','AppsStore','AppsInfo','AppsSearch','AppsLeftBox','BtnAppsLeftClose','BtnAppsLeft','AppsLeftText','AppsList','EmptyApps','EmptyAppsText',
               'BtnAppsUpdates','AppsViewApps','AppsViewStartup','AppsViewTasks','AppsViewMenu','AppsFilterBox','StartList','BtnCleanCustom','AutoJunkGB','AutoCleanWhen','SetCleanCard','SetCustomList','SetCustomEmpty','BtnSetCustomAdd','SetExcludeList','SetExcludeEmpty','BtnSetExcludeAdd',
               'BtnMovesRefresh','MovesInfo','MovesList','EmptyMoves','EmptyMovesText',
               'AutoRemindOn','AutoRemindGB','AutoRemindNote','AutoCleanOn','AutoCleanNote','HistInfo','HistChart','HistLast','HistFirst',
               'BtnLogOpenDir','BtnLogRefresh','LogKeep','LogKeepNote','LogCats','LogRange','LogSearch','LogCount','LogList','EmptyLog','EmptyLogText',
               'BtnLang','BtnLangText','BtnTheme','BtnThemeText','NavHelp','PageHelp','HelpScroll','HelpSections','HelpFaq','BtnHelpExpand','FeedbackCard','RiskCard','BtnFeedback','BtnGitHub','BtnIssue','BtnCopyDiag','BtnOpenLog','CopyHint','BtnSelfTest','BtnCheckUpdate','MapFast','MapChat',
               'NavClean','NavDup','PageClean','PageDup','AppVer','BtnLog','BtnLogText','BtnLogHide','LogPanel','Dim',
               'CapFree','CapTotal','CapBar','CapReclaim','EmptyClean','EmptyCleanText','EmptyDup','EmptyDupText','SizeCustomRow',
               'DestPick','BtnDestBrowse','DestHint','BtnOneClick','BtnScan','BtnRun','BtnHogs','Hint','List','Summary','Log',
               'Roots','BtnAddRoot','BtnDupScan','BtnDupStop',
               'FilterExpander','FilterSummary','TypeChips','TypeReset','ExtraExt','SizeChips',
               'SizeMin','SizeMinUnit','SizeMax','SizeMaxUnit','SizeHint','ModeName','ModeContent','SpeedFast','SpeedExact',
               'DupProgressText','DupList','DupRecycle','DupProtect','BtnDupDelete',
               'OpPanel','OpTime','OpTitle','OpBar','OpSubTime','OpDetail','OpSubBar','Root',
               'Overlay','OvTitle','OvTime','OvBar','OvStep','OvWhat','OvChecklist','OvDetail','OvSubBar','OvPlanBox','OvPlanScroll','OvPlan','OvHide','OvClose','OvNote',
               'BtnKeepNew','BtnKeepOld','BtnPickC','BtnPickNone','DupSummary',
               'CleanScroll','CleanMore','CleanMoreText','CleanOverview','CleanOverviewText',
               'OvCancel','OpCancel','MovesTabCand','MovesTabDone','CandList','EmptyCand','EmptyCandText','MovesCard','CandStore','BtnCandStore','CandStoreText','CandBar','MovesDest','BtnCandMove','BtnCandAll','BtnCandNone','CandSel','MapViewTree','BtnMapReport','MapTree','BtnMapExport','MapFilter','MapMinSize','MapAge','MapType','MapName','MapUnder',
               'MapAll','BtnMapAcct','MapMenu','MmEnter','MmOpen','MmCopy','MmCompress','MmDelete','NavHeadManage','NavSettings','PageSettings','SetScroll','BtnSetReset',
               'SetThemeLight','SetThemeDark','SetThemeSystem','SetLangZh','SetLangEn','SetPageDup','SetPageSave','SetPageApps','SetPageMoves','SetPageAuto','SetPageLog',
               'SetLinkTheme','SetLinkLang','SetLinkFeedback','SetLinkLog','SetPageSub','SetMapCheck','SetMapBar','SetMapPct','SetMapMeta','SetMapDisk','SetMapFastBtn','SetFast','SetLowIo',
               'SaveRpState','BtnRestoreOpen') { $ctl[$n] = $win.FindName($n) }
# 右键菜单不在窗口的元素树里：万一按名字找不到，就从菜单里一个个取
if (-not $ctl.MmDelete -and $ctl.MapList.ContextMenu) { $ctl.MapMenu = $ctl.MapList.ContextMenu; foreach ($it in $ctl.MapMenu.Items) { if ($it.Name) { $ctl[$it.Name] = $it } } }

# ---------- 左侧导航：两页切换 ----------
$script:pageList = [ordered]@{
    clean = @('PageClean', 'NavClean'); dup = @('PageDup', 'NavDup'); save = @('PageSave', 'NavSave'); map = @('PageMap', 'NavMap'); apps = @('PageApps', 'NavApps')
    moves = @('PageMoves', 'NavMoves'); auto = @('PageAuto', 'NavAuto'); log = @('PageLog', 'NavLog'); help = @('PageHelp', 'NavHelp'); settings = @('PageSettings', 'NavSettings')
}
$script:pageLoaded = @{}
function Show-Page([string]$key) {
    $script:curPage = $key
    foreach ($k in $script:pageList.Keys) {
        $on = ($k -eq $key)
        $ctl[$script:pageList[$k][0]].Visibility = if ($on) { 'Visible' } else { 'Collapsed' }
        $nav = $ctl[$script:pageList[$k][1]]
        if ($nav.IsChecked -ne $on) { $nav.IsChecked = $on }
    }
    # 第一次打开某一页时才去读数据
    switch ($key) {
        'map'   { if (-not $script:pageLoaded.map) { $script:pageLoaded.map = $true; Fill-MapDrives } }
        'save'  { if (-not $script:pageLoaded.save) { $script:pageLoaded.save = $true; Load-Save } }
        'apps'  { if (-not $script:pageLoaded.apps -and -not $script:worker) { $script:pageLoaded.apps = $true; Load-Apps } }
        'moves' { if (-not $script:candScanned) { $script:candPending = $true }; if (-not $script:worker) { Load-Moves } }
        'auto'  { Load-Auto }
        'log'   { Load-Log }
        'settings' { Load-Settings }
    }
}
foreach ($k in $script:pageList.Keys) {
    $ctl[$script:pageList[$k][1]].Add_Checked({
        foreach ($kk in $script:pageList.Keys) { if ([object]::ReferenceEquals($ctl[$script:pageList[$kk][1]], $this)) { Show-Page $kk } }
    })
}

# ---------- 帮助页：使用反馈 ----------
function Show-CopyHint([string]$t) { $ctl.CopyHint.Text = $t }
$ctl.BtnFeedback.Add_Click({
    Show-Page 'help'
    $ctl.HelpScroll.UpdateLayout()
    $ctl.FeedbackCard.BringIntoView()
})
# 点左侧「帮助」总是回到帮助的开头（先点「使用反馈」滚到下面后，帮助已是选中状态，Checked 不会再触发）
$ctl.NavHelp.Add_Click({ $ctl.HelpScroll.ScrollToTop() })
# 帮助的各节默认收起，点标题展开；「全部展开」一下展开或收起全部
function Get-HelpSections { @($ctl.HelpSections.Children | Where-Object { $_ -is [System.Windows.Controls.Expander] }) }
function Update-HelpExpand {
    $all = Get-HelpSections
    $open = @($all | Where-Object { $_.IsExpanded }).Count
    $ctl.BtnHelpExpand.Content = if ($all.Count -and $open -eq $all.Count) { T '全部收起' } else { T '全部展开' }
}
$script:helpBulk = $false
$ctl.BtnHelpExpand.Add_Click({
    $all = Get-HelpSections
    $open = @($all | Where-Object { -not $_.IsExpanded }).Count -gt 0
    $script:helpBulk = $true
    try { foreach ($x in $all) { $x.IsExpanded = $open } } finally { $script:helpBulk = $false }
    Update-HelpExpand
})
# 单独点开的一节（或一个问题）在页面下方时，往上滚到能看见它的内容
$helpOpened = {
    param($s, $e)
    if (-not [object]::ReferenceEquals($e.OriginalSource, $s)) { return }
    Update-HelpExpand
    if ($script:helpBulk) { return }
    $x = $s
    [void]$win.Dispatcher.BeginInvoke([Action]{ try { $x.BringIntoView() } catch {} }.GetNewClosure(), [System.Windows.Threading.DispatcherPriority]::Loaded)
}
foreach ($x in @(Get-HelpSections) + @($ctl.HelpFaq.Children)) {
    $x.Add_Expanded($helpOpened)
    $x.Add_Collapsed({ param($s, $e) if ([object]::ReferenceEquals($e.OriginalSource, $s)) { Update-HelpExpand } })
}
$script:projectPage = 'https://github.com/Xuanqiyun/ClearC'
function Open-Web([string]$url) {
    # 用资源管理器打开网址：浏览器不会以管理员身份运行
    try { Start-Process -FilePath "$env:SystemRoot\explorer.exe" -ArgumentList $url; UI-Log ((T "打开网页：{0}") -f $url) }
    catch { Show-CopyHint ((T "打不开浏览器，请手动访问 {0}") -f $url) }
}
$ctl.BtnGitHub.Add_Click({ Open-Web $script:projectPage })
$ctl.BtnIssue.Add_Click({ Open-Web ($script:projectPage + '/issues') })
$ctl.BtnCopyDiag.Add_Click({
    $c = $null; try { $c = New-Object System.IO.DriveInfo 'C:\' } catch {}
    $info = @(
        ((T "腾挪 ClearC {0}") -f $script:AppVersion) + $(if ($script:AppBuild) { " ($($script:AppBuild))" } else { '' })
        ((T "Windows {0}，{1} 位") -f [Environment]::OSVersion.Version, $(if ([Environment]::Is64BitOperatingSystem) { 64 } else { 32 }))
        $(if ($c) { (T "C 盘剩余 {0} / 共 {1}") -f (Fmt $c.AvailableFreeSpace), (Fmt $c.TotalSize) } else { '' })
        ((T "屏幕可用区域 {0:N0} x {1:N0}") -f [System.Windows.SystemParameters]::WorkArea.Width, [System.Windows.SystemParameters]::WorkArea.Height)
        ''
        (T '---- 最近的运行记录 ----')
    )
    $tail = @()
    try { $tail = @(Get-Content -LiteralPath $script:logFile -Encoding UTF8 -Tail 80 -ErrorAction Stop) } catch { $tail = @(($ctl.Log.Text -split "`r?`n") | Select-Object -Last 80) }
    try { [System.Windows.Clipboard]::SetText((($info + $tail) -join "`r`n")); Show-CopyHint (T '已复制，可以粘贴到 GitHub 的问题（Issue）里') }
    catch { Show-CopyHint (T '复制失败，可以点「打开运行记录文件」再手动复制') }
})
# ---------- 检查扫描功能（自检）、检查新版本 ----------
$ctl.BtnSelfTest.Add_Click({
    if ($script:worker) { Show-Sheet -Title (T '请等当前操作做完') -Text (T '另一个操作还在进行中。') | Out-Null; return }
    $sync.Mode = 'selftest'; $sync.SelfTest = $null
    Start-Op (T '检查扫描功能')
    UI-Busy $true
    UI-Log (T '开始检查扫描功能')
    Start-Worker @'
$sync.SelfTest = Invoke-SelfTest $arg.Version
'@ @{ Version = $script:AppVersion }
})
$script:releasePage = 'https://github.com/Xuanqiyun/ClearC/releases'
$ctl.BtnCheckUpdate.Add_Click({
    if ($script:worker) { Show-Sheet -Title (T '请等当前操作做完') -Text (T '另一个操作还在进行中。') | Out-Null; return }
    $sync.Mode = 'update'; $sync.Update = $null
    Start-Op (T '检查新版本') -NoCard
    UI-Busy $true
    Start-Worker @'
try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    $r = Invoke-RestMethod -Uri 'https://api.github.com/repos/Xuanqiyun/ClearC/releases/latest' -Headers @{ 'User-Agent' = 'ClearC'; 'Accept' = 'application/vnd.github+json' } -TimeoutSec 20 -UseBasicParsing -ErrorAction Stop
    $sync.Update = @{ Ok = $true; Tag = [string]$r.tag_name; Url = [string]$r.html_url; Body = [string]$r.body }
} catch { $sync.Update = @{ Ok = $false; Err = $_.Exception.Message } }
'@ $null
})

$ctl.BtnOpenLog.Add_Click({
    if (Test-Path -LiteralPath $script:logFile) { Start-Process -FilePath "$env:SystemRoot\System32\notepad.exe" -ArgumentList ('"{0}"' -f $script:logFile) }
    else { Show-CopyHint (T '还没有运行记录') }
})

# ---------- 运行记录：默认收起，左下角打开 ----------
function Set-LogVisible([bool]$on) {
    $ctl.LogPanel.Visibility = if ($on) { 'Visible' } else { 'Collapsed' }
    $ctl.BtnLogText.Text = if ($on) { (T '收起运行记录') } else { (T '运行记录') }
    if ($on) { $ctl.Log.ScrollToEnd() }
}
$ctl.BtnLog.Add_Click({ Set-LogVisible ($ctl.LogPanel.Visibility -ne 'Visible') })
$ctl.BtnLogHide.Add_Click({ Set-LogVisible $false })

# ---------- 对话框：代替系统消息框。返回点中的按钮文字；按 Esc 或关掉窗口返回 $Cancel ----------
#   Kind：info 蓝色信息 / warn 橙色提醒 / danger 红色删除 / done 绿色完成
function Show-Sheet {
    param([string]$Title, [string]$Text = '', [string[]]$Items = $null, [string[]]$Buttons = @((T '好')),
          [string]$Primary = '', [string]$Cancel = '', [string]$Kind = 'info', [string]$Confirm = '')
    if (-not $Primary) { $Primary = $Buttons[-1] }
    if (-not $Cancel)  { $Cancel = $Buttons[0] }
    if ($script:uiTest) { $script:uiSheets.Add(("{0}`n{1}" -f $Title, $Text)); return $Cancel }   # 界面自测：不弹对话框，当作点了取消
    $sw = $null
    try { $sw = [Windows.Markup.XamlReader]::Parse([Theme]::Xaml($script:sheetXaml)) } catch { $sw = $null }
    if (-not $sw) {
        # 万一自绘对话框出问题，退回系统消息框，保证流程能走下去
        $body = $Text; if ($Items) { $body += "`n`n" + (($Items | ForEach-Object { "  · $_" }) -join "`n") }
        if ($Confirm) { $body += "`n`n" + $Confirm + (T "（点「是」表示你确认这一点）") }
        if ($Buttons.Count -le 1) { [System.Windows.MessageBox]::Show($win, $body, $Title) | Out-Null; return $Buttons[0] }
        $r = [System.Windows.MessageBox]::Show($win, $body, $Title, 'YesNo')
        if ($r -eq 'Yes') { return $Primary } else { return $Cancel }
    }
    foreach ($k in @($win.Resources.Keys)) { try { $sw.Resources[$k] = $win.Resources[$k] } catch {} }
    $look = @{
        info   = @(0xE946, '#0071E3', '#E8F1FC')
        warn   = @(0xE7BA, '#C93400', '#FFF1E6')
        danger = @(0xE74D, '#D70015', '#FDECEE')
        done   = @(0xE73E, '#248A3D', '#E6F4EA')
    }
    $lk = if ($look.ContainsKey($Kind)) { $look[$Kind] } else { $look.info }
    $sw.FindName('SIconGlyph').Text = [string][char][int]$lk[0]
    $sw.FindName('SIconGlyph').Foreground = New-Brush $lk[1]
    $sw.FindName('SIconBg').Fill = New-Brush $lk[2] 'b'
    $sw.FindName('STitle').Text = $Title
    $st = $sw.FindName('SText'); $st.Text = $Text; if (-not $Text) { $st.Visibility = 'Collapsed' }
    if ($Items) {
        $sw.FindName('SListBox').Visibility = 'Visible'
        $sw.FindName('SList').Text = (($Items | ForEach-Object { if ([string]$_ -match '^[✓!✗·…]') { [string]$_ } else { "•  $_" } }) -join "`n")
    }
    $panel = $sw.FindName('SButtons')
    $script:sheetResult = $Cancel
    $script:sheetGuarded = New-Object System.Collections.ArrayList
    foreach ($b in $Buttons) {
        $btn = New-Object System.Windows.Controls.Button
        $btn.Content = $b; $btn.Tag = $b; $btn.MinWidth = 88
        $btn.Padding = New-Object System.Windows.Thickness 16, 7, 16, 7; $btn.Margin = New-Object System.Windows.Thickness 8, 0, 0, 0
        if ($b -eq $Primary) { $btn.Style = $win.FindResource($(if ($Kind -eq 'danger') { 'Danger' } else { 'Primary' })); $btn.IsDefault = $true }
        else { $btn.Style = $win.FindResource('Secondary') }
        if ($b -eq $Cancel) { $btn.IsCancel = $true }
        if ($Confirm -and $b -ne $Cancel) { $btn.IsEnabled = $false; [void]$script:sheetGuarded.Add($btn) }
        $btn.Add_Click({ $script:sheetResult = [string]$this.Tag; [System.Windows.Window]::GetWindow($this).Close() })
        [void]$panel.Children.Add($btn)
    }
    if ($Confirm) {
        $sw.FindName('SAckBox').Visibility = 'Visible'
        $sw.FindName('SAckText').Text = $Confirm
        $ack = $sw.FindName('SAck')
        $ack.Style = $win.FindResource([System.Windows.Controls.CheckBox])
        $ack.Add_Checked({ foreach ($x in $script:sheetGuarded) { $x.IsEnabled = $true } })
        $ack.Add_Unchecked({ foreach ($x in $script:sheetGuarded) { $x.IsEnabled = $false } })
    }
    $sw.Add_MouseLeftButtonDown({ try { $this.DragMove() } catch {} })
    if ($win.IsVisible) { $sw.Owner = $win } else { $sw.WindowStartupLocation = 'CenterScreen' }
    $ctl.Dim.Visibility = 'Visible'
    try { [void]$sw.ShowDialog() } finally { $ctl.Dim.Visibility = 'Collapsed' }
    return $script:sheetResult
}

$sync = [hashtable]::Synchronized(@{})
$sync.L10n = $script:L10n   # 后台任务用同一张翻译表
$sync.Log = [System.Collections.Queue]::Synchronized((New-Object System.Collections.Queue))
$script:worker = $null
$script:op = $null
$sync.P = $null
$script:rows = $null
$script:dupRows = $null
$script:dupByGroup = @{}
$script:dupGroups = $null
$script:dupWaste = [double]0

function Fmt($b) {
    $b = [double]$b
    if ($b -ge 1GB) { "{0:N2} GB" -f ($b / 1GB) } elseif ($b -ge 1MB) { "{0:N1} MB" -f ($b / 1MB) } elseif ($b -ge 1KB) { "{0:N0} KB" -f ($b / 1KB) } else { "{0} B" -f $b }
}
function FmtSpan([TimeSpan]$ts) {
    $sec = [int][math]::Floor($ts.TotalSeconds)
    if ($sec -ge 3600) { (T "{0} 小时 {1} 分") -f [int][math]::Floor($sec / 3600), [int][math]::Floor(($sec % 3600) / 60) }
    elseif ($sec -ge 60) { (T "{0} 分 {1} 秒") -f [int][math]::Floor($sec / 60), ($sec % 60) }
    else { ((T "{0} 秒") -f $sec) }
}
function DriveFree([string]$d) { try { [double](New-Object System.IO.DriveInfo $d).AvailableFreeSpace } catch { [double]0 } }
function Clamp01($x) { [math]::Max(0.0, [math]::Min(1.0, [double]$x)) }

# ---------- 运行中的提示：底部进度条 + 窗口中间的进度卡片 ----------
# role：f 文字和图标  b 底色  d 边框（深色模式按用途换颜色）
function New-Brush([string]$hex, [string]$role = 'f') { New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color][System.Windows.Media.ColorConverter]::ConvertFromString([Theme]::Map($hex, [char]$role))) }
# 把多行带颜色的文字写进一个 TextBlock：$lines = @( @('文字', '#颜色', $粗体), ... )
function Set-Lines($tb, $lines) {
    $tb.Inlines.Clear()
    $first = $true
    foreach ($l in $lines) {
        if (-not $first) { $tb.Inlines.Add((New-Object System.Windows.Documents.LineBreak)) }
        $run = New-Object System.Windows.Documents.Run ([string]$l[0])
        if ($l.Count -gt 1 -and $l[1]) { $run.Foreground = New-Brush $l[1] }
        if ($l.Count -gt 2 -and $l[2]) { $run.FontWeight = 'SemiBold' }
        $tb.Inlines.Add($run)
        $first = $false
    }
}

$script:movePhases = @(
    @('kill',    (T '关闭占用这些文件的聊天软件（开着的话没法搬）')),
    @('measure', (T '统计要搬多少')),
    @('copy',    (T '复制到目标盘')),
    @('verify',  (T '核对复制是否完整')),
    @('link',    (T '把原位置换成链接（软件照常找得到；被占用时会关掉占用的程序重试）')),
    @('cleanup', (T '删除 C 盘上的原目录，腾出空间'))
)
function Move-Checklist($p) {
    $cur = [string]$p.MovePhase
    $order = @($script:movePhases | ForEach-Object { $_[0] })
    $ci = [array]::IndexOf($order, $cur); if ($cur -eq 'done') { $ci = $order.Count }
    $lines = @()
    for ($i = 0; $i -lt $order.Count; $i++) {
        if ($order[$i] -eq 'kill' -and -not $p.HasKill) { continue }
        $text = $script:movePhases[$i][1]
        if ($p.MoveBack) {
            $text = @{ kill = (T '关闭占用这些文件的软件'); measure = (T '统计要搬回多少'); copy = (T '复制回 ') + $p.MoveDest; verify = (T '核对复制是否完整'); link = (T '拆掉链接，换回真正的文件夹'); cleanup = (T '删除目标盘上的那份') }[$order[$i]]
        }
        elseif ($order[$i] -eq 'copy' -and $p.MoveDest) { $text = (T '复制到 ') + $p.MoveDest; if ($p.MoveReuse) { $text = (T '补复制有变化的文件到 ') + $p.MoveDest + (T '（上次的副本接着用）') } }
        if ($i -lt $ci)      { $lines += ,@(('✓  ' + $text), '#248A3D', $false) }
        elseif ($i -eq $ci)  { $lines += ,@(('▶  ' + $text), '#0071E3', $true) }
        else                 { $lines += ,@(('○  ' + $text), '#AEAEB2', $false) }
    }
    return ,$lines
}
function Plan-Lines {
    $lines = @()
    $marks = @{ wait = '○'; run = '▶'; ok = '✓'; warn = '!'; fail = '✗'; skip = '·' }
    foreach ($x in $script:runPlan) {
        $v = if ($sync.Status) { $sync.Status[$x.Idx] } else { $null }
        $kind = if ($v) { [string]$v[1] } else { 'wait' }
        $text = if ($v) { [string]$v[0] } else { (T '等待') }
        $lines += ,@(((T "{0}  {1}：{2}") -f $marks[$kind], $x.Name, $text), $script:statusColor[$kind], ($kind -eq 'run'))
    }
    return ,$lines
}

function Show-Overlay {
    $ctl.Overlay.Visibility = 'Visible'
    $ctl.OvClose.Visibility = 'Collapsed'; $ctl.OvHide.Visibility = 'Visible'
    $ctl.OvNote.Text = (T '可以最小化窗口，任务栏图标上也有进度。做完前不要关闭本窗口。')
    $ctl.OvBar.IsIndeterminate = $true; $ctl.OvSubBar.Visibility = 'Collapsed'
    $ctl.OvStep.Text = (T '准备中…'); $ctl.OvWhat.Text = ''; $ctl.OvDetail.Text = ''; $ctl.OvChecklist.Inlines.Clear()
    $showPlan = (@('run', 'movemany') -contains $sync.Mode) -and $script:runPlan
    $ctl.OvPlanBox.Visibility = if ($showPlan) { 'Visible' } else { 'Collapsed' }
    if ($showPlan) { Set-Lines $ctl.OvPlan (Plan-Lines) }
}

# 开始一项操作：重置进度面板，开始计时，弹出进度卡片
function Start-Op([string]$title, [switch]$NoCard) {
    $sync.P = [hashtable]::Synchronized(@{ Steps = 0; Step = 0; StepName = ''; SubKind = 'none'; SubDone = [double]0; SubTotal = [double]0;
                                          SubStart = (Get-Date); FreeC0 = [double]0; DestDrive = ''; DestFree0 = [double]0; Detail = ''; MoveItem = $false; CanCancel = $true })
    $sync.Cancel = $false; $sync.WasCancelled = $false; $script:cancelUi = ''
    $script:op = @{ Title = $title; Start = (Get-Date) }
    $ctl.OpPanel.Visibility = 'Visible'
    $ctl.OpTitle.Text = $title; $ctl.OpTime.Text = (T '已用 0 秒'); $ctl.OpDetail.Text = ''; $ctl.OpSubTime.Text = ''
    $ctl.OpBar.IsIndeterminate = $true; $ctl.OpBar.Value = 0
    $ctl.OpSubBar.Visibility = 'Collapsed'
    $ctl.OvTitle.Text = $title; $ctl.OvTime.Text = (T '已用 0 秒')
    if (-not $NoCard) { Show-Overlay }
    UI-Log ((T "开始：{0}") -f $title)
}

# 结束：进度条拉满，显示总用时。执行和删除会在卡片上留下结果，等用户点「关闭」
function End-Op([string]$result, [switch]$KeepCard, [string]$headline = '', $reportLines = $null) {
    if (-not $script:op) { return }
    $cx = [bool]$sync.WasCancelled
    $ctl.OvCancel.Visibility = 'Collapsed'; $ctl.OpCancel.Visibility = 'Collapsed'; $script:cancelUi = ''
    $el = (Get-Date) - $script:op.Start
    $ctl.OpBar.IsIndeterminate = $false; $ctl.OpBar.Value = 100
    $ctl.OpSubBar.Visibility = 'Collapsed'
    $ctl.OpTitle.Text = (T "{0}：{1}") -f $script:op.Title, $result
    $ctl.OpTime.Text = (T "共用时 ") + (FmtSpan $el)
    $script:lastElapsed = $el
    if ($win.TaskbarItemInfo) { $win.TaskbarItemInfo.ProgressState = 'None' }
    $ctl.OpDetail.Text = ''; $ctl.OpSubTime.Text = ''
    UI-Log ((T "{0}：{1}，共用时 {2}") -f $script:op.Title, $result, (FmtSpan $el))
    if ($KeepCard -and $ctl.Overlay.Visibility -eq 'Visible') {
        $ctl.OvTitle.Text = $script:op.Title + $(if ($cx) { (T '：已中途取消') } else { (T '：已完成') })
        $ctl.OvTime.Text = (T "共用时 ") + (FmtSpan $el)
        $ctl.OvBar.IsIndeterminate = $false; $ctl.OvBar.Value = 100
        $ctl.OvSubBar.Visibility = 'Collapsed'
        $ctl.OvStep.Text = if ($headline) { $headline } else { $result }
        $ctl.OvWhat.Text = ''; $ctl.OvDetail.Text = ''; $ctl.OvChecklist.Inlines.Clear()
        if ($reportLines) { $ctl.OvPlanBox.Visibility = 'Visible'; Set-Lines $ctl.OvPlan $reportLines }
        $ctl.OvNote.Text = (T '每一项的结果也显示在列表里；详细过程可以在左下角「运行记录」里查看。')
        $ctl.OvClose.Visibility = 'Visible'; $ctl.OvHide.Visibility = 'Collapsed'
        $script:cardShowsResult = $true
    } else {
        $ctl.Overlay.Visibility = 'Collapsed'
        $script:cardShowsResult = $false
    }
    $script:op = $null
}

# ---------- 中途取消 ----------
# 能中途取消的操作。look = 只是查看，不用确认；其余先问一句。
# 不在这里的（删除单个文件夹、系统压缩、压缩虚拟磁盘、卸载、删除多余副本）要么很快做完，要么停在一半不安全
$script:cancelModes = @{ scan = 'look'; apps = 'look'; dup = 'look'; map = 'look'
    run = 'run'; dupdel = 'dupdel'; merge = 'merge'; leftdel = 'leftdel'; fcompress = 'fcompress'; moveback = 'moveback'; vmove = 'move'; appmove = 'move'
    movescan = 'look'; movemany = 'movemany'; mapdel = 'dupdel'; selftest = 'look' }
$script:cancelUi = ''
function Update-CancelUi {
    $m = [string]$sync.Mode
    if (-not ($script:worker -and $script:op -and $m -and $script:cancelModes.ContainsKey($m))) {
        $ctl.OvCancel.Visibility = 'Collapsed'; $ctl.OpCancel.Visibility = 'Collapsed'; $script:cancelUi = ''; return
    }
    $state = if ($sync.Cancel) { 'pending' } elseif ($sync.P -and $sync.P.CanCancel -eq $false) { 'hold' } else { 'ready' }
    if ($state -eq $script:cancelUi) { return }
    $script:cancelUi = $state
    foreach ($b in @($ctl.OvCancel, $ctl.OpCancel)) {
        $b.Visibility = 'Visible'
        $b.IsEnabled = ($state -eq 'ready')
        $b.Content = if ($state -eq 'pending') { (T '正在取消…') } else { (T '取消') }
    }
    if ($ctl.OvClose.Visibility -ne 'Visible') {   # 卡片上显示的不是上一次的结果
        $ctl.OvNote.Text = switch ($state) {
            'pending' { (T '正在取消：做完手上这一小步就停下，已经做完的不会撤销。') }
            'hold'    { (T '这一步不能中断（正在换成链接、删除备份或运行系统命令），做完就可以取消。') }
            default   { (T '可以最小化窗口，任务栏图标上也有进度。做完前不要关闭本窗口。') }
        }
    }
}
function Request-Cancel {
    $w = $script:worker
    if (-not $w -or $sync.Cancel) { return }
    $m = [string]$sync.Mode
    if (-not $script:cancelModes.ContainsKey($m)) { return }
    if ($sync.P -and $sync.P.CanCancel -eq $false) { return }
    $kind = $script:cancelModes[$m]
    if ($kind -ne 'look') {
        $text = switch ($kind) {
            'run'       { (T "已经做完的项目不会撤销，还没开始的都不做了。`n`n正在做的这一项会停在安全的地方：清理会停下，已经删掉的不会回来；搬家如果还在复制，C 盘上的原文件夹不动，已复制的部分留在目标盘，下次再搬会接着复制；如果正在换成链接或运行系统命令，会等这一步做完再停。") }
            'dupdel'    { (T '已经删掉的文件不会回来，剩下的不删了。') }
            'movemany'  { (T "已经搬好的不会撤销，还没开始的都不搬了。`n`n正在搬的这一项会停在安全的地方：如果还在复制，C 盘上的原文件夹不动，已复制的部分留在目标盘，下次再搬会接着复制；如果正在换成链接，会等这一步做完再停。") }
            'merge'     { (T '已经合并的保持合并，照常可用；剩下的不合并了。') }
            'leftdel'   { (T '已经移到回收站的还在回收站里，剩下的不删了。') }
            'fcompress' { (T '已经压缩的文件保持压缩，照常可用；剩下的不压缩了。') }
            'moveback'  { (T '数据仍在目标盘上，C 盘上的链接不动，软件照常使用；复制回 C 盘的那一半会删掉。如果已经在换回文件夹，会等这一步做完再停。') }
            default     { (T "C 盘上的原文件夹不动，软件照常使用。已复制到目标盘的部分先留着，下次再搬会接着复制；不需要的话，可以在「搬家管理」里删掉这份副本。如果已经在换成链接，会等这一步做完再停。") }
        }
        $ans = Show-Sheet -Kind warn -Title ((T "取消「{0}」？") -f $script:op.Title) -Text $text -Buttons @((T '继续做'), (T '停下来')) -Primary (T '停下来') -Cancel (T '继续做')
        if ($ans -ne (T '停下来')) { return }
        if (-not [object]::ReferenceEquals($w, $script:worker)) { return }   # 对话框开着的时候已经做完了
    }
    Set-CancelFlags
    UI-Log (T '正在取消：做完手上这一小步就停下。')
    Update-CancelUi
}
function Set-CancelFlags {
    $m = [string]$sync.Mode
    $sync.Cancel = $true
    if ($script:cancelModes.ContainsKey($m)) { [DirStat]::Cancel = $true; [DiskMap]::Cancel = $true }   # 读文件表、统计大小都停下
    if ($m -eq 'dup' -or $m -eq 'dupdel' -or $m -eq 'merge') { [DupFinder]::Cancel = $true }
    if ($m -eq 'map') { [DiskMap]::Cancel = $true }
    if ($m -eq 'scan') { $script:oneClickPending = $false }
}

# 每 0.3 秒刷新一次：底部进度条和中间的卡片显示同样的内容
function Update-Op {
    if (-not $script:op) { return }
    $p = $sync.P
    $now = Get-Date
    $el = $now - $script:op.Start
    $frac = $null          # 总进度 0~1；$null 表示不确定
    $etaEl = $el           # 用来估算剩余时间的已用时长
    $etaOk = $true         # 各步工作量差不多时，才用总进度估算剩余时间
    $stepLine = ''         # 现在在做第几步
    $what = ''             # 这一步是干什么的
    $detail = ''; $subFrac = $null; $subShow = $false; $subTime = ''

    if ($sync.Mode -eq 'dup') {
        $ph = [DupFinder]::Phase
        if ($ph -eq 'list') {
            $stepLine = (T '第 1 步：列出所有文件')
            $what = (T '先把每个位置里的文件名和大小都看一遍，名字和大小都对得上的才可能是重复文件。')
            $detail = (T "已看过 {0:N0} 个文件夹、{1:N0} 个文件    {2}") -f [DupFinder]::DirsSeen, [DupFinder]::FilesSeen, (Shorten ([DupFinder]::Current))
        } elseif ($ph -eq 'quick' -or $ph -eq 'deep') {
            if ($script:op.PhaseName -ne $ph) { $script:op.PhaseName = $ph; $script:op.PhaseStart = $now }
            $etaEl = $now - $script:op.PhaseStart
            $tot = [double][DupFinder]::BytesTotal
            if ($ph -eq 'quick') {
                $stepLine = (T "第 2 步：快速筛选 {0:N0} 个同名同大小的文件") -f [DupFinder]::FilesTotal
                $what = (T '每个文件只读开头和结尾各 64 KB，内容明显不同的在这一步就排除掉。')
            } else {
                $how = if ($ctl.SpeedExact.IsChecked) { (T '每个文件读完全部内容') } else { (T '小文件读全文，大文件抽 16 处') }
                $stepLine = (T "第 3 步：比对剩下的 {0:N0} 个文件") -f [DupFinder]::FilesTotal
                $what = ((T "确认内容是否真的相同（{0}）。") -f $how)
            }
            if ($tot -gt 0) { $frac = [math]::Min(0.99, [DupFinder]::BytesDone / $tot) } else { $frac = 0.99 }
            $detail = (T "{0:N0} / {1:N0} 个，已读 {2} / {3}") -f [DupFinder]::FilesDone, [DupFinder]::FilesTotal, (Fmt ([DupFinder]::BytesDone)), (Fmt $tot)
            if ($sync.DriveNote) { $detail += "    " + $sync.DriveNote }
        } elseif ($ph -eq 'finish') {
            $stepLine = (T '整理结果')
        }
    }
    elseif ($p -and $p.Steps -gt 0) {
        $step = [math]::Max(1, [int]$p.Step)
        $stepLine = (T "第 {0} / {1} 项：{2}") -f $step, $p.Steps, $p.StepName
        if (@('run', 'movemany') -contains $sync.Mode) {
            $what = [string]$p.StepNote
            if ($p.MoveItem -and [int]$p.PathCount -gt 1 -and [int]$p.PathNo -gt 0) { $what = (T "第 {0} / {1} 个文件夹：{2}") -f $p.PathNo, $p.PathCount, $p.MovePath }
            elseif ($p.MoveItem -and $p.MovePath) { $what = (T "从 {0} 搬到 {1}") -f $p.MovePath, $p.MoveDest }
        } elseif ($sync.Mode -eq 'scan') {
            $what = (T '统计这一项占了多少空间。扫描只是查看，不会删除任何东西。')
        } elseif ($sync.Mode -eq 'movescan') {
            $what = (T '统计每一项占了多少空间，看看哪些能搬。只是查看，不会改动任何东西。')
        } elseif ($sync.Mode -eq 'dupdel') {
            $what = (T '删除前会再确认保留的那份还在、内容相同；抽样判定的文件会逐字节核对。')
        }
        $kind = [string]$p.SubKind
        $subEl = $now - [datetime]$p.SubStart
        if ($kind -eq 'copy') {
            # 已复制量取两种算法的较大者：robocopy 报告的字节数，或目标盘可用空间的减少量
            $df = DriveFree $p.DestDrive
            $base = [double]$p.SubBase
            $drop = if ($df -gt 0 -and [double]$p.DestFree0 -gt 0) { [double]$p.DestFree0 - $df } else { 0 }
            $done = [math]::Max([double]$p.SubDone, [double]($base + $drop))
            $tot  = [double]$p.SubTotal
            $subShow = $true
            if ($tot -gt 0) { $subFrac = [math]::Min(0.99, (Clamp01 ($done / $tot))) }
            $speed = if ($subEl.TotalSeconds -gt 1) { [math]::Max([double]0, [double]($done - $base)) / $subEl.TotalSeconds } else { 0 }
            $detail = (T "已复制 {0} / {1}，{2}/秒") -f (Fmt $done), (Fmt $tot), (Fmt $speed)
            if ($base -gt 0) { $detail = (T "上次已复制 {0}，正在补有变化的文件：{1} / {2}") -f (Fmt $base), (Fmt $done), (Fmt $tot) }
            if ($speed -gt 0 -and $subEl.TotalSeconds -gt 5 -and $tot -gt $done) { $subTime = (T "这一项还要约 ") + (FmtSpan ([TimeSpan]::FromSeconds(($tot - $done) / $speed))) }
            else { $subTime = (T "这一项已用 ") + (FmtSpan $subEl) }
            $etaOk = $false
        } elseif ($kind -eq 'delete') {
            $fc = DriveFree 'C:'
            $done = if ($fc -gt 0) { $fc - [double]$p.FreeC0 } else { 0 }
            $tot  = [double]$p.SubTotal
            $subShow = $true
            if ($tot -gt 0) { $subFrac = [math]::Min(0.99, (Clamp01 ($done / $tot))) }
            $detail = if ($tot -gt 0) { (T "已释放 {0} / 约 {1}") -f (Fmt ([math]::Max([double]0, [double]$done))), (Fmt $tot) } else { [string]$p.Detail }
            $subTime = (T "这一项已用 ") + (FmtSpan $subEl)
            $etaOk = $false
        } elseif ($kind -eq 'verify') {
            $vt = [double][DupFinder]::VerifyTotal
            $subShow = $true
            if ($vt -gt 0) { $subFrac = [math]::Min(0.99, [DupFinder]::VerifyDone / $vt) }
            $detail = (T "逐字节核对 {0}：{1} / {2}") -f (Shorten ([IO.Path]::GetFileName([string]$p.Detail))), (Fmt ([DupFinder]::VerifyDone)), (Fmt $vt)
            $subTime = (T "删除前核对")
        } elseif ($kind -eq 'slow') {
            $subShow = $true
            $detail = [string]$p.Detail
            $subTime = (T "这一项已用 ") + (FmtSpan $subEl)
            $etaOk = $false
        } elseif ($kind -eq 'mft') {
            $subShow = $true
            $rt = [double][Mft]::RecordsTotal
            if ($rt -gt 0) {
                $subFrac = [math]::Min(0.99, [double][Mft]::RecordsDone / $rt)
                $detail = (T "读取 C 盘的文件表：{0:N0} / {1:N0} 条记录") -f [Mft]::RecordsDone, $rt
            } elseif ([string][DiskMap]::Phase -eq 'walk') { $detail = (T '逐个文件夹统计') }
            else { $detail = (T '读取 C 盘的文件表') }
            $subTime = (T "这一项已用 ") + (FmtSpan $subEl)
        } elseif ($kind -eq 'measure') {
            $subShow = $true
            $detail = (T "{0}：已数 {1:N0} 个文件，{2}") -f [string]$p.Detail, [DirStat]::Files, (Fmt ([DirStat]::Bytes))
            $subTime = (T "这一项已用 ") + (FmtSpan $subEl)
        } elseif ($kind -eq 'action') {
            $subShow = $true
            $detail = [string]$p.Detail
            $subTime = (T "这一项已用 ") + (FmtSpan $subEl)
        }
        $sf = if ($subFrac -ne $null) { $subFrac } else { 0 }
        $frac = [math]::Min(0.99, (($step - 1) + $sf) / [double]$p.Steps)
    }
    elseif ($sync.Mode -eq 'hogs') { $stepLine = (T '统计 C 盘各目录的大小'); $what = (T '找出 C 盘上最占地方的文件夹和大文件，目录多时要几分钟。') }
    elseif ($sync.Mode -eq 'map') {
        $stepLine = (T "扫描 {0}") -f $sync.MapRoot
        if ([string][DiskMap]::Phase -eq 'mft') {
            $what = (T '直接读取 NTFS 的文件表（MFT），比逐个文件夹查看快得多。只是查看，不会改动任何东西。')
            $rt = [double][Mft]::RecordsTotal
            if ($rt -gt 0) {
                $detail = (T "已读 {0:N0} / {1:N0} 条文件记录") -f [Mft]::RecordsDone, $rt
                $frac = [math]::Min(0.99, [double][Mft]::RecordsDone / $rt)
            } else { $detail = (T '读取文件表') }
        } else {
            $what = (T '把每个文件夹里的文件大小数一遍。只是查看，不会改动任何东西。')
            $detail = (T "已看过 {0:N0} 个文件夹、{1:N0} 个文件，{2}    {3}") -f [DiskMap]::DirsSeen, [DiskMap]::FilesSeen, (Fmt ([DiskMap]::BytesSeen)), (Shorten ([DiskMap]::Current))
            if ([double]$sync.MapUsed -gt 0) { $frac = [math]::Min(0.99, [double][DiskMap]::BytesSeen / [double]$sync.MapUsed) }
        }
    }

    $timeText = (T "已用 ") + (FmtSpan $el)
    if ($frac -ne $null -and $etaOk -and $frac -gt 0.03 -and $etaEl.TotalSeconds -gt 3) {
        $timeText += (T "，预计还要 ") + (FmtSpan ([TimeSpan]::FromSeconds($etaEl.TotalSeconds * (1 - $frac) / $frac)))
    }

    # ---- 底部进度条 ----
    $ctl.OpTitle.Text = if ($stepLine) { (T "{0}，{1}") -f $script:op.Title, $stepLine } else { $script:op.Title }
    $ctl.OpTime.Text = $timeText
    if ($frac -ne $null) { $ctl.OpBar.IsIndeterminate = $false; $ctl.OpBar.Value = 100 * $frac } else { $ctl.OpBar.IsIndeterminate = $true }
    $ctl.OpDetail.Text = $detail
    $ctl.OpSubTime.Text = $subTime
    if ($subShow) {
        $ctl.OpSubBar.Visibility = 'Visible'
        if ($subFrac -ne $null) { $ctl.OpSubBar.IsIndeterminate = $false; $ctl.OpSubBar.Value = 100 * $subFrac } else { $ctl.OpSubBar.IsIndeterminate = $true }
    } else { $ctl.OpSubBar.Visibility = 'Collapsed' }

    # ---- 任务栏图标上的进度，窗口最小化也看得到 ----
    if ($win.TaskbarItemInfo) {
        if ($frac -ne $null) { $win.TaskbarItemInfo.ProgressState = 'Normal'; $win.TaskbarItemInfo.ProgressValue = [double]$frac }
        else { $win.TaskbarItemInfo.ProgressState = 'Indeterminate' }
    }

    # ---- 中间的进度卡片 ----
    if ($ctl.Overlay.Visibility -eq 'Visible') {
        $ctl.OvTime.Text = $timeText
        if ($frac -ne $null) { $ctl.OvBar.IsIndeterminate = $false; $ctl.OvBar.Value = 100 * $frac } else { $ctl.OvBar.IsIndeterminate = $true }
        $ctl.OvStep.Text = if ($stepLine) { $stepLine } else { (T '准备中…') }
        $ctl.OvWhat.Text = $what
        $ctl.OvDetail.Text = if ($subTime) { "$detail        $subTime" } else { $detail }
        if ($subShow) {
            $ctl.OvSubBar.Visibility = 'Visible'
            if ($subFrac -ne $null) { $ctl.OvSubBar.IsIndeterminate = $false; $ctl.OvSubBar.Value = 100 * $subFrac } else { $ctl.OvSubBar.IsIndeterminate = $true }
        } else { $ctl.OvSubBar.Visibility = 'Collapsed' }
        if ((@('run', 'movemany') -contains $sync.Mode) -and $p -and $p.MoveItem) { Set-Lines $ctl.OvChecklist (Move-Checklist $p) } else { $ctl.OvChecklist.Inlines.Clear() }
        if ((@('run', 'movemany') -contains $sync.Mode) -and $script:runPlan) { Set-Lines $ctl.OvPlan (Plan-Lines) }
    }
    Update-CancelUi
}

function Shorten($p) { if (-not $p) { return '' }; if ($p.Length -le 80) { $p } else { '…' + $p.Substring($p.Length - 79) } }

$script:logFile = Join-Path ([IO.Path]::GetTempPath()) 'CleanC-run.log'
function Write-LogFile([string]$m) { try { [IO.File]::AppendAllText($script:logFile, ("{0:yyyy-MM-dd HH:mm:ss}  {1}`r`n" -f (Get-Date), $m), [Text.Encoding]::UTF8) } catch {} }
function UI-Log($m) { $ctl.Log.AppendText("$m`r`n"); $ctl.Log.ScrollToEnd(); Write-LogFile ([string]$m) }
# 存储空间卡片：一条横条分成 已用 / 可释放（按扫描后的默认选择） / 可用 三段
$script:reclaim = [double]0
function UI-Status {
    $total = [double]0; $free = [double]0
    try { $di = New-Object System.IO.DriveInfo 'C:\'; $total = [double]$di.TotalSize; $free = [double]$di.AvailableFreeSpace }
    catch { $d = Get-PSDrive C; $free = [double]$d.Free; $total = [double]($d.Used + $d.Free) }
    $used = [math]::Max([double]0, [double]($total - $free))
    $rec = [math]::Min([double]$script:reclaim, [double]$used)
    $ctl.CapFree.Text = Fmt $free
    $ctl.CapTotal.Text = (T "共 {0}，已用 {1}") -f (Fmt $total), (Fmt $used)
    $star = [System.Windows.GridUnitType]::Star
    $cols = $ctl.CapBar.ColumnDefinitions
    $cols[0].Width = New-Object System.Windows.GridLength ([math]::Max([double]0.0001, [double]($used - $rec))), $star
    $cols[1].Width = New-Object System.Windows.GridLength ([math]::Max([double]0, [double]$rec)), $star
    $cols[2].Width = New-Object System.Windows.GridLength ([math]::Max([double]0.0001, [double]$free)), $star
    $ctl.CapReclaim.Text = if ($rec -gt 0) { (T "可释放约 ") + (Fmt $rec) } else { (T '可释放（扫描后显示）') }
}
function UI-Busy($b) {
    $ctl.BtnScan.IsEnabled = -not $b; $ctl.BtnHogs.IsEnabled = -not $b; $ctl.BtnOneClick.IsEnabled = -not $b
    $ctl.BtnRun.IsEnabled = (-not $b) -and ($script:rows -ne $null)
    $ctl.BtnDupScan.IsEnabled = -not $b
    $ctl.BtnAddRoot.IsEnabled = -not $b; $ctl.Roots.IsEnabled = -not $b
    $has = (-not $b) -and ($script:dupRows -ne $null) -and ($script:dupRows.Count -gt 0)
    foreach ($n in 'BtnKeepNew','BtnKeepOld','BtnPickC','BtnPickNone') { $ctl[$n].IsEnabled = $has }
    $ctl.BtnDupStop.IsEnabled = $b -and ($sync.Mode -eq 'dup')
    foreach ($n in 'BtnMapScan','BtnAppsRefresh','BtnMovesRefresh','BtnCosOn','BtnCosOff','BtnPfMove','BtnPfAuto','BtnHibReduced','BtnHibOff','BtnHibFull','BtnFolderCompress','BtnSaveRefresh') { $ctl[$n].IsEnabled = -not $b }
    $ctl.BtnMapStop.IsEnabled = $b -and ($sync.Mode -eq 'map')
    if (-not $b -and $script:pageLoaded.save) { $on = Get-CompactOSOn; $ctl.BtnCosOn.IsEnabled = -not $on; $ctl.BtnCosOff.IsEnabled = $on }
    Update-DupSummary
    Update-MapSel
    Update-CandSel
}

function Start-Worker([string]$code, $arg) {
    $sync.Cancel = $false; $sync.WasCancelled = $false; Set-CanCancel $true
    [DirStat]::Cancel = $false; [DupFinder]::Cancel = $false; [DiskMap]::Cancel = $false
    $rs = [runspacefactory]::CreateRunspace(); $rs.ApartmentState = 'STA'; $rs.ThreadOptions = 'ReuseThread'; $rs.Open()
    $rs.SessionStateProxy.SetVariable('sync', $sync)
    $ps = [powershell]::Create(); $ps.Runspace = $rs
    $ps.AddScript("param(`$arg)`n" + $engine + "`nInit-DriveThreads`n" + $code).AddArgument($arg) | Out-Null
    $script:worker = @{ PS = $ps; Handle = $ps.BeginInvoke(); RS = $rs }
}

