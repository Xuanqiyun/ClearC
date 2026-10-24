# C# 部分按 C# 5 编一遍（exe 里的启动器和类型用 Windows 自带的 csc 也要能编）。用法：pwsh tools/cs5-check.ps1
# 需要 build/refasm/v4.8（见 build/build-roslyn.ps1 开头的说明）
$R = Split-Path $PSScriptRoot -Parent
$src = [IO.File]::ReadAllText((Join-Path $R 'src/CleanC-UI.ps1'))
$S = Join-Path $R 'build'; $obj = Join-Path $S 'obj'
$row = [regex]::Match($src, '(?s)\$rowCode = @"\r?\n(.*?)\r?\n"@').Groups[1].Value
$dup = [regex]::Match($src, "(?s)\`$dupCode = @'\r?\n(.*?)\r?\n'@").Groups[1].Value
New-Item -ItemType Directory -Force $obj | Out-Null
[IO.File]::WriteAllText("$obj/types_row.cs", $row); [IO.File]::WriteAllText("$obj/types_dup.cs", $dup)
$pw = Split-Path ([System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName)
Add-Type -Path "$pw/Microsoft.CodeAnalysis.dll","$pw/Microsoft.CodeAnalysis.CSharp.dll" -ErrorAction SilentlyContinue
$po = [Microsoft.CodeAnalysis.CSharp.CSharpParseOptions]::new([Microsoft.CodeAnalysis.CSharp.LanguageVersion]::CSharp5)
$trees = foreach ($f in "$S/launcher.cs","$obj/types_row.cs","$obj/types_dup.cs") { [Microsoft.CodeAnalysis.CSharp.CSharpSyntaxTree]::ParseText([IO.File]::ReadAllText($f), $po, $f) }
$refs = foreach ($r in 'mscorlib','System','System.Core') { [Microsoft.CodeAnalysis.MetadataReference]::CreateFromFile("$S/refasm/v4.8/$r.dll") }
$opt = [Microsoft.CodeAnalysis.CSharp.CSharpCompilationOptions]::new([Microsoft.CodeAnalysis.OutputKind]::WindowsApplication)
$c = [Microsoft.CodeAnalysis.CSharp.CSharpCompilation]::Create('t', [Microsoft.CodeAnalysis.SyntaxTree[]]$trees, [Microsoft.CodeAnalysis.MetadataReference[]]$refs, $opt.WithMainTypeName('CleanCLauncher'))
$d = @($c.GetDiagnostics() | Where-Object { $_.Severity -ge 'Warning' })
"C# 5 errors/warnings: $($d.Count)"; $d | Select-Object -First 8 | ForEach-Object { $_.ToString() }
