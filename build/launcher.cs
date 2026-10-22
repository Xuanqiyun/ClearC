using System;
using System.Collections;
using System.IO;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Text;

[assembly: AssemblyTitle("腾挪 ClearC")]
[assembly: AssemblyDescription("C 盘清理和搬家：清理 C 盘、把聊天记录和软件搬到其他盘、查找大文件和重复文件")]
[assembly: AssemblyProduct("腾挪 ClearC")]
[assembly: AssemblyVersion("2.7.0.0")]
[assembly: AssemblyFileVersion("2.7.0.0")]
[assembly: AssemblyInformationalVersion("2.7")]
[assembly: System.Runtime.Versioning.TargetFramework(".NETFramework,Version=v4.8", FrameworkDisplayName = ".NET Framework 4.8")]

// 启动器：把内置的 PowerShell 程序放进本进程里的 PowerShell 引擎运行（用 Windows 自带的 PowerShell 5.1，不需要另装任何东西）。
// 不写临时文件、不另开 powershell.exe 进程。启动失败时弹窗说明原因，并把详情写到 %TEMP%\CleanC-error.log。
static class CleanCLauncher {
    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    static extern int MessageBoxW(IntPtr hWnd, string text, string caption, uint type);

    static bool TestMode { get { return Environment.GetEnvironmentVariable("CLEANC_TEST") == "1"; } }
    static string LogPath { get { return Path.Combine(Path.GetTempPath(), "CleanC-error.log"); } }

    static void Fail(string shortMsg, string detail) {
        try { File.WriteAllText(LogPath, DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss") + "\r\n" + shortMsg + "\r\n\r\n" + detail, Encoding.UTF8); } catch { }
        if (TestMode) { Console.Error.WriteLine("FAIL: " + shortMsg); return; }
        try {
            bool zh = System.Globalization.CultureInfo.CurrentUICulture.Name.StartsWith("zh", StringComparison.OrdinalIgnoreCase);
            if (zh) MessageBoxW(IntPtr.Zero, "腾挪 ClearC 没能启动：\r\n\r\n" + shortMsg + "\r\n\r\n详细信息已保存到：\r\n" + LogPath, "腾挪 ClearC", 0x10);
            else MessageBoxW(IntPtr.Zero, "ClearC could not start:\r\n\r\n" + shortMsg + "\r\n\r\nDetails were saved to:\r\n" + LogPath, "ClearC", 0x10);
        } catch { }
    }

    static MethodInfo Method(Type t, string name, params Type[] args) {
        foreach (MethodInfo m in t.GetMethods(BindingFlags.Public | BindingFlags.Instance | BindingFlags.Static)) {
            if (m.Name != name || m.IsGenericMethodDefinition) continue;
            ParameterInfo[] ps = m.GetParameters();
            if (ps.Length != args.Length) continue;
            bool ok = true;
            for (int i = 0; i < ps.Length; i++) if (ps[i].ParameterType != args[i]) { ok = false; break; }
            if (ok) return m;
        }
        throw new MissingMethodException(t.FullName, name);
    }

    static void SetEnumProp(object target, string name, string value) {
        PropertyInfo p = target.GetType().GetProperty(name);
        p.SetValue(target, Enum.Parse(p.PropertyType, value), null);
    }

    [STAThread]
    static int Main(string[] args) {
        // 允许超过 260 字符的长路径（Windows 10 开启长路径支持后生效）
        try {
            AppContext.SetSwitch("Switch.System.IO.UseLegacyPathHandling", false);
            AppContext.SetSwitch("Switch.System.IO.BlockLongPaths", false);
        } catch { }

        Assembly me = Assembly.GetExecutingAssembly();
        Environment.SetEnvironmentVariable("CLEANC_SELF", me.Location);
        // 定时任务会带上 /check 或 /autoclean（自检是 /selftest），程序据此只做后台的事、不打开主窗口
        Environment.SetEnvironmentVariable("CLEANC_ARGS", string.Join(" ", args));
        // 本进程内的所有 PowerShell 运行空间都不受执行策略限制，等同于 powershell.exe -ExecutionPolicy Bypass
        Environment.SetEnvironmentVariable("PSExecutionPolicyPreference", "Bypass");

        string script;
        try {
            using (Stream s = me.GetManifestResourceStream("cleanc.ps1"))
            using (StreamReader r = new StreamReader(s, new UTF8Encoding(false), true)) script = r.ReadToEnd();
        } catch (Exception ex) { Fail("读不到内置的程序内容。", ex.ToString()); return 2; }

        object ps = null, rs = null;
        try {
            string smaPath = Environment.GetEnvironmentVariable("CLEANC_SMA");
            Assembly sma = string.IsNullOrEmpty(smaPath)
                ? Assembly.Load("System.Management.Automation, Version=3.0.0.0, Culture=neutral, PublicKeyToken=31bf3856ad364e35")
                : Assembly.LoadFrom(smaPath);
            Type rfType = sma.GetType("System.Management.Automation.Runspaces.RunspaceFactory", true);
            Type psType = sma.GetType("System.Management.Automation.PowerShell", true);

            rs = Method(rfType, "CreateRunspace").Invoke(null, null);
            if (!TestMode) SetEnumProp(rs, "ApartmentState", "STA");     // WPF 界面必须跑在 STA 线程上
            SetEnumProp(rs, "ThreadOptions", "UseCurrentThread");          // 就在当前（STA）主线程上执行
            Method(rs.GetType(), "Open").Invoke(rs, null);

            ps = Method(psType, "Create").Invoke(null, null);
            psType.GetProperty("Runspace").SetValue(ps, rs, null);
            Method(psType, "AddScript", typeof(string)).Invoke(ps, new object[] { script });
            Method(psType, "Invoke").Invoke(ps, null);

            object proxy = rs.GetType().GetProperty("SessionStateProxy").GetValue(rs, null);
            object shown = Method(proxy.GetType(), "GetVariable", typeof(string)).Invoke(proxy, new object[] { "CLEANC_UI_SHOWN" });
            if (shown == null) {
                // 程序里设了 SilentlyContinue，错误不会进错误流，但 PowerShell 仍会记在 $Error 里（最新的在前）
                System.Collections.Generic.List<string> errs = new System.Collections.Generic.List<string>();
                object streams = psType.GetProperty("Streams").GetValue(ps, null);
                foreach (object e in (IEnumerable)streams.GetType().GetProperty("Error").GetValue(streams, null)) errs.Add(e.ToString());
                IList all = Method(proxy.GetType(), "GetVariable", typeof(string)).Invoke(proxy, new object[] { "Error" }) as IList;
                if (all != null) for (int i = all.Count - 1; i >= 0; i--) { string t = all[i].ToString(); if (!errs.Contains(t)) errs.Add(t); }
                StringBuilder sb = new StringBuilder();
                for (int i = 0; i < errs.Count && i < 12; i++) sb.AppendLine((i + 1) + ". " + errs[i]);
                string first = errs.Count > 0 ? errs[0].Split('\n')[0].Trim() : "界面没有打开，也没有报告具体错误。";
                Fail(first, sb.ToString());
                return 1;
            }
            // 自检（/selftest）用退出码报告有几项不通过，测试机可以据此判断
            object code = Method(proxy.GetType(), "GetVariable", typeof(string)).Invoke(proxy, new object[] { "CLEANC_EXIT" });
            if (code is int) return (int)code;
            return 0;
        } catch (TargetInvocationException tie) {
            Exception inner = tie.InnerException ?? tie;
            Fail(inner.Message, inner.ToString());
            return 1;
        } catch (Exception ex) {
            Fail(ex.Message, ex.ToString());
            return 1;
        } finally {
            try { IDisposable d = ps as IDisposable; if (d != null) d.Dispose(); } catch { }
            try { IDisposable d = rs as IDisposable; if (d != null) d.Dispose(); } catch { }
        }
    }
}
