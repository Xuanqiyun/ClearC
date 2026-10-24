# ------------------------------------------------------------
# 公用：打开位置、选磁盘
# ------------------------------------------------------------
function Open-Location([string]$path) {
    if (-not $path) { return }
    if (Test-Path -LiteralPath $path -PathType Leaf) { Start-Process -FilePath "$env:SystemRoot\explorer.exe" -ArgumentList ("/select,`"{0}`"" -f $path) }
    elseif (Test-Path -LiteralPath $path) { Start-Process -FilePath "$env:SystemRoot\explorer.exe" -ArgumentList ("`"{0}`"" -f $path) }
    else { Show-Sheet -Kind warn -Title (T '这个位置不存在') -Text $path | Out-Null }
}
function Fixed-Drives([switch]$NoSystem) {
    $all = @([IO.DriveInfo]::GetDrives() | Where-Object {
        try { $_.DriveType -eq 'Fixed' -and $_.IsReady -and (-not $NoSystem -or $_.Name.TrimEnd('\') -ine $env:SystemDrive) } catch { $false } })
    if (-not $NoSystem) { return $all }
    # 选目标盘用的（页面文件、临时文件夹）：移动硬盘排在后面，默认选中的是本机硬盘
    $plug = @($all | Where-Object { Test-PluggableDrive $_.Name.Substring(0, 2) })
    @(@($all | Where-Object { $plug -notcontains $_ }) + $plug)
}
# 目标盘下拉框里一行：盘符、空闲，移动硬盘标出来
function Drive-ChoiceLabel($d) { ((T "{0}  空闲 {1}") -f $d.Name.TrimEnd('\'), (Fmt $d.AvailableFreeSpace)) + $(if (Test-PluggableDrive $d.Name.Substring(0, 2)) { (T '，移动硬盘') } else { '' }) }
function Ask-Restart([string]$why) {
    if ((Show-Sheet -Kind info -Title (T '需要重启电脑才生效') -Text $why -Buttons @((T '稍后自己重启'), (T '现在重启')) -Primary (T '现在重启') -Cancel (T '稍后自己重启')) -eq (T '现在重启')) {
        & "$env:SystemRoot\System32\shutdown.exe" /r /t 15 /c (T "腾挪 ClearC：15 秒后重启，让刚才的设置生效") | Out-Null
    }
}
function Shorten-Mid([string]$p, [int]$n = 70) { if (-not $p -or $p.Length -le $n) { return $p }; return $p.Substring(0, 24) + '…' + $p.Substring($p.Length - ($n - 25)) }

