# 在 Windows 上把源码构建成单个 exe：ClearC.exe
#
# 只用 Windows 自带的 .NET Framework 4.x 编译器 csc.exe，不需要安装 Visual Studio 或任何 SDK。
# 用法（在仓库根目录）：
#   powershell -NoProfile -ExecutionPolicy Bypass -File build\build.ps1
# 生成的 exe 在 out\ 文件夹里。
#
# exe 的结构：一个很小的 C# 启动器（launcher.cs），把 src\CleanC-UI.ps1 作为内嵌资源，
# 启动时放进本进程里的 Windows PowerShell 5.1 引擎运行；脚本里的 C# 类型（$rowCode、$dupCode）
# 提前编译进 exe，启动时不再临时编译。
param([string]$Out)

$ErrorActionPreference = 'Stop'
$here = $PSScriptRoot
$root = Split-Path $here -Parent
if (-not $Out) { $Out = Join-Path $root 'out\ClearC.exe' }
$script = Join-Path $root 'src\CleanC-UI.ps1'
$obj = Join-Path $here 'obj'
New-Item -ItemType Directory -Force -Path $obj, (Split-Path $Out -Parent) | Out-Null

# 1. 从脚本里取出 C# 代码，和启动器一起编译
$src = [IO.File]::ReadAllText($script)
$row = [regex]::Match($src, '(?s)\$rowCode = @"\r?\n(.*?)\r?\n"@').Groups[1].Value
$dup = [regex]::Match($src, "(?s)\`$dupCode = @'\r?\n(.*?)\r?\n'@").Groups[1].Value
if (-not $row -or -not $dup) { throw '没能从 CleanC-UI.ps1 里取出 C# 代码（$rowCode / $dupCode）' }
$utf8 = New-Object Text.UTF8Encoding $false
[IO.File]::WriteAllText((Join-Path $obj 'types_row.cs'), $row, $utf8)
[IO.File]::WriteAllText((Join-Path $obj 'types_dup.cs'), $dup, $utf8)

# 2. 内嵌的脚本：UTF-8、CRLF
[IO.File]::WriteAllText((Join-Path $obj 'cleanc.ps1'), ($src -replace "`r?`n", "`r`n"), $utf8)

# 3. 编译
$csc = Join-Path ([Runtime.InteropServices.RuntimeEnvironment]::GetRuntimeDirectory()) 'csc.exe'
if (-not (Test-Path -LiteralPath $csc)) { $csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe' }
if (-not (Test-Path -LiteralPath $csc)) { throw '找不到 .NET Framework 的 csc.exe' }
& $csc /nologo /target:winexe /platform:anycpu /optimize+ /codepage:65001 /utf8output `
    "/out:$Out" "/win32icon:$here\icon.ico" "/win32manifest:$here\app.manifest" `
    "/resource:$obj\cleanc.ps1,cleanc.ps1" /main:CleanCLauncher `
    "$here\launcher.cs" "$obj\types_row.cs" "$obj\types_dup.cs"
if ($LASTEXITCODE -ne 0) { throw "编译失败（csc 返回 $LASTEXITCODE）" }
"已生成：$Out"
