# 把 src/parts/ 下的各部分按 order.txt 的顺序原样拼成 src/CleanC-UI.ps1（直接运行源码和构建 exe 都用这个文件）。
# 用法：powershell -NoProfile -ExecutionPolicy Bypass -File build\merge.ps1          拼好写回
#       powershell -NoProfile -ExecutionPolicy Bypass -File build\merge.ps1 -Check   只检查 src/CleanC-UI.ps1 是不是最新的
# 每个部分要用 UTF-8、CRLF 换行，并以换行结尾；只有第一个部分开头带 BOM（编辑器给别的部分加的 BOM 会自动去掉）。
param([switch]$Check)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$parts = Join-Path $root 'src/parts'
$target = Join-Path $root 'src/CleanC-UI.ps1'
$names = @()
foreach ($line in [IO.File]::ReadAllLines((Join-Path $parts 'order.txt'), [Text.Encoding]::UTF8)) {
    $name = $line.Trim().TrimStart([char]0xFEFF)
    if ($name -and -not $name.StartsWith('#')) { $names += $name }
}
# order.txt 里没列的文件多半是漏加了
$known = @{}; foreach ($n in $names) { $known[($n -replace '\\', '/').ToLowerInvariant()] = $true }
foreach ($f in Get-ChildItem -LiteralPath $parts -Recurse -File) {
    $rel = $f.FullName.Substring($parts.Length).TrimStart('\', '/').Replace('\', '/')
    if ($rel -in @('order.txt', 'README.md')) { continue }
    if (-not $known.ContainsKey($rel.ToLowerInvariant())) { throw "src/parts/$rel is not listed in order.txt" }
}
$ms = New-Object System.IO.MemoryStream
$first = $true
foreach ($name in $names) {
    $b = [IO.File]::ReadAllBytes((Join-Path $parts $name))
    $off = 0
    $hasBom = $b.Length -ge 3 -and $b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF
    if ($first) {
        if (-not $hasBom) { $bom = [byte[]](0xEF, 0xBB, 0xBF); $ms.Write($bom, 0, 3) }   # Windows PowerShell 5.1 要靠 BOM 认出中文
    } elseif ($hasBom) { $off = 3 }
    if ($b.Length -lt 2 -or $b[$b.Length - 2] -ne 13 -or $b[$b.Length - 1] -ne 10) { throw "src/parts/$name must end with a CRLF line break" }
    $ms.Write($b, $off, $b.Length - $off)
    $first = $false
}
$new = $ms.ToArray()
$old = if (Test-Path -LiteralPath $target) { [IO.File]::ReadAllBytes($target) } else { [byte[]]@() }
$same = ($old.Length -eq $new.Length) -and ([Convert]::ToBase64String($old) -eq [Convert]::ToBase64String($new))
if ($Check) {
    if ($same) { 'src/CleanC-UI.ps1 is up to date'; exit 0 }
    'src/CleanC-UI.ps1 differs from src/parts (run build/merge.ps1 after editing parts, or build/split.py after editing CleanC-UI.ps1)'; exit 1
}
if ($same) { 'src/CleanC-UI.ps1 is already up to date' } else { [IO.File]::WriteAllBytes($target, $new); "wrote src/CleanC-UI.ps1 ($($new.Length) bytes)" }
