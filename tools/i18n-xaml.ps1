# 按程序的做法把界面换成英文，报告还剩哪些中文、哪些翻译键缺了、哪些格式串会出错。用法：pwsh tools/i18n-xaml.ps1 -Path src/CleanC-UI.ps1 -Keys <i18n-keys.ps1 的输出>
param([string]$Path, [string]$Keys)
$src = [IO.File]::ReadAllText($Path)
$cjk = '[㐀-鿿＀-￯　-〿]'
function HereString($decl, $q) { $m = [regex]::Match($src, '(?s)' + [regex]::Escape($decl + ' = @' + $q) + '\r?\n(.*?)\r?\n' + $q + '@'); return $m.Groups[1].Value }
$script:l10nData = HereString '$script:l10nData' "'"
$script:helpEnXaml = HereString '$script:helpEnXaml' "'"
# language block, exactly as in the program, with the language forced to English
$blk = [regex]::Match($src, '(?s)(\$script:L10n = \$null\r?\nif \(\$script:Lang -eq ''en''\) \{.*?\r?\n\})').Groups[1].Value
$script:Lang = 'en'; Invoke-Expression $blk
"dictionary entries: $($script:L10n.Count)"
# T exactly as in the engine
$tdef = [regex]::Match($src, '(?s)(function T\(\[string\]\$s\) \{.*?\r?\n\})').Groups[1].Value; Invoke-Expression $tdef
"T('清理 C 盘') = $(T '清理 C 盘');  T('不在表里') = $(T '不在表里')"
# every T key in the code resolves
$keys = Get-Content $Keys -Encoding utf8
$un = { param($x) $x.Replace('\\', [string][char]1).Replace('\t', "`t").Replace('\r', "`r").Replace('\n', "`n").Replace([string][char]1, '\') }
$miss = @($keys | Where-Object { $_ } | ForEach-Object { & $un $_ } | Where-Object { -not $script:L10n.ContainsKey($_) })
"code keys missing at runtime: $($miss.Count)"; $miss | Select-Object -First 5
# every English format string formats
$bad = 0
foreach ($kv in $script:L10n.GetEnumerator()) {
    $m = [regex]::Matches($kv.Value, '\{(\d+)'); if ($m.Count -eq 0) { continue }
    $n = 1 + (($m | ForEach-Object { [int]$_.Groups[1].Value }) | Measure-Object -Maximum).Maximum
    try { [void]([string]::Format($kv.Value, [object[]](1..$n | ForEach-Object { 1 }))) } catch { $bad++; "  bad format: $($kv.Value.Substring(0, [math]::Min(80, $kv.Value.Length)))" }
}
"format strings that throw: $bad"
# XAML: help swap + attribute/text translation as the program does it
$x = HereString '[xml]$xaml' '"'
$x = $x -replace '\$\(', '$('   # no expansion in this test
[xml]$xaml = $x
$loc = [regex]::Match($src, '(?s)# 换成英文的帮助页（整页替换中文的那一页）\r?\nfunction Use-EnglishHelp.*?\r?\n(?=\$win = \$null)').Value
if (-not $loc) { 'language block not found'; exit 1 }
Invoke-Expression $loc
# 帮助页在打开窗口时拆出去了，第一次打开帮助时照样查表（Initialize-HelpPage）
$hdoc = [xml]$script:helpXml; Set-XamlLang $hdoc
$left = @()
foreach ($d in @($xaml, $hdoc)) {
    foreach ($el in $d.SelectNodes('//*')) {
        foreach ($a in @($el.Attributes)) { if ($a.Value -match $cjk -and $a.LocalName -ne 'Tag') { $left += "$($el.LocalName).$($a.LocalName) = $($a.Value)" } }
        foreach ($c in @($el.ChildNodes)) { if ($c.NodeType -eq 'Text' -and $c.Value -match $cjk) { $left += "$($el.LocalName) text = $($c.Value)" } }
    }
}
"XAML Chinese left after translation: $($left.Count)"; $left | Sort-Object -Unique
$h = $xaml.SelectNodes("//*[local-name()='Grid' and @*[local-name()='Name']='PageHelp']")
"help pages: $($h.Count); help title: " + ($hdoc.SelectNodes("//*[local-name()='TextBlock']") | Select-Object -First 1).Text
