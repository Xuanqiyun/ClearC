# 更新记录

## 3.5.1
- **帮助的文字重写**：每一节开头一句话说清做什么，每一条一两句；去掉描述界面本身的话（「点哪一项右边只显示那一项」这类）和内部细节，安全提示保留。常见问题也一样精简。
- **帮助的排版**：标题、小标题、正文分得更清楚：节标题 20、条目标题 15、正文 14，行高 24，条目之间空 26，小标题改成灰色、上面多留空；卡片四周留白更大；圆点、提示框、标签、方块的间距一起调。
- **各页标题下的说明改成一句话**；设置里每一项的说明也精简了。
- Help text rewritten to be short and plain, with more generous typography (20/15/14 pt, 24 pt line height, more space between items); page subtitles and setting descriptions trimmed to one sentence.

## 3.5
- **帮助页改成左边目录**：和设置页一样，左边按「开始」「清理」「分析」「管理」「其他」分组列出每一项（快速上手、各功能、常见问题、反馈和新版本），点哪一项右边只显示那一项，下面有「上一项」「下一项」，记住上次看的那一项；左下角「使用反馈」直接打开「反馈和新版本」，再点「帮助」回到原来在看的那一项。
- **扫描提速**（GitHub 的 Windows 测试机上实测，同一台机器前后对比）：
  - 清理 C 盘：只统计这个模式下会列出的项目；要等系统回答的几项（Windows Installer 孤儿安装包、驱动存储里的旧版驱动包、传递优化缓存、失效的快捷方式）另外开后台同时问，这边接着读文件表、统计别的；安装包的登记一次问完（和原来一条一条问的位置、调用一样，测试核对两边结果完全相同）；回收站大小直接问系统；%TEMP% 这类短文件名路径先换成长路径再查文件表；同一个上级文件夹是不是链接只查一次（删除时照旧每次现查）。开发者和 IT 模式从 14.7 秒到 3 秒左右（文件表已经在内存里、驱动包问过一次以后），普通用户模式 第一次扫描从 18 秒左右到 9 秒左右（这台测试机冷启动，读文件表占了大头；平时打开几秒后文件表已经在后台读好）。
  - 打开本工具几秒后、空闲时在后台先把 C 盘的文件表读进内存（只读），之后清理扫描、软件管理、搬家、空间地图只按变更日志补读改过的部分。
  - 右键菜单扩展：直接读注册表，从 6.0 秒到 0.4 秒。
  - 系统健康：硬件、开机、蓝屏、事件、时钟各部分同时读，从 9.8 秒到 4.0 秒。
  - 搬家「可以搬的」：已装软件、应用商店聊天软件同时读；判断软件带没带系统服务和驱动时，直接读注册表里登记的程序路径，不再等 WMI（测试机上 WMI 有时要等将近 10 秒），从 4.6 秒到 1.8 秒。
  - 残留文件夹：最近改动和大小直接从 C 盘文件表查，不再逐个文件夹统计；装在别的盘上的软件、已经搬走的文件夹读那块盘的文件表一次；应用商店软件的名字直接读安装文件夹里的清单。
  - 重复文件：NTFS 盘上找 1 MB 以上的文件时，直接从文件表列出文件（规则和一个个文件夹去看一样：同样跳过系统、软件、开发环境的文件夹，链接、云端文件夹不进，系统、脱机、云端占位文件不比），不用再一个个文件夹去看：测试机上整个 Program Files 逐个文件夹列举要 2 到 6 分钟，文件表在内存里时不到 1 秒；文件表里多记了每个文件的属性。算指纹前核对文件大小和列出来时一样。
  - 驱动存储里的旧版驱动包：同一次打开程序里驱动包没变就不再问 DISM；开发者和 IT 模式空闲时顺便先问好。
  - 扫描时记下每一项用了多久，写进日志，以后哪里慢一看就知道。
- 测试：界面自测核对读注册表得到的服务、驱动不比 WMI 少；测速时同样的重复文件查找从文件表列一次，结果必须和逐个文件夹列举的完全一样（测试机上逐个列举 7 分钟，从文件表不到 1 秒）；界面自测覆盖帮助页目录（只显示选中的一项、上一项下一项、使用反馈和回到原来那一项、每一项都有内容）；Windows 测试第一遍量一下各种扫描的用时（报告里 timing 开头的几行）；核对安装包登记一次问完和一条一条问的结果相同；安全规则测试更新（接口读不了就不判断孤儿安装包）。
- The help page has a contents list on the left like Settings and shows one item at a time. Scans are faster: the cleanup scan only measures what the current mode lists and asks Windows for the slow items (installer packages, driver packages, Delivery Optimization, broken shortcuts) in parallel; the C: file table is read in the background while idle; system health, move candidates and context-menu extensions read their parts in parallel or straight from the registry; leftovers and apps on other drives use the file table.

## 3.4
- **一次处理几个**：软件、开机启动、计划任务、右键菜单、残留文件夹的每一行前面有复选框，也可以按住鼠标左键在行上拖，拖过的都勾上（Shift 点方框勾一段，表头的方框全选）。软件「卸载选中的」依次打开每个软件自己的卸载程序：一个走完、窗口关掉后再开下一个，可以随时停下或跳到下一个，不加静默参数；应用商店的直接卸载。开机启动、计划任务、右键菜单「禁用选中的」「启用选中的」；残留文件夹「移到回收站」。都先列出来确认一次。
- **系统健康不用等**：打开本工具几秒后、没有别的操作在做时，就在后台把硬件信息读好，点「系统健康」直接看；读过十分钟再打开在后台刷新一遍。中途插上或拔掉移动硬盘、U 盘，硬件卡片、空间地图的盘和搬家目标盘会自动跟着变。
- **空间地图**（参考了 disktree 的几个做法）：后退、前进（鼠标侧键、Alt+← / Alt+→，Backspace 回上一级），路径上每一层都能点；**待删清单**：在不同文件夹里挑要删的先放进清单，下面一直写着清单多大、这块盘现在空闲多少、删完大约剩多少，看过再一起删（和平时删除一样先确认、能选回收站），删完写明这块盘实际多出了多少，要删的是 git 仓库时提醒没提交的改动会丢；**值得一看**：扫完整块盘后列出名字一看就是缓存、依赖包、构建产物、虚拟环境、临时文件的大文件夹，点一下跳过去；**方块图按类上色**：系统、软件数据、文档、照片视频音乐、代码、同步盘、游戏各一种颜色，缓存和临时文件带斜线，下面有图例。
- **左边目录**：搬家管理左边是「可以搬的」（点它看全部，下面分聊天记录、装在 C 盘的软件、其他可搬的文件夹、不适合搬的软件）和「已经搬走的」，一次只看一组，每项写着几个；设置左边分「常用」「界面」「清理和扫描」，点哪一项右边只显示那一项。省空间、搬家、设置等所有两级目录里，第二级往里缩进、前面一条竖线，选中的那一项蓝底。
- **看得更清楚**：选项卡之间加了分隔线，选项卡上的数字放进小圆角标签；左侧栏的分组下面缩进；常见问题修复左边的问题列表加粗，右边的修法正常字重；Windows 事件、相关事件的行距加大：来源一行、事件内容另起一行（太长的截短），次数和时间放在右边，每条之间有分隔线；硬件卡片按窗口宽度自动排几列，最大化时不再只占左边一半；操作提示几秒后自动收起。
- 测试：界面自测覆盖勾几个软件依次卸载（不真的打开卸载程序）、一次禁用几个、残留一起移到回收站、设置和搬家的目录、二级目录缩进、空间地图后退前进、点路径、待删清单、值得一看、方块图按类上色；安全规则测试新增「批量卸载先确认、一个一个来、不加静默参数、自测不启动」「批量移走残留和单个走同一段后台代码」「批量禁用不碰本工具自己的项」「待删清单走 Start-MapDelete」。
- Tick several apps, startup items, tasks, menu entries or leftovers (check boxes or left-button drag) and act on them together: uninstall one after another with each app's own uninstaller, disable or enable, or move leftovers to the Recycle Bin, all after one confirmation. System health is read in the background shortly after start and drive hot-plug is picked up. The space map gains back / forward and a clickable path, a delete list with projected free space, "Worth a look" for caches and build output, and treemap colours by kind (ideas from disktree). Moves and Settings get a contents list on the left; second-level items are indented everywhere; tabs are separated, event lists are easier to read and hardware cards reflow when maximized.

## 3.3
- **所有列表都能点表头排序**：点列名按这一列排，再点一下反过来，箭头写在列名旁边；每个列表记住上次怎么排的，刷新、换文件夹、换筛选以后还按原来的排。活动监控可以按 CPU、内存、写入速度、本次监控写入、启动以来写入排（只列前 25 个，换了排序就按这一列重新取前 25 个）；操作日志按时间、类别、操作、对象、详情；空间地图的列表按名称、修改时间、大小，「和上次比」按文件夹、上次、这次、变化；重复文件在每一组里按位置、修改时间排；软件按名称、发行商、安装日期、大小；开机启动、计划任务、右键菜单按名称、状态；搬家管理的「可以搬的」在每一组里按名称、大小排，「已经搬走的」按名称、状态、大小。本来的顺序有意义的列表（清理页、空间地图、搬家）点第三下回到本来的顺序。
- **清理 C 盘按类分选项卡**：扫描后一排选项卡（安全清理、谨慎清理、需确认、其他可搬的文件夹……）一次只显示一类，选项卡上写着几项；往下滚到选项卡碰到顶边就停在那里，下面的列表照常滚，换一类时列表从头显示，不用来回滚。表头点「名称」「大小」排序；右边的下拉框可以只看某一种操作（只看删除的、只看跳过的……），排过的顺序不变。「执行所选操作」照旧处理所有类别。
- **重复文件的查找条件改成选项卡**：查找位置、文件类型、文件大小、怎样算重复各一个，选项卡上写着现在选的是什么；点「开始查找」后自动收起，只留这一排，结果占满下面。
- **省空间改成左边目录**：系统文件、还原点和临时文件、文件和文件夹、虚拟磁盘四组，点哪一项右边只显示那一项；记住上次看的那一项。
- **系统健康少滚动**：「蓝屏和崩溃」再分诊断结论、每次蓝屏、相关事件和驱动三个小选项卡（写着各有几条）；「常见问题修复」左边选问题，右边只显示它的修法；活动监控的表格占满这一页，自己滚动。
- **自动提醒改成选项卡**：空间提醒、定期自动清理、空间变化，选项卡上写着开着还是关着；空间变化的柱状图更高。
- 测试：界面自测覆盖点表头排序和反向（活动监控、操作日志用真的表头点）、清理页的选项卡只显示一类、按操作筛选后排序不变、点第三下回到原来的顺序、选项卡往下滚以后停在顶上（报告里写明位置）、停在顶上时换类列表从头显示、重复文件条件收起和展开、省空间目录、蓝屏小选项卡、自动提醒选项卡。
- Every list sorts by clicking a column name (again to reverse; a third click restores the natural order where it matters), and remembers its order. Cleanup is split into group tabs that stick to the top while you scroll, with name / size sorting and an action filter that keeps the order. Duplicate-search options are tabs that fold away when the search starts; Save space has a list on the left; System health has sub-tabs for crashes, a master-detail layout for common fixes and a full-height activity monitor; Reminders are tabs.

## 3.2
- **诊断结论带上处理办法**：每条结论下面分两块。「按建议处理」把本工具能直接做的几步一次做完：先列出要做什么、确认一次，都能撤销（硬盘掉线：关闭硬盘和 PCIe 省电、关闭快速启动；时间不准：打开日期和时间；系统文件：修复系统文件；内存：内存诊断），做完告诉你做好了什么、还剩什么。「需要你自己做的」按顺序列出本工具做不了的：备份、更新 BIOS / 存储驱动 / 固态硬盘固件（写明这台电脑现在的版本和日期有多旧）、厂商硬件检测（Dell 按 F12 进 ePSA）、重新插硬盘、最后才是换盘。报告和诊断包里的 summary.txt 也写上「本工具能直接做」和「需要你自己做」。
- **厂商驱动下载页**：按厂商和型号打开 BIOS、驱动和固件的下载页，Dell 按服务编号直达；链接同时复制，上不了外网的电脑可以拿到别的电脑上下载。
- **改用 Windows 自带的硬盘驱动**（硬盘接在 Intel RST / RAID On 上又老掉线时）：先替你查是不是单块盘、有没有组 RAID、BitLocker 开没开，再列出进 BIOS 改成 AHCI 的步骤和改回去的办法；要进 BIOS，本工具不替你改。
- **诊断更准**：蓝屏次数按系统的蓝屏记录（WER 1001）算，小转储只留最近几个也不漏；读出这台电脑的厂商、型号、BIOS 版本和日期、服务编号、存储控制器驱动的版本和日期、系统盘的型号和固件、BitLocker；磁盘读写错误按盘号归到具体哪块盘，U 盘、移动硬盘的错误不再算到系统盘头上；蓝屏时连转储都没写出来的次数单独算；系统时间比本工具的发布日期还早（电脑从装系统起时间就不对时，文件时间也跟着错，原来查不出来）、时间服务一直同步不了（域名解析不了 = 上不了外网）都会报出来。
- 修复系统文件：上不了外网时 DISM 会报错，窗口里写明不要紧，接着运行的 sfc 照样有效。「日期和时间」改成打开控制面板的日期和时间，上不了网的电脑也能手动改。
- 诊断包里 systeminfo、driverquery 的输出按系统区域的代码页读，中文系统上不再是乱码；硬盘温度报 0、1 °C 的（RST 之类的控制器乱报）当成读不到；最近装的驱动里空白的一行不再显示。
- 测试：WER 记录解析、U 盘错误不算系统盘、时钟比发布日期早、Dell 下载页、报告里有处理办法；安全规则测试新增「按建议处理只用能撤销、不删东西的几步，先确认一次」「硬盘驱动指南不替你运行 bcdedit」；检查里加发布日期一年没改就报；界面自测覆盖按建议处理要先确认、厂商下载页、硬盘驱动指南。
- Each diagnosis now has "Fix as suggested" (does the reversible steps ClearC can take in one go, after one confirmation) and "Things to do yourself" (backup, BIOS / driver / firmware updates with this PC's current versions, the maker's hardware test, reseating, replacing); a maker's driver page by service tag; a guided switch from Intel RST to Windows' own disk driver; crashes counted from Windows' crash records; USB disk errors no longer blamed on the system disk; clock checks against the release date and failed time syncs; readable systeminfo on Chinese Windows.

## 3.1
- **蓝屏诊断修好并讲人话**：转储解析之前读错了驱动表（每项 0x90 字节，名字是完整路径），真机转储里「可能的驱动」和「栈上的驱动」都不对，现在按真机的 Win10 1903 转储核对过。新读出读盘失败的状态码（0x7A 的 0xC000000E 就是硬盘掉线）、出事时的进程（0xEF 时就是退出的那个关键进程）、栈上驱动是谁做的；0x50 改看参数 3，0x116 看参数 2；栈上只有 Windows 自带驱动的不再冤枉某个驱动；0x7A 读不回来的那一页属于哪个驱动只说明它倒霉，不点名。每次蓝屏下面一句话说明是什么错、常见原因。
- **诊断结论**：把几次蓝屏、事件日志、硬盘健康、系统时钟和 Windows 版本放在一起看，给出几条结论和对应的修复按钮：硬盘或硬盘连接不稳定（读盘失败 + 系统进程反复退出 + 磁盘错误，顺带认出 Intel RST 存储驱动）、同一个第三方驱动反复被点名（按显卡、网卡、安全软件、反作弊、存储给不同的建议）、显卡、内存、硬件错误、睡眠唤醒、多次没有正常关机、系统时间不准（系统自己写的文件比「现在」还晚）、Windows 版本太旧。「复制报告」复制成文字；「导出诊断包」把转储、最近 30 天的系统和应用日志、systeminfo、驱动列表、硬盘信息和报告打成 zip，不覆盖已有文件。
- **常见问题修复**：按问题列出论坛里最常用、确实有效的修法（蓝屏死机、硬盘掉线卡顿、系统文件损坏、Windows 更新失败、上不了网、时间不准、关机变重启和唤醒失败、没有声音、图标和应用商店、开机慢、把信息发给别人），每一步标明只看 / 会改动 / 要重启。都是 Windows 自带的命令，在看得见的终端里跑，记进操作日志；会改动的先说明再确认；Windows 更新组件改名留底不删；「关闭硬盘省电」（PCIe 链路、AHCI 链路、关闭硬盘）先存原值，「恢复硬盘省电」原样改回；快速启动随时能改回。修复系统文件改成先 DISM /RestoreHealth 再 sfc /scannow，普通用户模式也能用。
- **系统健康改成选项卡**：标题旁一排选项卡（硬件、开机用时、蓝屏和崩溃、常见问题修复、活动监控、Windows 事件），点哪一项只显示哪一项，各自滚动；记住上次看的那一项。普通用户模式能看到蓝屏和崩溃、常见问题修复。
- **清理 C 盘**：扫描后双击一行打开它所在的文件夹，右键「打开全部位置」「复制路径」，方便把日志、转储拷出来分析；回收站、传递优化缓存、搜索索引、Installer、驱动存储、事件日志、WinSxS 这些由系统命令处理的项目，打开的是 Windows 存放它们的地方。
- **空间地图**：点上方的盘卡片就选中这块盘并扫描，下面换成它的详细情况，选中的卡片有蓝色描边。
- 点左下角的模式标签，到设置里时「使用模式」那张卡片会亮一下，告诉你在哪儿换。
- 测试：用拼出来的转储测 0x90 驱动表、完整路径、0x7A 状态码、0xEF 进程、0x50 只有微软驱动时不点名；诊断结论的几种组合；安全规则测试新增 §7f（修复命令不删文件、不结束进程、不建计划任务，会改动的都有确认，更新组件只改名并重启它停的服务，硬盘省电先留底，诊断包不覆盖文件）；界面自测覆盖选项卡、修复步骤要确认、清理页打开文件夹、盘卡片扫描、模式卡片高亮。
- Crash dump parsing fixed against real dumps (0x90 driver entries, full paths), with status codes, the process involved and plain-language explanations; a combined diagnosis with fix buttons and a diagnostics-package export; a "Common fixes" tab with forum-standard repairs that ask first and can be undone; System health split into tabs; double-click or right-click a cleanup row to open its folder; click a drive card in the space map to scan it; the mode card lights up when you click the mode tag.

## 3.0
- **数据安全审计**：逐个检查清理、搬家、重复文件、空间地图、软件管理、省空间的每条执行路径，修掉 29 条可能丢数据的问题（另有 9 条条件少见的也一起修了），其中最要紧的：删 Windows.old 时会顺着里面的链接删到现在系统的 AppData；同一个文件的两条路径被当成重复文件，删掉的是唯一一份；「放进回收站」在回收站放不下、被关掉或在网络位置时会变成永久删除；扫描后改了清理列表，执行的不是确认的那一项；一键清理会勾上「需确认」的项；OneDrive 同步文件夹里的聊天记录搬家后会被 OneDrive 当成删除；搬回 C 盘时会删掉用户自己建的链接指向的文件夹；软件搬到 D 盘后，清理会顺着链接删 D 盘上的缓存；重复文件能删掉搬到 D 盘的微信记录；把临时文件夹改到 D 盘时会接管用户自己的 D:\Temp 并在之后清空它。完整清单、可推迟的问题和理由见 docs/SAFETY.md。
- **安全规则测试**（tests/Safety.Tests.ps1）：每次推送在 Linux 和 Windows（PowerShell 5.1）上跑。一部分在临时文件夹里搭假的个人文件夹、链接、硬链接真的试删，一部分数源码里危险调用的个数（`rd /s`、回收站调用、`pnputil`、计划任务身份），改坏了就报错。
- **三种使用模式**：普通用户、工程师、开发者和 IT。双击打开默认是普通用户模式，不弹窗；在「设置」最上面随时换，左下角版本号下面写着当前模式。换模式只改显示，不丢设置和记录。
- **系统健康**页（只看不改）：硬件卡片（CPU 负载 / 频率 / 性能计数器判断降频 / ACPI 温度，内存已用 / 提交 / 硬错误 / WHEA 内存错误，每块盘 SMART 健康 / 温度 / 磨损 / 读错误 / 通电时间，电池设计容量 / 满充容量 / 循环次数，显卡占用 / 显存 / 驱动，Windows 开机时长 / 等待重启 / 最近更新 / 有问题的设备），读不到的明说读不到，不用估算冒充；开机用时和拖慢开机的程序（诊断-性能日志 100 / 101）；蓝屏和崩溃：自己解析 Minidump（DUMP_HEADER64 + TRIAGE_DUMP64：错误码、参数、驱动表、异常地址落在哪个驱动、栈上出现的驱动），最近 30 天的意外关机 / 蓝屏记录 / WHEA / 磁盘 / NTFS 事件和最近装的驱动，sfc / DISM 分成「检查（只看）」和「修复（会改，先确认）」；活动监控：开着时每 3 秒采样，按程序合并看 CPU、内存、写入速度、本次监控写入、启动以来写入，不装服务；Windows 事件：最近 7 天严重和错误事件按来源归并。
- **空间地图**：顶部概览（已用 / 总量、百分比，系统与软件、个人文件、可清理的缓存、其他、剩余的分段条）；方块图和列表一起显示并联动（点方块选中行、Ctrl 多选，选中的行在方块图上描边，双击进入）；「按类型」把全盘文件按扩展名分成十类（文件表里也数，不只 1 MB 以上的），双击一类到「找文件」；「找文件」最多 1000 个，按大小或修改时间排序，按所有者筛选，NTFS 压缩过的写明压缩后大小；「最近改动」读变更日志（USN）列出最近 1 / 3 / 7 / 30 天新建、改写的文件最集中的文件夹；「和上次比」的快照带日期保留（每盘最多 40 份），可以选和 1 / 3 / 7 / 30 天前或最早的比，并用一句话说清已用空间多了多少、主要在哪（Docker 数据、WSL 发行版、浏览器缓存、Windows 更新、某个文件夹……）。
- **分级清理**：安全清理、谨慎清理（浏览器缓存、缩略图、着色器、下载缓存：默认也清，单独成组，执行前单独列出）、需确认（默认跳过）、受保护（一律不碰）；确认对话框里「看文件清单」列出最大的 60 项、完整清单存成文本；设置里「删除时先放进回收站」（成批放，太大的由系统问；自动清理不受影响）；操作日志记每一项删前删后的剩余空间；需确认新增「驱动存储里的旧版驱动包」（Get-WindowsDriver 找同一驱动有更新版本的旧包，pnputil 删，不加 /force，启动必需的不碰；开发者和 IT）。
- **重复文件**：「相似照片」（9×8 灰度 dHash，几乎一样 4 位 / 相似 8 位 / 大致相似 12 位，按分辨率排序、写明尺寸和相差位数，不自动勾选，只能进回收站或归档，不能永久删除、不能合并）；留法新增「留某个文件夹里的」「留路径最短的」；「归档勾选的」不删，搬到选定文件夹下按盘符和原路径放。
- **安全规则测试** `tests/Safety.Tests.ps1`（Linux 和 Windows 的 CI 都跑）：个人文件夹不删、链接不跟进、系统目录拦截、目录库路径合规、自动清理只碰安全项、逐字节比对、pnputil 不加 /force，以及源码锁（回收站标志、不删还原点、不清注册表、计划任务不用 SYSTEM、Stop-Process 只在关聊天软件处、rd /s 调用点数过等）。
- 开发者：`Start-BgEngine` 在后台线程跑引擎代码并回调；`FileCats`（扩展名分类）、`DiskMap.RecentDirs`（变更日志汇总）、`DumpInfo`（转储解析）、`PhotoHash`（相似照片）、`FsTools.Owner / IsCompressed / RecycleMany`；目录库选项 `careful`。
- 2.8 的改动（未单独发布）并入本版：
  - **缓存目录库**：清理项改成一张表（`$script:cacheLib`，一行一条：名称、路径、说明、选项），加条目不用改代码。新增几十条：Firefox、Brave、Vivaldi、Opera、Chrome 测试版、360、QQ 浏览器的网页缓存（Chromium 系统一按 `@chromium:` 展开）；DirectX、AMD 显卡着色器缓存；Windows 更新日志、磁盘检查残留、应用商店软件的临时文件、系统网页缓存、远程桌面位图缓存；Steam 着色器与网页缓存（安装目录从注册表查）、Epic 启动器缓存、Unity 缓存；Adobe 媒体缓存、旧版 Teams、Discord、Slack、VS Code、Cursor、Spotify、网易云音乐的缓存；uv、Yarn、NuGet、Go、Rust 的下载缓存。删了要重新下载或重新生成、比较慢的（NuGet 全局包、Gradle、Maven、JetBrains 索引、虚幻引擎缓存）放进「需确认」，默认跳过。只删缓存，不碰 Cookie、历史记录、密码和保存的数据。
  - **Windows Installer 孤儿安装包**（需确认，默认跳过）：`C:\Windows\Installer` 里没有任何已装软件和补丁再引用的 .msi / .msp，判断方法和 PatchCleaner 一样（注册表登记的 LocalPackage 加 Windows Installer 接口）；一个引用都没读到就不判断，一天内改过的文件不算。
  - **自己加文件夹、排除文件夹**：设置里的「清理列表」。加的文件夹在清理页单独成组，删里面的东西、文件夹本身保留；排除的文件夹清理时一律不碰，估算时也不算。清理页右上角「自定义清理项」直达。
  - **垃圾攒多了也提醒**：自动提醒里可以设一个界限，定时检查时顺便统计「安全清理」里的缓存，超过就提醒（每天最多一次，只统计不删）。
  - **自动清理的时间可选**：每周某一天或每天，中午 12:30。
  - **软件管理**新增三个视图：**开机启动**（注册表 Run 项和「启动」文件夹，开关写在 StartupApproved 里，和任务管理器一样）、**计划任务**（只列第三方的）、**右键菜单**（只列第三方的 shellex 扩展，禁用写进 Shell Extensions\Blocked）。都只是禁用，不删任何东西，随时能恢复。
  - **检查新版本（winget）**：用 Windows 自带的 winget 查装过的软件有没有新版本，只在点的时候联网；列表里标出「可升级到」并给「升级」按钮，在终端窗口里升级，过程和提示都看得见。
  - **省空间**新增：OneDrive 同步文件改成「仅在线」（文件留在云端，什么都不删，「始终保留在此设备」的不动）；关掉 / 重新开启 Windows 保留的存储；组件存储（WinSxS）分析，DISM 算出实际大小、可回收多少、建不建议清理；蓝屏只存小转储；当前用户的临时文件夹改到其他盘；WSL 发行版搬到其他盘（`wsl --manage --move`，需要 WSL 2.5 以后）。
  - **清理 C 盘**再加三条需确认项：驱动安装包解压残留（C:\NVIDIA、C:\AMD、C:\Intel、C:\SWSetup、C:\Drivers、C:\Dell\Drivers）、开始菜单里失效的快捷方式（不碰桌面）、Windows 事件日志。
  - **软件管理**加「残留文件夹」视图：找已卸载软件可能留下的文件夹（名字对不上任何已装软件、没有程序在用、一个月没动过、至少 1 MB），只是猜测，看过再移到回收站。
  - **空间地图**上方每块盘一张健康卡片：用量条、健康状态，固态硬盘的温度、磨损、通电时间，按档位标色（绿、橙、红），点卡片选盘；只读，设置里可以关掉。
  - **自动提醒**页写明 Windows 自带的「存储感知」开没开。
  - 帮助里加了「为什么没有注册表清理」。
  - 测试：核心逻辑测试覆盖目录库解析、排除、自定义文件夹、winget 表格解析；界面自测覆盖清理列表、提醒设置、三个新视图和孤儿安装包判断；检查里核对目录库每一条都有英文。
  - Cache library as a data table with dozens of new entries (more browsers, shader caches, game launchers, Adobe, Teams, Discord, Slack, VS Code, Spotify, developer tools); orphaned Windows Installer packages, unpacked driver installers, broken Start menu shortcuts and event logs (all need confirmation); custom folders and exclusions; a junk-size reminder; a selectable cleanup day; startup items, third-party scheduled tasks, context menu extensions and leftover folders under Apps; "Check for updates" with winget; OneDrive online-only, reserved storage, component store analysis, small crash dumps, temp folder location and WSL moves under Save space; disk health in the space map; Storage Sense status under Reminders; FAQ on why there is no registry cleaner.

## 2.7
- **空间地图的项目复选框**：每一行前面有复选框（和资源管理器「查看」里的「项目复选框」一样），只有点方框才选中或取消（鼠标移到方框上会变成手形、方框变蓝），单击行的其他地方不会选中，双击文件夹照常往里点；Shift 点是从上次勾的那一行勾到这里，Esc 全部取消，左下角「全选」。右键点一行，菜单只对这一行起作用。在设置里关掉复选框，就照 Windows 列表原来的做法。
- **按住鼠标（左键或右键）上下拖，一次选中连着的几行**，拖到列表上下边会自动滚动；按住 Ctrl 再拖是在原来的基础上加。用右键拖的话，松开后弹出右键菜单：打开文件夹、在资源管理器里显示、复制路径、压缩、删除。
- **设置页**：外观、语言，以及界面上显示什么。用不上的页面、左下角的按钮、页面标题下的说明、空间地图的复选框、占比条、百分比、详细信息和「快速扫描」开关都可以关掉，随时能打开，「恢复默认显示」一下全回来。
- **实际占用和硬链接**：快速扫描时，从文件表里读出每个文件真正分配了多少簇，压缩、稀疏和只在云端（OneDrive 等）的文件按实际占用算；WinSxS 这类文件夹里和 System32 共用的硬链接单独标出，删了不腾空间。删除前写明实际能腾出多少。
- **空间明细**：已用空间分成文件实际占用（每个文件只算一次）、文件表（MFT）和其他几块，并说明为什么和按文件大小相加对不上。
- **省空间**里能看系统还原点（卷影副本）有几个、占了多少、上限多少；要调整打开 Windows 的「系统保护」，本工具不直接删还原点。
- **查重复文件时让着其他程序**（设置里打开）：用 Windows 的后台模式读文件，磁盘和内存都用低优先级，不拖慢正在用的程序，也不把它们缓存的数据挤出内存。
- 「崩溃转储与错误报告」也清 `C:\Windows\LiveKernelReports`（显卡驱动重置等留下的诊断转储）。
- 帮助里新增几条常见问题：扫描合计和已用空间为什么对不上、WinSxS 能不能删、为什么不清 Prefetch 也没有「内存加速」。
- 「使用反馈」只留 GitHub：项目主页和提交问题的按钮，不再显示开发者微信号；诊断信息和检查扫描功能的结果都可以贴到 GitHub 的问题里。
- **帮助页重新排版**：每个功能一张卡片，默认收起，标题下一行写着这一节讲什么，点开再看；右上角「全部展开」。条目改成粗体小标题加一两行说明，长段落拆成小点；操作方式、搬家状态做成对照表，搬家过程画成步骤条，要特别留意的（不删个人文件夹、别动 CDriveMoved）单独框出来。常见问题一行一个，点开看答案。新增「设置」一节。
- 修正：点「使用反馈」后再点「帮助」，回不到帮助的开头。
- 修正：英文界面里，清理列表的分组标题显示成了中文。自动清理的说明里组名写成了「可以放心删」，改成和列表一致的「安全清理」。
- 修正：窗口矮的时候（比如笔记本 150% 缩放），左侧栏最下面的「设置」被挤掉看不到，现在这一栏可以上下滚动；空间地图里的「空间明细」不再被「导出报告」按钮挡住。
- 测试：自检也核对实际占用和硬链接；新增 `ClearC.exe /uitest`，在真的 Windows 上把界面功能点一遍（英文浅色、中文深色各跑一遍，帮助页存一张截图）；NTFS 镜像测试也比实际占用、硬链接和压缩文件夹。
- Item check boxes, left- or right-button drag selection and a right-click menu in the space map; a Settings page that hides pages, buttons, descriptions and columns you don't use; size on disk and hard links from the file table, with a "Space breakdown" of the used space; restore point usage on "Save space"; low-priority duplicate search; LiveKernelReports cleanup; Feedback now points only to GitHub (the WeChat ID was removed); fixed Help not returning to the top after Feedback; a redesigned Help page with collapsible sections, short headed items, tables and callouts; clean-up group titles now translated in English; `/uitest` for automated UI tests (English light and Chinese dark).

## 2.6
- **深色模式**：左下角「外观」可以选浅色、深色或跟随系统（照 Windows 的「选择应用模式」）。
- **检查扫描功能**：「帮助」页里的新按钮，在你的电脑上核对快速扫描：比较直接读文件表和逐个文件夹扫描的结果，再在本工具自己的文件夹里建几个文件、改一改、删掉，看按变更日志更新对不对。只读 C 盘，结果自动复制，可以直接发给开发者。也可以用 `ClearC.exe /selftest` 运行。
- **检查新版本**：「帮助」页里点一下，查 GitHub 上有没有新版本；本工具平时不联网，只在点的时候连一次。
- **可以关掉快速扫描**：空间地图右上角的「快速扫描」，关掉后不再直接读盘，改为逐个文件夹扫描（少数安全软件对直接读盘会提示）。清理、搬家、软件管理统计大小时也按这个设置。
- **只看聊天记录里的大文件**：空间地图「找文件」里勾选「只找聊天软件里的」，看清微信、QQ 等是哪些视频和文件占了地方。这些文件只能查看、打开位置，要腾地方请整体搬家。
- **打开大文件夹更快**：一层里有上万项时（比如 WinSxS），只列最大的 500 项，其余合成一行。
- 启动时把各阶段用时记进运行记录，方便找出慢在哪。
- 开发：源码按功能分成 `src/parts/` 下的多个文件，由 `build/merge.ps1` 拼成原来的单文件；加了 `tests/`（语法和翻译检查、核心逻辑测试、Linux 上用真的 NTFS 镜像测试读文件表、深色模式对比度）；`build/build.ps1` 配置了证书时自动签名。
- Dark mode (Light / Dark / Follow Windows); "Check scanning" self-test on your PC (`ClearC.exe /selftest`); "Check for updates" (only when clicked); a switch to turn off the fast scan; view large files inside chat data; huge folders open faster. Source split by function under `src/parts/`, tests under `tests/`, optional code signing in `build/build.ps1`.

## 2.5
- 改名为「**腾挪 ClearC**」（原名「C盘清理工具」）：把占地方的东西清掉、挪走，给 C 盘腾出空间。设置、操作日志和自动提醒都照旧，不用重新设置。
- **扫描快得多**：NTFS 格式的盘（C 盘基本都是）直接读取盘上的文件表（MFT），不用一个个文件夹去看，几十万到上百万个文件一般几秒到十几秒就读完。读完会和直接列目录的结果核对；对不上或读不了（不是 NTFS、权限不够等）自动改回逐个文件夹扫描。
- **同一次打开里再扫描只看改动**：按 Windows 的变更日志（USN），只重新读改过的那部分。关掉工具后不在 C 盘留任何缓存。
- **一次读取，各页共用**：「清理 C 盘」「搬家管理」「软件管理」统计大小时也先读一次 C 盘的文件表，直接查出每个文件夹多大。这些数字只用于显示和估算；真正删除、搬家时，每一项都会重新统计、重新检查。
- **逐个文件夹扫描也更快**：一次读一大批目录记录，多个线程一起数（固态硬盘线程多一些，机械硬盘少一些）。查找重复文件列举文件时也用这种方式。
- 读文件表能看到逐个扫描进不去的文件夹（比如 System Volume Information），所以「和上次比」遇到两次扫描方式不同时会提示，免得把这部分误当成变大。
- Renamed to 腾挪 ClearC (formerly C盘清理工具); settings, logs and reminders carry over. Much faster scans: NTFS drives are read straight from the file table (MFT) and checked against a direct listing, with an automatic fallback to the folder-by-folder scan; later scans in the same session only re-read what changed (USN journal). Clean up, Moved folders and Apps reuse the same table for size estimates; deleting and moving still measure and check every item again. The folder-by-folder scan reads directory entries in batches on several threads.

## 2.4
- 「搬家管理」分成两页：**可以搬的**会自动列出 C 盘上还能搬走的东西，分聊天记录、装在 C 盘的软件、其他文件夹三组，标出大小；勾选后选好目标盘，一次搬好几项，搬之前列出全部项目和要先关掉的软件，中途可以取消。不适合搬的软件（带服务或驱动、给资源管理器装了右键菜单、微软的软件等）单独列出并写明原因。**已经搬走的**就是原来的列表；没搬完的项目在「可以搬的」里再搬一次，只补差异。
- 支持更多国外常用的聊天软件搬家：Discord、Slack、Signal、LINE、Viber、KakaoTalk、Zoom（Telegram 原来就支持）。从应用商店装的 WhatsApp、Microsoft Teams、Messenger 等由 Windows 管理，页面上会提示在 Windows 设置里用「移动」换盘。
- 空间地图新增「**方块图**」：这一层的文件夹和文件画成方块，方块越大占的空间越多；单击选中，双击往里点。
- 空间地图的列表可以**按住 Ctrl 或 Shift 多选，一起删除**（带小锁的照样跳过，删之前再核对一次）。
- 搬家时**只关掉确认框里列出的程序**：除了聊天软件，搬家还要关掉的后台程序、从要搬的文件夹里运行的程序，都先列出来问你；可以选「不关」，那几项会停在最后一步，下次再搬很快。确认之后才打开的程序一律不碰。
- 空间地图可以**导出报告**：一个网页，包含方块图、最大的文件夹和文件、各类文件占多少、和上次比的变化；在浏览器里按 Ctrl+P 可以存成 PDF。
- Moved folders: a new "Can be moved" tab lists everything on C: that can still be moved (chat data, apps installed on C:, other folders) and moves several items at once. Added Discord, Slack, Signal, LINE, Viber, KakaoTalk and Zoom. Space map: treemap view, multi-select delete and an HTML report.

## 2.3
- 耗时的操作都能**中途取消**：进度卡片和窗口底部多了「取消」按钮。会停在安全的地方，已经做完的不会撤销：清理会停下；搬家如果还在复制，C 盘上的原文件夹不动，已复制的部分留在目标盘，下次再搬接着复制；搬回 C 盘时复制回来的那一半会删掉。正在换成链接、删除备份或运行系统命令时按钮变灰，做完这一步就能取消。扫描、查找重复文件、空间地图、统计软件大小也能停。
- 有操作在进行时关窗口，改成「停下并关闭」：先停在安全的地方，再自动关闭，不会停在换链接的半路上。
- 空间地图的「最大的文件」改成「**找文件**」：在扫描时记下的 1 MB 以上的文件里，按大小、多久没改过、类型（视频、压缩包和安装包、光盘映像和虚拟磁盘等）和名称（可以用 * 和 ?）筛选，也可以只找当前文件夹里的。显示一共找到多少个、多大。
- 空间地图的列表可以**导出 CSV**，用 Excel 打开。
- 「和上次比」里双击一行，直接跳到那个文件夹；文件夹列表里也标出「比上次 +2.1 GB」这样的变化。
- Cancel long operations partway (stops at a safe point; nothing already done is undone). Space map: "Find files" with size, age, type and name filters, CSV export, and growth since the last scan shown in the folder list.

## 2.2
- 界面支持中文和英文。左下角点「English / 中文」切换，切换后本工具会自动重新打开；第一次打开时跟随系统显示语言。
- English UI: click "English / 中文" at the bottom left of the sidebar to switch; ClearC reopens in the chosen language. The first launch follows the Windows display language.

## 2.1
- 「清理 C 盘」的列表改成和上面的卡片一起整页滚动，不再挤在底部一小块里。列表上方写明一共扫到几项、分几类，每组标题旁标出这一组的项目数；下面还有内容时，底部提示「下面还有几项」。
- 自动提醒：除了每天中午，每次登录电脑 2 分钟后也检查一次。第一次清理完会问一次要不要开启提醒。本工具换了位置后打开一次，定时任务会自动改用新位置；从压缩包里直接打开（在临时文件夹里）时不让开启。
- 软件管理：装在 C 盘的软件可以「搬到其他盘」，整个安装文件夹搬走、原位置留链接，快捷方式、卸载、更新照常可用。带系统服务或驱动的、给资源管理器装了右键菜单的、输入法、微软的软件、Windows 组件等不适合搬的，会直接说明原因、不搬。
- 文件夹里有链接或用 Windows 压缩功能压过的文件时不搬，免得复制时漏掉。
- 「搬家管理」里的状态说明改得更直白。

## 2.0
- 新增「空间地图」：扫描整块盘，逐层查看哪里占空间，并和上次扫描比较。
- 新增「省空间」：系统压缩、NTFS 压缩文件夹、页面文件改盘、休眠文件精简、虚拟磁盘压缩、重复文件合并为硬链接。
- 新增「软件管理」：按大小列出已装软件，卸载并检查残留。
- 新增「搬家管理」：查看所有搬走的文件夹，搬回 C 盘、修复链接、删除多余副本。
- 新增「自动提醒」：空间不足提醒、每周自动清理（默认关闭）、C 盘空间变化记录。
- 新增「操作日志」：所有删除和搬运都记成 txt，可分类查看，默认保存半年。
- 删除保护加强：其他账户的个人文件夹、系统保存密码和证书的位置、安装包缓存等都不让删。

## 1.7
- 支持飞书、钉钉等更多聊天软件的聊天记录搬家。
- C 盘个人文件夹（桌面、文档、下载等）里的东西一律不删。

## 1.6
- 新增「帮助」页：详细使用说明、安全风险提示、使用反馈。
- 删除前必须勾选确认。

## 1.5
- 界面重新设计。
- 搬家时如果微信、企业微信还开着，先弹窗询问是否替你关掉。

## 1.4
- 原文件夹被占用、改名失败时，不再整个放弃搬家：数据先复制过去，再搬时只补差异。
