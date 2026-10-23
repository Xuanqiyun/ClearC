<#
腾挪 ClearC（单文件版，双击「run-from-source.bat」运行）
第一页 清理 C 盘：一键清理；或扫描后每项自选 删除 / 搬到其他盘 / 跳过；分析谁占空间。
第二页 重复文件：按类型、大小区间查找名字和内容都相同的文件，每组只留一份，其余删除。
#>
param()

$ErrorActionPreference = 'SilentlyContinue'
$script:AppVersion = '3.1'
$script:AppBuildStamp = ''   # 构建 exe 时由 build 脚本填上构建时间（UTC）：写进诊断信息和运行记录，反馈问题时好对上是哪一次构建的
$script:startClock = [Diagnostics.Stopwatch]::StartNew()   # 记下启动各阶段用了多久，写进运行记录

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

# 表格行的数据类型（带属性变更通知，下拉框改动能回写）
$rowCode = @"
