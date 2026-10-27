# ==================== 持久化设置服务：显式输入和结果，不依赖界面、引擎全局状态 ====================
function Get-SettingsLockName([string]$Path) {
    $full = [IO.Path]::GetFullPath($Path).ToUpperInvariant()
    $sha = [Security.Cryptography.SHA256]::Create()
    try { $key = [BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($full))).Replace('-', '') } finally { $sha.Dispose() }
    return ('Local\ClearC-Settings-' + $key)
}
function Write-SettingsFile {
    param([string]$Path, [string]$Key, [string]$Value, [int]$TimeoutMs = 3000)
    $ErrorActionPreference = 'Stop'
    $result = @{ Ok = $false; Error = ''; Stage = 'lock' }
    $mx = $null; $got = $false; $tmp = ''; $ownsTemp = $false
    try {
        if (-not $Key -or $Key -match '[=\r\n]' -or $Value -match '[\r\n]' -or $TimeoutMs -lt 0) { throw 'Invalid settings input' }
        $Path = [IO.Path]::GetFullPath($Path)
        $mx = New-Object Threading.Mutex($false, (Get-SettingsLockName $Path))
        try { $got = $mx.WaitOne($TimeoutMs) } catch [Threading.AbandonedMutexException] { $got = $true }
        if (-not $got) { throw 'Settings are busy; please retry' }
        $result.Stage = 'read'
        $old = @(); if ([IO.File]::Exists($Path)) { $old = [IO.File]::ReadAllLines($Path, [Text.Encoding]::UTF8) }
        $lines = New-Object Collections.Generic.List[string]
        foreach ($line in $old) {
            $i = $line.IndexOf('=')
            if ($i -gt 0 -and $line.Substring(0, $i).Trim() -ieq $Key) { continue }
            $lines.Add($line)
        }
        $lines.Add("$Key=$Value")
        $result.Stage = 'write'
        [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($Path))
        $tmp = $Path + '.' + [guid]::NewGuid().ToString('N') + '.tmp'
        $stream = [IO.File]::Open($tmp, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        $ownsTemp = $true
        try {
            $enc = New-Object Text.UTF8Encoding($true)
            $bytes = $enc.GetPreamble() + $enc.GetBytes(($lines.ToArray() -join "`r`n") + "`r`n")
            $stream.Write($bytes, 0, $bytes.Length); $stream.Flush($true)
        } finally { $stream.Dispose() }
        if ([IO.File]::Exists($Path)) { [IO.File]::Replace($tmp, $Path, ($Path + '.bak')) } else { [IO.File]::Move($tmp, $Path) }
        $result.Ok = $true; $result.Stage = 'done'
    } catch { $result.Error = $_.Exception.Message }
    finally {
        if ($ownsTemp -and $tmp) { try { if ([IO.File]::Exists($tmp)) { [IO.File]::Delete($tmp) } } catch {} }
        if ($mx) { if ($got) { try { $mx.ReleaseMutex() } catch {} }; $mx.Dispose() }
    }
    return $result
}

