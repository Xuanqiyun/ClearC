# ------------------------------------------------------------
# 重复文件：合并为一份（硬链接）
# ------------------------------------------------------------
$ctl.BtnDupMerge.Add_Click({
    if ($script:worker) { return }
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
            [void]$plan.Add(@{ Path = $r.Path; Size = $r.Size; Keep = $k.Path; Verified = $r.Verified })
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
    $fi = Get-Item -LiteralPath $p.Path -Force -ErrorAction SilentlyContinue
    $ki = Get-Item -LiteralPath $p.Keep -Force -ErrorAction SilentlyContinue
    if (-not $fi -or -not $ki -or $fi.Length -ne $p.Size -or $ki.Length -ne $p.Size) { Log ((T "  跳过（文件在扫描后变了）：{0}") -f $($p.Path)); continue }
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

