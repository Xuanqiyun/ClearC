# ------------------------------------------------------------
# 省空间
# ------------------------------------------------------------
function Load-Save {
    $on = Get-CompactOSOn
    $ctl.SaveCosState.Text = if ($on) { (T '当前：已开启，系统文件已压缩存放') } else { (T '当前：未开启') }
    $ctl.BtnCosOn.IsEnabled = -not $on; $ctl.BtnCosOff.IsEnabled = $on
    $pf = Get-PageFileInfo
    $desc = @($pf.Files | ForEach-Object { (T "{0}（约 {1}）") -f $_.Path, (Fmt ($_.MB * 1MB)) }) -join (T '、')
    if (-not $desc) { $desc = (T '没有页面文件') }
    $ctl.SavePfState.Text = ((T "当前：{0}") -f $desc) + $(if ($pf.Auto) { (T '，由系统自动管理') } else { '' })
    $ctl.SavePfDrive.Items.Clear()
    foreach ($d in (Fixed-Drives -NoSystem)) {
        $it = New-Object System.Windows.Controls.ComboBoxItem
        $it.Content = (T "{0}  空闲 {1}") -f $d.Name.TrimEnd('\'), (Fmt $d.AvailableFreeSpace); $it.Tag = $d.Name.TrimEnd('\')
        [void]$ctl.SavePfDrive.Items.Add($it)
    }
    if ($ctl.SavePfDrive.Items.Count -gt 0) { $ctl.SavePfDrive.SelectedIndex = 0 }
    $ctl.BtnPfMove.IsEnabled = $ctl.SavePfDrive.Items.Count -gt 0
    Start-RestoreInfo
    $h = Get-HiberInfo
    $ctl.SaveHibState.Text = if (-not $h.Exists) { (T '当前：已关闭休眠，没有 hiberfil.sys') } elseif ($h.Reduced) { ((T "当前：精简（只留快速启动），占 {0}") -f $(Fmt $h.Bytes)) } else { ((T "当前：完整休眠，占 {0}") -f $(Fmt $h.Bytes)) }
    $col = New-Object 'System.Collections.ObjectModel.ObservableCollection[VdiskRow]'
    foreach ($v in (Get-VDisks)) {
        $r = New-Object VdiskRow
        $r.Name = $v.Name; $r.Path = $v.Path; $r.Kind = $v.Kind; $r.Note = $v.Note; $r.CanCompact = [bool]$v.Compact; $r.CanMove = [bool]$v.Move
        if (Test-Path -LiteralPath $v.Path -PathType Leaf) { $r.Size = (Get-Item -LiteralPath $v.Path -Force).Length; $r.SizeText = Fmt $r.Size }
        elseif ($script:worker) { $r.SizeText = '—' }
        else { $r.Size = [long](DirBytes $v.Path); $r.SizeText = Fmt $r.Size }
        $col.Add($r)
    }
    $ctl.VdList.ItemsSource = $col
    $ctl.VdEmpty.Visibility = if ($col.Count -gt 0) { 'Collapsed' } else { 'Visible' }
}
$ctl.BtnSaveRefresh.Add_Click({ Load-Save })
# 系统还原点（卷影副本）：只看，不删；要调整打开 Windows 自己的「系统保护」。
# 在另一个线程里读（查卷影副本可能要先启动卷影复制服务，要几秒），读好了再填到页面上
$script:rpQuery = {
    param([string]$drive)
    $r = @{ Ok = $false; Storage = $false; Count = 0; Used = [double]0; Max = [double]0; Unbounded = $false }
    try {
        $vol = @(Get-CimInstance -ClassName Win32_Volume -Filter ("DriveLetter='{0}'" -f $drive) -ErrorAction Stop)[0]
        if (-not $vol) { return $r }
        $r.Ok = $true
        foreach ($s in @(Get-CimInstance -ClassName Win32_ShadowStorage -ErrorAction Stop)) {
            if ($s.Volume -and [string]$s.Volume.DeviceID -eq [string]$vol.DeviceID) {
                $r.Storage = $true; $r.Used += [double]$s.UsedSpace
                if ([double]$s.MaxSpace -le 0 -or [double]$s.MaxSpace -ge 1e18) { $r.Unbounded = $true } else { $r.Max += [double]$s.MaxSpace }
            }
        }
        $r.Count = @(Get-CimInstance -ClassName Win32_ShadowCopy -ErrorAction Stop | Where-Object { [string]$_.VolumeName -eq [string]$vol.DeviceID }).Count
    } catch {}
    return $r
}
$script:rpPs = $null
function Start-RestoreInfo {
    if ($script:rpPs) { return }            # 上一次还没读完
    $ctl.SaveRpState.Text = (T '当前：正在读取…')
    try {
        $ps = [powershell]::Create()
        [void]$ps.AddScript($script:rpQuery.ToString()).AddArgument([string]$env:SystemDrive)
        $script:rpPs = $ps; $script:rpAr = $ps.BeginInvoke()
    } catch { $script:rpPs = $null; $ctl.SaveRpState.Text = (T '当前：读不到还原点的信息'); return }
    $t = New-Object System.Windows.Threading.DispatcherTimer
    $t.Interval = [TimeSpan]::FromMilliseconds(300)
    $t.Add_Tick({
        if (-not $script:rpPs) { $this.Stop(); return }
        if (-not $script:rpAr.IsCompleted) { return }
        $this.Stop()
        $r = $null
        try { $out = $script:rpPs.EndInvoke($script:rpAr); if ($out.Count -gt 0) { $r = $out[$out.Count - 1] } } catch {}
        try { $script:rpPs.Dispose() } catch {}
        $script:rpPs = $null
        Show-RestoreInfo $r
    })
    $t.Start()
}
function Show-RestoreInfo($r) {
    $ctl.SaveRpState.Text = if (-not $r -or -not $r.Ok) { (T '当前：读不到还原点的信息') }
        elseif ($r.Count -eq 0 -and -not $r.Storage) { (T '当前：这块盘没有还原点（可能没有开系统保护）') }
        else { (T "当前：{0} 个还原点和卷影副本，占 {1}，最多可以用到 {2}") -f $r.Count, (Fmt $r.Used), $(if ($r.Unbounded -or $r.Max -le 0) { (T '没有上限') } else { Fmt $r.Max }) }
}
$ctl.BtnRestoreOpen.Add_Click({
    try { Start-Process -FilePath "$env:SystemRoot\System32\SystemPropertiesProtection.exe" } catch { Show-Sheet -Kind warn -Title (T '打不开系统保护设置') -Text $_.Exception.Message | Out-Null }
})
$ctl.BtnGoDup.Add_Click({ Show-Page 'dup' })
foreach ($b in @($ctl.BtnCosOn, $ctl.BtnCosOff)) {
    $b.Add_Click({
        if ($script:worker) { return }
        $on = [object]::ReferenceEquals($this, $ctl.BtnCosOn)
        $t = if ($on) { (T '开启系统压缩？') } else { (T '关闭系统压缩？') }
        $x = if ($on) { (T 'Windows 会把系统文件压缩存放，通常省 2 到 4 GB。要 10 到 30 分钟，期间可以照常用电脑，不需要重启。') } else { (T '系统文件会解压回原样，C 盘会多用 2 到 4 GB。要 10 到 30 分钟。') }
        $btn = if ($on) { (T '开启') } else { (T '关闭') }
        if ((Show-Sheet -Title $t -Text $x -Buttons @((T '取消'), $btn) -Primary $btn -Cancel (T '取消')) -ne $btn) { return }
        $sync.Mode = 'compactos'; $sync.CosRes = $null
        Start-Op $(if ($on) { (T '开启系统压缩') } else { (T '关闭系统压缩') }); UI-Busy $true
        Start-Worker @'
SetP @{ Steps = 1; Step = 1; StepName = 'compact.exe'; SubKind = 'slow'; SubStart = (Get-Date); Detail = '' }
$res = @{}; Invoke-CompactOS ([bool]$arg.On) $res; $sync.CosRes = $res
'@ @{ On = $on }
    })
}
$ctl.BtnPfMove.Add_Click({
    $d = [string]$ctl.SavePfDrive.SelectedItem.Tag
    if (-not $d) { return }
    $ans = Show-Sheet -Kind warn -Title ((T "把页面文件改到 {0} 盘？") -f $d.Substring(0, 1)) -Text ((T "C 盘不再放页面文件，改为放在 {0}\pagefile.sys，大小由系统自动管理。重启后生效，C 盘会多出几个 GB。{0} 必须是一直插着的本机硬盘。") -f $d) -Buttons @((T '取消'), (T '改到这块盘')) -Primary (T '改到这块盘') -Cancel (T '取消')
    if ($ans -ne (T '改到这块盘')) { return }
    $err = Set-PageFile $d
    if ($err) { Show-Sheet -Kind warn -Title (T '没改成') -Text $err | Out-Null } else { Load-Save; Ask-Restart (T '页面文件的新位置要重启电脑后才生效。') }
})
$ctl.BtnPfAuto.Add_Click({
    if ((Show-Sheet -Title (T '页面文件恢复系统默认？') -Text (T '恢复成 Windows 自动管理（通常放在 C 盘）。重启后生效。') -Buttons @((T '取消'), (T '恢复')) -Primary (T '恢复') -Cancel (T '取消')) -ne (T '恢复')) { return }
    $err = Set-PageFile ''
    if ($err) { Show-Sheet -Kind warn -Title (T '没改成') -Text $err | Out-Null } else { Load-Save; Ask-Restart (T '页面文件的设置要重启电脑后才生效。') }
})
foreach ($b in @($ctl.BtnHibReduced, $ctl.BtnHibOff, $ctl.BtnHibFull)) {
    $b.Add_Click({
        $mode = if ([object]::ReferenceEquals($this, $ctl.BtnHibOff)) { 'off' } elseif ([object]::ReferenceEquals($this, $ctl.BtnHibFull)) { 'full' } else { 'reduced' }
        $txt = @{ off = (T '整个删掉休眠文件。睡眠不受影响，但没有「休眠」和「快速启动」了，开机可能慢几秒。'); reduced = (T '休眠文件缩小到一半左右，只保留「快速启动」，开机速度不变，只是不能手动休眠。'); full = (T '恢复完整的休眠功能，休眠文件会变回约等于内存四到七成的大小。') }[$mode]
        if ((Show-Sheet -Title (T '修改休眠设置？') -Text $txt -Buttons @((T '取消'), (T '好')) -Primary (T '好') -Cancel (T '取消')) -ne (T '好')) { return }
        Set-Hiber $mode
        Load-Save
    })
}
$ctl.BtnFolderCompress.Add_Click({
    $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
    $dlg.Description = (T '选择要压缩的文件夹')
    if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { Start-FolderCompress $dlg.SelectedPath }
})
$ctl.VdList.AddHandler([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent, [System.Windows.RoutedEventHandler]{
    param($s, $e)
    $b = $e.OriginalSource
    if (-not ($b -is [System.Windows.Controls.Button]) -or -not ($b.Tag -is [VdiskRow])) { return }
    $r = $b.Tag
    if ($script:worker) { Show-Sheet -Title (T '请等当前操作做完') -Text (T '另一个操作还在进行中。') | Out-Null; return }
    switch ($b.Name) {
        'VdOpen' { Open-Location $r.Path }
        'VdCompact' {
            $apps = @(); if ($r.Kind -eq 'docker') { $apps = @('Docker Desktop') }
            if ($apps) {
                $busy = Get-BusyApps $apps
                if ($busy.Count -gt 0) { Show-Sheet -Kind warn -Title (T '请先退出 Docker Desktop') -Text (T '在任务栏右下角的 Docker 图标上右键，选「Quit Docker Desktop」，再回来压缩。') | Out-Null; return }
            }
            $extra = if ($r.Kind -eq 'wsl' -or $r.Kind -eq 'docker') { (T '压缩前会先关闭所有 WSL（wsl --shutdown），正在 WSL 里运行的程序会被结束。') } else { (T '用这个磁盘的虚拟机要先关掉。') }
            if ((Show-Sheet -Title ((T "压缩「{0}」？") -f $r.Name) -Text ((T "{0}`n`n现在 {1}。{2}压缩不会删除里面的任何数据，只把已经空出来的部分还给 Windows，可能要几分钟。") -f $r.Path, $r.SizeText, $extra) -Buttons @((T '取消'), (T '压缩')) -Primary (T '压缩') -Cancel (T '取消')) -ne (T '压缩')) { return }
            $sync.Mode = 'vdisk'; $sync.VdRes = $null
            Start-Op ((T "压缩虚拟磁盘：{0}") -f $r.Name); UI-Busy $true
            Start-Worker @'
SetP @{ Steps = 1; Step = 1; StepName = (Split-Path $arg.Path -Leaf); SubKind = 'slow'; SubStart = (Get-Date); Detail = '' }
$res = @{}; Invoke-CompactVdisk $arg.Path $arg.Kind $res; $sync.VdRes = $res
'@ @{ Path = $r.Path; Kind = $r.Kind }
        }
        'VdMove' {
            $dest = Get-Dest
            if (-not $dest) { Show-Sheet -Kind warn -Title (T '没有可用的搬家目标') -Text (T '请先在「清理 C 盘」页的「搬家目标」里选一块 C 盘以外的硬盘。') | Out-Null; return }
            $apps = switch -Wildcard ($r.Name) { (T '安卓*') { @('Android 模拟器') } 'VirtualBox*' { @('VirtualBox') } 'VMware*' { @('VMware') } default { @() } }
            $defs = Get-ChatApps; $k = @(); $dd = @()
            foreach ($a in $apps) { $k += $defs[$a].P; $dd += $defs[$a].Dirs }
            $item = @{ N = $r.Name; Paths = @($r.Path); Apps = $apps; Kill = @($k); KillDirs = @($dd) }
            $cp = Get-ClosePlan @($item) $apps
            $text = (T "{0}（{1}）整个搬到 {2}，原位置留一个链接，软件照常使用。") -f $r.Path, $r.SizeText, $dest
            if ($cp.Names.Count -gt 0) { $text += ((T "`n`n{0} 正在运行，搬之前会替你关掉它们（正在运行的模拟器或虚拟机会被结束）。") -f $cp.Text) }
            if ((Show-Sheet -Title ((T "把「{0}」搬到其他盘？") -f $r.Name) -Text $text -Buttons @((T '取消'), (T '搬')) -Primary (T '搬') -Cancel (T '取消')) -ne (T '搬')) { return }
            $item.Restrict = $true; $item.Allowed = @($cp.Names)
            $sync.Mode = 'vmove'; $sync.VmRes = $null
            Start-Op ((T "搬到其他盘：{0}") -f $r.Name); UI-Busy $true
            Start-Worker @'
New-Item -ItemType Directory -Path $arg.Dest -Force | Out-Null
SetP @{ Steps = 1; Step = 1; StepName = $arg.Item.N; StepNote = '' }
$res = @{}; Invoke-Move $arg.Item $arg.Dest $res; $sync.VmRes = $res
'@ @{ Item = $item; Dest = $dest }
        }
    }
})

