using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using Microsoft.CodeAnalysis;
using Microsoft.CodeAnalysis.CSharp;
using Microsoft.CodeAnalysis.Emit;

public static class ExeBuilder {
    // kind: "exe" = Windows GUI exe for .NET Framework 4.8; "lib" = library (used for the Linux functional test against .NET 8)
    public static string Build(string kind, string[] sources, string[] refs, string scriptPath, string manifestPath, string iconPath, string outPath) {
        CSharpParseOptions po = new CSharpParseOptions(LanguageVersion.CSharp7_3);
        List<SyntaxTree> trees = sources.Select(p => CSharpSyntaxTree.ParseText(File.ReadAllText(p), po, p)).ToList();
        List<MetadataReference> mrefs = refs.Select(r => (MetadataReference)MetadataReference.CreateFromFile(r)).ToList();
        CSharpCompilationOptions opts = new CSharpCompilationOptions(
            kind == "exe" ? OutputKind.WindowsApplication : OutputKind.DynamicallyLinkedLibrary,
            mainTypeName: kind == "exe" ? "CleanCLauncher" : null,
            optimizationLevel: OptimizationLevel.Release,
            platform: Platform.AnyCpu);
        CSharpCompilation comp = CSharpCompilation.Create(kind == "exe" ? "ClearC" : "CleanCTest", trees, mrefs, opts);
        byte[] script = File.ReadAllBytes(scriptPath);
        ResourceDescription[] res = { new ResourceDescription("cleanc.ps1", () => new MemoryStream(script), true) };
        Stream win32 = null;
        try {
            if (kind == "exe") {
                using (FileStream man = File.OpenRead(manifestPath))
                using (FileStream ico = File.OpenRead(iconPath))
                    win32 = comp.CreateDefaultWin32Resources(true, false, man, ico);
            }
            using (FileStream pe = File.Create(outPath)) {
                EmitResult r = comp.Emit(pe, win32Resources: win32, manifestResources: res);
                IEnumerable<Diagnostic> errs = r.Diagnostics.Where(d => d.Severity == DiagnosticSeverity.Error);
                if (!r.Success) return "ERRORS:\n" + string.Join("\n", errs.Select(d => d.ToString()));
                return "OK, warnings: " + string.Join(" | ", r.Diagnostics.Where(d => d.Severity == DiagnosticSeverity.Warning).Select(d => d.Id).Distinct());
            }
        } finally { if (win32 != null) win32.Dispose(); }
    }
}
