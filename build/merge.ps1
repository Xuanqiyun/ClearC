# 把 src/parts/ 下的各部分按 order.txt 的顺序原样拼成 src/CleanC-UI.ps1（直接运行源码和构建 exe 都用这个文件）。
# 用法：powershell -NoProfile -ExecutionPolicy Bypass -File build\merge.ps1          拼好写回
#       powershell -NoProfile -ExecutionPolicy Bypass -File build\merge.ps1 -Check   只检查 src/CleanC-UI.ps1 是不是最新的
param([switch]$Check)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$parts = Join-Path $root 'src/parts'
$target = Join-Path $root 'src/CleanC-UI.ps1'
$ms = New-Object System.IO.MemoryStream
foreach ($line in [IO.File]::ReadAllLines((Join-Path $parts 'order.txt'))) {
    $name = $line.Trim()
    if (-not $name -or $name.StartsWith('#')) { continue }
    $b = [IO.File]::ReadAllBytes((Join-Path $parts $name))
    $ms.Write($b, 0, $b.Length)
}
$new = $ms.ToArray()
$old = if (Test-Path -LiteralPath $target) { [IO.File]::ReadAllBytes($target) } else { [byte[]]@() }
$same = ($old.Length -eq $new.Length) -and ([Convert]::ToBase64String($old) -eq [Convert]::ToBase64String($new))
if ($Check) {
    if ($same) { 'src/CleanC-UI.ps1 is up to date'; exit 0 }
    'src/CleanC-UI.ps1 is out of date: run build/merge.ps1'; exit 1
}
if ($same) { 'src/CleanC-UI.ps1 is already up to date' } else { [IO.File]::WriteAllBytes($target, $new); "wrote src/CleanC-UI.ps1 ($($new.Length) bytes)" }
