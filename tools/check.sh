#!/bin/bash
# 本地把能在 Linux 上查的都查一遍，只打印每项的结论（看详细输出就单独跑那一项）
#   拆分同步、语法、翻译缺项、界面英文化后剩下的中文、三套测试、C# 5 编译、深色对比度
# 用法：PWSH=/path/to/pwsh bash tools/check.sh
R=$(cd "$(dirname "$0")/.." && pwd); cd "$R" || exit 2
PW=${PWSH:-pwsh}; T=$(mktemp -d); fail=0
say() { printf '%-22s %s\n' "$1" "$2"; }
python3 build/split.py >/dev/null && say split ok || { say split FAIL; fail=1; }
$PW -NoProfile -File tools/i18n-keys.ps1 -Path src/CleanC-UI.ps1 -Out "$T/keys.txt" > "$T/keys.log" 2>&1
say parse "$(grep -m1 'parse errors' "$T/keys.log")"; grep -q 'parse errors: 0' "$T/keys.log" || fail=1
python3 tools/i18n-missing.py "$T/keys.txt" > "$T/miss.log" && say translations ok || { say translations "FAIL: $(sed -n 2,4p "$T/miss.log" | tr '\n' '|')"; fail=1; }
$PW -NoProfile -File tools/i18n-xaml.ps1 -Path src/CleanC-UI.ps1 -Keys "$T/keys.txt" > "$T/xaml.log" 2>&1
n=$(grep -o 'XAML Chinese left after translation: [0-9]*' "$T/xaml.log" | grep -o '[0-9]*$'); say xaml-english "${n:-?} left (1 expected: the 中文 / English tooltip)"; [ "${n:-9}" -le 1 ] || fail=1
for t in Checks Engine.Tests Safety.Tests; do
  $PW -NoProfile -File tests/$t.ps1 > "$T/$t.log" 2>&1; c=$?
  if [ $c -eq 0 ]; then say $t ok; else say $t "FAIL: $(grep -m3 -E 'FAIL|fail' "$T/$t.log" | tr '\n' '|')"; fail=1; fi
done
if [ -d build/refasm/v4.8 ]; then r=$($PW -NoProfile -File tools/cs5-check.ps1 2>&1 | grep -m1 'errors/warnings'); say cs5 "$r"; echo "$r" | grep -q ': 0' || fail=1; else say cs5 'skipped (no build/refasm)'; fi
PWSH=$PW bash tests/theme/run.sh > "$T/theme.log" 2>&1 && say contrast ok || { say contrast "FAIL: $(grep -m2 FAIL "$T/theme.log" | tr '\n' '|')"; fail=1; }
rm -rf "$T"; exit $fail
