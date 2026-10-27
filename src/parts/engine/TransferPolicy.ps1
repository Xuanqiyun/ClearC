# ==================== 文件传输策略：纯判断，可脱离界面与磁盘单独测试 ====================
function Test-RobocopySuccess([int]$Code) { return ($Code -ge 0 -and $Code -lt 8 -and ($Code -band 4) -eq 0) }
function Test-CountComplete($Count) {
    return [bool]($Count -and $Count.Complete -and -not $Count.Cancelled -and $Count.ErrorCount -eq 0 -and $Count.Reparse -eq 0)
}
function Test-SameCount($a, $b) {
    return [bool]((Test-CountComplete $a) -and (Test-CountComplete $b) -and [long]$a.Files -eq [long]$b.Files -and [long]$a.Bytes -eq [long]$b.Bytes)
}

