# 源码的各个部分

`src/CleanC-UI.ps1` 是由这里的文件**按 `order.txt` 的顺序原样拼起来**的，拼出来和原来的单文件逐字节相同。

改代码时改这里的文件，然后运行：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File build\merge.ps1
```

`build\build.ps1` 构建 exe 前会检查两边是否一致，不一致就停下；`tests\Checks.ps1` 会检查 `src\CleanC-UI.ps1` 是不是最新的。

| 文件夹 | 内容 |
|---|---|
| `glue/` | 把各部分接起来的 PowerShell：管理员权限、加载 C# 类型、定时任务的后台模式（`/check`、`/autoclean`、`/selftest`）等 |
| `cs/` | C# 部分。`RowTypes.cs` 是 `$rowCode`；其余几个按顺序拼成 `$dupCode`，一起编译：重复文件查找、批量读目录和多线程统计（`DirReader.cs`）、直接读 NTFS 文件表和变更日志（`Mft.cs`）、空间地图的文件夹树（`DiskMap.cs`）、深色模式配色（`Theme.cs`）、文件系统小工具、各页面列表的行 |
| `engine/` | `$engine`：清理、搬家、删除保护、日志、自检等核心逻辑，界面线程和每个后台任务共用 |
| `i18n/en.tsv` | 英文界面的翻译表：每行「中文原文<Tab>英文」，`\n` 表示换行 |
| `ui/` | `main.xaml` 是主窗口，`help-en.xaml` 是英文帮助页；`10-…` 到 `99-…` 是各页面的界面逻辑，按页面分开 |

注意：

- 这些文件是**片段**，不能单独运行或编译，拼起来才是完整的程序。
- `cs/RowTypes.cs` 和 `ui/main.xaml` 在双引号的 here-string 里，不要在里面写 `$` 和反引号。
- 文件用 UTF-8、CRLF 换行；`glue/00-start.ps1` 开头带 BOM（Windows PowerShell 5.1 要靠它认出中文）。
