#!/bin/bash
# GitHub 上 Linux 测试机跑的测试。每一步失败时，把最后几十行输出写成一条错误注释（在提交的检查结果里能直接看到原因）。
# 用法：bash tests/ci.sh        需要 pwsh；NTFS 镜像测试还要 sudo 和 ntfs-3g
cd "$(dirname "$0")/.."
esc() { sed -e 's/%/%25/g' -e 's/\r/%0D/g' | sed ':a;N;$!ba;s/\n/%0A/g'; }
fail=0
step() {
  local name="$1"; shift
  echo "::group::$name"
  local log; log=$(mktemp)
  "$@" 2>&1 | tee "$log"; local code=${PIPESTATUS[0]}
  echo "::endgroup::"
  if [ "$code" -ne 0 ]; then
    echo "::error title=$name (exit $code)::$(grep -E '^FAIL' "$log" | head -20 | esc)%0A----%0A$(tail -40 "$log" | esc)"
    fail=1
  else
    echo "::notice title=$name::$(tail -3 "$log" | esc)"
  fi
  rm -f "$log"
}
PW="$(command -v pwsh)"
if [ -z "$PW" ]; then echo "::error title=pwsh missing::PowerShell 7 is not installed on this runner"; exit 1; fi
step "checks" "$PW" -NoProfile -File tests/Checks.ps1
step "engine tests" "$PW" -NoProfile -File tests/Engine.Tests.ps1
step "safety tests" "$PW" -NoProfile -File tests/Safety.Tests.ps1
step "dark-mode contrast" env PWSH="$PW" bash tests/theme/run.sh
step "NTFS image tests" sudo env PWSH="$PW" bash tests/ntfs/run.sh
exit $fail
