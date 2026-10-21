# 读一个 NTFS 镜像的文件表，把文件夹树写成 JSON（每个文件夹：自己的文件个数、字节数、子文件夹、链接）
# 用法：pwsh scan.ps1 <镜像> <输出.json>
#       pwsh scan.ps1 <旧镜像> <输出.json> -Then <新镜像> -Frns <改动的记录号文件>   先读旧镜像，再按改动的记录号增量更新到新镜像
param([Parameter(Mandatory)] $Image, [Parameter(Mandatory)] $OutFile, $Then, $Frns)
$src = [IO.File]::ReadAllText((Join-Path $PSScriptRoot '../../src/CleanC-UI.ps1'))
Add-Type -TypeDefinition ([regex]::Match($src, "(?s)\`$dupCode = @'\r?\n(.*?)\r?\n'@").Groups[1].Value)
$root = [DiskMap]::ScanImage((Resolve-Path $Image).Path, '')
if ($Then) {
    $list = [int[]]((Get-Content $Frns -Raw).Trim() -split '\s+' | Where-Object { $_ })
    $root = [DiskMap]::RereadImage((Resolve-Path $Then).Path, [DiskMap]::TestIndex, $list)
    if ($null -eq $root) { Write-Error 'incremental reread refused'; exit 2 }
}
$o = @{}
function Walk($n, $rel) {
    $kids = @(); $links = @()
    foreach ($k in $n.Kids) { $kids += $k.Name; if ($k.IsLink) { $links += $k.Name } else { Walk $k ($rel + '/' + $k.Name) } }
    $o[$rel] = @{ files = $n.OwnFiles; bytes = $n.Own; dirs = @($kids); links = @($links) }
}
Walk $root ''
($o | ConvertTo-Json -Depth 5 -Compress) | Set-Content -Path $OutFile -Encoding utf8
"{0}: {1} folders, {2} files, {3} bytes" -f $(if ($Then) { 'incremental' } else { 'full' }), $o.Count, $root.Files, $root.Size
