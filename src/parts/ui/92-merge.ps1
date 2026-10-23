# ------------------------------------------------------------
# 重复文件：合并为一份（硬链接）
# ------------------------------------------------------------
# 归档：不删，把勾选的搬到选定的文件夹（<文件夹>\<盘符>\<原路径>），每组照样至少留一份不动
$ctl.BtnDupMove.Add_Click({
    if ($script:worker) { return }
    $plan = New-Object System.Collections.ArrayList
    $allChecked = 0; $bytes = [double]0
    foreach ($gid in @($script:dupByGroup.Keys)) {
        $rows = @($script:dupByGroup[$gid])
        $del = @($rows | Where-Object { $_.ToDelete -and $_.CanDelete })
        if ($del.Count -eq 0) { continue }
        if ($del.Count -ge $rows.Count) { $allChecked++; continue }
        $keepers = @($rows | Where-Object { -not $_.ToDelete } | ForEach-Object { $_.Path })
        foreach ($r in $del) { [void]$plan.Add(@{ Path = $r.Path; Size = $r.Size; Mtime = $r.ModifiedTicks; Keep = $keepers }); $bytes += $r.Size }
    }
    if ($plan.Count -eq 0) { if ($allChecked) { Show-Sheet -Kind warn -Title (T '每组至少要留一份') -Text ((T "有 {0} 组把所有副本都勾上了，这些组不会动。") -f $allChecked) | Out-Null }; return }
    $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
    $dlg.Description = (T '把勾选的文件搬到哪个文件夹（里面会按盘符和原路径建子文件夹）')
    if ($dlg.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) { return }
    $dest = $dlg.SelectedPath.TrimEnd('\')
    $why = Get-DeleteBlock $dest
    if ($why) { Show-Sheet -Kind warn -Title (T '这个文件夹不能用来归档') -Text $why | Out-Null; return }
    $free = DriveFree ($dest.Substring(0, 2))
    if ($free -lt $bytes * 1.02) { Show-Sheet -Kind warn -Title ((T "{0} 盘放不下") -f $dest.Substring(0, 1)) -Text ((T "{0} 只剩 {1}，要搬的文件有 {2}。") -f $dest.Substring(0, 2), (GB $free), (GB $bytes)) | Out-Null; return }
    $text = (T "把 {0} 个勾选的文件搬到 {1}，共 {2}。不删任何东西：每个文件放到「{1}\盘符\原来的路径」，保留的那份留在原地。跨盘的会复制再删原件。`n`n归档以后这些文件就不在原来的位置了，用到它们的程序要重新指路径。") -f $plan.Count, $dest, (Fmt $bytes)
    if ($allChecked) { $text += ((T "`n`n另有 {0} 组所有副本都被勾选，这些组会跳过。") -f $allChecked) }
    if ((Show-Sheet -Title ((T "归档 {0} 个文件？") -f $plan.Count) -Text $text -Buttons @((T '取消'), (T '归档')) -Primary (T '归档') -Cancel (T '取消')) -ne (T '归档')) { return }
    $sync.Mode = 'dupmove'; $sync.DupDeleted = $null; $sync.DupMoveDest = $dest
    Start-Op ((T "归档 {0} 个文件") -f $plan.Count)
    UI-Busy $true
    UI-Log ((T "开始归档 {0} 个文件到 {1}") -f $plan.Count, $dest)
    Start-Worker @'
$done = New-Object System.Collections.ArrayList
$i = 0; $total = $arg.Plan.Count; $moved = [double]0; $fails = 0
foreach ($p in $arg.Plan) {
    if (Stopping) { break }
    $i++
    SetP @{ Steps = $total; Step = $i; StepName = [IO.Path]::GetFileName($p.Path); SubKind = 'none' }
    if ($arg.Protect -and (Test-Personal $p.Path)) { Log ((T "  跳过（C 盘个人文件夹，受保护）：{0}") -f $($p.Path)); continue }
    $why = Get-DupBlock $p.Path (Test-Personal $p.Path)
    if ($why) { Log ((T "  跳过（{0}）：{1}") -f $why, $p.Path); continue }
    $fi = Get-Item -LiteralPath $p.Path -Force -ErrorAction SilentlyContinue
    if (-not $fi) { continue }
    if ($fi.Length -ne $p.Size -or ($p.Mtime -and $fi.LastWriteTime.Ticks -ne [long]$p.Mtime)) { Log ((T "  跳过（文件在扫描后被修改过）：{0}") -f $($p.Path)); continue }
    $sameOne = $false; foreach ($k in @($p.Keep)) { if ([FsTools]::SameFile($k, $p.Path)) { $sameOne = $true; break } }
    if ($sameOne) { Log ((T "  跳过（和保留的那份是同一个文件，只是路径不同）：{0}") -f $($p.Path)); continue }
    $rel = $p.Path.Substring(0, 1).ToUpper() + '\' + $p.Path.Substring(3)
    $to = Join-Path $arg.Dest $rel
    if ($to.StartsWith($p.Path + '\', [StringComparison]::OrdinalIgnoreCase) -or $to -ieq $p.Path) { Log ((T "  跳过（目标在原文件里面）：{0}") -f $($p.Path)); continue }
    try {
        New-Item -ItemType Directory -Path (Split-Path $to -Parent) -Force | Out-Null
        if (Test-Path -LiteralPath $to) { $to = Join-Path (Split-Path $to -Parent) (([IO.Path]::GetFileNameWithoutExtension($to)) + ' (' + (Get-Date -Format 'yyyyMMdd-HHmmss') + ')' + [IO.Path]::GetExtension($to)) }
        [IO.File]::Move($p.Path, $to)
        if (-not (Test-Path -LiteralPath $to) -or (Get-Item -LiteralPath $to).Length -ne $p.Size) { throw (T '搬过去的文件大小对不上') }
        [void]$done.Add($p.Path); $moved += $p.Size
        OpLog '搬运' (T '归档重复文件') $p.Path $to
        if ($total -le 200 -or $i % 100 -eq 0) { Log ((T "  [{0}/{1}] 已归档  {2}") -f $i, $total, $p.Path) }
    } catch { $fails++; Log ((T "  归档失败  {0}：{1}") -f $($p.Path), $($_.Exception.Message)) }
}
Log ((T "归档完成：{0} 个文件，{1}；失败 {2} 个。") -f $done.Count, (Fmt $moved), $fails)
$sync.DupDeleted = $done
'@ @{ Plan = $plan; Dest = $dest; Protect = [bool]$ctl.DupProtect.IsChecked }
})
$ctl.BtnDupMerge.Add_Click({
    if ($script:worker) { return }
    if ($script:dupSimilar) { Show-Sheet -Kind warn -Title (T '相似照片不能合并') -Text (T '合并是把内容完全相同的文件换成硬链接；相似照片内容不同，合并会丢掉其中一张。') | Out-Null; return }
    $plan = New-Object System.Collections.ArrayList
    $skip = 0; $bytes = [double]0
    foreach ($gid in @($script:dupByGroup.Keys)) {
        $rows = @($script:dupByGroup[$gid])
        $del = @($rows | Where-Object { $_.ToDelete -and $_.CanDelete })
        $keepers = @($rows | Where-Object { -not $_.ToDelete })
        if ($del.Count -eq 0 -or $keepers.Count -eq 0) { if ($del.Count) { $skip += $del.Count }; continue }
        foreach ($r in $del) {
            $root = [IO.Path]::GetPathRoot($r.Path)
            $k = @($keepers | Where-Object { [IO.Path]::GetPathRoot($_.Path) -ieq $root }) | Select-Object -First 1
            if (-not $k) { $skip++; continue }
            [void]$plan.Add(@{ Path = $r.Path; Size = $r.Size; Keep = $k.Path; KeepMtime = $k.ModifiedTicks; Verified = $r.Verified; Mtime = $r.ModifiedTicks })
            $bytes += $r.Size
        }
    }
    if ($plan.Count -eq 0) {
        Show-Sheet -Title (T '没有可以合并的') -Text (T '合并只适用于同一块盘上的副本：勾选的副本要和没勾选（保留）的那份在同一块盘上。') | Out-Null
        return
    }
    $text = (T "合并后，每个位置的文件都还在，打开、复制都和原来一样，只是这几个位置共用一份空间。`n`n要注意：合并后它们其实是同一个文件，改了其中一个位置，其他位置也会跟着变。所以适合照片、视频、安装包、压缩包这类不会再改的文件。")
    if ($skip -gt 0) { $text += ((T "`n`n另有 {0} 个勾选的副本和保留的那份不在同一块盘上，不能合并，会跳过。") -f $skip) }
    $ans = Show-Sheet -Title ((T "合并 {0} 个重复文件，腾出 {1}？") -f $plan.Count, (Fmt $bytes)) -Text $text -Confirm (T '我知道合并后改动一个位置，其他位置会跟着变。') -Buttons @((T '取消'), (T '合并')) -Primary (T '合并') -Cancel (T '取消')
    if ($ans -ne (T '合并')) { return }
    $sync.Mode = 'merge'; $sync.DupMerged = $null
    Start-Op ((T "合并 {0} 个重复文件") -f $plan.Count)
    UI-Busy $true
    Start-Worker @'
$done = New-Object System.Collections.ArrayList
$i = 0; $total = $arg.Plan.Count
foreach ($p in $arg.Plan) {
    if (Stopping) { break }
    $i++
    SetP @{ Steps = $total; Step = $i; StepName = [IO.Path]::GetFileName($p.Path); SubKind = 'none' }
    if ($arg.Protect -and (Test-Personal $p.Path)) { continue }
    $why = Get-DupBlock $p.Path (Test-Personal $p.Path)
    if ($why) { Log ((T "  跳过（{0}）：{1}") -f $why, $p.Path); continue }
    $fi = Get-Item -LiteralPath $p.Path -Force -ErrorAction SilentlyContinue
    $ki = Get-Item -LiteralPath $p.Keep -Force -ErrorAction SilentlyContinue
    if ($ki -and $p.KeepMtime -and $ki.LastWriteTime.Ticks -ne [long]$p.KeepMtime) { Log ((T "  跳过（保留的那份在扫描后被改过）：{0}") -f $($p.Keep)); continue }
    if (-not $fi -or -not $ki -or $fi.Length -ne $p.Size -or $ki.Length -ne $p.Size -or ($p.Mtime -and $fi.LastWriteTime.Ticks -ne [long]$p.Mtime)) { Log ((T "  跳过（文件在扫描后变了）：{0}") -f $($p.Path)); continue }
    if ([FsTools]::SameFile($p.Keep, $p.Path)) { Log ((T "  跳过（本来就是同一个文件）：{0}") -f $($p.Path)); continue }
    if (-not $p.Verified) {
        SetP @{ SubKind = 'verify'; Detail = $p.Path }
        $same = [DupFinder]::SameContent($p.Keep, $p.Path)
        if (-not $same -and (Stopping)) { break }   # 核对到一半取消了：这个不合并
        if (-not $same) { Log ((T "  跳过（和保留的那份内容不完全相同）：{0}") -f $($p.Path)); SetP @{ SubKind = 'none' }; continue }
        SetP @{ SubKind = 'none' }
    }
    $err = [FsTools]::MergeHardLink($p.Keep, $p.Path)
    if ($err) { Log ((T "  没合并：{0}：{1}") -f $($p.Path), $err); OpLog '合并' (T '合并为一份失败') $p.Path $err; continue }
    [void]$done.Add($p.Path)
    OpLog '合并' (T '合并为一份（硬链接）') $p.Path ((T "和 {0} 共用一份，腾出 {1}") -f $p.Keep, (GB $p.Size))
}
$sync.DupMerged = $done
'@ @{ Plan = $plan; Protect = [bool]$ctl.DupProtect.IsChecked }
})

