# GitHub 上 Windows 测试机跑的测试（Windows PowerShell 5.1）：检查、核心逻辑测试、构建 exe、在真的系统盘上跑自检。
# 每一步失败时写一条错误注释；自检报告整份写成几条说明注释，不用下载附件也能看到。
$ErrorActionPreference = 'Continue'
Set-Location (Split-Path $PSScriptRoot -Parent)
function Esc([string]$s) { $s.Replace('%', '%25').Replace("`r", '%0D').Replace("`n", '%0A') }
$fail = 0
function Step([string]$name, [scriptblock]$body) {
    Write-Host "::group::$name"
    $out = @(& $body 2>&1 | ForEach-Object { "$_" })
    $code = $LASTEXITCODE
    $out | ForEach-Object { Write-Host $_ }
    Write-Host '::endgroup::'
    if ($code) {
        $fails = @($out | Where-Object { $_ -like 'FAIL*' } | Select-Object -First 20) -join "`n"
        Write-Host ("::error title={0} (exit {1})::{2}" -f $name, $code, (Esc ($fails + "`n----`n" + ((@($out) | Select-Object -Last 40) -join "`n"))))
        $script:fail = 1
    } else { Write-Host ("::notice title={0}::{1}" -f $name, (Esc ((@($out) | Select-Object -Last 3) -join "`n"))) }
}
Step 'checks (PS 5.1)' { powershell -NoProfile -ExecutionPolicy Bypass -File tests\Checks.ps1 }
Step 'engine tests (PS 5.1)' { powershell -NoProfile -ExecutionPolicy Bypass -File tests\Engine.Tests.ps1 }
Step 'build exe' { powershell -NoProfile -ExecutionPolicy Bypass -File build\build.ps1 }
if (Test-Path out\ClearC.exe) {
    # 界面自测：照常打开窗口（放在屏幕外），把界面功能点一遍，对话框都当作点了取消，做完自己关掉
    $env:CLEANC_REPORT = Join-Path $PWD 'out\uitest.txt'
    $u = Start-Process -FilePath .\out\ClearC.exe -ArgumentList '/uitest' -PassThru
    $ulines = @()
    if (-not $u.WaitForExit(300000)) { Write-Host '::error title=UI test::did not finish within 5 minutes'; $fail = 1 }
    else {
        if (Test-Path $env:CLEANC_REPORT) { $ulines = @(Get-Content $env:CLEANC_REPORT -Encoding UTF8) }
        $ulines | ForEach-Object { Write-Host $_ }
        if (-not $ulines) { Write-Host ("::error title=UI test::no report was written (exit {0})" -f $u.ExitCode); $fail = 1 }
        elseif ($u.ExitCode) { Write-Host ("::error title=UI test (exit {0})::{1}" -f $u.ExitCode, (Esc ((@($ulines) | Where-Object { $_ -like 'FAIL*' } | Select-Object -First 20) -join "`n"))); $fail = 1 }
        else { Write-Host ("::notice title=UI test::{0}" -f (Esc (($ulines | Select-Object -Last 3) -join "`n"))) }
    }
    $env:CLEANC_QUIET = '1'; $env:CLEANC_REPORT = Join-Path $PWD 'out\selftest.txt'
    $p = Start-Process -FilePath .\out\ClearC.exe -ArgumentList '/selftest' -Wait -PassThru
    $lines = @(); if (Test-Path $env:CLEANC_REPORT) { $lines = @(Get-Content $env:CLEANC_REPORT -Encoding UTF8) }
    $lines | ForEach-Object { Write-Host $_ }
    # 报告分几段写成说明注释（每段不超过 40 行）
    for ($i = 0; $i -lt $lines.Count; $i += 40) {
        $chunk = ($lines[$i..([math]::Min($i + 39, $lines.Count - 1))]) -join "`n"
        Write-Host ("::notice title=self-test {0}::{1}" -f ([int]($i / 40) + 1), (Esc $chunk))
    }
    if (-not $lines) { Write-Host '::error title=self-test::no report was written'; $fail = 1 }
    elseif ($p.ExitCode) { Write-Host ("::error title=self-test::{0} item(s) failed, see the self-test notices" -f $p.ExitCode); $fail = 1 }
}
exit $fail
