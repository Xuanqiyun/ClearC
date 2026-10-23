# 在 Windows 上把源码构建成单个 exe：ClearC.exe
#
# 只用 Windows 自带的 .NET Framework 4.x 编译器 csc.exe，不需要安装 Visual Studio 或任何 SDK。
# 用法（在仓库根目录）：
#   powershell -NoProfile -ExecutionPolicy Bypass -File build\build.ps1
# 生成的 exe 在 out\ 文件夹里。设置了签名证书时顺便签名（见第 4 步）。
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

# 0. 源码分成了 src/parts/ 下的多个文件：src/CleanC-UI.ps1 必须和它们一致，不一致就停下（不替你决定以哪边为准）
if (Test-Path -LiteralPath (Join-Path $root 'src\parts\order.txt')) {
    & (Join-Path $here 'merge.ps1') -Check | Out-Host
    if ($LASTEXITCODE) { throw 'src\CleanC-UI.ps1 和 src\parts 不一致：改了 parts 就先运行 build\merge.ps1；直接改了 CleanC-UI.ps1 就先运行 python build\split.py' }
}

# 1. 从脚本里取出 C# 代码，和启动器一起编译
$src = [IO.File]::ReadAllText($script)
$row = [regex]::Match($src, '(?s)\$rowCode = @"\r?\n(.*?)\r?\n"@').Groups[1].Value
$dup = [regex]::Match($src, "(?s)\`$dupCode = @'\r?\n(.*?)\r?\n'@").Groups[1].Value
if (-not $row -or -not $dup) { throw '没能从 CleanC-UI.ps1 里取出 C# 代码（$rowCode / $dupCode）' }
$utf8 = New-Object Text.UTF8Encoding $false
[IO.File]::WriteAllText((Join-Path $obj 'types_row.cs'), $row, $utf8)
[IO.File]::WriteAllText((Join-Path $obj 'types_dup.cs'), $dup, $utf8)

# 2. 内嵌的脚本：UTF-8、CRLF
# 内嵌的脚本里写上构建时间（UTC），写进诊断信息和运行记录
[IO.File]::WriteAllText((Join-Path $obj 'cleanc.ps1'), ($src -replace "`r?`n", "`r`n").Replace("`$script:AppBuildStamp = ''", ("`$script:AppBuildStamp = '{0}'" -f [DateTime]::UtcNow.ToString("yyyy-MM-dd'T'HH':'mm'Z'", [Globalization.CultureInfo]::InvariantCulture))), $utf8)

# 3. 版本号和版权写进 exe 的文件属性：从脚本的 $script:AppVersion 和 LICENSE 取，在 obj 里生成改好的启动器和清单
. (Join-Path $here 'version.ps1')
$vs = New-VersionedSources $root $obj $src
"版本：$($vs.Version)（文件版本 $($vs.Version4)），$($vs.Copyright)"

# 4. 编译
$csc = Join-Path ([Runtime.InteropServices.RuntimeEnvironment]::GetRuntimeDirectory()) 'csc.exe'
if (-not (Test-Path -LiteralPath $csc)) { $csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe' }
if (-not (Test-Path -LiteralPath $csc)) { throw '找不到 .NET Framework 的 csc.exe' }
& $csc /nologo /target:winexe /platform:anycpu /optimize+ /codepage:65001 /utf8output `
    "/out:$Out" "/win32icon:$here\icon.ico" "/win32manifest:$($vs.Manifest)" `
    "/resource:$obj\cleanc.ps1,cleanc.ps1" /main:CleanCLauncher `
    "$($vs.Launcher)" "$obj\types_row.cs" "$obj\types_dup.cs"
if ($LASTEXITCODE -ne 0) { throw "编译失败（csc 返回 $LASTEXITCODE）" }
"已生成：$Out"

# 5. 代码签名（可选）：设置了证书才签，没设置就跳过。证书从哪来见 README 的「代码签名」
#    CLEARC_SIGN_PFX（.pfx 文件路径）+ CLEARC_SIGN_PASSWORD，或者 CLEARC_SIGN_THUMBPRINT（装在「当前用户 → 个人」里的证书）
$pfx = $env:CLEARC_SIGN_PFX; $thumb = $env:CLEARC_SIGN_THUMBPRINT
if ($pfx -or $thumb) {
    $signtool = $null
    $cmd = Get-Command signtool.exe -ErrorAction SilentlyContinue
    if ($cmd) { $signtool = $cmd.Source }
    if (-not $signtool) {
        $pf86 = if (${env:ProgramFiles(x86)}) { ${env:ProgramFiles(x86)} } else { $env:ProgramFiles }
        $kit = Join-Path $pf86 'Windows Kits\10\bin'
        $signtool = Get-ChildItem -Path $kit -Recurse -Filter signtool.exe -ErrorAction SilentlyContinue | Where-Object { $_.FullName -match '\\x64\\' } |
            Sort-Object FullName -Descending | Select-Object -First 1 -ExpandProperty FullName
    }
    if (-not $signtool) { throw '要签名，但找不到 signtool.exe（安装 Windows SDK 时勾选「Windows SDK Signing Tools」）' }
    $ts = if ($env:CLEARC_SIGN_TIMESTAMP) { $env:CLEARC_SIGN_TIMESTAMP } else { 'http://timestamp.digicert.com' }
    $sa = @('sign', '/fd', 'SHA256', '/tr', $ts, '/td', 'SHA256', '/d', 'ClearC', '/du', 'https://github.com/Xuanqiyun/ClearC')
    # 从证书管理器复制的指纹常带看不见的字符和空格，只留十六进制
    if ($pfx) { $sa += @('/f', $pfx); if ($env:CLEARC_SIGN_PASSWORD) { $sa += @('/p', $env:CLEARC_SIGN_PASSWORD) } } else { $sa += @('/sha1', ($thumb -replace '[^0-9A-Fa-f]', '')) }
    & $signtool @sa $Out
    if ($LASTEXITCODE -ne 0) { throw "签名失败（signtool 返回 $LASTEXITCODE）" }
    "已签名：$Out"
}
