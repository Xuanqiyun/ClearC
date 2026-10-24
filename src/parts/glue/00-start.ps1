<#
腾挪 ClearC（单文件版，双击「run-from-source.bat」运行）
第一页 清理 C 盘：一键清理；或扫描后每项自选 删除 / 搬到其他盘 / 跳过；分析谁占空间。
第二页 重复文件：按类型、大小区间查找名字和内容都相同的文件，每组只留一份，其余删除。
#>
param()

$ErrorActionPreference = 'SilentlyContinue'
$script:AppVersion = '3.6'
$script:AppBuildStamp = ''   # 构建 exe 时由 build 脚本填上构建时间（UTC）：写进诊断信息和运行记录，反馈问题时好对上是哪一次构建的
$script:startClock = [Diagnostics.Stopwatch]::StartNew()   # 记下启动各阶段用了多久，写进运行记录
# 构建日期只有一个来源：exe 由构建脚本填上 AppBuildStamp；直接运行脚本时用脚本文件的修改日期
try { $env:CLEANC_BUILT = $(if ($script:AppBuildStamp) { $script:AppBuildStamp.Substring(0, 10) } elseif ($PSCommandPath) { (Get-Item -LiteralPath $PSCommandPath).LastWriteTime.ToString('yyyy-MM-dd') } else { '' }) } catch {}
# 系统文件夹从系统接口取，不信环境变量：环境变量是启动本工具的那个程序给的，普通权限就能改，
# 而本工具以管理员身份运行 cmd、robocopy、icacls 这些系统程序。之后用到的 SystemRoot、SystemDrive 环境变量都是这里的值
function Use-SystemPaths {
    $w = ''; try { $w = [Environment]::GetFolderPath('Windows') } catch {}
    if ($w -and $w.Length -ge 3 -and $w[1] -eq ':') { $env:SystemRoot = $w; $env:windir = $w; $env:SystemDrive = $w.Substring(0, 2) }
}
Use-SystemPaths
# ---------- 运行记录 ----------
# 运行记录（给排查问题用）放在本工具自己的文件夹里：以前放在 TEMP，本工具清理 TEMP 时会把它一起清掉。
# 超过 2 MB 就把它改名留一份（run.1.log、run.2.log），更早的删掉。加载时就要用（编译出错也要记下来），所以写在最前面
$script:logDir = Join-Path $env:LOCALAPPDATA 'CleanC\logs'
$script:logFile = Join-Path $script:logDir 'run.log'
function Rotate-RunLog([long]$max = 2MB) {
    try {
        if (-not (Test-Path -LiteralPath $script:logFile) -or (Get-Item -LiteralPath $script:logFile).Length -lt $max) { return }
        $o2 = Join-Path $script:logDir 'run.2.log'; $o1 = Join-Path $script:logDir 'run.1.log'
        if ([IO.File]::Exists($o2)) { [IO.File]::Delete($o2) }
        if ([IO.File]::Exists($o1)) { [IO.File]::Move($o1, $o2) }
        [IO.File]::Move($script:logFile, $o1)
    } catch {}
}
function Write-LogFile([string]$m) {
    try {
        if (-not [IO.Directory]::Exists($script:logDir)) { [void][IO.Directory]::CreateDirectory($script:logDir) }
        [IO.File]::AppendAllText($script:logFile, ("{0:yyyy-MM-dd HH:mm:ss}  {1}`r`n" -f (Get-Date), $m), [Text.Encoding]::UTF8)
    } catch {}
}
Rotate-RunLog
# ---------- 运行记录结束 ----------
# 公司电脑的应用控制策略（AppLocker、WDAC）把 PowerShell 限制在受限语言模式时，后面编译 C#、调系统接口都会失败：先说清楚（exe 在启动器里已经查过）
if ($ExecutionContext.SessionState.LanguageMode -ne 'FullLanguage') {
    Write-Host ("这台电脑的应用控制策略（AppLocker 或 WDAC）把 PowerShell 限制在「{0}」模式，本工具在这种模式下没法运行。请找管理员把它加进允许运行的列表。" -f $ExecutionContext.SessionState.LanguageMode)
    Write-Host ("This PC's application control policy (AppLocker or WDAC) keeps PowerShell in {0} mode, so ClearC cannot run. Ask your administrator to allow it." -f $ExecutionContext.SessionState.LanguageMode)
    $global:CLEANC_UI_SHOWN = $true
    return
}

# ---------------- 管理员权限 ----------------
$script:selfScript = $PSCommandPath
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin -and $env:CLEANC_ARGS) { $global:CLEANC_UI_SHOWN = $true; return }
if (-not $isAdmin) {
    # exe 版本由清单要求管理员权限，正常不会走到这里；直接运行源码时，在这里弹出 UAC 请求管理员权限后重新打开
    try {
        if ($env:CLEANC_SELF) { Start-Process -FilePath $env:CLEANC_SELF -Verb RunAs -ErrorAction Stop }
        elseif ($PSCommandPath) { Start-Process -FilePath "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -Verb RunAs -ErrorAction Stop -ArgumentList ('-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}"' -f $PSCommandPath) }
    } catch {}
    exit
}

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
# 输完管理员密码到主窗口出来要几秒（编译、读界面）：先显示一个小窗口说「正在打开」，主窗口画出来后关掉。定时任务、自测不显示
$script:splash = $null
function Show-Splash {
    if ($env:CLEANC_ARGS) { return }
    try {
        $zh = [Globalization.CultureInfo]::CurrentUICulture.Name.StartsWith('zh', [StringComparison]::OrdinalIgnoreCase)
        $w = New-Object System.Windows.Window
        $w.WindowStyle = 'None'; $w.ResizeMode = 'NoResize'; $w.SizeToContent = 'WidthAndHeight'; $w.WindowStartupLocation = 'CenterScreen'
        $w.ShowInTaskbar = $true; $w.Title = $(if ($zh) { '腾挪 ClearC' } else { 'ClearC' })   # 不置顶：万一打不开，启动器的错误提示要能盖在它上面
        $w.Background = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromRgb(0xF5, 0xF5, 0xF7))
        $b = New-Object System.Windows.Controls.Border; $b.Padding = New-Object System.Windows.Thickness 28, 20, 28, 20
        $b.BorderBrush = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromRgb(0xD9, 0xD9, 0xDE)); $b.BorderThickness = New-Object System.Windows.Thickness 1
        $t = New-Object System.Windows.Controls.TextBlock; $t.FontSize = 15; $t.FontFamily = New-Object System.Windows.Media.FontFamily 'Segoe UI, Microsoft YaHei UI'
        $t.Text = $(if ($zh) { '腾挪 ClearC 正在打开…' } else { 'Opening ClearC…' })
        $b.Child = $t; $w.Content = $b
        $w.Show()
        [System.Windows.Threading.Dispatcher]::CurrentDispatcher.Invoke([Action]{}, [System.Windows.Threading.DispatcherPriority]::Render)
        $script:splash = $w
    } catch { $script:splash = $null }
}
function Close-Splash { if ($script:splash) { try { $script:splash.Close() } catch {}; $script:splash = $null } }
Show-Splash

# 表格行的数据类型（带属性变更通知，下拉框改动能回写）
$rowCode = @"
