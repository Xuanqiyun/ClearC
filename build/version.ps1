# 把版本号、版权写进 exe 的文件属性（资源管理器 → 属性 → 详细信息）。
# 版本只有一个来源：src/CleanC-UI.ps1 里的 $script:AppVersion。launcher.cs 和 app.manifest 里的版本号不用手改，
# 构建时在 obj 里生成改好的副本再编译；版权取 LICENSE 的第一行 Copyright。
# 本工具挪位置后重建定时任务时要比两个 exe 的文件版本（Get-ExeVersion），所以版本号必须跟着程序走。
function New-VersionedSources([string]$root, [string]$obj, [string]$scriptText) {
    $m = [regex]::Match($scriptText, "\`$script:AppVersion = '(\d+(?:\.\d+){1,3})'")
    if (-not $m.Success) { throw 'src/CleanC-UI.ps1 里找不到 $script:AppVersion' }
    $ver = $m.Groups[1].Value
    $parts = @($ver.Split('.')); while ($parts.Count -lt 4) { $parts += '0' }
    $ver4 = ($parts[0..3]) -join '.'
    $copy = ''
    $lic = Join-Path $root 'LICENSE'
    if (Test-Path -LiteralPath $lic) { $l = @(Get-Content -LiteralPath $lic | Where-Object { $_ -match '^\s*Copyright' } | Select-Object -First 1); if ($l.Count) { $copy = ($l[0] -replace '\s+', ' ').Trim() } }
    $here = Join-Path $root 'build'
    $cs = [IO.File]::ReadAllText((Join-Path $here 'launcher.cs'))
    $cs = [regex]::Replace($cs, 'AssemblyVersion\("[^"]*"\)', ('AssemblyVersion("{0}")' -f $ver4))
    $cs = [regex]::Replace($cs, 'AssemblyFileVersion\("[^"]*"\)', ('AssemblyFileVersion("{0}")' -f $ver4))
    $cs = [regex]::Replace($cs, 'AssemblyInformationalVersion\("[^"]*"\)', ('AssemblyInformationalVersion("{0}")' -f $ver))
    if ($copy -and $cs -notmatch 'AssemblyCopyright') { $cs = $cs.Replace('[assembly: AssemblyProduct(', ('[assembly: AssemblyCopyright("{0}")]' -f $copy.Replace('"', '')) + "`r`n" + '[assembly: AssemblyProduct(') }
    $man = [IO.File]::ReadAllText((Join-Path $here 'app.manifest'))
    $man = [regex]::Replace($man, '(<assemblyIdentity version=")[^"]*(")', ('${1}' + $ver4 + '${2}'))
    $utf8 = New-Object Text.UTF8Encoding $false
    $csOut = Join-Path $obj 'launcher.cs'; $manOut = Join-Path $obj 'app.manifest'
    [IO.File]::WriteAllText($csOut, $cs, $utf8); [IO.File]::WriteAllText($manOut, $man, $utf8)
    return @{ Version = $ver; Version4 = $ver4; Copyright = $copy; Launcher = $csOut; Manifest = $manOut }
}
