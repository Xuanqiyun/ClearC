# 在真的 Windows 上真跑一遍搬家（ARC-7）：挂一个临时的虚拟磁盘当目标盘，把 C 盘上一个测试用的文件夹搬过去、再搬回来；
# 再模拟两次中途断电（停在「已改名、还没建链接」和「已建链接、旧文件夹还没删」），看下次打开能不能接着做完或撤回。
# 每一步都核对每个文件的内容、属性和修改时间。只在 Windows 测试机上跑（挂虚拟磁盘要管理员）；别的地方打印 skip。
# 只碰它自己建的东西：C 盘根目录下一个 ClearC-CI-move-xxxx 文件夹、临时目录里的虚拟磁盘文件。用法：powershell -File tests\MoveDisk.Tests.ps1
param([string]$Script = (Join-Path $PSScriptRoot '../src/CleanC-UI.ps1'))
if ([IO.Path]::DirectorySeparatorChar -ne '\') { 'skip real move on a virtual disk (Windows only)'; exit 0 }
$me = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
if (-not $me.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { 'skip real move on a virtual disk (needs an administrator to attach the disk)'; exit 0 }

$ErrorActionPreference = 'Stop'
$code = [IO.File]::ReadAllText($Script)
$dupCode = [regex]::Match($code, "(?s)\`$dupCode = @'\r?\n(.*?)\r?\n'@").Groups[1].Value
$engineText = [regex]::Match($code, "(?s)\`$engine = @'\r?\n(.*?)\r?\n'@").Groups[1].Value
if (-not ('DupFinder' -as [type])) { Add-Type -TypeDefinition $dupCode }
Invoke-Expression $engineText
$ErrorActionPreference = 'Continue'
$sync = [hashtable]::Synchronized(@{}); $sync.Log = [System.Collections.Queue]::Synchronized((New-Object System.Collections.Queue)); $sync.P = [hashtable]::Synchronized(@{})
$fails = 0
function Check($name, $ok) { if ($ok) { "ok   $name" } else { "FAIL $name"; $script:fails++ } }

# 设置、操作日志、搬家进度都写到临时目录，不碰测试机上的
$T = Join-Path ([IO.Path]::GetTempPath()) ('clearc-move-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Force -Path $T | Out-Null
$script:appDir = Join-Path $T 'appdir'; $script:settingsFile = Join-Path $script:appDir 'settings.txt'; $script:opLogDir = Join-Path $script:appDir 'log'
$base = Join-Path $env:SystemDrive ('ClearC-CI-move-' + [guid]::NewGuid().ToString('N').Substring(0, 4))
$vhd = Join-Path $T 'target.vhdx'
$letter = @('R', 'S', 'T', 'U', 'V', 'W', 'X', 'Y', 'Z' | Where-Object { -not (Test-Path ($_ + ':\')) })[0]

function Invoke-DiskPart([string[]]$lines) {
    $f = Join-Path $T ('dp-' + [guid]::NewGuid().ToString('N').Substring(0, 6) + '.txt')
    [IO.File]::WriteAllText($f, ($lines -join "`r`n") + "`r`n", [Text.Encoding]::ASCII)
    $o = @(& "$env:SystemRoot\System32\diskpart.exe" /s $f 2>&1)
    return ($o -join "`n")
}
# 一个像聊天记录的文件夹：几层子文件夹、随机内容的文件、中文和带方括号的名字、空文件、空文件夹、隐藏只读的文件、一个 6 MB 的文件
function New-TestTree([string]$root) {
    New-Item -ItemType Directory -Force -Path $root | Out-Null
    $rnd = New-Object Random 7
    for ($i = 0; $i -lt 60; $i++) {
        $d = Join-Path $root ('sub{0}\deeper{1}' -f ($i % 6), ($i % 3))
        New-Item -ItemType Directory -Force -Path $d | Out-Null
        $b = New-Object byte[] ($rnd.Next(0, 20000)); $rnd.NextBytes($b)
        [IO.File]::WriteAllBytes((Join-Path $d ('file {0}.bin' -f $i)), $b)
    }
    [IO.File]::WriteAllText((Join-Path $root '中文 名字 [1].txt'), '聊天记录', [Text.Encoding]::UTF8)
    [IO.File]::WriteAllText((Join-Path $root 'a1.txt'), 'x')
    [IO.File]::WriteAllBytes((Join-Path $root 'empty.dat'), (New-Object byte[] 0))
    $big = New-Object byte[] (6MB); $rnd.NextBytes($big); [IO.File]::WriteAllBytes((Join-Path $root 'big.bin'), $big)
    New-Item -ItemType Directory -Force -Path (Join-Path $root 'empty folder') | Out-Null
    $h = Join-Path $root 'hidden.cfg'; [IO.File]::WriteAllText($h, 'h')
    [IO.File]::SetAttributes($h, [IO.FileAttributes]'Hidden, ReadOnly')
    [IO.File]::SetLastWriteTimeUtc((Join-Path $root 'a1.txt'), [datetime]'2020-01-02T03:04:05Z')
}
# 每一项：文件夹记 dir，文件记 SHA256、隐藏和只读、修改时间
function Get-Manifest([string]$root) {
    $out = @{}
    if (-not (Test-Path -LiteralPath $root)) { return $out }
    $pre = $root.TrimEnd('\').Length + 1
    $sha = [Security.Cryptography.SHA256]::Create()
    foreach ($p in [IO.Directory]::GetFileSystemEntries($root, '*', [IO.SearchOption]::AllDirectories)) {
        $rel = $p.Substring($pre)
        $a = [IO.File]::GetAttributes($p)
        if ($a -band [IO.FileAttributes]::Directory) { $out[$rel] = 'dir'; continue }
        $fs = [IO.File]::OpenRead($p)
        try { $h = [BitConverter]::ToString($sha.ComputeHash($fs)) } finally { $fs.Dispose() }
        $flags = ''; if ($a -band [IO.FileAttributes]::Hidden) { $flags += 'H' }; if ($a -band [IO.FileAttributes]::ReadOnly) { $flags += 'R' }
        $out[$rel] = '{0} {1} {2}' -f $h, $flags, [IO.File]::GetLastWriteTimeUtc($p).Ticks
    }
    return $out
}
function Same($a, $b) {
    if ($a.Count -ne $b.Count) { return $false }
    foreach ($k in $a.Keys) { if ($b[$k] -ne $a[$k]) { return $false } }
    return $true
}
function Show-Diff($a, $b) {
    $d = @(); foreach ($k in $a.Keys) { if ($b[$k] -ne $a[$k]) { $d += $k } }; foreach ($k in $b.Keys) { if (-not $a.ContainsKey($k)) { $d += "+$k" } }
    return (@($d | Select-Object -First 5) -join ', ')
}
function Show-Log { while ($sync.Log.Count) { '    | ' + $sync.Log.Dequeue() } }

try { & {
    trap { "FAIL error in the test script: $($_.Exception.Message) (line $($_.InvocationInfo.ScriptLineNumber))"; $script:fails++; continue }
    Init-DriveThreads
    $o = Invoke-DiskPart @("create vdisk file=`"$vhd`" maximum=400 type=expandable", "select vdisk file=`"$vhd`"", 'attach vdisk', 'create partition primary', 'format fs=ntfs quick label=ClearCCI', "assign letter=$letter")
    $vol = "$letter`:\"
    for ($i = 0; $i -lt 60 -and -not (Test-Path -LiteralPath $vol); $i++) { Start-Sleep -Milliseconds 500 }
    if (-not (Test-Path -LiteralPath $vol)) { "FAIL could not attach a virtual disk: $o"; $script:fails++; return }
    # 这个进程开始以后才挂上的盘，PowerShell 里不一定有这个盘符（真用的时候后台是挂上以后才开的，没有这个问题）
    if (-not (Get-PSDrive -Name $letter -ErrorAction SilentlyContinue)) { New-PSDrive -Name $letter -PSProvider FileSystem -Root $vol | Out-Null }
    $di = New-Object IO.DriveInfo $letter
    Check ("a 400 MB virtual disk is attached as {0} ({1}, {2})" -f $vol, $di.DriveType, $di.DriveFormat) ($di.DriveType -eq 'Fixed' -and $di.DriveFormat -eq 'NTFS')
    $destRoot = Join-Path $vol 'CDriveMoved'

    # ---- 1. 搬过去 ----
    $src = Join-Path $base 'Fake Chat Data'
    New-TestTree $src
    $before = Get-Manifest $src
    $res = @{}
    Invoke-Move @{ N = 'CI'; Paths = @($src); Kill = @(); KillDirs = @() } $destRoot $res
    Show-Log
    $dst = [string]@($res.Dest)[0]
    Check ("move: one folder done, nothing failed or waiting ({0} files)" -f $before.Count) ($res.Done -eq 1 -and $res.Fail -eq 0 -and $res.Wait -eq 0 -and $dst.StartsWith($vol, [StringComparison]::OrdinalIgnoreCase))
    Check 'move: C: now holds a link that points at the copy on the virtual disk' ((IsLink $src) -and ([string](LinkTarget $src)).TrimEnd('\') -ieq $dst.TrimEnd('\'))
    $viaLink = Get-Manifest $src; $onDisk = Get-Manifest $dst
    Check ("move: every file arrived with the same content, attributes and time, seen through the link and on the disk ({0})" -f (Show-Diff $before $onDisk)) ((Same $before $viaLink) -and (Same $before $onDisk))
    Check 'move: the old folder on C: is deleted and no move journal is left' (-not (Test-Path -LiteralPath "$src.moved_backup") -and @(Get-MoveJournal).Count -eq 0)
    Check 'move: it shows up in the move records' (@(Get-MoveRecords | Where-Object { [string]$_.Src -ieq $src }).Count -eq 1)

    # ---- 2. 搬回来 ----
    $r2 = @{}
    Invoke-MoveBack @{ Src = $src; Dst = $dst; Idx = 0; Restrict = $true; Allowed = @() } $r2
    Show-Log
    $back = Get-Manifest $src
    Check ("move back: a real folder again with the same files, the copy on the virtual disk is removed ({0})" -f $r2.Msg) ($r2.Ok -and -not (IsLink $src) -and (Same $before $back) -and -not (Test-Path -LiteralPath $dst) -and @(Get-MoveJournal).Count -eq 0)

    # ---- 3. 断电：已经改名、还没建链接 → 下次打开接着做完 ----
    $dst3 = Join-Path $destRoot 'Fake Chat Data (power cut 1)'
    & "$env:SystemRoot\System32\robocopy.exe" $src $dst3 /E /COPY:DAT /DCOPY:DAT /R:1 /W:1 /NFL /NDL /NJH /NJS /NP | Out-Null
    $bak = "$src.moved_backup"
    [IO.Directory]::Move($src, $bak)
    [void](Set-MoveStep @{ Kind = 'move'; Src = $src; Dst = $dst3; Bak = $bak; Cp = '/COPY:DAT'; Step = 'renamed' })
    $j = @(Get-MoveJournal)
    $r3 = if ($j.Count -eq 1) { Resume-Move $j[0] 'finish' } else { @{ Ok = $false; Msg = "journal has $($j.Count) entries" } }
    Show-Log
    Check ("power cut after the rename: finishing makes the link and deletes the old folder ({0})" -f $r3.Msg) ($r3.Ok -and (IsLink $src) -and (Same $before (Get-Manifest $src)) -and -not (Test-Path -LiteralPath $bak) -and @(Get-MoveJournal).Count -eq 0)
    # 收拾：拆掉链接，换回真文件夹（照搬回的办法）
    $r3b = @{}; Invoke-MoveBack @{ Src = $src; Dst = $dst3; Idx = 0; Restrict = $true; Allowed = @() } $r3b; Show-Log
    Check 'after that, moving back works too' ($r3b.Ok -and -not (IsLink $src) -and (Same $before (Get-Manifest $src)))

    # ---- 4. 断电：已经建好链接、C 盘上的旧文件夹还没删 → 撤回 ----
    $dst4 = Join-Path $destRoot 'Fake Chat Data (power cut 2)'
    & "$env:SystemRoot\System32\robocopy.exe" $src $dst4 /E /COPY:DAT /DCOPY:DAT /R:1 /W:1 /NFL /NDL /NJH /NJS /NP | Out-Null
    [IO.Directory]::Move($src, $bak)
    & "$env:SystemRoot\System32\cmd.exe" /c mklink /J "$src" "$dst4" | Out-Null
    [void](Set-MoveStep @{ Kind = 'move'; Src = $src; Dst = $dst4; Bak = $bak; Cp = '/COPY:DAT'; Step = 'linked' })
    $j = @(Get-MoveJournal)
    $r4 = if ($j.Count -eq 1) { Resume-Move $j[0] 'undo' } else { @{ Ok = $false; Msg = "journal has $($j.Count) entries" } }
    Show-Log
    Check ("power cut after the link: undo puts the original folder back, the copy stays on the virtual disk ({0})" -f $r4.Msg) ($r4.Ok -and -not (IsLink $src) -and (Same $before (Get-Manifest $src)) -and -not (Test-Path -LiteralPath $bak) -and (Same $before (Get-Manifest $dst4)) -and @(Get-MoveJournal).Count -eq 0)
} } finally {
    # 只收拾自己建的：C 盘上的测试文件夹（先拆链接，不跟进去）、虚拟磁盘、临时目录
    foreach ($p in @((Join-Path $base 'Fake Chat Data'))) { if (Test-Path -LiteralPath $p) { if (([IO.File]::GetAttributes($p) -band [IO.FileAttributes]::ReparsePoint)) { & "$env:SystemRoot\System32\cmd.exe" /c rmdir "$p" 2>$null | Out-Null } } }
    if (Test-Path -LiteralPath $base) { & "$env:SystemRoot\System32\cmd.exe" /c rd /s /q "$base" 2>$null | Out-Null }
    if (Test-Path -LiteralPath $vhd) { [void](Invoke-DiskPart @("select vdisk file=`"$vhd`"", 'detach vdisk')) }
    if (Test-Path -LiteralPath $T) { & "$env:SystemRoot\System32\cmd.exe" /c rd /s /q "$T" 2>$null | Out-Null }
}
""
if ($fails) { "$fails real move test(s) failed" } else { 'all real move tests passed' }
exit $fails
