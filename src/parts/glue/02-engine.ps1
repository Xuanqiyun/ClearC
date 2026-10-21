'@
if (-not ('DupFinder' -as [type])) { Add-Type -TypeDefinition $dupCode }
$script:tPrep = $script:startClock.Elapsed.TotalSeconds

# ============================================================
# 引擎：清理项目录、测量、删除、搬家。主线程和后台线程都会加载这一段。
# ============================================================
$engine = @'
