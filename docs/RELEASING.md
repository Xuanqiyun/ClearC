# 发版流程

给维护者看的：从改版本号到 GitHub Release 上能下载，每一步做什么。代码怎么改、测试怎么跑见 [AGENTS.md](../AGENTS.md)。

## 1. 打包

1. 只改一处版本号：`src/CleanC-UI.ps1` 里的 `$script:AppVersion`。
2. 在 `CHANGELOG.md` 最上面加这一版的中英文说明（检查会核对有没有这一节）。
3. 在功能分支上提交、推送，等 CI 在 Linux 和 Windows 上都通过：`bash tools/ci-wait.sh <sha>`。
4. 合并到 main：`git checkout main && git merge --ff-only <分支> && git push origin main`。
5. 打 exe：`pwsh build/build-roslyn.ps1 -Out out/ClearC-vX.exe`，算 SHA256：`sha256sum out/ClearC-vX.exe`。
6. 写发布说明，放在 `docs/releases/vX.md`：开头写下载和核对 SHA256 的方法，接着是这一版和之前几版的更新内容，最后是安全风险提示，中英文各一份。格式照前面几份。

## 2. 发布前先请微软复核（exe 签名之前每一版都要做）

exe 没有代码签名，Windows Defender 的机器学习判断有时会把新版本当成木马，下载就删。3.6.1 被报成 `Trojan:Win32/Bearfoos.B!ml`（结尾的 `!ml` 表示是机器学习的启发式判断，不是查到了具体的恶意代码）。每个新 exe 都是一个新文件，以前的复核结果不算数，所以每一版发布前都提交一次。

1. 把 exe 装进加了密码的压缩包，密码用安全厂商交换样本惯用的 `infected`：`zip -e -P infected ClearC-vX-for-microsoft.zip ClearC-vX.exe`。不装进压缩包的话，上传时 Defender 会先把 exe 删掉，网页上只显示「上传失败」。
2. 打开 <https://www.microsoft.com/wdsi/filesubmission>，用微软账号登录，身份选 Software developer。
3. 逐项填：
   - 产品：Microsoft Defender Antivirus（Windows 10/11 那一项）
   - Company name：`ClearC (open-source project by Leon Lu)`
   - 文件：上传那个 zip
   - 是否在某个日期后删除：No
   - What do you believe this file is：Incorrectly detected as malware/malicious
   - Detection name：Defender 报的名字，比如 `Trojan:Win32/Bearfoos.B!ml`；还没被报过就留空
   - Definition version：Windows 安全中心 →「病毒和威胁防护更新」里的「安全智能版本」
   - Additional information：用下面这段，SHA256 和版本换成这一版的
     ```
     The attached zip is password-protected; the password is: infected
     ClearC is an open-source Windows C: drive cleanup tool (MIT license): https://github.com/Xuanqiyun/ClearC
     The exe is a small .NET launcher that runs the project's own PowerShell script in-process with the built-in Windows PowerShell 5.1 and shows a WPF window. The script is embedded as a resource and is readable in the repository as src/CleanC-UI.ps1; the exe is built from the public repository with build/build-roslyn.ps1.
     It deletes caches and temporary files only after the user confirms, never deletes files in personal folders, moves folders to another drive with robocopy and directory junctions, and keeps an activity log of every change. Folders such as AppData\Microsoft\Protect, Credentials and Vault appear in the code only to block them from deletion. The scheduled task (off by default, user-level, never SYSTEM) runs a copy under Program Files so that standard users cannot replace it. The only network access is an update check against the GitHub releases API that the user starts.
     SHA256: <这一版 exe 的 SHA256>
     The exe is not code-signed yet.
     ```
4. 进度在 <https://www.microsoft.com/wdsi/submissionhistory> 看：Submitted → In progress → Completed，一般几个小时到一天。点提交编号进去看 Analyst comments：3.6.2 那次的结论是「do not meet our criteria for malware … The detection has been removed」。
5. 自己电脑上清掉 Defender 缓存的旧判断，再下载试一次（管理员身份的命令提示符）：
   ```
   cd "C:\Program Files\Windows Defender"
   MpCmdRun.exe -removedefinitions -dynamicsignature
   MpCmdRun.exe -SignatureUpdate
   ```
   别人的电脑会自动更新病毒库，一般一两天内就不会再拦。

## 3. 发 Release

推 tag 会被拒绝，Release 由维护者在网页上手动发：

1. 仓库的 Releases → Draft a new release。
2. Tag 填 `vX`，目标选 `main`，标题「腾挪 ClearC X」。
3. 说明栏贴 `docs/releases/vX.md` 的全文。
4. 上传 `ClearC-vX.exe`。上传前先核对 SHA256 和说明里写的一样；本机的 Defender 删了它的话，在「保护历史记录」里还原。
5. Publish release。发布以后，旧版本里的「检查新版本」就会提示。

## 4. 以后：代码签名

签了名，这类误报会少很多，也不用每一版都提交微软。打算申请 [SignPath Foundation](https://signpath.org/) 给开源项目的免费签名：

- 申请：<https://signpath.org/apply>。GitHub 账号要先开两步验证。
- 要求：OSI 认可的许可证（本项目是 MIT）；exe 由 GitHub 自己的机器上的自动构建生成（现在 CI 已经在 Windows 上打 exe）；每次签名由维护者手动批准；项目主页和发布页要有一段 "Code signing policy"。
- 批下来以后：在 SignPath 上加 GitHub.com 作为可信的构建来源、建项目和签名策略，API 令牌存进仓库的 Secrets；CI 里把 exe 上传成构建产物，再用 `signpath/github-action-submit-signing-request` 提交签名、取回签好的文件。之后 Release 上放 CI 签好的 exe。
- 按他们的条款，证书以 SignPath Foundation 的名义签发，Windows 上显示的发布者应该是 SignPath Foundation。

## 5. 用户说「打不开」时先问的

- 被杀毒软件删了：见第 2 步；着急的话可以直接运行源码，双击 `src\run-from-source.bat`。
- 双击没反应：3.6.3 以前，关掉窗口后程序有时会留在后台，新开的以为已经开着一个就直接退出。3.6.3 起窗口一关程序就结束；还有卡住的，双击时会问要不要结束它再打开。旧版本只能在任务管理器里结束 `ClearC` 开头的进程。
- 其他：`%TEMP%\CleanC-error.log`（启动失败的原因）和 `%LOCALAPPDATA%\CleanC\logs\run.log`（运行记录）。
