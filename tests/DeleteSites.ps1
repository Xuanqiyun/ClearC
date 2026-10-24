# 用语法树找出脚本里所有会删文件、删文件夹的地方，以及它们在哪个函数里。
# 后台代码写在单引号的 here-string 里（@'…'@），语法树里只是字符串，所以把这些字符串也拿出来再解析一遍，
# 它们的位置记成「外面的函数/后台」。安全测试用它锁定：删用户数据的只有 Invoke-SafeRemove。
function Get-DeleteSites([string]$code, [string]$outer = '') {
    $L = [System.Management.Automation.Language.Parser]
    $errs = $null; $tok = $null
    $ast = $L::ParseInput($code, [ref]$tok, [ref]$errs)
    $where = {
        param($n)
        # 最里层的函数名；不在函数里时，用事件处理的名字（$ctl.BtnX.Add_Click → BtnX.Click）或赋值给的变量名
        $w = $null; $p = $n.Parent
        while ($p -and -not $w) {
            if ($p -is [System.Management.Automation.Language.FunctionDefinitionAst]) { $w = $p.Name }
            elseif ($p -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and $p.Member.Extent.Text -match '^Add(_|Handler)') {
                $w = ($p.Expression.Extent.Text -replace '^\$ctl\.', '') + '.' + ($p.Member.Extent.Text -replace '^Add_?', '')
            }
            $p = $p.Parent
        }
        if (-not $w) { $p = $n.Parent; while ($p -and -not $w) { if ($p -is [System.Management.Automation.Language.AssignmentStatementAst]) { $w = $p.Left.Extent.Text }; $p = $p.Parent } }
        if (-not $w) { $w = '(top)' }
        if ($outer) { $w = $outer + '/' + $w }
        return $w
    }
    $out = New-Object System.Collections.Generic.List[object]
    foreach ($n in $ast.FindAll({ param($x) $true }, $true)) {
        $kind = $null
        if ($n -is [System.Management.Automation.Language.InvokeMemberExpressionAst]) {
            $t = $n.Expression.Extent.Text -replace '^\[System\.', '[' ; $m = $n.Member.Extent.Text
            if ($t -eq '[FsTools]' -and ($m -eq 'Recycle' -or $m -eq 'RecycleMany')) { $kind = $m }
            elseif (($t -eq '[IO.File]' -or $t -eq '[IO.Directory]') -and $m -eq 'Delete') { $kind = $t.Trim('[', ']') + '.Delete' }
        } elseif ($n -is [System.Management.Automation.Language.CommandAst]) {
            $name = $n.GetCommandName()
            if ($name -and @('Remove-Item', 'ri', 'del', 'erase', 'rm', 'rd', 'rmdir') -contains $name) { $kind = 'Remove-Item' }
            else {
                $words = @($n.CommandElements | ForEach-Object { $_.Extent.Text.Trim('"', "'").ToLowerInvariant() })
                if ($words.Count -ge 3 -and $words[0] -match 'cmd(\.exe)?$' -and ($words -contains 'rd' -or $words -contains 'rmdir')) { $kind = if ($words -contains '/s') { 'rd /s' } else { 'rmdir' } }
            }
        } elseif ($n -is [System.Management.Automation.Language.StringConstantExpressionAst] -and $n.StringConstantType -eq 'SingleQuotedHereString' -and $n.Value.Length -gt 80 -and $n.Value -notmatch '(?m)^\s*using System') {
            foreach ($s in (Get-DeleteSites $n.Value ((& $where $n) + '/worker'))) { $out.Add($s) }
        }
        if ($kind) { $out.Add([pscustomobject]@{ Where = (& $where $n); Kind = $kind; Line = $n.Extent.StartLineNumber; Text = $n.Extent.Text }) }
    }
    return $out.ToArray()
}
