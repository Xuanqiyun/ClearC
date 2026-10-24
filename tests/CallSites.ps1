# 用语法树找出脚本里所有命令调用和 .NET 方法调用，以及它们在哪个函数里、带了什么参数。
# 安全测试用它锁定「哪里调用了什么」：注释和普通字符串里的字不算；& "$sys32\taskkill.exe"、spps 这类别名、
# cmd /c 后面真正运行的命令（rd、mklink……）都认得出。后台代码写在单引号 here-string 里（@'…'@），
# 这些字符串也拆开再找一遍，位置记成「外面的函数/worker」。
#   Name：命令名，小写，去掉路径和 .exe；别名换成全名（spps、kill → stop-process；ri、rm、del、erase、rd、rmdir → remove-item）；
#         cmd /c 后面的命令记成 cmd:rd、cmd:mklink；方法调用记成 [fstools]::recycle 或 .kill
#   Args：参数，小写，去掉引号
function Get-CallSites([string]$code, [string]$outer = '') {
    $L = [System.Management.Automation.Language.Parser]
    $errs = $null; $tok = $null
    $ast = $L::ParseInput($code, [ref]$tok, [ref]$errs)
    $alias = @{ 'spps' = 'stop-process'; 'kill' = 'stop-process'; 'ri' = 'remove-item'; 'rm' = 'remove-item'; 'del' = 'remove-item'; 'erase' = 'remove-item'; 'rd' = 'remove-item'; 'rmdir' = 'remove-item' }
    $where = {
        param($n)
        $w = $null; $p = $n.Parent
        while ($p -and -not $w) {
            if ($p -is [System.Management.Automation.Language.FunctionDefinitionAst]) { $w = $p.Name }
            elseif ($p -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and $p.Member.Extent.Text -match '^Add(_|Handler)') {
                $w = ($p.Expression.Extent.Text -replace '^\$ctl\.', '') + '.' + ($p.Member.Extent.Text -replace '^Add_?', '')
            }
            $p = $p.Parent
        }
        if (-not $w) { $w = '(top)' }
        if ($outer) { $w = $outer + '/' + $w }
        return $w
    }
    $word = { param($e) if ($null -eq $e) { '' } else { $e.Extent.Text.Trim('"', "'").ToLowerInvariant() } }
    $out = New-Object System.Collections.Generic.List[object]
    foreach ($n in $ast.FindAll({ param($x) $true }, $true)) {
        if ($n -is [System.Management.Automation.Language.CommandAst]) {
            $els = @($n.CommandElements)
            $name = $n.GetCommandName()
            if (-not $name) { $name = & $word $els[0] }
            $name = ($name -split '[\\/]')[-1].ToLowerInvariant() -replace '\.exe$', ''
            if ($alias.ContainsKey($name)) { $name = $alias[$name] }
            $argv = @($els | Select-Object -Skip 1 | ForEach-Object { & $word $_ })
            $w = & $where $n
            $out.Add([pscustomobject]@{ Where = $w; Name = $name; Args = $argv; Line = $n.Extent.StartLineNumber; Text = $n.Extent.Text })
            # cmd /c 后面才是真正运行的命令
            $ci = [array]::IndexOf([string[]]$argv, '/c')
            if ($name -eq 'cmd' -and $ci -ge 0 -and $ci + 1 -lt $argv.Count) {
                $out.Add([pscustomobject]@{ Where = $w; Name = 'cmd:' + $argv[$ci + 1]; Args = @($argv | Select-Object -Skip ($ci + 2)); Line = $n.Extent.StartLineNumber; Text = $n.Extent.Text })
            }
        } elseif ($n -is [System.Management.Automation.Language.InvokeMemberExpressionAst]) {
            $t = $n.Expression.Extent.Text
            $m = $n.Member.Extent.Text.ToLowerInvariant()
            $name = if ($n.Static) { (($t -replace '^\[System\.', '[') + '::' + $m).ToLowerInvariant() } else { '.' + $m }
            $argv = @($n.Arguments | Where-Object { $null -ne $_ } | ForEach-Object { & $word $_ })
            $out.Add([pscustomobject]@{ Where = (& $where $n); Name = $name; Args = $argv; Line = $n.Extent.StartLineNumber; Text = $n.Extent.Text })
        } elseif ($n -is [System.Management.Automation.Language.StringConstantExpressionAst] -and $n.StringConstantType -eq 'SingleQuotedHereString' -and $n.Value.Length -gt 40 -and $n.Value -notmatch '(?m)^\s*using System') {
            foreach ($s in (Get-CallSites $n.Value ((& $where $n) + '/worker'))) { $out.Add($s) }
        }
    }
    return $out.ToArray()
}
