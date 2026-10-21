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
$stopped = $false
foreach ($a in $out) {
    $i++
    $a.Size = $a.Est; $a.Measured = $false
    if ($stopped -or (Stopping)) { $stopped = $true; continue }   # 取消后剩下的用安装时登记的大小
    SetP @{ Steps = $out.Count + 1; Step = $i + 1; StepName = $a.Name; SubKind = 'none' }
    $loc = $a.Location
    if ($loc -and $loc.Length -gt 3 -and ($generic -notcontains $loc) -and (Test-Path -LiteralPath $loc -PathType Container)) {
        $b = Est-Bytes $loc $tree
        if (Stopping) { $stopped = $true; continue }
        if ($b -gt 0) { $a.Size = $b; $a.Measured = $true }
    }
}
$sync.AppsResult = $out
'@ $null
}
function Filter-Apps {
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
}
foreach ($c in @($ctl.AppsAll, $ctl.AppsC, $ctl.AppsStore)) { $c.Add_Checked({ Filter-Apps }) }
$ctl.AppsSearch.Add_TextChanged({ Filter-Apps })
$ctl.BtnAppsRefresh.Add_Click({ Load-Apps })
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
        if ($ans -eq (T '打开 Windows 设置')) { try { Start-Process 'ms-settings:appsfeatures' } catch {} }
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
    $sync.Mode = 'leftdel'; $sync.LeftRes = $null
    Start-Op ((T "清理「{0}」的残留") -f $r.Name); UI-Busy $true
    Start-Worker @'
$n = 0; $i = 0
foreach ($x in $arg.Items) {
    if (Stopping) { break }
    $i++
    SetP @{ Steps = $arg.Items.Count; Step = $i; StepName = $x.Path; SubKind = 'none' }
    if (Get-DeleteBlock $x.Path -Leftover) { continue }
    [void][FsTools]::Recycle($x.Path, [long]$sync.Hwnd)
    $ok = -not (Test-Path -LiteralPath $x.Path)
    if ($ok) { $n++ }
    OpLog '删除' ((T "软件残留：移到回收站（{0}）") -f $arg.Name) $x.Path $(if ($ok) { GB $x.Bytes } else { (T '没删掉，可能被占用') })
}
$sync.LeftRes = @{ Count = $n; Name = $arg.Name }
'@ @{ Items = $left; Name = $r.Name }
})

