# 取出主界面、对话框、提醒和英文帮助的 XAML，各存一份浅色、一份深色
param($Out = (Join-Path ([IO.Path]::GetTempPath()) "clearc-theme"))
$src = [IO.File]::ReadAllText((Join-Path $PSScriptRoot '../../src/CleanC-UI.ps1'))
Add-Type -TypeDefinition ([regex]::Match($src, "(?s)\`$dupCode = @'\r?\n(.*?)\r?\n'@").Groups[1].Value)
$parts = @{
    main  = [regex]::Match($src, '(?s)\[xml\]\$xaml = @"\r?\n(.*?)\r?\n"@').Groups[1].Value
    sheet = [regex]::Match($src, "(?s)\`$script:sheetXaml = @'\r?\n(.*?)\r?\n'@").Groups[1].Value
    toast = [regex]::Match($src, "(?s)function Show-Toast.*?\`$x = @'\r?\n(.*?)\r?\n'@").Groups[1].Value
    help  = '<R xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml">' + [regex]::Match($src, "(?s)\`$script:helpEnXaml = @'\r?\n(.*?)\r?\n'@").Groups[1].Value + '</R>'
}
New-Item -ItemType Directory -Force $Out | Out-Null
foreach ($k in $parts.Keys) {
    $t = $parts[$k]
    if (-not $t) { "missing $k"; continue }
    [Theme]::Dark = $false; [IO.File]::WriteAllText("$Out/$k.light.xaml", [Theme]::Xaml($t))
    [Theme]::Dark = $true;  [IO.File]::WriteAllText("$Out/$k.dark.xaml", [Theme]::Xaml($t))
    "{0}: {1} chars" -f $k, $t.Length
}
