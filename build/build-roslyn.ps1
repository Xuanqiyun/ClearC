# 不在 Windows 上也能构建 exe（例如 Linux / macOS 上的 PowerShell 7），用 PowerShell 7 自带的 Roslyn 编译器。
# Windows 用户请直接用 build.ps1，更简单。
#
# 准备：
#   1. 安装 PowerShell 7（pwsh），它自带 Microsoft.CodeAnalysis*.dll
#   2. 下载 .NET Framework 4.8 的引用程序集（mono/reference-assemblies，MIT 许可）：
#        git clone --depth 1 --filter=blob:none --sparse https://github.com/mono/reference-assemblies build/refasm
#        git -C build/refasm sparse-checkout set v4.8
# 用法（在仓库根目录）：
#   pwsh -NoProfile -File build/build-roslyn.ps1
param([string]$Out)

$ErrorActionPreference = 'Stop'
$B = $PSScriptRoot
$root = Split-Path $B -Parent
if (-not $Out) { $Out = Join-Path $root 'out/ClearC.exe' }
$Script = Join-Path $root 'src/CleanC-UI.ps1'
$obj = Join-Path $B 'obj'
New-Item -ItemType Directory -Force -Path $obj, (Split-Path $Out -Parent) | Out-Null
$pw = Split-Path ([System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName)

# 源码分成了 src/parts/ 下的多个文件：先拼成 src/CleanC-UI.ps1
if (Test-Path -LiteralPath (Join-Path $root 'src/parts/order.txt')) { & (Join-Path $B 'merge.ps1') }
$src = Get-Content $Script -Raw
$row = [regex]::Match($src, '(?s)\$rowCode = @"\r?\n(.*?)\r?\n"@').Groups[1].Value
$dup = [regex]::Match($src, "(?s)\`$dupCode = @'\r?\n(.*?)\r?\n'@").Groups[1].Value
if (-not $row -or -not $dup) { throw 'could not extract C# from script' }
Set-Content -Path "$obj/types_row.cs" -Value $row -Encoding utf8
Set-Content -Path "$obj/types_dup.cs" -Value $dup -Encoding utf8
[IO.File]::WriteAllText("$obj/cleanc.ps1", ($src -replace "`r?`n", "`r`n"), (New-Object Text.UTF8Encoding $false))

$roslyn = @("$pw/Microsoft.CodeAnalysis.dll", "$pw/Microsoft.CodeAnalysis.CSharp.dll")
Add-Type -IgnoreWarnings -Path "$B/ExeBuilder.cs" -ReferencedAssemblies ($roslyn + @('System.Collections.Immutable', 'System.Linq', 'System.Collections', 'System.Runtime', 'System.IO', 'netstandard')) 3>$null
$net48 = @("$B/refasm/v4.8/mscorlib.dll", "$B/refasm/v4.8/System.dll", "$B/refasm/v4.8/System.Core.dll")
foreach ($r in $net48) { if (-not (Test-Path $r)) { throw "缺少 $r，请先按文件开头的说明下载引用程序集" } }
"exe build : " + [ExeBuilder]::Build('exe', [string[]]@("$B/launcher.cs", "$obj/types_row.cs", "$obj/types_dup.cs"), [string[]]$net48, "$obj/cleanc.ps1", "$B/app.manifest", "$B/icon.ico", $Out)
