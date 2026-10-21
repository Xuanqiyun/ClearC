#!/bin/bash
# 深色模式的静态检查：把界面的 XAML 按浅色、深色各导出一份，算每段文字和底色的对比度。
# 只是近似（不算模板里的状态切换和绑定），真正的效果要在 Windows 上打开看。用法：bash tests/theme/run.sh
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"; OUT="${1:-/tmp/clearc-theme}"
"${PWSH:-pwsh}" -NoProfile -File "$HERE/dump.ps1" "$OUT"
cd "$OUT" && python3 "$HERE/contrast.py" main.dark.xaml sheet.dark.xaml toast.dark.xaml help.dark.xaml
