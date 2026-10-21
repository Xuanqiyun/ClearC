"@
# exe 版已经把这些类型编译进去了，直接用；单独运行脚本时才现场编译
if (-not ('RowItem' -as [type])) { Add-Type -TypeDefinition $rowCode }

Add-Type -AssemblyName System.Windows.Forms, Microsoft.VisualBasic

# 重复文件查找引擎（C#）：多线程列举，头尾指纹 + 抽样/全文快速哈希分级筛选，按磁盘类型安排并发；删除前逐字节核对
$dupCode = @'
