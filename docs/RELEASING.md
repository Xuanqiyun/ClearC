# Release process

For the maintainer: every step from changing the version number to a downloadable GitHub Release. How to change the code and run the tests: see [AGENTS.md](../AGENTS.md).

## 1. Build

1. Change the version number in one place only: `$script:AppVersion` in `src/CleanC-UI.ps1`.
2. Add a section for this version at the top of `CHANGELOG.md` (English) and `CHANGELOG.zh-CN.md` (Chinese); the checks verify both.
3. Commit and push on a feature branch, and wait until CI passes on both Linux and Windows: `bash tools/ci-wait.sh <sha>`.
4. Merge into main: `git checkout main && git merge --ff-only <branch> && git push origin main`.
5. Build the exe with `pwsh build/build-roslyn.ps1 -Out out/ClearC-vX.exe` and compute its SHA256 with `sha256sum out/ClearC-vX.exe`.
6. Write the release notes in `docs/releases/vX.md`: how to download and check the SHA256 first, then the changes in this version and the few before it, and finally the risk notice. English first, then the Chinese (中文说明). Follow the format of the earlier files.

## 2. Ask Microsoft to review it before publishing (every version, until the exe is signed)

The exe has no code signature, and Windows Defender's machine-learning detection sometimes treats a new version as a trojan and deletes it on download. 3.6.1 was reported as `Trojan:Win32/Bearfoos.B!ml` (the `!ml` at the end means a machine-learning heuristic, not a match on specific malicious code). Every new exe is a new file and earlier review results don't carry over, so submit each version before publishing it.

1. Put the exe in a password-protected zip, using `infected`, the password security vendors conventionally use for exchanging samples: `zip -e -P infected ClearC-vX-for-microsoft.zip ClearC-vX.exe`. Without the zip, Defender deletes the exe during the upload and the web page only says "upload failed".
2. Open <https://www.microsoft.com/wdsi/filesubmission>, sign in with a Microsoft account and choose Software developer.
3. Fill in each field:
   - Product: Microsoft Defender Antivirus (the Windows 10/11 entry)
   - Company name: `ClearC (open-source project by Leon Lu)`
   - File: upload the zip
   - Should this file be removed from our database at a certain date: No
   - What do you believe this file is: Incorrectly detected as malware/malicious
   - Detection name: the name Defender reported, such as `Trojan:Win32/Bearfoos.B!ml`; leave it empty if it hasn't been flagged yet
   - Definition version: Windows Security → "Virus & threat protection updates" → "Security intelligence version"
   - Additional information: the text below, with this version's SHA256 and version number
     ```
     The attached zip is password-protected; the password is: infected
     ClearC is an open-source Windows C: drive cleanup tool (MIT license): https://github.com/Xuanqiyun/ClearC
     The exe is a small .NET launcher that runs the project's own PowerShell script in-process with the built-in Windows PowerShell 5.1 and shows a WPF window. The script is embedded as a resource and is readable in the repository as src/CleanC-UI.ps1; the exe is built from the public repository with build/build-roslyn.ps1.
     It deletes caches and temporary files only after the user confirms, never deletes files in personal folders, moves folders to another drive with robocopy and directory junctions, and keeps an activity log of every change. Folders such as AppData\Microsoft\Protect, Credentials and Vault appear in the code only to block them from deletion. The scheduled task (off by default, user-level, never SYSTEM) runs a copy under Program Files so that standard users cannot replace it. The only network access is an update check against the GitHub releases API that the user starts.
     SHA256: <this version's exe SHA256>
     The exe is not code-signed yet.
     ```
4. Follow the progress at <https://www.microsoft.com/wdsi/submissionhistory>: Submitted → In progress → Completed, usually within a few hours to a day. Open the submission number to read the Analyst comments. For 3.6.2 the result was "do not meet our criteria for malware … The detection has been removed".
5. Clear Defender's cached verdict on your own PC and download again (Command Prompt as administrator):
   ```
   cd "C:\Program Files\Windows Defender"
   MpCmdRun.exe -removedefinitions -dynamicsignature
   MpCmdRun.exe -SignatureUpdate
   ```
   Other people's PCs update their definitions automatically and usually stop blocking it within a day or two.

## 3. Publish the Release

Pushing tags is rejected, so the maintainer publishes the Release by hand on the web page:

1. In the repository, Releases → Draft a new release.
2. Tag `vX`, target `main`, title "腾挪 ClearC X".
3. Paste the whole of `docs/releases/vX.md` into the description.
4. Upload `ClearC-vX.exe`. Check first that its SHA256 matches the one in the notes; if Defender deleted it on your PC, restore it from Protection history.
5. Publish release. Once it is published, "Check for updates" in older versions offers it.

## 4. Later: code signing

With a signature, false positives like this become much rarer and each version no longer needs a Microsoft submission. The plan is to apply for free open-source signing from [SignPath Foundation](https://signpath.org/):

- Apply at <https://signpath.org/apply>. Turn on two-factor authentication for the GitHub account first.
- Requirements: an OSI-approved license (this project is MIT); the exe must be produced by an automated build on GitHub's own runners (CI already builds the exe on Windows); each signing is approved by hand by the maintainer; the project page and release pages need a "Code signing policy" section.
- Once approved: on SignPath, add GitHub.com as a trusted build system, create the project and signing policy, and store the API token in the repository's Secrets. In CI, upload the exe as a build artifact, then use `signpath/github-action-submit-signing-request` to submit the signing request and fetch the signed file. From then on, Releases carry the exe signed by CI.
- Under their terms the certificate is issued in SignPath Foundation's name, so Windows should show SignPath Foundation as the publisher.

## 5. What to ask first when a user says "it won't open"

- The antivirus deleted it: see step 2. In a hurry, the user can run the source directly by double-clicking `src\run-from-source.bat`.
- Nothing happens on double-click: before 3.6.3, ClearC sometimes stayed in the background after its window closed, and a new copy assumed one was already open and quit. From 3.6.3 on, closing the window ends the program, and if a copy is still stuck, double-clicking asks whether to end it and open again. On older versions the only fix is ending the processes whose names start with `ClearC` in Task Manager.
- Anything else: `%TEMP%\CleanC-error.log` (why startup failed) and `%LOCALAPPDATA%\CleanC\logs\run.log` (the run log).
