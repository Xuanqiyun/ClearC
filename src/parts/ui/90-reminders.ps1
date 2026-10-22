# ------------------------------------------------------------
# 自动提醒：用 Windows 任务计划，开关打开时创建，关掉时删除
# ------------------------------------------------------------
$script:taskRemind = 'CleanC\LowSpaceReminder'
$script:taskClean  = 'CleanC\WeeklyCleanup'
function Test-CleanTask([string]$name) { & "$env:SystemRoot\System32\schtasks.exe" /Query /TN $name 2>$null | Out-Null; return ($LASTEXITCODE -eq 0) }
function Get-TaskCommand([string]$name) {
    try { $x = [xml]((& "$env:SystemRoot\System32\schtasks.exe" /Query /TN $name /XML 2>$null) -join "`n"); return [string]$x.Task.Actions.Exec.Command } catch { return '' }
}
# 是不是在临时文件夹里（从压缩包里直接打开时，exe 会被解到这里，过后会被清掉）
function Test-TempPath([string]$path) {
    foreach ($t in @($env:TEMP, $env:TMP, "$env:LOCALAPPDATA\Temp", "$env:SystemRoot\Temp")) {
        if ($t -and $path.StartsWith($t.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) { return $true }
    }
    return $false
}
function Get-ExeVersion([string]$path) { try { return [version]([Diagnostics.FileVersionInfo]::GetVersionInfo($path).FileVersion) } catch { return $null } }
function Register-CleanTask([string]$name, [string]$desc, [string]$argsText, [string]$trigger) {
    $exe = [string]$env:CLEANC_SELF
    if (-not $exe -or -not (Test-Path -LiteralPath $exe)) { return (T '只有 exe 版本支持定时任务') }
    if (Test-TempPath $exe) { return ((T "本工具现在是从临时文件夹运行的（{0}），比如直接在压缩包里双击打开的。这个位置过后会被清掉，任务就找不到本工具了。`n`n请先把本工具复制到一个固定的位置（比如 D:\工具），从那里打开，再开启。") -f $exe) }
    $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $esc = [Security.SecurityElement]
    $xml = @"
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.2" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo><Author>腾挪 ClearC</Author><Description>$($esc::Escape($desc))</Description></RegistrationInfo>
  <Triggers>$($trigger.Replace('{USER}', $esc::Escape([Security.Principal.WindowsIdentity]::GetCurrent().Name)))</Triggers>
  <Principals><Principal id="Author"><UserId>$sid</UserId><LogonType>InteractiveToken</LogonType><RunLevel>HighestAvailable</RunLevel></Principal></Principals>
  <Settings>
    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
    <StartWhenAvailable>true</StartWhenAvailable>
    <ExecutionTimeLimit>PT1H</ExecutionTimeLimit>
    <Enabled>true</Enabled>
  </Settings>
  <Actions Context="Author"><Exec><Command>$($esc::Escape($exe))</Command><Arguments>$argsText</Arguments></Exec></Actions>
</Task>
"@
    $tmp = Join-Path $env:TEMP ("cleanc-task-{0}.xml" -f (Get-Random))
    [IO.File]::WriteAllText($tmp, $xml, [Text.Encoding]::Unicode)
    $out = & "$env:SystemRoot\System32\schtasks.exe" /Create /TN $name /XML $tmp /F 2>&1 | Out-String
    $code = $LASTEXITCODE
    Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
    if ($code -ne 0) { return $out.Trim() }
    return ''
}
# 两个任务的内容。提醒任务有两个触发时间：每次登录电脑 2 分钟后、每天中午 12 点（错过了就在下次开机后补一次）
function Enable-AutoTask([bool]$isRemind) {
    if ($isRemind) {
        return (Register-CleanTask $script:taskRemind (T '腾挪 ClearC：每次登录电脑后和每天中午各检查一次 C 盘剩余空间，低于设定值时提醒（每天最多一次）。在工具的「自动提醒」页关掉开关即可删除本任务。') '/check' `
            ('<LogonTrigger><UserId>{USER}</UserId><Delay>PT2M</Delay></LogonTrigger>' +
             '<CalendarTrigger><StartBoundary>2026-01-01T12:00:00</StartBoundary><ScheduleByDay><DaysInterval>1</DaysInterval></ScheduleByDay></CalendarTrigger>'))
    }
    $when = Get-Setting 'CleanWhen' 'sun'
    $days = @{ sun = 'Sunday'; mon = 'Monday'; tue = 'Tuesday'; wed = 'Wednesday'; thu = 'Thursday'; fri = 'Friday'; sat = 'Saturday' }
    $trig = if ($when -eq 'daily') { '<CalendarTrigger><StartBoundary>2026-01-04T12:30:00</StartBoundary><ScheduleByDay><DaysInterval>1</DaysInterval></ScheduleByDay></CalendarTrigger>' }
            else { $d = $days[$when]; if (-not $d) { $d = 'Sunday' }; "<CalendarTrigger><StartBoundary>2026-01-04T12:30:00</StartBoundary><ScheduleByWeek><DaysOfWeek><$d/></DaysOfWeek><WeeksInterval>1</WeeksInterval></ScheduleByWeek></CalendarTrigger>" }
    return (Register-CleanTask $script:taskClean (T '腾挪 ClearC：定期自动清理临时文件、缓存和日志（不搬家、不清空回收站、不碰个人文件夹）。在工具的「自动提醒」页关掉开关即可删除本任务。') '/autoclean' $trig)
}
# 打开工具时检查一次：本工具挪了位置、或者任务是旧版本建的（提醒没有「登录后检查」），就按现在的位置和设置重建
function Repair-AutoTasks {
    $exe = [string]$env:CLEANC_SELF
    if (-not $exe -or -not (Test-Path -LiteralPath $exe) -or (Test-TempPath $exe)) { return }
    $myVer = Get-ExeVersion $exe
    foreach ($isRemind in @($true, $false)) {
        $tn = if ($isRemind) { $script:taskRemind } else { $script:taskClean }
        $x = $null
        try { $raw = (& "$env:SystemRoot\System32\schtasks.exe" /Query /TN $tn /XML 2>$null) -join "`n"; if ($LASTEXITCODE -eq 0 -and $raw) { $x = [xml]$raw } } catch {}
        if (-not $x) { continue }
        $cmd = [string]$x.Task.Actions.Exec.Command
        $noLogon = $isRemind -and -not $x.Task.Triggers.LogonTrigger
        $repoint = $false
        if ($cmd -and $cmd -ine $exe) {
            # 只在原来那个 exe 不在了、或者比现在这个旧的时候才改用现在这个，别的副本（比如下载文件夹里的另一份）不抢
            $oldExists = Test-Path -LiteralPath $cmd
            $oldVer = if ($oldExists) { Get-ExeVersion $cmd } else { $null }
            $repoint = (-not $oldExists) -or ($myVer -and $oldVer -and $myVer -gt $oldVer)
        }
        if ($repoint -or ($noLogon -and $cmd -ieq $exe)) {
            $err = Enable-AutoTask $isRemind
            if (-not $err) { OpLog '系统设置' (T '更新任务计划') $tn $(if ($repoint) { ((T "改用 {0}（原来的 {1} 不在了或版本更旧）") -f $exe, $cmd) } else { (T '加上「登录电脑后检查」') }) }
        }
    }
}
function Remove-CleanTask([string]$name) { & "$env:SystemRoot\System32\schtasks.exe" /Delete /TN $name /F 2>$null | Out-Null }
$script:autoSync = $false
function Load-Auto {
    $script:autoSync = $true
    $exe = [string]$env:CLEANC_SELF
    $hasExe = $exe -and (Test-Path -LiteralPath $exe)
    $r1 = Test-CleanTask $script:taskRemind; $r2 = Test-CleanTask $script:taskClean
    $ctl.AutoRemindOn.IsChecked = $r1; $ctl.AutoCleanOn.IsChecked = $r2
    $ctl.AutoRemindOn.IsEnabled = $hasExe; $ctl.AutoCleanOn.IsEnabled = $hasExe
    $gb = Get-Setting 'RemindGB' '20'
    $idx = [array]::IndexOf(@('10', '20', '30', '50'), $gb); if ($idx -lt 0) { $idx = 1 }
    $ctl.AutoRemindGB.SelectedIndex = $idx
    $idx = [array]::IndexOf(@('0', '1', '2', '5', '10'), (Get-Setting 'JunkGB' '0')); if ($idx -lt 0) { $idx = 0 }
    $ctl.AutoJunkGB.SelectedIndex = $idx
    $idx = [array]::IndexOf(@('sun', 'mon', 'tue', 'wed', 'thu', 'fri', 'sat', 'daily'), (Get-Setting 'CleanWhen' 'sun')); if ($idx -lt 0) { $idx = 0 }
    $ctl.AutoCleanWhen.SelectedIndex = $idx
    $where = (T "不用开着本工具，也不用设置开机启动。开启后会在 Windows「任务计划程序」里建一个任务（{0}）：每次登录电脑 2 分钟后、以及每天中午 12 点，Windows 会在后台运行一下本工具（{1}）检查 C 盘，空间够就什么都不显示，查完马上退出。关掉开关就删除这个任务。`n请把本工具放在固定的位置，不要删掉；挪了位置后打开一次，任务会自动改用新位置。")
    $ctl.AutoRemindNote.Text = if ($hasExe) { $where -f $script:taskRemind, $exe } else { (T '只有 exe 版本支持自动提醒。') }
    $moved = ''
    foreach ($t in @($script:taskRemind, $script:taskClean)) { if (Test-CleanTask $t) { $c = Get-TaskCommand $t; if ($c -and $hasExe -and ($c -ine $exe)) { $moved = (T '本工具的位置变了，请把开关关掉再打开一次，让任务改用现在的位置。') } } }
    if ($moved) { $ctl.AutoRemindNote.Text += "`n" + $moved }
    $last = ''
    foreach ($row in (Read-OpLog)) { if ($row.What -in @('每周自动清理完成', (T '每周自动清理完成'))) { $last = (T "上次自动清理：{0}，{1}") -f $row.Time, $row.Detail; break } }
    $ctl.AutoCleanNote.Text = if ($hasExe) { ((T "任务名：{0}。") -f $script:taskClean) + $(if ($last) { "`n$last" } else { '' }) } else { (T '只有 exe 版本支持每周自动清理。') }
    $ctl.AutoCleanNote.Text += "`n" + $(if (Get-StorageSenseOn) { (T 'Windows 自带的「存储感知」现在是开着的：它也会定期清临时文件和回收站，和这里的自动清理不冲突，只是会各做一遍。') } else { (T 'Windows 自带的「存储感知」现在是关着的（在 Windows 设置 → 系统 → 存储里）。') })
    $script:autoSync = $false
    Draw-History
}
function Draw-History {
    $h = Get-History
    $days = [ordered]@{}
    foreach ($x in $h) { $days[$x.When.ToString('yyyy-MM-dd')] = $x }
    $keys = @($days.Keys | Select-Object -Last 30)
    $bars = New-Object System.Collections.Generic.List[HistBar]
    foreach ($k in $keys) {
        $x = $days[$k]
        $used = [math]::Max([double]0, $x.Total - $x.Free); $ratio = if ($x.Total -gt 0) { $used / $x.Total } else { 0 }
        $b = New-Object HistBar
        $b.H = [math]::Max([double]3, 140.0 * $ratio)
        $b.Fill = if ($ratio -ge 0.95) { '#FF3B30' } elseif ($ratio -ge 0.85) { '#FF9F0A' } else { '#0071E3' }
        $b.Tip = (T "{0}：已用 {1}，剩余 {2}") -f $k, (Fmt $used), (Fmt $x.Free)
        $b.Label = $k
        $bars.Add($b)
    }
    $ctl.HistChart.ItemsSource = $bars
    if ($keys.Count -gt 0) {
        $f = $days[$keys[0]]; $l = $days[$keys[-1]]
        $ctl.HistFirst.Text = $keys[0]; $ctl.HistLast.Text = $keys[-1]
        $d = $l.Free - $f.Free
        $ctl.HistInfo.Text = (T "最近 {0} 天有记录：C 盘剩余从 {1} 变成 {2}（{3}{4}）。蓝色正常，橙色表示用掉了八成五以上，红色表示快满了。") -f $keys.Count, (Fmt $f.Free), (Fmt $l.Free), $(if ($d -ge 0) { (T '多了 ') } else { (T '少了 ') }), (Fmt ([math]::Abs($d)))
    } else { $ctl.HistInfo.Text = (T '还没有记录。每次打开本工具都会记一笔。'); $ctl.HistFirst.Text = ''; $ctl.HistLast.Text = '' }
}
$ctl.AutoRemindGB.Add_SelectionChanged({
    if ($script:autoSync) { return }
    $gb = @('10', '20', '30', '50')[[math]::Max(0, $ctl.AutoRemindGB.SelectedIndex)]
    Set-Setting 'RemindGB' $gb
    OpLog '系统设置' (T '空间不足提醒的界限') "$gb GB" ''
})
$ctl.AutoJunkGB.Add_SelectionChanged({
    if ($script:autoSync) { return }
    $gb = @('0', '1', '2', '5', '10')[[math]::Max(0, $ctl.AutoJunkGB.SelectedIndex)]
    Set-Setting 'JunkGB' $gb
    OpLog '系统设置' (T '可清理垃圾提醒的界限') $(if ($gb -eq '0') { (T '不提醒') } else { "$gb GB" }) ''
})
# 换了清理的时间：任务开着就按新时间重建
$ctl.AutoCleanWhen.Add_SelectionChanged({
    if ($script:autoSync) { return }
    $w = @('sun', 'mon', 'tue', 'wed', 'thu', 'fri', 'sat', 'daily')[[math]::Max(0, $ctl.AutoCleanWhen.SelectedIndex)]
    Set-Setting 'CleanWhen' $w
    OpLog '系统设置' (T '自动清理的时间') ([string]$ctl.AutoCleanWhen.SelectedItem.Content) ''
    if (Test-CleanTask $script:taskClean) { $err = Enable-AutoTask $false; if ($err) { Show-Sheet -Kind warn -Title (T '没改成') -Text $err | Out-Null }; Load-Auto }
})
foreach ($sw in @($ctl.AutoRemindOn, $ctl.AutoCleanOn)) {
    $sw.Add_Checked({
        if ($script:autoSync) { return }
        $isRemind = [object]::ReferenceEquals($this, $ctl.AutoRemindOn)
        $err = Enable-AutoTask $isRemind
        if ($isRemind) { $what = (T '开启空间不足提醒'); $tn = $script:taskRemind } else { $what = (T '开启每周自动清理'); $tn = $script:taskClean }
        if ($err) { Show-Sheet -Kind warn -Title (T '没开成') -Text $err | Out-Null; Load-Auto; return }
        OpLog '系统设置' $what $tn ((T "任务计划：{0}") -f [string]$env:CLEANC_SELF)
        Load-Auto
    })
    $sw.Add_Unchecked({
        if ($script:autoSync) { return }
        $isRemind = [object]::ReferenceEquals($this, $ctl.AutoRemindOn)
        $tn = if ($isRemind) { $script:taskRemind } else { $script:taskClean }
        Remove-CleanTask $tn
        OpLog '系统设置' $(if ($isRemind) { (T '关闭空间不足提醒') } else { (T '关闭每周自动清理') }) $tn (T '已删除任务计划')
        Load-Auto
    })
}

