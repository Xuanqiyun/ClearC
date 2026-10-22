
<p align="center"><img src="docs/icon.png" width="96" alt="腾挪 ClearC"></p>

<h1 align="center">腾挪 ClearC</h1>

<p align="center">Windows 10 / 11 上给 C 盘腾空间的小工具（原名「C盘清理工具」）：清缓存、把聊天记录和软件搬到其他盘、找出大文件和重复文件。<br>单个 exe，双击就能用，不用安装。</p>

<p align="center">中文 · <a href="#english">English</a></p>

---

## 能做什么

| 页面 | 做什么 |
|---|---|
| **清理 C 盘** | 扫描后分组列出可以处理的项目，每一项都可以选「删除」「搬到其他盘」或「跳过」。缓存、临时文件、日志这类删了会自动重建的，默认选中；Windows.old、回收站这类有代价的，默认跳过。也可以「一键清理」。 |
| **聊天记录搬家** | 微信（新版和旧版）、QQ、企业微信、腾讯会议、飞书、钉钉，以及 Telegram、Discord、Slack、Signal、LINE、Viber、KakaoTalk、Zoom 的聊天记录和数据，整个搬到其他硬盘，C 盘原位置留一个链接，软件照常使用。软件开着时会先问你要不要替你关掉。 |
| **重复文件** | 找出内容完全相同的文件。可以删掉多余的，也可以「合并为一份」（硬链接，每个位置的文件都还在，只占一份空间）。 |
| **省空间** | 不删文件也能省：系统压缩（CompactOS）、NTFS 压缩文件夹、页面文件改到其他盘、休眠文件精简、压缩 WSL / Docker 的虚拟磁盘、把模拟器和虚拟机整个搬走。还能看系统还原点占了多少（只看不删，要调整打开 Windows 的「系统保护」）。 |
| **空间地图** | 扫描整块盘，一层层点进去看是哪些文件夹占了空间，也可以看成「方块图」。NTFS 格式的盘直接读盘上的文件表（MFT），几十万个文件一般几秒到十几秒就扫完；读不了时自动改回逐个文件夹扫描（也可以关掉「快速扫描」）。「找文件」按大小、多久没改过、类型、名称筛选大文件，可以多选一起删，也可以只看聊天记录里的大文件（只看不删）；「和上次比」看哪些文件夹在变大。每一行前面有复选框（像资源管理器的「项目复选框」），也可以按住鼠标左键或右键上下拖一次选中连着的几行，右键菜单里能打开、复制路径、压缩、删除。快速扫描时会注明实际占用（压缩、稀疏、只在云端的文件比文件大小占得少）和硬链接（WinSxS 里很多文件和 System32 是同一份），「空间明细」说清已用空间分成哪几块、为什么和按文件大小相加对不上。列表可以导出成 CSV，整块盘的情况可以导出成网页报告（在浏览器里能存成 PDF）。 |
| **软件管理** | 已装软件按占用大小排列。可以卸载，卸载后检查残留文件夹；装在 C 盘的还可以整个搬到其他盘，不用重装。 |
| **搬家管理** | 「可以搬的」自动列出 C 盘上还能搬走的聊天记录、软件和其他大文件夹，勾选后一次搬好几项；不适合搬的软件单独列出并写明原因。「已经搬走的」显示每个搬走的文件夹现在的状态，可以搬回 C 盘、修复断掉的链接、删掉没搬完留下的多余副本。 |
| **自动提醒** | C 盘剩余空间低于设定值时在右下角提醒（每次登录电脑后和每天中午各检查一次）；每周自动清一次缓存。两项默认关闭，由 Windows 任务计划运行，不用一直开着本工具。 |
| **操作日志** | 每一次删除、搬运、合并、压缩、卸载和系统设置改动都记成 txt，可以按类别和时间查看。默认保存半年，可以改。 |
| **设置** | 外观、语言，以及界面上显示什么：用不上的页面、左下角的按钮、页面说明、空间地图的复选框和各列都可以关掉；快速扫描的开关；查重复文件时让着其他程序（Windows 的后台模式，磁盘和内存都用低优先级）。 |

界面支持**中文和英文**、**浅色和深色**，在「设置」里或左侧栏底部的「English / 中文」「外观」切换。「帮助」页里可以**检查新版本**（只在点的时候联网），以及**检查扫描功能**：在你的电脑上核对快速扫描是否准确，结果可以发给开发者。

## 安全原则

- **个人文件夹里的东西一律不删**：桌面、文档、下载、图片、视频、音乐、收藏夹、OneDrive，包括这台电脑上其他账户的个人文件夹和「公用」文件夹。即使误选也会自动跳过。
- **删除前必须确认**：每次删除都要先勾选「我已确认这些资料不再需要」才能点删除。
- **系统位置不让删**：Windows 文件夹、软件的安装文件夹（请到「软件管理」卸载）、保存密码和证书的位置、软件安装包缓存、搬家后的数据，都会被挡住并说明原因。
- **搬家先核对再删**：复制到目标盘后，两边的文件个数和大小核对一致，才把原位置换成链接、删除 C 盘上的那份。核对不过、文件被占用，原文件夹都原样不动。
- **可以中途取消**：耗时的操作随时能点「取消」，停在安全的地方。搬家时还在复制就取消，C 盘上的原文件夹不动；正在换成链接这类不能停在一半的步骤，会做完这一步再停。
- **有记录可查**：所有改动都写进操作日志。

## 搬家是怎么工作的

软件去哪里读写数据，是软件自己决定的，大多数没法改（比如 `AppData\Roaming\Tencent`）。所以搬家时，工具把整个文件夹复制到其他盘（默认放在空闲最多那块盘的 `CDriveMoved` 文件夹里），核对一致后，在 C 盘原位置放一个 **目录链接（junction）**，再删掉 C 盘上的原文件夹。

链接几乎不占空间。软件打开原来的路径时，Windows 自动转到目标盘上读写，软件察觉不到任何变化，不用改设置，也不用重装。

需要注意：目标盘要一直接着；请不要删除、改名或移动 `CDriveMoved` 文件夹。在「搬家管理」里随时可以把它们搬回 C 盘。

## 下载和使用

1. 到 [Releases](../../releases) 下载最新的 `ClearC-vX.X.exe`（就是腾挪 ClearC，用英文文件名是因为 GitHub 不支持中文的下载文件名）。
2. 放到一个固定的位置（比如 `D:\工具\`），双击运行。需要管理员权限，会弹出 UAC 确认。
3. 第一次打开会显示安全风险提示，同意后才能使用。左侧「帮助」里有完整的使用说明。

系统要求：Windows 10 或 11。用的是系统自带的 Windows PowerShell 5.1 和 .NET Framework 4.8，不需要另装任何东西。

exe 暂时没有代码签名，Windows SmartScreen 可能提示「Windows 已保护你的电脑」，点「更多信息」→「仍要运行」即可。不放心的话可以按下面的方法自己从源码构建。

## 从源码运行或构建

整个程序就是一个 PowerShell 脚本 `src/CleanC-UI.ps1`，exe 只是把它包起来。这个脚本由 `src/parts/` 下按功能分开的文件拼成（见 [src/parts/README.md](src/parts/README.md)）：改代码时改 `src/parts/` 里的文件，再运行 `build\merge.ps1`。

**直接运行源码**：双击 `src/run-from-source.bat`（会请求管理员权限）。功能和 exe 一样，只是自动提醒、每周清理这类定时任务只有 exe 版本支持。

**在 Windows 上构建 exe**（只用系统自带的 C# 编译器，不需要 Visual Studio）：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File build\build.ps1
```

生成的 exe 在 `out\` 里。在 Linux / macOS 上可以用 PowerShell 7 运行 `build/build-roslyn.ps1`，准备步骤写在文件开头。

### 代码结构

```
src/parts/               源码，按功能分开（拼起来就是 src/CleanC-UI.ps1）
  ├─ cs/                   C# 部分：重复文件查找、批量读目录和多线程统计、读取 NTFS 文件表（MFT）和变更日志、空间地图、深色配色、列表的行
  ├─ engine/Engine.ps1     清理、搬家、删除保护、日志、自检等核心逻辑；界面线程和每个后台任务共用
  ├─ i18n/en.tsv           英文界面的翻译表
  ├─ ui/                   WPF 界面（main.xaml、英文帮助页）和各页面的界面逻辑
  └─ glue/                 把各部分接起来：管理员权限、加载 C# 类型、定时任务模式（/check、/autoclean、/selftest）
src/CleanC-UI.ps1        拼好的整个程序（直接运行源码、构建 exe 都用它）
src/run-from-source.bat  不构建、直接运行源码
build/merge.ps1          把 src/parts/ 拼成 src/CleanC-UI.ps1（-Check 只检查是不是最新的）
build/launcher.cs        exe 启动器：把脚本作为内嵌资源，放进本进程里的 PowerShell 5.1 运行
build/app.manifest       要求管理员权限、长路径支持
build/build.ps1          Windows 上构建 exe（先自动拼一次；设置了证书就顺便签名）
build/build-roslyn.ps1   其他系统上构建 exe
tests/                   测试，见下面
```

### 测试

| 测试 | 在哪跑 | 怎么跑 |
|---|---|---|
| 语法、C# 编译、XAML、控件名、翻译 | 任何装了 PowerShell 的系统 | `pwsh tests/Checks.ps1` |
| 核心逻辑（统计大小、查找、树上查大小、深色配色等） | Windows PowerShell 5.1 或 PowerShell 7 | `pwsh tests/Engine.Tests.ps1` |
| 直接读文件表、按改动增量更新 | Linux，root，装 ntfs-3g 和 PowerShell 7 | `sudo bash tests/ntfs/run.sh`：用 mkntfs 和 ntfs-3g 做出真的 NTFS 镜像（硬链接、稀疏文件、碎片、备用数据流、很深的路径、各种簇大小），和挂载后逐个文件夹数出来的结果对比。ntfs-3g 建的符号链接是普通文件，和 Windows 不同，所以允许差几处 |
| 深色模式的对比度 | 任何装了 PowerShell 和 Python 的系统 | `bash tests/theme/run.sh`：算每段文字和底色的对比度（近似） |
| 在真的 Windows 上核对快速扫描 | Windows | 程序里「帮助」→「检查扫描功能」；或者 `ClearC.exe /selftest`，结果在 `%LOCALAPPDATA%\CleanC\selftest.txt`（设置环境变量 `CLEANC_REPORT` 可以改位置，`CLEANC_QUIET=1` 不弹提示），退出码是不通过的项数。也核对实际占用（稀疏、NTFS 压缩、系统压缩、硬链接）和 Windows 自己报的是否一致 |
| 界面功能 | Windows | `ClearC.exe /uitest`：打开窗口（放在屏幕外），把各页、设置开关、项目复选框、右键拖选、右键菜单、空间明细点一遍，对话框都当作点了取消，做完自己关掉；结果在 `%LOCALAPPDATA%\CleanC\uitest.txt`（`CLEANC_REPORT` 可以改），退出码是不通过的项数。测完设置原样放回 |

### 代码签名

exe 签了名，SmartScreen 的提示会少很多（签名的发布者信誉要随着下载量慢慢积累，刚签的版本一开始可能还会提示）。`build\build.ps1` 已经支持签名：设置环境变量 `CLEARC_SIGN_PFX`（.pfx 证书）和 `CLEARC_SIGN_PASSWORD`，或者 `CLEARC_SIGN_THUMBPRINT`（装在「当前用户 → 个人」里的证书），构建完会用 Windows SDK 的 signtool 签名并加时间戳。证书可以这样拿：

- **SignPath Foundation**（免费，给开源项目）：在 [signpath.org](https://signpath.org/) 申请。要求包括 OSI 认可的开源许可证（本项目是 MIT）、exe 由公开的自动构建（比如 GitHub Actions）从源码生成、每次签名都由维护者手动批准、项目主页写明代码签名政策。
- **Azure Artifact Signing**（原 Trusted Signing，每月约 10 美元）：目前个人开发者只限美国和加拿大，机构限美国、加拿大、欧盟和英国。
- 也可以向证书机构买 OV 代码签名证书。

### 国内下载镜像

GitHub 在国内下载慢的话，可以在 [Gitee](https://gitee.com/) 建一个同名仓库做镜像：Gitee 的「从 GitHub 导入仓库」可以定时同步代码；发版时把 exe 也上传到 Gitee 仓库的「发行版」里，再把下载地址补到这里。

### 程序在电脑上留下的东西

- `%LOCALAPPDATA%\CleanC\`：设置（settings.txt）、C 盘空间记录（history.txt）、操作日志、空间地图快照。
- 各盘的 `CDriveMoved\`：搬到其他盘的数据。
- 任务计划程序里的 `CleanC` 文件夹：只在打开自动提醒或每周清理时才会创建，关掉开关就删除。
- <img width="1509" height="970" alt="image" src="https://github.com/user-attachments/assets/39907aed-ba40-4885-bc80-381db17b7348" />
<img width="1525" height="976" alt="image" src="https://github.com/user-attachments/assets/25cf0dfc-011b-4311-91b6-cb299468f394" />
<img width="1516" height="960" alt="image" src="https://github.com/user-attachments/assets/64d37cf8-ae32-4be6-ac40-bcc38cde5d77" />
<img width="1529" height="981" alt="image" src="https://github.com/user-attachments/assets/c317aaa8-6581-43bf-a4c3-697f699398ac" />
<img width="1526" height="986" alt="image" src="https://github.com/user-attachments/assets/7ca6d454-f5ff-4fdc-846e-a8df708666c5" />








## 安全风险提示

本工具会按你的选择删除或搬移电脑上的文件。删除的文件可能无法恢复，存在资料丢失的风险。每次删除前，请确认这些资料确实不再需要、删除不会给你带来损失；重要资料请先备份。

**因使用本工具造成的资料丢失或其他损失，责任由使用者自行承担，开发者不承担责任。**

## 反馈

- 在本仓库提 [Issue](https://github.com/Xuanqiyun/ClearC/issues)，最好附上截图，以及程序里「帮助」→「复制诊断信息」的内容；扫描结果不对的话，附上「检查扫描功能」的结果。程序里「帮助」→「使用反馈」也有打开项目主页和提交问题的按钮。

## 许可证

[MIT](LICENSE)

---

<a id="english"></a>

## English

ClearC (Chinese name 腾挪, "make room") frees up space on drive C: on Windows 10 / 11. It is a single exe that needs no installation and runs on the PowerShell 5.1 and .NET Framework 4.8 that ship with Windows.

- **Clean up C:** lists what can be removed (caches, temp files, update leftovers) and what has a cost (Windows.old, Recycle Bin), each with Delete / Move / Skip.
- **Move chat history and apps to another drive.** WeChat, QQ, WeCom, Tencent Meeting, Feishu, DingTalk, Telegram, Discord, Slack, Signal, LINE, Viber, KakaoTalk and Zoom data, as well as installed apps, are copied to another drive, verified, and replaced by a directory link, so the software keeps working unchanged.
- **Duplicates, Save space, Space map, Apps, Moved folders, Reminders, Activity log, Settings.** Find duplicate files or merge them into hard links. Use CompactOS, NTFS folder compression, page-file and hibernation settings, and WSL / Docker disk compaction. The "Moved folders" page lists everything on C: that can still be moved and moves several items at once. Browse folder sizes as a list or treemap (NTFS drives are read straight from the file table, the MFT, so even large drives take seconds; "Fast scan" can be turned off), look at the large files inside chat data (view only), find large files by size, age, type and name and delete several at once (item check boxes like File Explorer's, left- or right-button drag to select a run of rows, and a right-click menu), see size on disk and hard links with the fast scan plus a "Space breakdown" of the used space, check how much restore points take, export an HTML report, see which folders grew since the last scan, export lists to CSV, uninstall apps and clean leftovers, move folders back, and get low-space reminders. Every change is logged.
- **Safety rules.** Personal folders (Desktop, Documents, Downloads…) are never deleted, every deletion needs an explicit confirmation, and system locations are blocked. Long operations can be cancelled at any time and stop at a safe point.

The interface is available in English and Chinese, light and dark. Switch on the "Settings" page or with "English / 中文" and "Appearance" at the bottom of the sidebar; "Settings" also hides pages, buttons, descriptions and space-map columns you don't use; the first launch follows the Windows display language. The Help page can check for updates (only when you click it) and run "Check scanning", which verifies the fast scan on your PC and produces a report you can send to the developer (also `ClearC.exe /selftest`; `ClearC.exe /uitest` clicks through the interface for automated testing).

Developers: the source is split by function under `src/parts/` and merged into `src/CleanC-UI.ps1` by `build/merge.ps1`; tests are in `tests/` (checks, engine tests, real NTFS image tests on Linux, dark-mode contrast). `build/build.ps1` signs the exe when a certificate is configured.

Download the latest `ClearC-vX.X.exe` from [Releases](../../releases). The exe is not code-signed, so SmartScreen may warn; choose "More info → Run anyway", or build it yourself with `build\build.ps1`.

**Disclaimer:** deleting files can lose data. Back up anything important. You use ClearC at your own risk, and the developer accepts no liability for any loss.

