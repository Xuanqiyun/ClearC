# 不用 Windows 也能跑的检查：语法、C# 编译、XAML、控件名、翻译。PowerShell 7 或 Windows PowerShell 5.1 都行。
# 用法：pwsh tests/Checks.ps1        有问题时退出码是问题的个数
param([string]$Script = (Join-Path $PSScriptRoot '../src/CleanC-UI.ps1'))
$fails = 0
function Ok([string]$m) { "ok   $m" }
function Bad([string]$m) { "FAIL $m"; $script:fails++ }
$src = [IO.File]::ReadAllText($Script)
function Here([string]$decl, [string]$q) { [regex]::Match($src, '(?s)' + [regex]::Escape($decl + ' = @' + $q) + '\r?\n(.*?)\r?\n' + $q + '@').Groups[1].Value }

# 0. src/CleanC-UI.ps1 是由 src/parts/ 拼成的，要是最新的
$merge = Join-Path $PSScriptRoot '../build/merge.ps1'
if ((Test-Path -LiteralPath $merge) -and (Test-Path -LiteralPath (Join-Path $PSScriptRoot '../src/parts/order.txt'))) {
    $r = & $merge -Check
    if ($LASTEXITCODE) { Bad "$r" } else { Ok "$r" }
}

# 1. PowerShell 语法：整个脚本、核心逻辑、每个后台任务
$e = $null; $ast = [System.Management.Automation.Language.Parser]::ParseInput($src, [ref]$null, [ref]$e)
if ($e) { Bad ("script: " + ($e | Select-Object -First 3 | ForEach-Object { "line $($_.Extent.StartLineNumber): $($_.Message)" }) -join '; ') } else { Ok 'script parses' }
$engine = Here '$engine' "'"
$e = $null; [void][System.Management.Automation.Language.Parser]::ParseInput($engine, [ref]$null, [ref]$e)
if ($e) { Bad "engine: $($e[0].Message)" } else { Ok 'engine parses' }
$n = 0; $bad = 0
foreach ($w in [regex]::Matches($src, "(?s)Start-Worker @'\r?\n(.*?)\r?\n'@")) {
    $n++; $e = $null
    [void][System.Management.Automation.Language.Parser]::ParseInput("param(`$arg)`n" + $engine + "`n" + $w.Groups[1].Value, [ref]$null, [ref]$e)
    if ($e) { $bad++; Bad "worker $n : $($e[0].Message)" }
}
if (-not $bad) { Ok "$n background workers parse" }

# 2. C#：和运行时一样用 Add-Type 编译两段
foreach ($k in @(@('$rowCode', '"'), @('$dupCode', "'"))) {
    $cs = Here $k[0] $k[1]
    if (-not $cs) { Bad "$($k[0]) not found"; continue }
    try { Add-Type -TypeDefinition $cs -ErrorAction Stop; Ok "$($k[0]) compiles" } catch { Bad "$($k[0]): $($_.Exception.Message)" }
}

# 3. XAML 是合法的 XML；深色模式换过颜色以后也是
$xaml = [regex]::Match($src, '(?s)\[xml\]\$xaml = @"\r?\n(.*?)\r?\n"@').Groups[1].Value
$parts = @{ main = $xaml; sheet = (Here '$script:sheetXaml' "'"); help = ('<R xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml">' + (Here '$script:helpEnXaml' "'") + '</R>') }
foreach ($k in $parts.Keys) {
    try { [void][xml]$parts[$k]; Ok "$k XAML is well-formed" } catch { Bad "$k XAML: $($_.Exception.Message)" }
    if ('Theme' -as [type]) {
        [Theme]::Dark = $true
        try { [void][xml]([Theme]::Xaml($parts[$k])); Ok "$k XAML in dark mode is well-formed" } catch { Bad "$k dark XAML: $($_.Exception.Message)" }
        [Theme]::Dark = $false
    }
}

# 4. 代码里用到的控件都在 XAML 里
$names = [regex]::Matches($xaml, 'x:Name="([^"]+)"') | ForEach-Object { $_.Groups[1].Value }
$list = [regex]::Match($src, "(?s)foreach \(\`$n in ('Nav.*?)\) \{ \`$ctl\[\`$n\]").Groups[1].Value
$wanted = [regex]::Matches($list, "'([^']+)'") | ForEach-Object { $_.Groups[1].Value }
$missing = @($wanted | Where-Object { $_ -notin $names })
if ($missing) { Bad "controls missing in XAML: $($missing -join ', ')" } else { Ok "$($wanted.Count) controls found in XAML" }
$used = [regex]::Matches($src, '\$ctl\.([A-Za-z]+)') | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique
$unk = @($used | Where-Object { $_ -notin $wanted })
if ($unk) { Bad "controls used but not fetched: $($unk -join ', ')" } else { Ok 'every control used in code is fetched' }

# 5. 翻译：代码里每句 T '…' 在英文表里都有，英文的格式占位符能用
$tsv = Here '$script:l10nData' "'"
$dict = @{}
$un = { param($x) $x.Replace('\\', [string][char]1).Replace('\t', "`t").Replace('\r', "`r").Replace('\n', "`n").Replace([string][char]1, '\') }
foreach ($line in ($tsv -split "`r?`n")) { if (-not $line -or $line.StartsWith('#')) { continue }; $kv = $line.Split("`t", 2); if ($kv.Count -eq 2) { $dict[(& $un $kv[0])] = (& $un $kv[1]) } }
$keys = New-Object 'System.Collections.Generic.HashSet[string]'
function Scan([string]$code) {
    $a = [System.Management.Automation.Language.Parser]::ParseInput($code, [ref]$null, [ref]$null)
    foreach ($c in $a.FindAll({ param($x) $x -is [System.Management.Automation.Language.CommandAst] -and $x.GetCommandName() -eq 'T' }, $true)) {
        $arg = $c.CommandElements[1]
        if ($arg -is [System.Management.Automation.Language.StringConstantExpressionAst]) { [void]$keys.Add($arg.Value) }
    }
    foreach ($h in $a.FindAll({ param($x) $x -is [System.Management.Automation.Language.StringConstantExpressionAst] -and $x.StringConstantType -eq 'SingleQuotedHereString' }, $true)) {
        $p = $h.Parent; while ($p -and -not ($p -is [System.Management.Automation.Language.CommandAst] -or $p -is [System.Management.Automation.Language.AssignmentStatementAst])) { $p = $p.Parent }
        if (($p -is [System.Management.Automation.Language.CommandAst] -and $p.GetCommandName() -eq 'Start-Worker') -or ($p -is [System.Management.Automation.Language.AssignmentStatementAst] -and $p.Left.Extent.Text -eq '$engine')) { Scan $h.Value }
    }
}
Scan $src
$miss = @($keys | Where-Object { -not $dict.ContainsKey($_) })
if ($miss) { Bad ("{0} strings have no English translation, e.g. {1}" -f $miss.Count, ($miss | Select-Object -First 3) -join ' | ') } else { Ok "$($keys.Count) strings all translated" }
$fmtBad = 0
foreach ($k in $keys) {
    if (-not $dict.ContainsKey($k) -or $k -notmatch '\{\d') { continue }
    $nArgs = ([regex]::Matches($k, '\{(\d+)') | ForEach-Object { [int]$_.Groups[1].Value } | Measure-Object -Maximum).Maximum + 1
    try { [void]([string]::Format($dict[$k], [object[]](1..$nArgs))) } catch { $fmtBad++; if ($fmtBad -le 3) { Bad "format: $($dict[$k])" } }
}
if (-not $fmtBad) { Ok 'translated format strings are valid' }

# 6. 对话框的参数名都写对了
$known = @('Title', 'Text', 'Items', 'Buttons', 'Primary', 'Cancel', 'Kind', 'Confirm')
$sheetBad = 0
foreach ($c in $ast.FindAll({ param($x) $x -is [System.Management.Automation.Language.CommandAst] -and $x.GetCommandName() -eq 'Show-Sheet' }, $true)) {
    $ps = @($c.CommandElements | Where-Object { $_ -is [System.Management.Automation.Language.CommandParameterAst] } | ForEach-Object { $_.ParameterName })
    if (@($ps | Where-Object { $known -notcontains $_ }) -or -not ($ps -contains 'Title')) { $sheetBad++; Bad "Show-Sheet at line $($c.Extent.StartLineNumber): $($ps -join ',')" }
}
if (-not $sheetBad) { Ok 'dialog calls use known parameters' }

""
if ($fails) { "$fails check(s) failed" } else { "all checks passed" }
exit $fails
