using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Text;
using System.Windows.Forms;

internal static class Program
{
    [STAThread]
    private static int Main()
    {
        try
        {
            string root = AppDomain.CurrentDomain.BaseDirectory.TrimEnd(Path.DirectorySeparatorChar);
            string appDir = Path.Combine(root, "app");
            string desktop = Path.Combine(appDir, "Hermes.exe");
            if (!File.Exists(desktop))
            {
                MessageBox.Show("Hermes desktop executable was not found:\r\n" + desktop, "Hermes Desktop", MessageBoxButtons.OK, MessageBoxIcon.Error);
                return 1;
            }
            SetPortableEnvironment(root);
            var psi = new ProcessStartInfo { FileName = desktop, WorkingDirectory = appDir, UseShellExecute = false, CreateNoWindow = true };
            using (var child = Process.Start(psi)) { child.WaitForExit(); return child.ExitCode; }
        }
        catch (Exception ex)
        {
            MessageBox.Show(ex.ToString(), "Hermes Desktop", MessageBoxButtons.OK, MessageBoxIcon.Error);
            return 1;
        }
    }

    internal static void SetPortableEnvironment(string root)
    {
        string home = Path.Combine(root, "data", "hermes-home");
        string git = Path.Combine(home, "git");
        EnsureFirstRunConfig(home);
        ShowUpdateResultIfFailed(root, home);
        Environment.SetEnvironmentVariable("HERMES_HOME", home);
        Environment.SetEnvironmentVariable("HERMES_DESKTOP_USER_DATA_DIR", Path.Combine(root, "data", "electron-user-data"));
        Environment.SetEnvironmentVariable("HERMES_DESKTOP_HERMES", Path.Combine(root, "runtime", "bin", "hermes-cli.cmd"));
        Environment.SetEnvironmentVariable("HERMES_GIT_BASH_PATH", Path.Combine(git, "bin", "bash.exe"));
        Environment.SetEnvironmentVariable("HERMES_PORTABLE_SITE_PACKAGES", Path.Combine(home, "hermes-agent", "venv", "Lib", "site-packages"));
        string pythonPath = string.Join(";", new[] {
            Path.Combine(root, "runtime", "python-bootstrap"),
            Path.Combine(home, "hermes-agent"),
            Environment.GetEnvironmentVariable("PYTHONPATH") ?? ""
        });
        Environment.SetEnvironmentVariable("PYTHONPATH", pythonPath);
        Environment.SetEnvironmentVariable("UV_PYTHON_INSTALL_DIR", Path.Combine(root, "runtime", "python"));
        Environment.SetEnvironmentVariable("UV_PYTHON_INSTALL_BIN", "0");
        Environment.SetEnvironmentVariable("UV_PYTHON_INSTALL_REGISTRY", "0");
        // Desktop backend must run the bundled runtime python, not the packaged
        // venv trampoline: pyvenv.cfg `home` records the builder's build-tree
        // python and CPython requires that path to exist, so the trampoline is
        // not relocatable (a ZIP-installed copy on a machine without the build
        // tree fails with "Cannot find home"). HERMES_DESKTOP_HERMES_ROOT pins
        // resolveHermesBackend() to the embedded checkout (rung 1) and
        // HERMES_DESKTOP_PYTHON selects the runtime interpreter; PYTHONPATH +
        // runtime\python-bootstrap sitecustomize supply the site-packages wrapper.
        string currentTxt = Path.Combine(root, "runtime", "python", "current.txt");
        string pythonDir = File.Exists(currentTxt) ? File.ReadAllText(currentTxt).Trim() : "";
        if (!string.IsNullOrEmpty(pythonDir))
        {
            string pythonExe = Path.Combine(root, "runtime", "python", pythonDir, "python.exe");
            if (File.Exists(pythonExe))
            {
                Environment.SetEnvironmentVariable("HERMES_DESKTOP_PYTHON", pythonExe);
                Environment.SetEnvironmentVariable("HERMES_DESKTOP_HERMES_ROOT", Path.Combine(home, "hermes-agent"));
            }
        }
        string[] entries = {
            Path.Combine(home, "hermes-agent", "venv", "Scripts"), Path.Combine(home, "node"),
            Path.Combine(git, "cmd"), Path.Combine(git, "bin"), Path.Combine(git, "usr", "bin"),
            Path.Combine(root, "runtime", "bin"), Environment.GetEnvironmentVariable("PATH") ?? ""
        };
        Environment.SetEnvironmentVariable("PATH", string.Join(";", entries));
    }

    private static void EnsureFirstRunConfig(string home)
    {
        string config = Path.Combine(home, "config.yaml");
        if (File.Exists(config)) return;
        Directory.CreateDirectory(home);
        try
        {
            using (var stream = new FileStream(config, FileMode.CreateNew, FileAccess.Write, FileShare.Read))
            using (var writer = new StreamWriter(stream, new UTF8Encoding(false)))
            {
                writer.Write("display:\n  language: zh\n");
            }
        }
        catch (IOException)
        {
            if (!File.Exists(config)) throw;
        }
    }

    // Update.exe writes data\hermes-home\.hermes-update-result.json on every
    // exit (success, step failure, gate abort, crash). Surface a FAILED result
    // once on the next launch so a detached update never ends silently, then
    // consume (delete) the file either way. A success result is silently
    // consumed. (Pair with Update.cs Finish().)
    private static void ShowUpdateResultIfFailed(string root, string home)
    {
        string resultPath = Path.Combine(home, ".hermes-update-result.json");
        try
        {
            if (!File.Exists(resultPath)) return;
            string json = File.ReadAllText(resultPath, Encoding.UTF8);
            bool ok = json.IndexOf("\"ok\":true", StringComparison.OrdinalIgnoreCase) >= 0;
            if (!ok)
            {
                string message = ExtractJsonString(json, "message");
                if (string.IsNullOrEmpty(message)) message = "(无详细信息)";
                MessageBox.Show(
                    "上次 Hermes 更新未成功完成：\n\n" + message +
                    "\n\n可查看日志：data\\hermes-home\\logs\\Update.exe-diagnostic.log",
                    "Hermes Update", MessageBoxButtons.OK, MessageBoxIcon.Warning);
            }
            try { File.Delete(resultPath); } catch { }
        }
        catch { }
    }

    private static string ExtractJsonString(string json, string key)
    {
        // Minimal JSON string-value extractor: find  "key":" ... " (no nested
        // quotes in our messages beyond escaped ones). .NET 4.0-safe.
        string needle = "\"" + key + "\":\"";
        int start = json.IndexOf(needle, StringComparison.Ordinal);
        if (start < 0) return "";
        start += needle.Length;
        var sb = new StringBuilder();
        for (int i = start; i < json.Length; i++)
        {
            char c = json[i];
            if (c == '\\' && i + 1 < json.Length)
            {
                char n = json[i + 1];
                if (n == 'n') sb.Append('\n');
                else if (n == 'r') sb.Append('\r');
                else if (n == 't') sb.Append('\t');
                else if (n == '"') sb.Append('"');
                else if (n == '\\') sb.Append('\\');
                else { sb.Append('\\'); sb.Append(n); }
                i++;
            }
            else if (c == '"')
            {
                break;
            }
            else
            {
                sb.Append(c);
            }
        }
        return sb.ToString();
    }
}
