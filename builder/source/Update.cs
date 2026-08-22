using System;
using System.Diagnostics;
using System.IO;
using System.Text;
using System.Windows.Forms;

internal static class Program
{
    // Shared state for the unified Finish() path: every exit route (success,
    // step failure, gate abort, uncaught exception) writes .hermes-update-result.json
    // (consumed by the relaunched Hermes.exe) and removes the re-entrancy marker
    // when we own it. Learned from the official scripts/desktop-update.ps1:
    // every exit path must leave a truthful record and clean up its claim.
    private static string s_root;
    private static string s_markerPath;
    private static string s_resultPath;
    private static bool s_ownsMarker;

    [STAThread]
    private static int Main()
    {
        // The child processes we stream (npm/node, git, powershell, python)
        // emit UTF-8, but .NET 4.0 decodes redirected child output with
        // Console.OutputEncoding — the OEM code page (GBK/936 on zh-CN) — so
        // non-ASCII child output (e.g. the official postinstall "\u2705"
        // checkmark) renders as "?". Switch the console to UTF-8 and force
        // child Python to UTF-8 so streamed text displays correctly; restore
        // the caller's code page on exit.
        Encoding originalConsole = null;
        try { originalConsole = Console.OutputEncoding; Console.OutputEncoding = Encoding.UTF8; } catch { }
        try { Environment.SetEnvironmentVariable("PYTHONIOENCODING", "utf-8"); } catch { }
        try { Environment.SetEnvironmentVariable("PYTHONUTF8", "1"); } catch { }
        try
        {
            return MainBody();
        }
        finally
        {
            try { if (originalConsole != null) Console.OutputEncoding = originalConsole; } catch { }
        }
    }

    private static int MainBody()
    {
        string root = AppDomain.CurrentDomain.BaseDirectory.TrimEnd(Path.DirectorySeparatorChar);
        // The updater writes a diagnostic log here so a failed step is never a
        // dead end: the dialog names the step, the likely cause, and this path.
        string diagLog = Path.Combine(root, "data", "hermes-home", "logs", "Update.exe-diagnostic.log");
        s_root = root;
        s_markerPath = Path.Combine(root, "data", "hermes-home", ".hermes-update-in-progress");
        s_resultPath = Path.Combine(root, "data", "hermes-home", ".hermes-update-result.json");
        try
        {
            try { Directory.CreateDirectory(Path.GetDirectoryName(diagLog)); } catch { }
            try { File.WriteAllText(diagLog, "=== Hermes Portable Update diagnostic " + DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss") + " ===\r\n"); } catch { }

            // Re-entrancy guard (learned from official desktop-update.ps1 marker
            // claim): a second Update.exe must not run concurrently — two
            // updaters racing over the same checkout/venv bricks the install.
            // We claim the marker with OUR pid; a stale marker whose pid is no
            // longer alive is reclaimed silently. The marker file is only
            // removed by Finish() when we still own it.
            try
            {
                if (File.Exists(s_markerPath))
                {
                    int oldPid = 0;
                    bool oldAlive = false;
                    try { oldPid = int.Parse(File.ReadAllText(s_markerPath).Trim()); } catch { }
                    if (oldPid > 0)
                    {
                        try { Process.GetProcessById(oldPid); oldAlive = true; } catch (ArgumentException) { }
                    }
                    if (oldAlive)
                    {
                        return Fail("防重入", 1,
                            "另一个 Update.exe 正在运行（PID " + oldPid + "）。请等待其完成后再试。",
                            "", diagLog);
                    }
                }
                File.WriteAllText(s_markerPath, Process.GetCurrentProcess().Id.ToString());
                s_ownsMarker = true;
            }
            catch { }

            // FAIL CLOSED gate (learned from official desktop-update.ps1 steps
            // 1-2): updating while the Desktop backend (venv python) holds the
            // install open is how installs brick (2026-08-09 Access-denied
            // incident). Wait up to 30s for a Hermes/backend process under this
            // root to exit; if it never does, abort BEFORE touching anything.
            if (!WaitForRootProcessesExit(root, 30))
            {
                return Fail("进程占用", 1,
                    "Hermes 仍在运行（30 秒内未退出）。请完全退出 Hermes 后重新运行 Update.exe。未做任何更改。",
                    "", diagLog);
            }

            // Pre-flight connectivity probe to github.com (the update source)
            // through the bundled node — same contract as the DeepSeek
            // updater's network check (2026-08-22): a dead/flaky link fails in
            // seconds with a clear reason instead of minutes of git retries,
            // and nothing local is touched yet.
            string nodeExe = Path.Combine(root, "data", "hermes-home", "node", "node.exe");
            if (File.Exists(nodeExe))
            {
                string netReason = ProbeGitHub(nodeExe, root);
                if (netReason != null)
                {
                    AppendDiag(diagLog, "网络预检", -1, netReason);
                    MessageBox.Show("无法开始更新（网络问题）。\n\n" + netReason +
                        "\n\n建议：检查网络或代理后重新运行 Update.exe。更新流程是安全的，重试不会损坏现有安装。",
                        "Hermes Update", MessageBoxButtons.OK, MessageBoxIcon.Warning);
                    return Finish(1, "network preflight failed: " + netReason);
                }
            }

            string updater = Path.Combine(root, "scripts", "Update-Portable.ps1");
            string repair = Path.Combine(root, "scripts", "Repair-Portable.ps1");
            string cli = Path.Combine(root, "runtime", "bin", "hermes-cli.cmd");
            foreach (string required in new[] { updater, repair, cli })
                if (!File.Exists(required)) throw new FileNotFoundException("Required updater component was not found.", required);

            string output;
            int rc = RunCaptured("powershell.exe", "-NoProfile -ExecutionPolicy Bypass -File " + Quote(repair) + " -KeepProcesses", root, out output);
            if (rc != 0) return Fail("便携环境修复", rc, "便携 Python 环境修复失败，无法继续更新。", output, diagLog);
            rc = RunCaptured("powershell.exe", "-NoProfile -ExecutionPolicy Bypass -File " + Quote(updater) + " -Stage PatchRemove", root, out output);
            if (rc != 0) return Fail("移除便携补丁", rc, "移除 Portable 源码补丁失败，无法继续更新。", output, diagLog);
            // Stray non-gitignored untracked files in the packaged checkout
            // (e.g. desktop sources from a newer upstream that leaked in)
            // make the official `hermes update` stash them and prompt
            // "Restore local changes now? [Y/n]"; answering Y then conflicts,
            // because those files already exist in the updated tree. Clean
            // them pre-emptively so the official preflight sees a pristine
            // checkout and resets cleanly. `-fd` leaves gitignored payloads
            // (hermes_cli/tui_dist, node_modules) untouched. Best-effort: if
            // it fails, the official flow still works (answer n at its prompt).
            string gitExe = Path.Combine(root, "data", "hermes-home", "git", "cmd", "git.exe");
            string gitBin = File.Exists(gitExe) ? gitExe : "git.exe";
            string checkoutDir = Path.Combine(root, "data", "hermes-home", "hermes-agent");
            int cleanRc = RunCaptured(gitBin, "-C " + Quote(checkoutDir) + " clean -fd", root, out output);
            if (cleanRc != 0)
                Console.WriteLine("WARNING: git clean -fd returned " + cleanRc + "; the update may prompt about local changes.");
            // The official `hermes update` ends by stopping every running
            // dashboard/serve process it finds via a command-line match
            // (wmic CommandLine LIKE %serve%/%dashboard%). On a machine with
            // several portable installs that also kills the OTHER installs'
            // backends, which are not stale (they serve their own homes).
            // The official cleanup honours HERMES_DESKTOP_CHILD_PID (a
            // comma-separated pid list read from its own environment) — fill
            // it with the foreign serve/dashboard processes so only this
            // install's own stale backend is stopped.
            string foreign = FindForeignDashboardPids(root);
            if (foreign.Length > 0)
                Environment.SetEnvironmentVariable("HERMES_DESKTOP_CHILD_PID", foreign);
            // Stop every Hermes/python process under this install BEFORE the
            // official update: the Python dependency install rewrites
            // cryptography's native DLLs (_rust.pyd etc.), and Windows refuses
            // to replace a DLL that a running Hermes/python process has loaded
            // (verified 2026-08-15: os error 5 on _rust.pyd — the desktop
            // backend python.exe loads it, so any update while the app is
            // running fails the dependency step). The update relaunches the
            // app afterwards anyway, so nothing is lost. Best-effort: if the
            // stop fails the update still runs and may hit the lock again.
            StopPortableProcesses(root);
            // Record the source commit before the official update so a later
            // standalone-uv fallback can prove the source actually advanced.
            // A fallback that succeeds while HEAD is unchanged means the git
            // step failed (e.g. network) — continuing would report a fake
            // success with un-updated source.
            string headBefore = RunGitHead(gitBin, checkoutDir, root);
            // hermes-cli.cmd already wraps `python -m hermes_cli.main %*`, so
            // pass the bare subcommand; a redundant "-m hermes_cli.main" only
            // works by accident (it parses as --model + parse_known_args).
            rc = RunCaptured(cli, "update", root, out output);
            if (rc != 0)
            {
                AppendDiag(diagLog, "官方更新 (hermes update)", rc, output);
                // The official update's dependency install can fail because
                // cryptography's native DLLs (_rust.pyd etc.) are mapped by a
                // running Hermes/python process — Windows refuses to replace a
                // loaded DLL (os error 5, verified on the cryptography 48→50
                // upgrade; the desktop backend python.exe loads _rust.pyd, and
                // `import hermes_cli.main` itself does NOT load cryptography,
                // so it is not the update process locking itself — 2026-08-15
                // reattribution). The update process has exited by now, so a
                // STANDALONE uv install (Rust process, never loads
                // cryptography) can finish the deps once the lock is released.
                // Best-effort: if it succeeds, continue the update; otherwise
                // fall through to the failure dialog.
                string uvBin = Path.Combine(root, "data", "hermes-home", "bin", "uv.exe");
                string repoDir = Path.Combine(root, "data", "hermes-home", "hermes-agent");
                string venvPython = Path.Combine(repoDir, "venv", "Scripts", "python.exe");
                if (File.Exists(uvBin) && File.Exists(venvPython))
                {
                    Console.WriteLine("官方更新失败（依赖安装），尝试用独立 uv 完成依赖安装...");
                    int uvRc = RunCaptured(uvBin, "pip install --python \"" + venvPython + "\" -e .", repoDir, out output);
                    if (uvRc == 0)
                    {
                        string headAfter = RunGitHead(gitBin, repoDir, root);
                        if (headBefore.Length > 0 && headAfter != headBefore)
                        {
                            Console.WriteLine("✓ 独立 uv 依赖安装完成，源码已更新。");
                            rc = 0;
                        }
                        else
                        {
                            // The git step itself failed (network/conflict) and
                            // the source did not advance; installing deps alone
                            // must not report a completed update.
                            AppendDiag(diagLog, "独立 uv 依赖安装", 0,
                                "依赖已安装但源码未更新（HEAD 未前进：" + headBefore + "）。");
                            Console.WriteLine("✗ 依赖已安装，但源码未更新（git 步骤失败）。");
                        }
                    }
                    else
                    {
                        AppendDiag(diagLog, "独立 uv 依赖安装", uvRc, output);
                    }
                }
                if (rc != 0)
                {
                    MessageBox.Show(
                        "更新失败：无法完成官方 Hermes 更新（退出码 " + rc + "）。\n\n" +
                        ClassifyUpdateError(output) +
                        "\n\n详细日志：" + diagLog,
                        "Hermes Update", MessageBoxButtons.OK, MessageBoxIcon.Error);
                    return Finish(rc, "hermes update failed with exit code " + rc);
                }
            }
            // PythonVersion is read only after the official source update, so a
            // newly changed upstream selector controls provisioning and cutover.
            // Stop processes again: the official update may have left its own
            // python children behind, and the venv repair below renames the
            // venv directory — a stray child holding it would fail that step.
            StopPortableProcesses(root);
            rc = RunCaptured("powershell.exe", "-NoProfile -ExecutionPolicy Bypass -File " + Quote(repair) + " -UpdatePython -KeepProcesses", root, out output);
            if (rc != 0) return Fail("更新 Python 运行时", rc, "按官方选择器更新 Python 失败，现有版本不受影响。", output, diagLog);
            rc = RunCaptured("powershell.exe", "-NoProfile -ExecutionPolicy Bypass -File " + Quote(updater) + " -Stage SyncDesktop", root, out output);
            if (rc != 0) return Fail("桌面同步", rc, "Portable 桌面应用同步失败，现有版本不受影响。", output, diagLog);
            // No completion dialog: launch the app directly. Step 5 (desktop
            // sync) already killed the root processes; start Hermes.exe fresh.
            // Best-effort: if the launch fails, fall back to the informational
            // dialog so the user is not left wondering why nothing opened.
            try
            {
                Process.Start(Path.Combine(root, "Hermes.exe"));
            }
            catch (Exception launchEx)
            {
                MessageBox.Show("更新已完成，但无法自动启动 Hermes：\n" + launchEx.Message + "\n\n请手动启动 Hermes.exe。",
                    "Hermes Update", MessageBoxButtons.OK, MessageBoxIcon.Warning);
            }
            return Finish(0, "Update complete.");
        }
        catch (Exception ex)
        {
            try { AppendDiag(diagLog, "未捕获异常", 1, ex.ToString()); } catch { }
            MessageBox.Show("更新失败：发生未预期的错误。\n\n" + ex.Message + "\n\n详细日志：" + diagLog,
                "Hermes Update", MessageBoxButtons.OK, MessageBoxIcon.Error);
            return Finish(1, ex.Message);
        }
    }

    // Detect the common failure classes from the official updater output and
    // turn them into a user-facing explanation. Must stay .NET 4.0 csc-safe:
    // no string interpolation, no Contains(StringComparison).
    private static string ClassifyUpdateError(string output)
    {
        string low = output == null ? "" : output.ToLowerInvariant();
        if (low.IndexOf("network error") >= 0 || low.IndexOf("failed to connect") >= 0 ||
            low.IndexOf("could not connect") >= 0 || low.IndexOf("recv failure") >= 0 ||
            low.IndexOf("connection was reset") >= 0 || low.IndexOf("unable to access") >= 0 ||
            low.IndexOf("timed out") >= 0 || low.IndexOf("timeout") >= 0)
        {
            return "原因：无法连接到 GitHub（网络错误）。\n\n" +
                "官方更新器需要访问：\nhttps://github.com/NousResearch/hermes-agent.git\n\n" +
                "可能原因：\n" +
                "• 当前网络暂时无法访问 github.com（连接超时或被重置）\n" +
                "• 需要代理/VPN 才能访问 GitHub\n\n" +
                "建议：检查网络或代理后重新运行 Update.exe。更新流程是安全的，重复重试不会损坏现有安装。";
        }
        if (low.IndexOf("could not resolve host") >= 0 || low.IndexOf("name resolution") >= 0 ||
            low.IndexOf("dns") >= 0)
        {
            return "原因：DNS 解析失败，无法找到 GitHub 服务器地址。\n\n建议：检查 DNS 与网络配置后重试。";
        }
        if (low.IndexOf("authentication") >= 0 || low.IndexOf("permission denied") >= 0 ||
            low.IndexOf("access denied") >= 0 || low.IndexOf(" 403") >= 0 || low.IndexOf(" 401") >= 0)
        {
            return "原因：访问被拒绝（网络限制或服务端拦截）。\n\n建议：检查网络环境后重试。";
        }
        return "原因：官方更新器返回了错误，详情见日志。\n\n输出摘要：\n" + FirstLines(output, 6);
    }

    private static string FirstLines(string text, int count)
    {
        if (string.IsNullOrEmpty(text)) return "(无输出)";
        var sb = new StringBuilder();
        int seen = 0;
        foreach (string raw in text.Split('\n'))
        {
            string line = raw.Trim();
            if (line.Length == 0) continue;
            sb.AppendLine(line);
            seen++;
            if (seen >= count) break;
        }
        return sb.ToString();
    }

    // Pre-flight connectivity probe to github.com (the git update source),
    // run through the SAME bundled node the updater's tooling uses (a .NET
    // HttpWebRequest probe misjudges this machine's TLS path — same finding as
    // the DeepSeek updater, 2026-08-22). Returns null when reachable, else a
    // user-facing reason. A dead/flaky link fails in ~6s instead of minutes of
    // git retries.
    private static string ProbeGitHub(string nodeExe, string workDir)
    {
        string script = "const https=require('https');const t=setTimeout(()=>{console.log('PROBE_TIMEOUT');process.exit(0)},6000);https.get('https://github.com/',r=>{clearTimeout(t);console.log('PROBE_OK '+r.statusCode);process.exit(0)}).on('error',e=>{clearTimeout(t);console.log('PROBE_ERR '+(e.code||e.message));process.exit(0)})";
        string output;
        RunCaptured(nodeExe, "-e \"" + script + "\"", workDir, out output);
        string line = null;
        if (output != null)
        {
            foreach (string raw in output.Split('\n'))
            {
                string t = raw.Trim();
                if (t.Length > 0) { line = t; break; }
            }
        }
        if (line != null && line.StartsWith("PROBE_OK")) return null;
        if (line == "PROBE_TIMEOUT") return "无法连接 github.com：连接超时（网络或代理不稳定）。";
        string code = line != null && line.StartsWith("PROBE_ERR ") ? line.Substring("PROBE_ERR ".Length) : line;
        if (code != null && (code.IndexOf("ENOTFOUND") >= 0 || code.IndexOf("getaddrinfo") >= 0)) return "无法连接 github.com：DNS 解析失败。";
        if (code != null && code.IndexOf("ECONNREFUSED") >= 0) return "无法连接 github.com：连接被拒绝（网络或代理配置问题）。";
        if (code != null) return "无法连接 github.com：" + code;
        return "无法连接 github.com（网络探测失败）。";
    }

    private static int Fail(string step, int rc, string message, string output, string diagLog)
    {
        AppendDiag(diagLog, step, rc, output);
        MessageBox.Show("更新失败：" + step + "（退出码 " + rc + "）。\n\n" + message + "\n\n详细日志：" + diagLog,
            "Hermes Update", MessageBoxButtons.OK, MessageBoxIcon.Error);
        return Finish(rc, step + " failed with exit code " + rc);
    }

    // Unified exit path: write .hermes-update-result.json (read+deleted by the
    // relaunched Hermes.exe so the user sees how a detached update ended) and
    // remove the re-entrancy marker only while we still own it. Every exit
    // route must go through here — success, step failure, gate abort, crash.
    private static int Finish(int code, string message)
    {
        if (s_ownsMarker)
        {
            try { if (File.Exists(s_markerPath)) File.Delete(s_markerPath); } catch { }
            s_ownsMarker = false;
        }
        try
        {
            string json = "{\"ok\":" + (code == 0 ? "true" : "false") +
                ",\"exit_code\":" + code +
                ",\"message\":\"" + JsonEscape(message) +
                "\",\"finished_at\":\"" + DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss") + "\"}";
            File.WriteAllText(s_resultPath, json, new UTF8Encoding(false));
        }
        catch { }
        return code;
    }

    private static string JsonEscape(string s)
    {
        if (s == null) return "";
        var sb = new StringBuilder();
        foreach (char c in s)
        {
            switch (c)
            {
                case '"': sb.Append("\\\""); break;
                case '\\': sb.Append("\\\\"); break;
                case '\n': sb.Append("\\n"); break;
                case '\r': sb.Append("\\r"); break;
                case '\t': sb.Append("\\t"); break;
                default: sb.Append(c); break;
            }
        }
        return sb.ToString();
    }

    // FAIL CLOSED preflight: wait (up to timeoutSeconds) for every Hermes.exe
    // and venv-backend python.exe whose path lives under this portable root to
    // exit. A live Desktop means a live backend that can re-lock the venv at
    // any moment; updating under it is how installs brick. Returns true when
    // the root is clear, false on timeout (caller aborts BEFORE mutating).
    private static bool WaitForRootProcessesExit(string root, int timeoutSeconds)
    {
        string rootPrefix = root.TrimEnd(Path.DirectorySeparatorChar) + Path.DirectorySeparatorChar;
        var pids = new System.Collections.Generic.List<int>();
        try
        {
            foreach (Process p in Process.GetProcesses())
            {
                try
                {
                    string exe = p.MainModule.FileName;
                    if (exe == null) continue;
                    string name = Path.GetFileName(exe);
                    bool relevant = name.Equals("Hermes.exe", StringComparison.OrdinalIgnoreCase) ||
                        name.Equals("python.exe", StringComparison.OrdinalIgnoreCase);
                    if (!relevant) continue;
                    if (exe.StartsWith(rootPrefix, StringComparison.OrdinalIgnoreCase) ||
                        exe.Equals(root, StringComparison.OrdinalIgnoreCase))
                    {
                        pids.Add(p.Id);
                    }
                }
                catch { }
            }
        }
        catch { }
        if (pids.Count == 0) return true;
        DateTime deadline = DateTime.Now.AddSeconds(timeoutSeconds);
        while (DateTime.Now < deadline)
        {
            bool anyAlive = false;
            foreach (int pid in pids)
            {
                try { Process.GetProcessById(pid); anyAlive = true; break; } catch (ArgumentException) { }
            }
            if (!anyAlive) return true;
            System.Threading.Thread.Sleep(500);
        }
        return false;
    }

    private static void AppendDiag(string path, string step, int rc, string output)
    {
        try
        {
            var sb = new StringBuilder();
            sb.AppendLine();
            sb.AppendLine("--- " + step + " failed with exit code " + rc + " ---");
            sb.AppendLine(string.IsNullOrEmpty(output) ? "(no output)" : output);
            File.AppendAllText(path, sb.ToString());
        }
        catch { }
    }

    // Run a child process, streaming its output to this console in real time
    // while capturing it for the diagnostic log. Async event handlers avoid
    // the classic ReadToEnd/WaitForExit deadlock. The 5-arg overload with
    // silent=true still CAPTURES everything but skips the console forwarding —
    // for quiet probes (e.g. `git rev-parse HEAD`) whose stdout is meaningless
    // to the user and would only clutter the update console.
    private static int RunCaptured(string file, string args, string cwd, out string output)
    {
        return RunCaptured(file, args, cwd, false, out output);
    }

    private static int RunCaptured(string file, string args, string cwd, bool silent, out string output)
    {
        var sb = new StringBuilder();
        var psi = new ProcessStartInfo
        {
            FileName = file,
            Arguments = args,
            WorkingDirectory = cwd,
            UseShellExecute = false,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            CreateNoWindow = false
        };
        using (var p = Process.Start(psi))
        {
            p.OutputDataReceived += delegate(object s, DataReceivedEventArgs e)
            {
                if (e.Data != null) { lock (sb) { sb.AppendLine(e.Data); } if (!silent) Console.WriteLine(e.Data); }
            };
            p.ErrorDataReceived += delegate(object s, DataReceivedEventArgs e)
            {
                if (e.Data != null) { lock (sb) { sb.AppendLine(e.Data); } if (!silent) Console.Error.WriteLine(e.Data); }
            };
            p.BeginOutputReadLine();
            p.BeginErrorReadLine();
            p.WaitForExit();
            // .NET 4.0: the FIRST WaitForExit() only guarantees the process
            // handle exited; the async output/error events (Begin*ReadLine)
            // may still be draining their buffers on the thread pool. A second
            // WaitForExit() waits for those event handlers to finish, so by the
            // time we return (and a failure MessageBox pops) no more child
            // output can appear on the console afterwards.
            p.WaitForExit();
            output = sb.ToString();
            return p.ExitCode;
        }
    }

    private static void StopPortableProcesses(string root)
    {
        // Kill only Hermes/python processes whose image lives under this
        // install root; never touch unrelated python.exe processes elsewhere.
        // Powershell's -like wildcard treats backslashes as literals, so the
        // root path is used as-is. Must stay .NET 4.0 csc-safe.
        try
        {
            string safeRoot = root.Replace("'", "''");
            // Directory-boundary match: root has no trailing separator
            // (BaseDirectory was TrimEnd'd), so a bare -like '<root>*' would
            // ALSO match a DIFFERENT install whose path merely begins with this
            // root (e.g. "...-Portable-2\..." or "...-Portable-Beta\...") and
            // kill its live Hermes/python — same bug class as IsForeignServe's
            // bare StartsWith. Prefer StartsWith over -like so a '[' in the
            // path cannot act as a wildcard either.
            string ps = "Get-Process Hermes,python -ErrorAction SilentlyContinue | " +
                        "Where-Object { $_.Path.StartsWith('" + safeRoot + "\\', [System.StringComparison]::OrdinalIgnoreCase) } | " +
                        "Stop-Process -Force";
            string ignored;
            RunCaptured("powershell.exe", "-NoProfile -ExecutionPolicy Bypass -Command \"" + ps + "\"", root, out ignored);
        }
        catch { }
    }

    private static string FindForeignDashboardPids(string root)
    {
        // wmic.exe is removed on Windows 11 24H2+, so enumerate via PowerShell
        // Get-CimInstance (Win32_Process). Keep every serve/dashboard process
        // whose executable is NOT under this portable root — the official
        // `hermes update` cleanup stops all of them by command-line match, so
        // they must be listed in HERMES_DESKTOP_CHILD_PID to survive. Directory
        // boundary: root has no trailing separator, so compare against
        // '<root>\*' (a bare '<root>*' would also match "...-Portable-2\...").
        string safeRoot = root.Replace("'", "''");
        string ps = "Get-CimInstance Win32_Process | Where-Object { " +
                    "$_.ExecutablePath -and ($_.CommandLine -match 'serve|dashboard') -and " +
                    "($_.ExecutablePath -notlike '" + safeRoot + "\\*') } | " +
                    "ForEach-Object { $_.ProcessId }";
        var psi = new ProcessStartInfo
        {
            FileName = "powershell.exe",
            Arguments = "-NoProfile -ExecutionPolicy Bypass -Command \"" + ps + "\"",
            WorkingDirectory = root,
            UseShellExecute = false,
            RedirectStandardOutput = true,
            CreateNoWindow = true
        };
        var found = new System.Collections.Generic.List<string>();
        try
        {
            string output;
            using (var p = Process.Start(psi)) { output = p.StandardOutput.ReadToEnd(); p.WaitForExit(); }
            foreach (string raw in output.Split('\n'))
            {
                string line = raw.Trim();
                if (line.Length > 0) found.Add(line);
            }
        }
        catch { }
        return string.Join(",", found.ToArray());
    }
    private static string Quote(string value) { return "\"" + value.Replace("\"", "\\\"") + "\""; }

    // Best-effort source commit probe. rev-parse failures surface as stderr
    // inside the captured output, so both the "before" and "after" probes
    // fail identically and the caller's equality check stays conservative.
    // Runs SILENT: the hash is meaningless to the user on the update console.
    private static string RunGitHead(string gitExe, string repoDir, string cwd)
    {
        try
        {
            string head;
            RunCaptured(gitExe, "-C " + Quote(repoDir) + " rev-parse HEAD", cwd, true, out head);
            return head == null ? "" : head.Trim();
        }
        catch { return ""; }
    }
}
