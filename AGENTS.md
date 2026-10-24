# 给接手这个仓库的人和 AI 助手

腾挪 ClearC：Windows C 盘清理工具。PowerShell 5.1 + WPF + 内嵌 C#，打包成一个不用安装的 exe。先读这一页，再按需要去读下面指到的文件，不要从头通读 2.3 万行的脚本。

## 代码在哪

- `src/CleanC-UI.ps1`：真正运行的单个脚本，exe 里内嵌的就是它。
- `src/parts/`：同一份内容按模块拆开，方便阅读和评审（`order.txt` 是拼接顺序，`README.md` 说明每个文件管什么）。两边必须一致：改完单文件跑 `python3 build/split.py`；改完 parts 跑 `pwsh build/merge.ps1`。
- 主要模块：`engine/Engine.ps1`（后台：目录库、删除、搬家、扫描、修复）、`ui/*.ps1`（各页的交互）、`ui/main.xaml`（界面和中文帮助）、`cs/*.cs`（C#：读 NTFS 文件表、查重复、目录统计、颜色换算）、`i18n/en.tsv`（英文翻译表）。
- 帮助页的内容和排版由 `tools/help/` 生成，不要手改 XAML 里的帮助：改 `help_zh.py`、`help_en.py` 或 `helpxaml.py`，再跑 `python3 tools/help/regen.py`。
- `docs/SAFETY.md`：安全规则、每条删除和搬家路径的防护、缺陷清单，以及守着它们的测试。改任何删除、搬家、改系统设置的代码前先读它。
- `docs/BACKLOG.md`：待办和已经做完的改进，按优先级排，每条写着状态。

## 常用命令（在仓库根目录）

- 本地检查：`bash tools/check.sh`。它会做这几件事，每项只打印一行结论：
  - 拆分同步
  - 语法检查
  - 查漏翻的文字
  - 查界面换成英文后还剩的中文
  - 跑 `tests/` 里的三套测试
  - 用 C# 5 编一遍
  - 检查深色模式的对比度
  `PWSH` 指向 pwsh；C# 5 编译要先准备 `build/refasm`，见 `build/build-roslyn.ps1` 开头。
- 打 exe：`pwsh build/build-roslyn.ps1 -Out out/ClearC-vX.exe`，在 Linux 上也能打。
- 等 CI：`bash tools/ci-wait.sh <sha>`。GitHub Actions 会在 Linux 和真 Windows 上各跑一遍；Windows 上还要跑三遍界面自测（`src/parts/ui/95-ui-test.ps1`）和真盘自检。

## 改代码的约定

- 改单文件用 `tools/ed.py`，按原文精确替换，匹配次数不对就停下。文件是 CRLF，带 BOM。
- 界面文字用中文写在 `T '…'` 里，英文加进翻译表：`python3 tools/i18n_add.py '中文' 'English'`。中文原文就是翻译键，改了中文措辞，英文那条也要跟着改。
- C# 只用 C# 5 的语法，因为 Windows 自带的 csc 只支持到 5。`$rowCode`、`$dupCode` 两段编进 exe；`$script:photoCode` 要引用 WPF，是运行时现场编译的。
- 主窗口 XAML 在 `[xml]$xaml = @"…"@` 里，是可以展开变量的字符串：XAML 里不要写 `$`。
- 运行时才会被调用的函数可以写在调用处的后面；加载时就要执行的代码，只能用已经定义好的函数。比如 `Write-LogFile` 在 `ui/10-window.ps1` 才定义。
- PowerShell 的坑：
  - `$x = if (…) { $list }` 会把列表摊开，要直接赋值；
  - `@(f)`：f 返回的是 `,$list` 时，结果会被包成只有一个元素；
  - 开关参数不要叫 `-Quiet`，安全测试会数它出现了几次。

## 不能破的规则（详见 docs/SAFETY.md，测试守着）

- C 盘个人文件夹里的东西不删；聊天记录只能搬不能删；删除从不跟进链接；系统位置、软件安装文件夹、回收站和还原点不能删。
- 删除前必须让用户确认。删用户的文件只能调用 `Invoke-SafeRemove`：它做所有检查（个人文件夹、系统位置、链接、回收站放不放得下），删完核对、写操作日志。别处新写的删除调用会让安全测试失败（第 14 节用语法树数着）。
- 不结束进程，只有搬家时确认框里列出的那些例外。不清注册表，不删还原点。
- 计划任务默认关，只用当前用户身份，从不以 SYSTEM 身份、也不在开机时运行。
- 为了提速而改的代码只能读和统计，不能改变删什么。
- 源码锁：所有删除调用的位置和数量（`tests/DeleteSites.ps1` 找）、`rd /s` 的个数、修复里能不确认就运行的步骤，都由测试数着。要改这些数字，先在 SAFETY.md 里写明为什么安全。

## 发布

版本号改两处：`$script:AppVersion` 和 `$script:AppBuilt`。在 `CHANGELOG.md` 写中英文说明，在功能分支上提交。CI 通过后，`git checkout main && git merge --ff-only <分支> && git push origin main`，再打 exe，写 `out/ClearC-vX-release-notes.md`，附上 exe 的 SHA256。
CI 的产物和日志下载不了，只能看注释，每一步最多 10 条。推 tag 会被拒绝，Release 由维护者手动发。
