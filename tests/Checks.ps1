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
# 帮助页里的控件在第一次打开帮助时才取（Initialize-HelpPage 按 $script:helpNames 取）
$helpList = [regex]::Match($src, "\`$script:helpNames = @\(([^)]*)\)").Groups[1].Value
$wanted = @($wanted) + @([regex]::Matches($helpList, "'([^']+)'") | ForEach-Object { $_.Groups[1].Value })
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
# 缓存目录库里每一条的名称和说明也要有英文（它们不经过 T '…' 的写法）
$libText = [regex]::Match($src, '(?s)\$script:cacheLib = @\(\r?\n(.*?)\r?\n\)').Groups[1].Value
$libN = 0
foreach ($l in ($libText -split "`r?`n")) {
    $m = [regex]::Match($l, "^\s*'([^']*)'\s*$"); if (-not $m.Success) { continue }
    $f = $m.Groups[1].Value.Split('|'); if ($f.Count -lt 3) { Bad "cache library line has fewer than 3 fields: $l"; continue }
    [void]$keys.Add($f[0].Trim()); [void]$keys.Add($f[2].Trim()); $libN++
}
if ($libN -lt 40) { Bad "cache library: only $libN entries parsed" } else { Ok "cache library: $libN entries" }
# exe 的版本号只有一个来源：两个构建脚本都要经过 build/version.ps1，启动器和清单里不能再写死版本号
$bdir = Join-Path (Join-Path (Split-Path $Script -Parent) '..') 'build'
$bOk = $true
foreach ($bf in 'build.ps1', 'build-roslyn.ps1') { $bt = [IO.File]::ReadAllText((Join-Path $bdir $bf)); if ($bt -notmatch 'New-VersionedSources' -or $bt -notmatch '\$vs\.Launcher' -or $bt -notmatch '\$vs\.Manifest') { $bOk = $false } }
$lt = [IO.File]::ReadAllText((Join-Path $bdir 'launcher.cs')); $mt = [IO.File]::ReadAllText((Join-Path $bdir 'app.manifest'))
if ($bOk -and $lt -match 'AssemblyFileVersion\("0\.0\.0\.0"\)' -and $mt -match 'assemblyIdentity version="0\.0\.0\.0"') { Ok 'exe version comes from $script:AppVersion (build/version.ps1)' } else { Bad 'exe version must come from $script:AppVersion through build/version.ps1 (no hard-coded version in launcher.cs / app.manifest)' }
# 版本号只有一个来源：$script:AppVersion（exe 的文件版本由构建脚本从它生成）。构建日期不再手写：exe 由构建脚本填 AppBuildStamp，
# 直接运行脚本时用脚本文件的修改日期，经环境变量 CLEANC_BUILT 交给引擎（判断系统时钟往回走用）。CHANGELOG 里要有这一版
$vm = [regex]::Match($src, "\`$script:AppVersion = '(\d+(?:\.\d+){1,3})'")
$cl = [IO.File]::ReadAllText((Join-Path $PSScriptRoot '../CHANGELOG.md'))
if ($src -match "\`$script:AppBuilt = \[DateTime\]'\d") { Bad 'the build date is still written by hand ($script:AppBuilt = [DateTime]...)' }
elseif ($src -notmatch '\$env:CLEANC_BUILT = ' -or $src -notmatch 'ParseExact\(\$env:CLEANC_BUILT') { Bad 'the build date must come from the build stamp or the script file (CLEANC_BUILT)' }
elseif (-not $vm.Success -or $cl -notmatch ('(?m)^## ' + [regex]::Escape($vm.Groups[1].Value) + '\b')) { Bad ("CHANGELOG.md has no section for version {0}" -f $vm.Groups[1].Value) }
else { Ok ("one version source ({0}), build date from the build" -f $vm.Groups[1].Value) }
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
$known = @('Title', 'Text', 'Items', 'Buttons', 'Primary', 'Cancel', 'Kind', 'Confirm', 'Extra', 'Destructive')
$sheetBad = 0
foreach ($c in $ast.FindAll({ param($x) $x -is [System.Management.Automation.Language.CommandAst] -and $x.GetCommandName() -eq 'Show-Sheet' }, $true)) {
    $ps = @($c.CommandElements | Where-Object { $_ -is [System.Management.Automation.Language.CommandParameterAst] } | ForEach-Object { $_.ParameterName })
    if (@($ps | Where-Object { $known -notcontains $_ }) -or -not ($ps -contains 'Title')) { $sheetBad++; Bad "Show-Sheet at line $($c.Extent.StartLineNumber): $($ps -join ',')" }
}
if (-not $sheetBad) { Ok 'dialog calls use known parameters' }

# 7. 同一页上同一个数只出现一次；文字有行距（3.6.1：空间地图上 C 盘、D 盘的容量出现了三遍）
$fn = { param($name) [regex]::Match($src, '(?s)function ' + [regex]::Escape($name) + '\b.*?\r?\n\}').Value }
$fill = & $fn 'Fill-MapDrives'; $card = & $fn 'Show-DiskHealth'; $ov = & $fn 'Show-MapOverview'; $lvl = & $fn 'Show-MapLevel'
if ($fill -and $fill -notmatch 'Fmt' -and $fill -notmatch '已用') { Ok 'space map: the drive picker shows only the drive (the cards show how full it is)' } else { Bad 'space map: the drive picker repeats used / total that the drive cards already show' }
if ($card -match '\.FreeText = ' -and $card -notmatch '（\{2:N0\}%），剩') { Ok 'space map: a drive card says used / total / % and free once, without cramped （…）， punctuation' } else { Bad 'space map: drive card text' }
if ($ov -match 'Update-MapOvHead' -and $src -match '(?s)function Update-MapOvHead.*?MapHealthBox.*?MapOvHead\.Visibility' -and $card -match 'Update-MapOvHead' -and $ov -notmatch "T '剩余空间'") { Ok 'space map: the overview shows what the used space is made of; the used / total headline only when no card shows this drive' } else { Bad 'space map: the overview repeats the used / total / free of the drive card' }
if ($lvl -match '\$ctl\.MapInfo\.Text = if \(\$node\.Parent\)') { Ok 'space map: at a drive root the info line does not repeat a size next to the drive card' } else { Bad 'space map: the info line at the drive root repeats a size' }
$du = @('UI-Status', 'Show-DiskHealth', 'Show-MapOverview') | Where-Object { (& $fn $_) -notmatch 'Get-DriveUse' }
if ($src -match '(?s)function Get-DriveUse' -and -not $du) { Ok 'one way to read how full a drive is (Get-DriveUse) on the cleanup page, the drive cards and the overview' } else { Bad ("these read drive use their own way: {0}" -f ($du -join ', ')) }
$dc = & $fn 'Fill-DestChoices'
if ($dc -and $dc -notmatch '已自动选了空闲最多的 \{0\} 盘（剩 \{1\}）') { Ok 'move target: the hint does not repeat the free space shown in the picker' } else { Bad 'move target: the hint repeats the free space of the picked drive' }
# 换行的文字按字号给行距（约 1.5 倍）：12 号 19、13 号 21、14 号 22；页面说明、小字、设置说明都基于同一个基础样式
$base = [regex]::Match($xaml, '(?s)<Style x:Key="TextBase" TargetType="TextBlock">.*?</Style>').Value
$lh = @{}; foreach ($m in [regex]::Matches($base, '(?s)<MultiTrigger>.*?Property="FontSize" Value="([\d.]+)".*?Property="LineHeight" Value="([\d.]+)"')) { $lh[$m.Groups[1].Value] = [double]$m.Groups[2].Value }
$badLh = @($lh.Keys | Where-Object { $lh[$_] -lt [double]$_ * 1.45 -or $lh[$_] -gt [double]$_ * 1.75 })
$noBase = @('Caption', 'PageSub', 'SetNote', 'RowLabel') | Where-Object { $xaml -notmatch ('<Style x:Key="' + $_ + '" TargetType="TextBlock" BasedOn="\{StaticResource TextBase\}"') }
if ($lh.Count -ge 3 -and -not $badLh -and -not $noBase -and $xaml -match '<Style TargetType="TextBlock" BasedOn="\{StaticResource TextBase\}"/>') { Ok ("wrapped text gets about 1.5x line spacing ({0})" -f (($lh.Keys | Sort-Object | ForEach-Object { "$_ → $($lh[$_])" }) -join ', ')) } else { Bad ("line spacing for wrapped text: sizes {0}; off {1}; styles not based on TextBase {2}" -f ($lh.Keys -join ','), ($badLh -join ','), ($noBase -join ',')) }
if ($src -match '(?s)function Set-TextMode.*?TransformToDevice.*?Ideal' -and $src -match 'Set-TextMode \$win') { Ok 'on high-DPI screens text uses ideal glyph spacing (Display mode squeezes or stretches letters to whole pixels)' } else { Bad 'text formatting mode does not follow the screen DPI' }

""
if ($fails) { "$fails check(s) failed" } else { "all checks passed" }
exit $fails
