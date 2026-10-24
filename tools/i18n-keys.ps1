# 用法：pwsh tools/i18n-keys.ps1 -Path src/CleanC-UI.ps1 -Out keys.txt
# Parse the rewritten script (outer + code here-strings), report parse errors, and list every T argument's runtime value.
param([string]$Path, [string]$Out)
$src = [IO.File]::ReadAllText($Path)
$keys = New-Object 'System.Collections.Generic.List[string]'
$errs = 0
function Scan([string]$code, [string]$scope) {
    $t = $null; $e = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseInput($code, [ref]$t, [ref]$e)
    if ($e -and $e.Count) { $script:errs += $e.Count; $e | Select-Object -First 3 | ForEach-Object { Write-Host "$scope L$($_.Extent.StartLineNumber): $($_.Message)" } }
    foreach ($c in $ast.FindAll({ param($x) $x -is [System.Management.Automation.Language.CommandAst] -and $x.GetCommandName() -eq 'T' }, $true)) {
        $a = $c.CommandElements[1]
        if ($a -is [System.Management.Automation.Language.StringConstantExpressionAst]) { $keys.Add($a.Value) } else { Write-Host "non-literal T arg: $($c.Extent.Text)" }
    }
    foreach ($h in $ast.FindAll({ param($x) $x -is [System.Management.Automation.Language.StringConstantExpressionAst] -and $x.StringConstantType -eq 'SingleQuotedHereString' }, $true)) {
        $p = $h.Parent; $q = $p; while ($q -and -not ($q -is [System.Management.Automation.Language.CommandAst] -or $q -is [System.Management.Automation.Language.AssignmentStatementAst])) { $q = $q.Parent }
        $isCode = ($q -is [System.Management.Automation.Language.CommandAst] -and $q.GetCommandName() -eq 'Start-Worker') -or ($q -is [System.Management.Automation.Language.AssignmentStatementAst] -and $q.Left.Extent.Text -eq '$engine')
        if ($isCode) { Scan $h.Value "$scope>" }
    }
}
Scan $src 'outer'
"parse errors: $errs"
$u = @($keys | Select-Object -Unique)
"T calls: $($keys.Count), unique keys: $($u.Count)"
$enc = { param($s) $s.Replace('\', '\\').Replace("`t", '\t').Replace("`r", '\r').Replace("`n", '\n') }
[IO.File]::WriteAllLines($Out, [string[]]@($u | ForEach-Object { & $enc $_ }), (New-Object Text.UTF8Encoding $false))
