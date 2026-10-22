# 更新记录

## 2.7
- **空间地图的项目复选框**：每一行前面有复选框（和资源管理器「查看」里的「项目复选框」一样），点一下就能多选，不用按住 Ctrl；鼠标移到方框上会变成手形、方框变蓝。勾过以后，点行的其他地方是加上这一行，不会把已经勾的清掉；按 Esc 全部取消。左下角「全选」。
- **按住鼠标（左键或右键）上下拖，一次选中连着的几行**，拖到列表上下边会自动滚动；按住 Ctrl 再拖是在原来的基础上加。用右键拖的话，松开后弹出右键菜单：打开文件夹、在资源管理器里显示、复制路径、压缩、删除。
- **设置页**：外观、语言，以及界面上显示什么。用不上的页面、左下角的按钮、页面标题下的说明、空间地图的复选框、占比条、百分比、详细信息和「快速扫描」开关都可以关掉，随时能打开，「恢复默认显示」一下全回来。
- **实际占用和硬链接**：快速扫描时，从文件表里读出每个文件真正分配了多少簇，压缩、稀疏和只在云端（OneDrive 等）的文件按实际占用算；WinSxS 这类文件夹里和 System32 共用的硬链接单独标出，删了不腾空间。删除前写明实际能腾出多少。
- **空间明细**：已用空间分成文件实际占用（每个文件只算一次）、文件表（MFT）和其他几块，并说明为什么和按文件大小相加对不上。
- **省空间**里能看系统还原点（卷影副本）有几个、占了多少、上限多少；要调整打开 Windows 的「系统保护」，本工具不直接删还原点。
- **查重复文件时让着其他程序**（设置里打开）：用 Windows 的后台模式读文件，磁盘和内存都用低优先级，不拖慢正在用的程序，也不把它们缓存的数据挤出内存。
- 「崩溃转储与错误报告」也清 `C:\Windows\LiveKernelReports`（显卡驱动重置等留下的诊断转储）。
- 帮助里新增几条常见问题：扫描合计和已用空间为什么对不上、WinSxS 能不能删、为什么不清 Prefetch 也没有「内存加速」。
- 「使用反馈」只留 GitHub：项目主页和提交问题的按钮，不再显示开发者微信号；诊断信息和检查扫描功能的结果都可以贴到 GitHub 的问题里。
- 修正：点「使用反馈」后再点「帮助」，回不到帮助的开头。
- 测试：自检也核对实际占用和硬链接；新增 `ClearC.exe /uitest`，在真的 Windows 上把界面功能点一遍；NTFS 镜像测试也比实际占用、硬链接和压缩文件夹。
- Item check boxes, left- or right-button drag selection and a right-click menu in the space map; a Settings page that hides pages, buttons, descriptions and columns you don't use; size on disk and hard links from the file table, with a "Space breakdown" of the used space; restore point usage on "Save space"; low-priority duplicate search; LiveKernelReports cleanup; Feedback now points only to GitHub (the WeChat ID was removed); fixed Help not returning to the top after Feedback; `/uitest` for automated UI tests.

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
