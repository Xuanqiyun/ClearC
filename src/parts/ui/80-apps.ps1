# ------------------------------------------------------------
# 软件管理
# ------------------------------------------------------------
$script:appRows = $null; $script:leftApp = $null
function Load-Apps {
    if ($script:worker) { return }
    $ctl.EmptyApps.Visibility = 'Visible'; $ctl.EmptyAppsText.Text = (T '正在读取已安装的软件，并统计每个占多少空间…')
    $ctl.AppsList.ItemsSource = $null
    $sync.Mode = 'apps'; $sync.AppsResult = $null
    Start-Op (T '统计已安装的软件') -NoCard
    UI-Busy $true
    Start-Worker @'
$out = Get-InstalledApps
$i = 0
SetP @{ Steps = $out.Count + 1; Step = 1; StepName = (T '读取 C 盘的文件表') }
$tree = Get-SysTree
$generic = @($env:SystemRoot, "$env:SystemDrive\Program Files", "$env:SystemDrive\Program Files (x86)", "$env:SystemDrive\ProgramData", $env:LOCALAPPDATA, $env:APPDATA, "$env:LOCALAPPDATA\Programs")
# 装在别的盘上的：同一块盘上有两个以上，就读那块盘的文件表一次（比一个一个文件夹统计快得多）
$far = @{}; foreach ($a in $out) { $l = [string]$a.Location; if ($l.Length -gt 3 -and $l[1] -eq ':' -and $l.Substring(0, 2) -ine $env:SystemDrive) { $far[$l.Substring(0, 1).ToUpperInvariant()] = [int]$far[$l.Substring(0, 1).ToUpperInvariant()] + 1 } }
$stopped = $false
foreach ($a in $out) {
    $i++
    $a.Size = $a.Est; $a.Measured = $false
    if ($stopped -or (Stopping)) { $stopped = $true; continue }   # 取消后剩下的用安装时登记的大小
    SetP @{ Steps = $out.Count + 1; Step = $i + 1; StepName = $a.Name; SubKind = 'none' }
    $loc = $a.Location
    if ($loc -and $loc.Length -gt 3 -and ($generic -notcontains $loc) -and (Test-Path -LiteralPath $loc -PathType Container)) {
        $dt = $tree
        if ($loc[1] -eq ':' -and $loc.Substring(0, 2) -ine $env:SystemDrive) { $dt = if ([int]$far[$loc.Substring(0, 1).ToUpperInvariant()] -ge 2) { Get-DriveTree $loc } else { $null } }
        $b = Est-Bytes $loc $dt
        if (Stopping) { $stopped = $true; continue }
        if ($b -gt 0) { $a.Size = $b; $a.Measured = $true }
    }
}
$sync.AppsResult = $out
'@ $null
}
function Filter-Apps {
    if ($script:appsView -ne 'apps') { return }
    if (-not $script:appRows) { return }
    $q = ([string]$ctl.AppsSearch.Text).Trim()
    $col = New-Object 'System.Collections.ObjectModel.ObservableCollection[AppRow]'
    $tot = [double]0
    foreach ($r in $script:appRows) {
        if ($ctl.AppsC.IsChecked -and -not $r.OnC) { continue }
        if ($ctl.AppsStore.IsChecked -and $r.Kind -ne 'store') { continue }
        if ($q -and ($r.Name.IndexOf($q, [StringComparison]::OrdinalIgnoreCase) -lt 0) -and ([string]$r.Publisher).IndexOf($q, [StringComparison]::OrdinalIgnoreCase) -lt 0) { continue }
        $col.Add($r); $tot += $r.Size
    }
    $ctl.AppsList.ItemsSource = $col
    $ctl.AppsInfo.Text = (T "{0} 个软件，合计约 {1}") -f $col.Count, (Fmt $tot)
    $ctl.EmptyApps.Visibility = if ($col.Count -gt 0) { 'Collapsed' } else { 'Visible' }
    if ($col.Count -eq 0) { $ctl.EmptyAppsText.Text = (T '没有符合条件的软件') }
    Update-PickBar
}
foreach ($c in @($ctl.AppsAll, $ctl.AppsC, $ctl.AppsStore)) { $c.Add_Checked({ Filter-Apps }) }
$ctl.AppsSearch.Add_TextChanged({ Filter-Apps })
$ctl.BtnAppsRefresh.Add_Click({ $v = Get-AppsView; if ($v -eq 'apps') { Load-Apps } else { $script:startRows.Remove($v); Load-StartRows $v } })
function Build-AppRows($list) {
    $rows = New-Object System.Collections.Generic.List[AppRow]
    foreach ($a in @($list | Sort-Object { [double]$_.Size } -Descending)) {
        $r = New-Object AppRow
        $r.Name = $a.Name; $r.Publisher = $a.Publisher; $r.Version = $a.Version; $r.Location = $a.Location; $r.Uninstall = $a.Uninstall
        $r.Kind = $a.Kind; $r.PackageName = $a.Package; $r.Size = [long]$a.Size
        $r.Icon = if ($a.Name) { $a.Name.Substring(0, 1).ToUpper() } else { '?' }
        $r.SizeText = if ($a.Size -gt 0) { $(if ($a.Measured) { '' } else { (T '约 ') }) + (Fmt $a.Size) } else { '—' }
        $r.OnC = (-not $a.Location) -or $a.Location.StartsWith($env:SystemDrive, [StringComparison]::OrdinalIgnoreCase)
        $r.LocReg = [bool]$a.LocReg
        $movedTo = ''
        if ($a.Location -and $r.OnC -and $a.Kind -ne 'store') {
            $movedTo = LinkTarget $a.Location
            if (-not $movedTo) { $up = Get-LinkedAncestor $a.Location; if ($up) { $t = LinkTarget $up; if ($t) { $movedTo = Join-Path $t.TrimEnd('\') $a.Location.Substring($up.Length).TrimStart('\') } } }
        }
        if ($movedTo) { $r.OnC = $false }
        $r.CanMove = $r.OnC -and [bool]$a.Location
        $d = ''
        if ($a.Date -match '^(\d{4})(\d{2})(\d{2})$') { $d = "{0}-{1}-{2}" -f $matches[1], $matches[2], $matches[3] }
        $r.Date = $d
        $parts = @()
        if ($a.Publisher) { $parts += $a.Publisher }
        if ($a.Version) { $parts += ((T '版本 ') + $a.Version) }
        if ($d) { $parts += ((T '安装于 ') + $d) }
        if ($a.Kind -eq 'store') { $parts += (T '应用商店') }
        if ($movedTo) { $parts += ((T "已搬到 {0}") -f $movedTo.TrimEnd('\')) } elseif ($a.Location) { $parts += $a.Location } else { $parts += (T '没有记录安装位置') }
        $r.Meta = $parts -join ' · '
        $rows.Add($r)
    }
    $script:appRows = $rows
    Filter-Apps
}
# 软件整个搬到其他盘
function Start-AppMove($r) {
    UI-Log ((T "检查「{0}」能不能搬") -f $r.Name)
    $win.Cursor = [System.Windows.Input.Cursors]::Wait
    try { $why = Get-AppMoveBlock $r $sync.AppsResult } finally { $win.Cursor = $null }
    if ($why -eq 'store') {
        $ans = Show-Sheet -Title (T '应用商店的软件由 Windows 管理') -Text ((T "「{0}」是从应用商店装的，本工具不能搬它。`n`n有的应用可以在 Windows 设置里换盘：设置 → 应用 → 已安装的应用，点它右边的「…」，选「移动」（没有这个选项就是不支持）。") -f $r.Name) -Buttons @((T '好'), (T '打开 Windows 设置')) -Primary (T '打开 Windows 设置') -Cancel (T '好')
        if ($ans -eq (T '打开 Windows 设置')) { [void](Open-AsUser 'ms-settings:appsfeatures') }
        return
    }
    if ($why) { Show-Sheet -Kind warn -Title ((T "「{0}」不适合搬") -f $r.Name) -Text $why | Out-Null; return }
    $dest = Get-Dest
    if (-not $dest) { Show-Sheet -Kind warn -Title (T '没有可用的搬家目标') -Text (T '这台电脑没有 C 盘以外的硬盘，或者还没选搬家目标。请先在「清理 C 盘」页的「搬家目标」里选一块硬盘。') | Out-Null; return }
    $loc = ([string]$r.Location).TrimEnd('\')
    # 资源管理器加载了它的组件（右键菜单、图标叠加等）时，文件夹会一直被占着
    $ex = @()
    foreach ($p in @(Get-Process -Name explorer -ErrorAction SilentlyContinue)) {
        try { foreach ($m in $p.Modules) { if (([string]$m.FileName).StartsWith("$loc\", [StringComparison]::OrdinalIgnoreCase)) { $ex += $m.ModuleName } } } catch {}
    }
    if ($ex.Count -gt 0) {
        Show-Sheet -Kind warn -Title ((T "「{0}」不适合搬") -f $r.Name) -Text ((T "它给资源管理器装了右键菜单之类的组件（{0}），桌面和文件夹窗口一直开着这些文件，文件夹被占着搬不了。这类软件通常不大，建议留在 C 盘。") -f (@($ex | Select-Object -Unique -First 3) -join (T '、'))) | Out-Null
        return
    }
    $running = Get-ProcsInside @($loc)
    $small = if ($r.Size -gt 0 -and $r.Size -lt 100MB) { (T "`n`n它只占 {0}，搬走腾出的空间不多。") -f $r.SizeText } else { '' }
    $text = (T "把安装文件夹 {0}（{1}）整个搬到 {2}，C 盘原位置留一个链接。桌面快捷方式、开始菜单、卸载和自动更新都照常可用，不用重装。`n`n搬之前先核对两边的文件完全一致，再删掉 C 盘上的那份。{3}") -f $loc, $r.SizeText, $dest, $small
    if ($running.Count -gt 0) { $text += (T "`n`n{0} 正在运行，搬之前会替你关掉（没保存的内容请先保存）。") -f ($running -join (T '、')) }
    $text += (T "`n`n要注意：{0} 盘要一直接着；以后软件大版本升级时，个别安装程序会把它重新装回 C 盘，到时在这里再搬一次就好。要搬回来，到「搬家管理」点「搬回 C 盘」。") -f $dest.Substring(0, 1)
    $btn = if ($running.Count -gt 0) { (T '关掉并搬走') } else { (T '搬到其他盘') }
    if ((Show-Sheet -Title ((T "把「{0}」搬到其他盘？") -f $r.Name) -Text $text -Buttons @((T '取消'), $btn) -Primary $btn -Cancel (T '取消')) -ne $btn) { return }
    $item = @{ N = $r.Name; Paths = @($loc); Apps = @(); Kill = @(); KillDirs = @(); Restrict = $true; Allowed = @($running)
        BusyHint = (T '还有程序开着里面的文件。请退出这个软件（包括屏幕右下角托盘里的图标），关掉打开着这个文件夹的窗口，再搬一次；已经复制好的部分下次直接用，很快') }
    $sync.Mode = 'appmove'; $sync.AmRes = $null; $script:appMoveRow = $r
    Start-Op ((T "搬到其他盘：{0}") -f $r.Name); UI-Busy $true
    Start-Worker @'
New-Item -ItemType Directory -Path $arg.Dest -Force | Out-Null
SetP @{ Steps = 1; Step = 1; StepName = $arg.Item.N; StepNote = '' }
$res = @{ Done = 0; Fail = 0; Wait = 0; Moved = [double]0; Dest = @(); Msgs = @() }
Invoke-AppMove $arg.Item $arg.Dest $res
$sync.AmRes = $res
'@ @{ Item = $item; Dest = $dest }
}
# 把注册表里的卸载命令拆成「程序 + 参数」
function Split-Command([string]$cmd) {
    $cmd = $cmd.Trim()
    if ($cmd -match '(?i)^"?(?:[a-z]:\\[^"]*\\)?msiexec(\.exe)?"?\s+(.*)$') { return @("$env:SystemRoot\System32\msiexec.exe", ($matches[2] -replace '(?i)/I\s*\{', '/X{')) }
    if ($cmd.StartsWith('"')) { $e = $cmd.IndexOf('"', 1); if ($e -gt 0) { return @($cmd.Substring(1, $e - 1), $cmd.Substring($e + 1).Trim()) } }
    $m = [regex]::Match($cmd, '(?i)^(.+?\.exe)(\s+.*)?$')
    if ($m.Success) { return @($m.Groups[1].Value, $m.Groups[2].Value.Trim()) }
    return @($cmd, '')
}
$ctl.AppsList.AddHandler([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent, [System.Windows.RoutedEventHandler]{
    param($s, $e)
    $b = $e.OriginalSource
    if (-not ($b -is [System.Windows.Controls.Button]) -or -not ($b.Tag -is [AppRow])) { return }
    $r = $b.Tag
    if ($b.Name -eq 'AppOpen') {
        if ($r.Location -and (Test-Path -LiteralPath $r.Location)) { Open-Location $r.Location } else { Show-Sheet -Title (T '没有记录安装位置') -Text (T '这个软件的安装程序没有写明装在哪里。') | Out-Null }
        return
    }
    if ($b.Name -eq 'AppUpgrade') { Start-WingetUpgrade $r.UpgradeId $r.Name; return }
    if ($script:worker) { Show-Sheet -Title (T '请等当前操作做完') -Text (T '另一个操作还在进行中。') | Out-Null; return }
    if ($b.Name -eq 'AppMove') { Start-AppMove $r; return }
    $txt = if ($r.Kind -eq 'store') { (T "从应用商店卸载 {0}（{1}）。") -f $r.Name, $r.SizeText } else { (T "会打开 {0} 自带的卸载程序，按它的提示一步步操作即可。卸载完回到这里点「检查残留」，看看还有没有剩下的文件夹。") -f $r.Name }
    if ((Show-Sheet -Kind warn -Title ((T "卸载「{0}」？") -f $r.Name) -Text ($txt + (T "`n`n卸载会删除这个软件，它保存在软件里的数据可能一起被删掉。")) -Buttons @((T '取消'), (T '卸载')) -Primary (T '卸载') -Cancel (T '取消')) -ne (T '卸载')) { return }
    if ($r.Kind -eq 'store') {
        $sync.Mode = 'uninst'; $sync.UninstRes = $null
        Start-Op ((T "卸载 {0}") -f $r.Name); UI-Busy $true
        Start-Worker @'
$ok = $true; $msg = ''
try { Remove-AppxPackage -Package $arg.Pkg -ErrorAction Stop } catch { $ok = $false; $msg = $_.Exception.Message }
OpLog '卸载' (T '卸载应用商店软件') $arg.Name $(if ($ok) { ((T "约 {0}") -f $(GB $arg.Size)) } else { (T '失败：') + $msg })
$sync.UninstRes = @{ Ok = $ok; Msg = $msg; Name = $arg.Name }
'@ @{ Pkg = $r.PackageName; Name = $r.Name; Size = [double]$r.Size }
        return
    }
    $pc = Split-Command $r.Uninstall
    try {
        if ($pc[1]) { Start-Process -FilePath $pc[0] -ArgumentList $pc[1] -ErrorAction Stop } else { Start-Process -FilePath $pc[0] -ErrorAction Stop }
        OpLog '卸载' (T '打开卸载程序') $r.Name $r.Uninstall
        $script:leftApp = $r
        $ctl.AppsLeftText.Text = (T "已打开「{0}」的卸载程序。卸载完成后点「检查残留」，看看还剩下哪些文件夹。") -f $r.Name
        $ctl.AppsLeftBox.Visibility = 'Visible'
    } catch { Show-Sheet -Kind warn -Title (T '打不开卸载程序') -Text ("{0}`n`n{1}" -f $r.Uninstall, $_.Exception.Message) | Out-Null }
})
$ctl.BtnAppsLeftClose.Add_Click({ $ctl.AppsLeftBox.Visibility = 'Collapsed'; $script:leftApp = $null })
# 卸载后可能留下的文件夹：以软件名命名的、装在原来位置的。发行商的总文件夹（比如 Tencent）不算
function Find-Leftovers($r) {
    $names = New-Object System.Collections.Generic.List[string]
    $n0 = [string]$r.Name
    $shared = @('Tencent','Microsoft','Google','Adobe','Intel','NVIDIA','Apple','Packages','Programs','Temp','Common Files','Mozilla','Oracle','Java','Python','Steam','Microsoft Office',
        'Games','Program Files','Program Files (x86)','ProgramData','Users','Windows','Downloads','Documents','Desktop')
    # 太短或太常见的名字（bin、app、tools……）会撞上别的软件的文件夹，不拿来找
    $generic = @('bin','app','apps','application','applications','program','programs','software','tools','data','current','x64','x86','common','setup','install','update','client','launcher')
    $ok = { param($n) $n -and $n.Length -ge 4 -and ($generic -notcontains $n.ToLowerInvariant()) -and ($shared -notcontains $n) }
    foreach ($n in @($n0, ($n0 -replace '\s*\(.*?\)\s*', ' ').Trim(), ($n0 -replace '\s+v?\d+([\.\d]+)?\s*$', '').Trim(), ($n0 -replace '\s+(x64|x86|64-bit|32-bit)$', '').Trim())) {
        if ((& $ok $n) -and -not $names.Contains($n)) { $names.Add($n) }
    }
    $norm = { param($x) (([string]$x).ToLowerInvariant() -replace '[^\p{L}\p{N}]', '') }
    $loc = ([string]$r.Location).TrimEnd('\')
    $useLoc = $false
    if ($loc -and $loc.Length -gt 3) {
        $leaf = Split-Path $loc -Leaf
        $ln = & $norm $leaf; $nn = & $norm $n0
        $matchName = $ln.Length -ge 3 -and $nn.Length -ge 3 -and ($nn.Contains($ln) -or $ln.Contains($nn))
        # 装在盘符下面一层（比如 D:\Games）又和软件名对不上的，多半是装软件的总文件夹，不当残留
        $topLevel = ((Split-Path $loc -Parent).TrimEnd('\').Length -le 2)
        if ((& $ok $leaf) -and -not ($topLevel -and -not $matchName)) {
            $useLoc = $true
            if (-not $names.Contains($leaf)) { $names.Add($leaf) }
        }
    }
    # 别的还装着的软件用的文件夹，不能当成这个软件的残留
    $others = @()
    if ($sync.AppsResult) { foreach ($a in $sync.AppsResult) { $l = ([string]$a.Location).TrimEnd('\'); if ($l -and $l.Length -gt 3 -and [string]$a.Name -ne $n0) { $others += $l } } }
    $bases = @($env:APPDATA, $env:LOCALAPPDATA, "$env:LOCALAPPDATA\Programs", "$env:SystemDrive\ProgramData", "$env:SystemDrive\Program Files", "$env:SystemDrive\Program Files (x86)")
    $pub = ([string]$r.Publisher).Trim()
    $cands = New-Object System.Collections.Generic.List[string]
    if ($useLoc -and (Test-Path -LiteralPath $loc)) { $cands.Add($loc) }
    foreach ($b in $bases) {
        foreach ($n in $names) {
            if ($shared -contains $n) { continue }
            foreach ($c in @((Join-Path $b $n), $(if ($pub -and $pub.Length -ge 2) { Join-Path (Join-Path $b $pub) $n } else { '' }))) {
                if ($c -and (Test-Path -LiteralPath $c -PathType Container) -and -not $cands.Contains($c)) { $cands.Add($c) }
            }
        }
    }
    $out = @()
    foreach ($c in $cands) {
        if (IsLink $c) { continue }
        if (Get-DeleteBlock $c -Leftover) { continue }
        $cf = $c.TrimEnd('\'); $inUse = $false
        foreach ($o in $others) { if ($o -ieq $cf -or $o.StartsWith("$cf\", [StringComparison]::OrdinalIgnoreCase) -or $cf.StartsWith("$o\", [StringComparison]::OrdinalIgnoreCase)) { $inUse = $true; break } }
        if ($inUse) { continue }
        $out += @{ Path = $c; Bytes = (DirBytes $c) }
    }
    return ,$out
}
$ctl.BtnAppsLeft.Add_Click({
    $r = $script:leftApp
    if (-not $r -or $script:worker) { return }
    $still = $false
    foreach ($k in 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*', 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*', 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*') {
        foreach ($p in @(Get-ItemProperty $k -ErrorAction SilentlyContinue)) { if ([string]$p.DisplayName -eq $r.Name) { $still = $true } }
    }
    if ($still) { Show-Sheet -Title (T '看起来还没卸载完') -Text ((T "系统里还登记着「{0}」。等卸载程序走完，再点「检查残留」。") -f $r.Name) | Out-Null; return }
    $left = Find-Leftovers $r
    if (-not $left -or $left.Count -eq 0) {
        Show-Sheet -Kind done -Title (T '没发现残留') -Text ((T "「{0}」已经卸载干净了。") -f $r.Name) | Out-Null
        $ctl.AppsLeftBox.Visibility = 'Collapsed'; $script:leftApp = $null; Load-Apps; return
    }
    $items = @($left | ForEach-Object { (T "{0}（{1}）") -f $_.Path, (Fmt $_.Bytes) })
    $ans = Show-Sheet -Kind danger -Title ((T "「{0}」留下了 {1} 个文件夹") -f $r.Name, $left.Count) -Text (T '这些文件夹以软件名命名，多半是卸载后剩下的设置和缓存。会移到回收站，需要的话还能恢复。') -Items $items `
        -Confirm (T '我已确认这些是已卸载软件留下的，删除不会给我带来损失。') -Buttons @((T '先不删'), (T '移到回收站')) -Primary (T '移到回收站') -Cancel (T '先不删')
    if ($ans -ne (T '移到回收站')) { return }
    $sync.Mode = 'leftdel'; $sync.LeftRes = $null; $script:leftBatch = $false
    Start-Op ((T "清理「{0}」的残留") -f $r.Name); UI-Busy $true
    Start-Worker $script:leftDelCode @{ Items = $left; Name = $r.Name }
})
# 残留文件夹移到回收站（「检查残留」和「残留文件夹」里一次选几个都用这一段）：删前再查一遍，链接不跟进，放不进回收站的不删
$script:leftDelCode = @'
$n = 0; $i = 0
foreach ($x in $arg.Items) {
    if (Stopping) { break }
    $i++
    SetP @{ Steps = $arg.Items.Count; Step = $i; StepName = $x.Path; SubKind = 'none' }
    # 删前再查一遍（Get-DeleteBlock -Leftover、链接、上级是链接）、只放进回收站、放不进就不删、写操作日志：都在 Invoke-SafeRemove 里
    $r = Invoke-SafeRemove -Path $x.Path -Scope leftover -How recycle -Bytes ([double]$x.Bytes) -What ((T "软件残留：移到回收站（{0}）") -f $arg.Name)
    if ($r.Ok) { $n++ } else { Log ((T "  没删（{0}）：{1}") -f $r.Why, $x.Path) }
}
$sync.LeftRes = @{ Count = $n; Name = $arg.Name }
'@

# ---------- 开机启动 / 计划任务 / 右键菜单：同一个列表，按视图换内容 ----------
$script:startRows = @{}   # kind -> List[StartRow]
$script:appsView = 'apps'
function Get-AppsView { if ($ctl.AppsViewStartup.IsChecked) { 'startup' } elseif ($ctl.AppsViewTasks.IsChecked) { 'task' } elseif ($ctl.AppsViewMenu.IsChecked) { 'shellex' } elseif ($ctl.AppsViewLeft.IsChecked) { 'leftover' } else { 'apps' } }
function Show-AppsView {
    $v = Get-AppsView; $script:appsView = $v
    $isApps = ($v -eq 'apps')
    $ctl.AppsList.Visibility = if ($isApps) { 'Visible' } else { 'Collapsed' }
    $ctl.StartList.Visibility = if ($isApps) { 'Collapsed' } else { 'Visible' }
    Update-HeadVis
    $ctl.AppsFilterBox.Visibility = if ($isApps) { 'Visible' } else { 'Collapsed' }
    $ctl.BtnAppsUpdates.Visibility = if ($isApps -and $script:appsUpdatesAllowed) { 'Visible' } else { 'Collapsed' }
    if ($isApps) { Filter-Apps; return }
    if (-not $script:startRows.ContainsKey($v)) { Load-StartRows $v } else { Filter-StartRows }
}
function Filter-StartRows {
    $v = $script:appsView
    if ($v -eq 'apps' -or -not $script:startRows.ContainsKey($v)) { return }
    $q = ([string]$ctl.AppsSearch.Text).Trim()
    $col = New-Object 'System.Collections.ObjectModel.ObservableCollection[StartRow]'
    foreach ($r in $script:startRows[$v]) {
        if ($q -and ($r.Name.IndexOf($q, [StringComparison]::OrdinalIgnoreCase) -lt 0) -and ([string]$r.Meta).IndexOf($q, [StringComparison]::OrdinalIgnoreCase) -lt 0 -and ([string]$r.Detail).IndexOf($q, [StringComparison]::OrdinalIgnoreCase) -lt 0) { continue }
        $col.Add($r)
    }
    $ctl.StartList.ItemsSource = $col
    $on = @($col | Where-Object { $_.Enabled }).Count
    $ctl.AppsInfo.Text = switch ($v) {
        'startup' { (T "{0} 个开机启动项，{1} 个已启用") -f $col.Count, $on }
        'task'    { (T "{0} 个第三方计划任务，{1} 个已启用（Windows 自己的不列）") -f $col.Count, $on }
        'leftover' { $tb = [double]0; foreach ($r in $col) { $tb += [double]$r.Key2 }; (T "{0} 个可能是残留的文件夹，共 {1}。只是猜测：名字对不上任何已装软件、没有程序在用、一个月没动过") -f $col.Count, (Fmt $tb) }
        default   { (T "{0} 个第三方右键菜单扩展，{1} 个已启用（系统自带的不列）") -f $col.Count, $on }
    }
    $ctl.EmptyApps.Visibility = if ($col.Count -gt 0) { 'Collapsed' } else { 'Visible' }
    if ($col.Count -eq 0) { $ctl.EmptyAppsText.Text = switch ($v) { 'startup' { (T '没有开机启动项') } 'task' { (T '没有第三方的计划任务') } 'leftover' { (T '没找到像是残留的文件夹') } default { (T '没有第三方的右键菜单扩展') } } }
    Update-PickBar
}
function Load-StartRows([string]$kind) {
    if ($script:worker) { return }
    $ctl.StartList.ItemsSource = $null
    $ctl.EmptyApps.Visibility = 'Visible'; $ctl.EmptyAppsText.Text = (T '正在读取…')
    if ($kind -eq 'leftover') {
        $ctl.EmptyAppsText.Text = (T '正在找已卸载软件可能留下的文件夹…')
        $sync.Mode = 'leftovers'; $sync.LeftoverResult = $null
        Start-Op (T '查找残留文件夹') -NoCard; UI-Busy $true
        Start-Worker @'
$apps = if ($sync.AppsResult) { $sync.AppsResult } else { Get-InstalledApps }
$tree = Get-SysTree
$sync.LeftoverResult = @(Get-OrphanFolders $apps $tree)
'@ $null
        return
    }
    $sync.Mode = 'startup'; $sync.StartResult = $null; $sync.StartKind = $kind
    Start-Op $(switch ($kind) { 'startup' { (T '读取开机启动项') } 'task' { (T '读取计划任务') } default { (T '读取右键菜单扩展') } }) -NoCard
    UI-Busy $true
    Start-Worker @'
$k = $arg.Kind
$sync.StartResult = switch ($k) { 'startup' { @(Get-StartupItems) } 'task' { @(Get-UserTasks) } default { @(Get-ContextMenuItems) } }
'@ @{ Kind = $kind }
}
function Build-StartRows([string]$kind, $list) {
    $rows = New-Object System.Collections.Generic.List[StartRow]
    $srcText = @{ HKCU = (T '注册表 · 当前用户'); HKLM = (T '注册表 · 所有用户'); HKLM32 = (T '注册表 · 所有用户 (32 位)'); UserFolder = (T '「启动」文件夹 · 当前用户'); CommonFolder = (T '「启动」文件夹 · 所有用户') }
    foreach ($x in @($list)) {
        $r = New-Object StartRow
        $r.Kind = $kind; $r.Name = [string]$x.Name
        switch ($kind) {
            'startup' {
                $exe = Get-CommandExe ([string]$x.Cmd)
                $co = Get-FileCompany $exe
                $r.Meta = (@($srcText[[string]$x.Src], $co) | Where-Object { $_ }) -join ' · '
                $r.Detail = [string]$x.Cmd
                $r.Open = if ($exe -and (Test-Path -LiteralPath $exe)) { $exe } else { '' }
                $r.Key1 = [string]$x.Approved; $r.Key2 = [string]$x.Val
                $r.Enabled = [bool]$x.Enabled
            }
            'leftover' {
                $r.Name = Split-Path ([string]$x.Path) -Leaf
                $r.Meta = (T "{0} · 最后改动 {1:yyyy-MM-dd}") -f (Fmt ([double]$x.Bytes)), $x.Modified
                $r.Detail = [string]$x.Path; $r.Open = [string]$x.Path
                $r.Key1 = [string]$x.Path; $r.Key2 = [string]([double]$x.Bytes); $r.Size = (Fmt ([double]$x.Bytes))
            }
            'task' {
                $parts = @(); if ($x.Author) { $parts += [string]$x.Author }; $parts += ((T '任务 ') + [string]$x.Path + [string]$x.Name)
                if ($x.Desc) { $parts += ([string]$x.Desc) }
                $r.Meta = ($parts -join ' · ')
                $r.Detail = [string]$x.Cmd
                $exe = Get-CommandExe ([string]$x.Cmd)
                $r.Open = if ($exe -and (Test-Path -LiteralPath $exe)) { $exe } else { '' }
                $r.Key1 = [string]$x.Path; $r.Key2 = [string]$x.Name
                $r.Ours = [bool]$x.Ours
                $r.Enabled = ([string]$x.State -ne 'Disabled')
            }
            default {
                $parts = @(); if ($x.Company) { $parts += [string]$x.Company }; $parts += ((T '出现在：') + (@($x.Where) -join (T '、')))
                $r.Meta = ($parts -join ' · ')
                $r.Detail = [string]$x.Dll
                $r.Open = if ($x.Dll -and (Test-Path -LiteralPath $x.Dll)) { [string]$x.Dll } else { '' }
                $r.Key1 = [string]$x.Clsid
                $r.Enabled = [bool]$x.Enabled
            }
        }
        $rows.Add($r)
    }
    $sorted = New-Object System.Collections.Generic.List[StartRow]
    $ordered = if ($kind -eq 'leftover') { @($rows | Sort-Object { -[double]$_.Key2 }) } else { @($rows | Sort-Object { -not $_.Enabled }, Name) }
    foreach ($r in $ordered) { $sorted.Add($r) }
    $script:startRows[$kind] = $sorted
    if ($script:appsView -eq $kind) { Filter-StartRows }
}
function Set-StartRow($r, [bool]$on, [switch]$Quiet) {
    try {
        switch ($r.Kind) {
            'startup' { Set-StartupEnabled $r.Key1 $r.Key2 $on }
            'task'    { if ($on) { Enable-ScheduledTask -TaskPath $r.Key1 -TaskName $r.Key2 -ErrorAction Stop | Out-Null } else { Disable-ScheduledTask -TaskPath $r.Key1 -TaskName $r.Key2 -ErrorAction Stop | Out-Null } }
            default   { Set-ContextMenuEnabled $r.Key1 $on }
        }
    } catch {
        if ($Quiet) { return ((T "{0}：{1}") -f $r.Name, $_.Exception.Message) }
        Show-Sheet -Kind warn -Title $(if ($on) { (T '没启用成') } else { (T '没禁用成') }) -Text $_.Exception.Message | Out-Null; return
    }
    $r.Enabled = $on
    $what = switch ($r.Kind) { 'startup' { if ($on) { (T '启用开机启动项') } else { (T '禁用开机启动项') } } 'task' { if ($on) { (T '启用计划任务') } else { (T '禁用计划任务') } } default { if ($on) { (T '启用右键菜单扩展') } else { (T '禁用右键菜单扩展') } } }
    OpLog '系统设置' $what $r.Name $r.Detail
    UI-Log ((T "{0}：{1}") -f $what, $r.Name)
    if ($Quiet) { return '' }
    if ($r.Kind -eq 'shellex') { $ctl.AppsInfo.Text = (T '右键菜单的改动对新打开的资源管理器窗口生效；还没生效的话注销再登录一次') }
    else { Filter-StartRows }
}
foreach ($rb in @($ctl.AppsViewApps, $ctl.AppsViewStartup, $ctl.AppsViewTasks, $ctl.AppsViewMenu, $ctl.AppsViewLeft)) { $rb.Add_Checked({ Show-AppsView }) }
$ctl.AppsSearch.Add_TextChanged({ Filter-StartRows })
$ctl.StartList.AddHandler([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent, [System.Windows.RoutedEventHandler]{
    param($s, $e)
    $b = $e.OriginalSource
    if (-not ($b -is [System.Windows.Controls.Button]) -or -not ($b.Tag -is [StartRow])) { return }
    $r = $b.Tag
    if ($b.Name -eq 'StartOpen') { if ($r.Open) { Open-Location $r.Open }; return }
    if ($b.Name -ne 'StartToggle' -or $r.Ours) { return }
    if ($r.Kind -eq 'leftover') {
        if ($script:worker) { Show-Sheet -Title (T '请等当前操作做完') -Text (T '另一个操作还在进行中。') | Out-Null; return }
        $ans = Show-Sheet -Kind danger -Title ((T "把「{0}」移到回收站？") -f $r.Name) -Text ((T "{0}（{1}）。这只是猜测：名字对不上任何已装软件、没有程序在用、一个月没动过。先点「打开位置」看一眼里面是什么。移到回收站后还能恢复。") -f $r.Detail, $r.Size) `
            -Confirm (T '我看过了，这是已卸载软件留下的，删除不会给我带来损失。') -Buttons @((T '先不删'), (T '移到回收站')) -Primary (T '移到回收站') -Cancel (T '先不删')
        if ($ans -ne (T '移到回收站')) { return }
        $x = Invoke-SafeRemove -Path $r.Detail -Scope leftover -How recycle -What (T '残留文件夹：移到回收站') -Detail $r.Size
        if ($x.Ok) { $script:startRows['leftover'].Remove($r) | Out-Null; Filter-StartRows; UI-Log ((T "残留文件夹已移到回收站：{0}") -f $r.Detail) }
        elseif ($x.Stage -eq 'block') { Show-Sheet -Kind warn -Title (T '不能删') -Text $x.Why | Out-Null }
        elseif ($x.Stage -eq 'recycle') { Show-Sheet -Kind warn -Title (T '没有删') -Text ((T "{0}`n`n{1}。这个文件夹只能放进回收站，所以没有删。") -f $r.Detail, $x.Why) | Out-Null }
        else { Show-Sheet -Kind warn -Title (T '没删掉') -Text $x.Why | Out-Null }
        return
    }
    if ($r.Enabled) {
        $what = switch ($r.Kind) {
            'startup' { (T "「{0}」以后开机时不再自动启动。它本身不会被删，随时可以在这里重新启用，也可以在任务管理器的「启动应用」里改。") -f $r.Name }
            'task'    { (T "计划任务「{0}」会被禁用，到时间不再运行。随时可以在这里重新启用，也可以在「任务计划程序」里改。") -f $r.Name }
            default   { (T "「{0}」会从资源管理器的右键菜单里去掉（对新打开的窗口生效）。它所属的软件照常使用，随时可以在这里重新启用。") -f $r.Name }
        }
        if ((Show-Sheet -Title ((T "禁用「{0}」？") -f $r.Name) -Text $what -Buttons @((T '取消'), (T '禁用')) -Primary (T '禁用') -Cancel (T '取消')) -ne (T '禁用')) { return }
        Set-StartRow $r $false
    } else { Set-StartRow $r $true }
})
# ---------- 软件、开机启动、计划任务、右键菜单、残留文件夹：勾选几项一起处理 ----------
# 点方框勾上或取消；Shift 点方框把上次点的那一行到这一行都勾上；按住左键在行上上下拖，拖过的行跟着按下的那一行变
# （按下的那一行原来没勾，拖过的都勾上；原来勾着，拖过的都取消）。勾了以后下面出现一排按钮：一次卸载、禁用、启用、移到回收站
$script:pickAnchor = -1; $script:pickSync = $false; $script:pdrag = $null
function Get-PickList { if ($script:appsView -eq 'apps') { $ctl.AppsList } else { $ctl.StartList } }
function Get-Picked { @(@((Get-PickList).Items) | Where-Object { $_.Picked }) }
function Update-PickBar {
    [AppRow]::PickDirty = $false
    $v = $script:appsView
    $items = @((Get-PickList).Items); $p = @($items | Where-Object { $_.Picked }); $n = $p.Count
    $can = @($items | Where-Object { -not $_.Ours }).Count
    $all = if ($v -eq 'apps') { $ctl.AppsPickAll } else { $ctl.StartPickAll }
    $script:pickSync = $true
    try { $all.IsChecked = if ($n -eq 0) { $false } elseif ($n -ge $can) { $true } else { $null }; $all.IsEnabled = $can -gt 0 } finally { $script:pickSync = $false }
    $ctl.AppsPickBar.Visibility = if ($n -gt 0) { 'Visible' } else { 'Collapsed' }
    if ($n -eq 0) { return }
    $isStart = $v -in 'startup', 'task', 'shellex'
    $ctl.BtnPickUninstall.Visibility = if ($v -eq 'apps') { 'Visible' } else { 'Collapsed' }
    $ctl.BtnPickRecycle.Visibility = if ($v -eq 'leftover') { 'Visible' } else { 'Collapsed' }
    $ctl.BtnPickDisable.Visibility = if ($isStart) { 'Visible' } else { 'Collapsed' }
    $ctl.BtnPickEnable.Visibility = if ($isStart) { 'Visible' } else { 'Collapsed' }
    if ($v -eq 'apps') { $b = [double]0; foreach ($r in $p) { if ($r.Size -gt 0) { $b += [double]$r.Size } }; $ctl.AppsPickText.Text = (T "已选 {0} 个软件，合计约 {1}") -f $n, (Fmt $b) }
    elseif ($v -eq 'leftover') { $b = [double]0; foreach ($r in $p) { $b += [double]$r.Key2 }; $ctl.AppsPickText.Text = (T "已选 {0} 个文件夹，共 {1}") -f $n, (Fmt $b) }
    else {
        $on = @($p | Where-Object { $_.Enabled }).Count
        $ctl.AppsPickText.Text = (T "已选 {0} 项：{1} 项启用中，{2} 项已禁用") -f $n, $on, ($n - $on)
        $ctl.BtnPickDisable.IsEnabled = $on -gt 0; $ctl.BtnPickEnable.IsEnabled = ($n - $on) -gt 0
    }
}
function Clear-Picks { foreach ($r in @((Get-PickList).Items)) { if ($r.Picked) { $r.Picked = $false } }; Update-PickBar }
foreach ($cb in @($ctl.AppsPickAll, $ctl.StartPickAll)) {
    $cb.Add_Click({ if ($script:pickSync) { return }; $on = [bool]$this.IsChecked; foreach ($r in @((Get-PickList).Items)) { if (-not $r.Ours -and $r.Picked -ne $on) { $r.Picked = $on } }; Update-PickBar })
}
$ctl.BtnPickClear.Add_Click({ Clear-Picks })
function Get-PickRowIndex($lv, $el) {
    $c = $null; try { $c = [System.Windows.Controls.ItemsControl]::ContainerFromElement($lv, $el) } catch {}
    if (-not $c) { return -1 }
    return $lv.ItemContainerGenerator.IndexFromContainer($c)
}
foreach ($lv in @($ctl.AppsList, $ctl.StartList)) {
    # 点了行前面的方框：记下从哪一行接着用 Shift 勾
    $lv.AddHandler([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent, [System.Windows.RoutedEventHandler]{
        param($s, $e)
        if ($e.OriginalSource -isnot [System.Windows.Controls.CheckBox]) { return }
        $i = Get-PickRowIndex $s $e.OriginalSource
        if ($i -lt 0) { return }
        $shift = ([System.Windows.Input.Keyboard]::Modifiers -band [System.Windows.Input.ModifierKeys]::Shift) -ne 0
        if ($shift -and $script:pickAnchor -ge 0 -and $script:pickAnchor -lt $s.Items.Count) {
            $want = [bool]$s.Items[$i].Picked
            for ($k = [math]::Min($i, $script:pickAnchor); $k -le [math]::Max($i, $script:pickAnchor); $k++) { $r = $s.Items[$k]; if (-not $r.Ours -and $r.Picked -ne $want) { $r.Picked = $want } }
        }
        $script:pickAnchor = $i
        Update-PickBar
    })
    $lv.Add_PreviewMouseLeftButtonDown({
        param($s, $e)
        $script:pdrag = $null
        $src = $e.OriginalSource
        if ($src -isnot [System.Windows.DependencyObject]) { return }
        try {
            for ($v = $src; $v -and -not [object]::ReferenceEquals($v, $s); $v = [System.Windows.Media.VisualTreeHelper]::GetParent($v)) {
                if ($v -is [System.Windows.Controls.Primitives.ButtonBase] -or $v -is [System.Windows.Controls.Primitives.ScrollBar]) { return }   # 按钮、方框、滚动条照常用
                if ($v -is [System.Windows.Controls.ListViewItem]) { break }
            }
        } catch { return }
        $i = Get-PickRowIndex $s $src
        if ($i -lt 0 -or $s.Items[$i].Ours) { return }
        $script:pdrag = @{ Lv = $s; Anchor = $i; Cur = $i; Moved = $false; Want = -not [bool]$s.Items[$i].Picked; Snap = $null }
    })
    $lv.Add_PreviewMouseMove({
        param($s, $e)
        $d = $script:pdrag
        if (-not $d -or -not [object]::ReferenceEquals($d.Lv, $s)) { return }
        if ($e.LeftButton -ne [System.Windows.Input.MouseButtonState]::Pressed) { $script:pdrag = $null; return }
        $i = Get-RowAt $s ($e.GetPosition($s).Y)
        if ($i -lt 0 -or $i -eq $d.Cur) { return }
        if (-not $d.Moved) { $d.Moved = $true; $d.Snap = @(@($s.Items) | ForEach-Object { [bool]$_.Picked }) }
        $a = [math]::Min($d.Anchor, $i); $b = [math]::Max($d.Anchor, $i); $k = 0
        foreach ($r in @($s.Items)) {
            if (-not $r.Ours) { $want = if ($k -ge $a -and $k -le $b) { $d.Want } else { $d.Snap[$k] }; if ($r.Picked -ne $want) { $r.Picked = $want } }
            $k++
        }
        $d.Cur = $i; $script:pickAnchor = $i
        Update-PickBar
    })
    $lv.Add_PreviewMouseLeftButtonUp({ $script:pdrag = $null })
}
# 一次卸载几个：应用商店的直接卸载；其余的依次打开各自的卸载程序，关掉一个再打开下一个（不加静默参数，每一步都看得见）
$script:uq = $null
$script:uqTimer = New-Object System.Windows.Threading.DispatcherTimer
$script:uqTimer.Interval = [TimeSpan]::FromMilliseconds(800)
$script:uqTimer.Add_Tick({ Step-UninstQueue })
function Start-BatchUninstall {
    $rows = @(Get-Picked | Where-Object { $_ -is [AppRow] })
    if ($rows.Count -eq 0) { return }
    if ($script:worker -or $script:uq) { Show-Sheet -Title (T '请等当前操作做完') -Text (T '另一个操作还在进行中。') | Out-Null; return }
    $store = @($rows | Where-Object { $_.Kind -eq 'store' -and $_.PackageName })
    $win32 = @($rows | Where-Object { $_.Kind -ne 'store' -and $_.Uninstall })
    $none = @($rows | Where-Object { -not ($_.Kind -eq 'store' -and $_.PackageName) -and -not ($_.Kind -ne 'store' -and $_.Uninstall) })
    $items = @($rows | ForEach-Object { (T "{0}（{1}）") -f $_.Name, $_.SizeText })
    $txt = ''
    if ($win32.Count -gt 0) { $txt += (T "会依次打开 {0} 个软件自带的卸载程序：一个走完、窗口关掉后，自动打开下一个。每个都按它自己的提示操作，可以随时停下。") -f $win32.Count }
    if ($store.Count -gt 0) { $txt += $(if ($txt) { "`n" } else { '' }) + ((T "应用商店的 {0} 个直接卸载。") -f $store.Count) }
    if ($none.Count -gt 0) { $txt += "`n" + ((T "另有 {0} 个没有登记卸载方法，跳过：{1}") -f $none.Count, ((@($none | ForEach-Object { $_.Name })) -join (T '、'))) }
    $txt += "`n`n" + (T '卸载会删除这些软件，它们保存在软件里的数据可能一起被删掉。')
    if ((Show-Sheet -Kind warn -Title ((T "卸载选中的 {0} 个软件？") -f $rows.Count) -Text $txt -Items $items -Buttons @((T '取消'), (T '卸载')) -Primary (T '卸载') -Cancel (T '取消')) -ne (T '卸载')) { return }
    $script:uq = @{ Win32 = $win32; I = -1; Proc = $null; At = (Get-Date); ExitAt = $null; Done = 0; Fail = (New-Object System.Collections.ArrayList); Stop = $false; Total = ($win32.Count + $store.Count) }
    OpLog '卸载' (T '批量卸载') ((@($rows | ForEach-Object { $_.Name })) -join (T '、')) ((T "{0} 个") -f $rows.Count)
    if ($store.Count -gt 0) {
        $sync.Mode = 'uninstmany'; $sync.UninstMany = $null
        Start-Op ((T "卸载 {0} 个应用商店软件") -f $store.Count); UI-Busy $true
        Start-Worker @'
$res = New-Object System.Collections.ArrayList; $i = 0
foreach ($x in $arg.Items) {
    if (Stopping) { break }
    $i++
    SetP @{ Steps = $arg.Items.Count; Step = $i; StepName = $x.Name; SubKind = 'none' }
    $ok = $true; $msg = ''
    try { Remove-AppxPackage -Package $x.Pkg -ErrorAction Stop } catch { $ok = $false; $msg = $_.Exception.Message }
    OpLog '卸载' (T '卸载应用商店软件') $x.Name $(if ($ok) { ((T "约 {0}") -f $(GB $x.Size)) } else { (T '失败：') + $msg })
    [void]$res.Add(@{ Name = $x.Name; Ok = $ok; Msg = $msg })
}
$sync.UninstMany = $res
'@ @{ Items = @($store | ForEach-Object { @{ Pkg = $_.PackageName; Name = $_.Name; Size = [double]$_.Size } }) }
    } else { Step-UninstQueue }
}
# 有的卸载程序把自己复制到临时文件夹再打开一次，原来那个马上退出：临时文件夹里在这之后开的程序还在，就当还没走完
function Test-UninstChild($since) {
    $tmp = [IO.Path]::GetTempPath().TrimEnd('\')
    foreach ($p in @(Get-Process -ErrorAction SilentlyContinue)) {
        try { if ($p.StartTime -ge $since -and $p.Path -and $p.Path.StartsWith($tmp, [StringComparison]::OrdinalIgnoreCase)) { return $true } } catch {}
    }
    return $false
}
function Step-UninstQueue([switch]$Next) {
    $q = $script:uq
    if (-not $q) { $script:uqTimer.Stop(); return }
    if ($q.Proc -and -not $Next) {
        $busy = $false
        try { if (-not $q.Proc.HasExited) { $busy = $true } } catch {}
        if (-not $busy -and (Test-UninstChild $q.At)) { $busy = $true }
        if ($busy) { $q.ExitAt = $null; if (-not $script:uqTimer.IsEnabled) { $script:uqTimer.Start() }; return }
        if (-not $q.ExitAt) { $q.ExitAt = Get-Date; return }
        if (((Get-Date) - $q.ExitAt).TotalSeconds -lt 1.5) { return }   # 走完后停一下再开下一个，免得两个窗口叠在一起
    }
    $q.Proc = $null; $q.ExitAt = $null
    if ($q.Stop -or ($q.I + 1) -ge $q.Win32.Count) { Finish-UninstQueue; return }
    $q.I++
    $r = $q.Win32[$q.I]
    $pc = Split-Command $r.Uninstall
    try {
        if ($script:uiTest) { $script:uiFixRuns.Add('uninstall:' + $r.Name) }
        elseif ($pc[1]) { $q.Proc = Start-Process -FilePath $pc[0] -ArgumentList $pc[1] -PassThru -ErrorAction Stop }
        else { $q.Proc = Start-Process -FilePath $pc[0] -PassThru -ErrorAction Stop }
        $q.At = Get-Date; $q.Done++
        OpLog '卸载' (T '打开卸载程序') $r.Name $r.Uninstall
    } catch { [void]$q.Fail.Add(((T "{0}：打不开卸载程序（{1}）") -f $r.Name, $_.Exception.Message)) }
    $ctl.AppsBatchText.Text = (T "正在卸载第 {0} / {1} 个：{2}。按卸载程序的提示操作；它的窗口关掉后，自动打开下一个。") -f ($q.I + 1), $q.Win32.Count, $r.Name
    $ctl.AppsBatchBox.Visibility = 'Visible'; $ctl.AppsLeftBox.Visibility = 'Collapsed'
    if (-not $script:uqTimer.IsEnabled) { $script:uqTimer.Start() }
}
function Finish-UninstQueue {
    $script:uqTimer.Stop()
    $q = $script:uq; $script:uq = $null
    $ctl.AppsBatchBox.Visibility = 'Collapsed'
    if (-not $q) { return }
    $msg = (T "处理了 {0} 个软件。") -f $q.Done
    if ($q.Stop -and ($q.I + 1) -lt $q.Win32.Count) { $msg += (T '中途停下了，后面的没有打开。') }
    if ($q.Fail.Count -gt 0) { $msg += "`n`n" + (T '没成的：') + "`n" + ((@($q.Fail)) -join "`n") }
    $msg += "`n`n" + (T '卸载程序常会留下设置和缓存：可以到「残留文件夹」里看看。列表已经刷新。')
    if ($script:uiTest) { $script:uiSheets.Add('batch-uninstall') } else { Show-Sheet -Kind done -Title (T '批量卸载走完了') -Text $msg | Out-Null }
    Clear-Picks
    if (-not $script:worker -and -not $script:uiTest) { Load-Apps }
}
$ctl.BtnPickUninstall.Add_Click({ Start-BatchUninstall })
$ctl.BtnBatchNext.Add_Click({ if ($script:uq) { Step-UninstQueue -Next } })
$ctl.BtnBatchStop.Add_Click({ if ($script:uq) { $script:uq.Stop = $true; Finish-UninstQueue } })
# 一次禁用 / 启用几个开机启动项、计划任务、右键菜单扩展：先列出来确认一次
function Start-BatchToggle([bool]$on) {
    $rows = @(Get-Picked | Where-Object { $_ -is [StartRow] -and -not $_.Ours -and $_.Kind -ne 'leftover' -and [bool]$_.Enabled -ne $on })
    if ($rows.Count -eq 0) { return }
    $verb = if ($on) { (T '启用') } else { (T '禁用') }
    $txt = if ($on) { (T '这些项目会重新生效：开机启动项下次开机时启动，计划任务到时间照常运行，右键菜单扩展对新打开的资源管理器窗口生效。') }
           else { (T '这些项目会停用：开机时不再自动启动、计划任务到时间不再运行、右键菜单里不再出现。程序本身都不删，随时可以在这里重新启用。') }
    $items = @($rows | ForEach-Object { $_.Name })
    $title = if ($on) { (T "启用选中的 {0} 项？") -f $rows.Count } else { (T "禁用选中的 {0} 项？") -f $rows.Count }
    if ((Show-Sheet -Title $title -Text $txt -Items $items -Buttons @((T '取消'), $verb) -Primary $verb -Cancel (T '取消')) -ne $verb) { return }
    $errs = New-Object System.Collections.Generic.List[string]
    foreach ($r in $rows) { $err = Set-StartRow $r $on -Quiet; if ($err) { $errs.Add([string]$err) } else { $r.Picked = $false } }
    if (@($rows | Where-Object { $_.Kind -eq 'shellex' }).Count -gt 0) { $ctl.AppsInfo.Text = (T '右键菜单的改动对新打开的资源管理器窗口生效；还没生效的话注销再登录一次') }
    Filter-StartRows; Update-PickBar
    if ($errs.Count -gt 0) { Show-Sheet -Kind warn -Title $(if ($on) { (T "{0} 项没启用成") -f $errs.Count } else { (T "{0} 项没禁用成") -f $errs.Count }) -Text ($errs -join "`n") | Out-Null }
    else { UI-Log $(if ($on) { (T "启用了 {0} 项") -f $rows.Count } else { (T "禁用了 {0} 项") -f $rows.Count }) }
}
$ctl.BtnPickDisable.Add_Click({ Start-BatchToggle $false })
$ctl.BtnPickEnable.Add_Click({ Start-BatchToggle $true })
# 一次把几个残留文件夹移到回收站
function Start-BatchLeftover {
    $rows = @(Get-Picked | Where-Object { $_ -is [StartRow] -and $_.Kind -eq 'leftover' })
    if ($rows.Count -eq 0) { return }
    if ($script:worker) { Show-Sheet -Title (T '请等当前操作做完') -Text (T '另一个操作还在进行中。') | Out-Null; return }
    $tb = [double]0; foreach ($r in $rows) { $tb += [double]$r.Key2 }
    $items = @($rows | ForEach-Object { (T "{0}（{1}）") -f $_.Detail, $_.Size })
    $ans = Show-Sheet -Kind danger -Title ((T "把选中的 {0} 个文件夹移到回收站？") -f $rows.Count) -Text ((T "共 {0}。这些只是猜测：名字对不上任何已装软件、没有程序在用、一个月没动过。拿不准的先点「打开位置」看一眼。移到回收站后还能恢复。") -f (Fmt $tb)) -Items $items `
        -Confirm (T '我看过了，这些是已卸载软件留下的，删除不会给我带来损失。') -Buttons @((T '先不删'), (T '移到回收站')) -Primary (T '移到回收站') -Cancel (T '先不删')
    if ($ans -ne (T '移到回收站')) { return }
    $sync.Mode = 'leftdel'; $sync.LeftRes = $null; $script:leftBatch = $true
    Start-Op ((T "把 {0} 个残留文件夹移到回收站") -f $rows.Count); UI-Busy $true
    Start-Worker $script:leftDelCode @{ Items = @($rows | ForEach-Object { @{ Path = [string]$_.Detail; Bytes = [double]$_.Key2 } }); Name = (T '残留文件夹') }
}
$ctl.BtnPickRecycle.Add_Click({ Start-BatchLeftover })
# ---------- 检查新版本（winget）----------
function Start-WingetCheck {
    if ($script:worker) { Show-Sheet -Title (T '请等当前操作做完') -Text (T '另一个操作还在进行中。') | Out-Null; return }
    if (-not (Get-WingetExe)) { Show-Sheet -Kind warn -Title (T '这台电脑没有 winget') -Text (T 'winget 是 Windows 自带的软件包管理器（「应用安装程序」），Windows 10 1809 以后的系统都有。打不开的话，在应用商店里搜「应用安装程序」装一下。') | Out-Null; return }
    $sync.Mode = 'winget'; $sync.WingetResult = $null
    Start-Op (T '用 winget 检查新版本') -NoCard; UI-Busy $true
    $ctl.AppsInfo.Text = (T '正在用 winget 查，要几十秒…')
    Start-Worker @'
$sync.WingetResult = Get-WingetUpgrades
'@ $null
}
function Apply-WingetResult($res) {
    if (-not $res) { return }
    if ($res.Err) {
        $msg = switch ($res.Err) { 'nowinget' { (T '这台电脑没有 winget') } 'timeout' { (T 'winget 三分钟都没查完，可能是网络不通') } default { $res.Err } }
        Show-Sheet -Kind warn -Title (T '没查成') -Text $msg | Out-Null; Filter-Apps; return
    }
    $items = @($res.Items)
    $hit = 0
    if ($script:appRows) {
        foreach ($r in $script:appRows) { $r.Upgrade = ''; $r.UpgradeId = '' }
        $norm = { param($x) (([string]$x).ToLowerInvariant() -replace '[^\p{L}\p{N}]', '') }
        foreach ($u in $items) {
            $un = & $norm $u.Name
            if ($un.Length -lt 2) { continue }
            foreach ($r in $script:appRows) {
                if ($r.Upgrade) { continue }
                $rn = & $norm $r.Name
                if ($rn -eq $un -or ($un.Length -ge 4 -and $rn.StartsWith($un)) -or ($rn.Length -ge 4 -and $un.StartsWith($rn))) {
                    $r.Upgrade = [string]$u.Available; $r.UpgradeId = [string]$u.Id
                    $r.Meta = ($r.Meta -replace '\s*·\s*' + [regex]::Escape((T '可升级到')) + '[^·]*', '') + ' · ' + (T '可升级到') + ' ' + $u.Available
                    $hit++; break
                }
            }
        }
    }
    $script:wingetItems = $items
    Filter-Apps
    if ($items.Count -eq 0) { Show-Sheet -Kind done -Title (T '都是最新的') -Text (T 'winget 没有查到有新版本的软件。') | Out-Null; return }
    $ctl.AppsInfo.Text = (T "winget：{0} 个软件有新版本，其中 {1} 个在列表里标出来了") -f $items.Count, $hit
    $lines = @($items | ForEach-Object { (T "{0}：{1} → {2}") -f $_.Name, $_.Version, $_.Available })
    $ans = Show-Sheet -Title ((T "{0} 个软件有新版本") -f $items.Count) -Text (T '列表里有的软件旁边多了「升级」按钮。也可以在终端窗口里一次全部升级：winget 会逐个下载安装，有的安装程序会弹出自己的窗口，照提示点就行。') -Items $lines `
        -Buttons @((T '好'), (T '在终端里全部升级')) -Primary (T '好') -Cancel (T '好')
    if ($ans -eq (T '在终端里全部升级')) { Start-WingetUpgrade '' }
}
function Start-WingetUpgrade([string]$id, [string]$name = '') {
    $exe = Get-WingetExe; if (-not $exe) { return }
    $cmd = if ($id) { ('"{0}" upgrade --id "{1}" --accept-source-agreements --accept-package-agreements' -f $exe, $id) }
           elseif ($name) { ('"{0}" upgrade --name "{1}" --accept-source-agreements --accept-package-agreements' -f $exe, $name) }
           else { ('"{0}" upgrade --all --accept-source-agreements --accept-package-agreements' -f $exe) }
    try {
        Start-Process -FilePath "$env:SystemRoot\System32\cmd.exe" -ArgumentList ('/k ' + $cmd)
        OpLog '系统设置' (T '用 winget 升级软件') $(if ($id) { $id } elseif ($name) { $name } else { (T '全部') }) $cmd
        UI-Log ((T "已在终端里开始升级：{0}") -f $cmd)
    } catch { Show-Sheet -Kind warn -Title (T '打不开终端') -Text $_.Exception.Message | Out-Null }
}
$ctl.BtnAppsUpdates.Add_Click({ Start-WingetCheck })

