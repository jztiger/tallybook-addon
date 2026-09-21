using System;
using System.Collections.Generic;
using System.IO;
using System.Text;
using System.Threading;
using System.Windows.Forms;

namespace Tallybook.Tray
{
    internal static class Program
    {
        /// <summary>
        /// No arguments: the tray app. Three headless modes, each of which does its one thing and exits - a
        /// windowed program has no console, so each also writes what it says to the file named with --out:
        ///   --version  [--out f]                          what this build is
        ///   --selftest [--out f]                          proves the Windows-only parts work on this PC (used by CI)
        ///   --once --config f --wow folder [--out f]      one send-and-fetch pass with a plain download file, then exit
        ///                                                 (end-to-end tests; never touches %APPDATA% or the Run key)
        /// </summary>
        [STAThread]
        private static int Main(string[] args)
        {
            Dictionary<string, string> opts = Options(args);
            if (opts.ContainsKey("--version")) return Say(opts, 0, AppInfo.Name + " tray " + AppInfo.Version + " on " + Environment.OSVersion.VersionString + ", .NET Framework " + Environment.Version);
            if (opts.ContainsKey("--selftest")) return SelfTest(opts);
            if (opts.ContainsKey("--once")) return Once(opts);
            if (args.Length > 0) return Say(opts, 1, "usage: Tallybook.exe [--version | --selftest | --once --config <file> --wow <folder>] [--out <file>]");
            return RunTray();
        }

        private static int RunTray()
        {
            Application.EnableVisualStyles();
            Application.SetCompatibleTextRenderingDefault(false);
            if (!SystemInformation.UserInteractive) return 1; // no desktop, no icon: it never runs unseen

            using (var single = new Mutex(true, @"Local\Tallybook.Tray", out bool first))
            {
                if (!first)
                {
                    MessageBox.Show("Tallybook is already running - look for its icon next to the clock.", AppInfo.Name, MessageBoxButtons.OK, MessageBoxIcon.Information);
                    return 0;
                }

                var protector = new Dpapi();
                var log = new TrayLog(Paths.Log);
                TrayConfig? config = LoadConfig(protector, log);
                if (config == null)
                {
                    // Not beside the exe (a browser may have saved it elsewhere, or renamed it "... (1).json"): the
                    // person points at it. Nothing is searched for.
                    MessageBox.Show("Tallybook needs your settings file, tallybook.config.json - the second download on the website.\n\n"
                        + "Press OK and pick it.", AppInfo.Name, MessageBoxButtons.OK, MessageBoxIcon.Information);
                    config = SettingsFile.Pick(null, log);
                    if (config == null) return 1;
                    ConfigStore.Save(Paths.Config, config, protector);
                }

                if (!config.AcceptedNotice || !GameFolders.LooksLikeWow(config.WowFolder))
                {
                    using (var setup = new SetupForm(config, true))
                    {
                        if (setup.ShowDialog() != DialogResult.OK) return 0; // nothing starts without "I understand"
                        setup.ApplyTo(config);
                    }
                    ConfigStore.Save(Paths.Config, config, protector);
                }

                try { Autostart.Apply(config.StartWithWindows); }
                catch (Exception e) when (e is UnauthorizedAccessException || e is System.Security.SecurityException || e is IOException)
                {
                    log.Write("could not set Start with Windows: " + e.GetType().Name);
                }

                try
                {
                    using (var app = new TrayApp(config, protector, log)) Application.Run(app);
                }
                catch (InvalidOperationException e)
                {
                    log.Write("stopped: " + e.Message);
                    return 1;
                }
                return 0;
            }
        }

        /// <summary>
        /// The saved config, or the download beside the exe. A NEW download wins for the credentials (each download
        /// retires the key of the one before) and keeps the folder and the switches; the plain file is then deleted.
        /// </summary>
        private static TrayConfig? LoadConfig(ISecretProtector protector, TrayLog log)
        {
            TrayConfig? saved = ConfigStore.Load(Paths.Config, protector);
            TrayConfig? download = null;
            try
            {
                if (File.Exists(Paths.Download)) download = ConfigStore.ImportDownload(File.ReadAllText(Paths.Download, Encoding.UTF8));
            }
            catch (Exception e) when (e is IOException || e is UnauthorizedAccessException)
            {
                log.Write("could not read the download's config: " + e.GetType().Name);
            }
            if (download == null) return saved;

            if (saved != null)
            {
                ConfigStore.ApplyCredentials(saved, download);
                download = saved;
            }
            try
            {
                ConfigStore.Save(Paths.Config, download, protector);
                File.Delete(Paths.Download); // the credentials now live sealed under %APPDATA%; the plain copy goes
                log.Write("took the credentials from the settings file and removed the plain file");
            }
            catch (Exception e) when (e is IOException || e is UnauthorizedAccessException)
            {
                log.Write("could not move the download's config: " + e.GetType().Name);
            }
            return download;
        }

        private static int Once(Dictionary<string, string> opts)
        {
            if (!opts.TryGetValue("--config", out string? configFile) || !opts.TryGetValue("--wow", out string? wow) || configFile.Length == 0 || wow.Length == 0)
                return Say(opts, 1, "--once needs --config <tallybook.config.json> and --wow <folder>");
            TrayConfig? config = File.Exists(configFile) ? ConfigStore.ImportDownload(File.ReadAllText(configFile, Encoding.UTF8)) : null;
            if (config == null) return Say(opts, 1, "that is not a tallybook.config.json");
            config.WowFolder = wow;
            config.AcceptedNotice = true;

            string work = Path.Combine(Path.GetTempPath(), "tallybook-once-" + Guid.NewGuid().ToString("N"));
            Directory.CreateDirectory(work);
            try
            {
                var log = new TrayLog(Path.Combine(work, "log.txt"));
                using (var client = new ServerClient(config, ServerClient.CreateHandler()))
                {
                    var cycle = new Cycle(config, client, new SentLog(Path.Combine(work, "sent.txt")), new Stability(), log, () => DateTime.UtcNow);
                    cycle.RunAsync(false).GetAwaiter().GetResult();          // the first look
                    Thread.Sleep(Stability.Quiet + TimeSpan.FromMilliseconds(500));
                    CycleReport r = cycle.RunAsync(true).GetAwaiter().GetResult(); // quiet now: send, then fetch
                    string line = "uploaded=" + r.Uploaded + " rejected=" + r.Rejected + " wrote=" + r.Wrote + " state=" + r.State
                        + (client.LastError.Length > 0 ? " (" + client.LastError + ")" : "");
                    return Say(opts, r.State == TrayState.Ok ? 0 : r.State == TrayState.NeedsAttention ? 2 : 3, line);
                }
            }
            finally
            {
                try { Directory.Delete(work, true); } catch (IOException) { } catch (UnauthorizedAccessException) { }
            }
        }

        private static int SelfTest(Dictionary<string, string> opts)
        {
            var lines = new List<string>();
            bool ok = true;
            void Check(string name, Func<bool> test)
            {
                bool passed;
                try { passed = test(); }
                catch (Exception e) { passed = false; name += " (" + e.GetType().Name + ")"; }
                lines.Add((passed ? "ok   " : "FAIL ") + name);
                ok &= passed;
            }

            var dpapi = new Dpapi();
            Check("DPAPI seals and opens", () => dpapi.Unprotect(dpapi.Protect("a secret")) == "a secret" && !dpapi.Protect("a secret").Contains("a secret"));
            Check("DPAPI refuses what was altered", () =>
            {
                // The sealed body and its check value, not the blob's descriptive header (which Windows does not check).
                string good = dpapi.Protect("a secret");
                foreach (int at in new[] { good.Length / 2, good.Length * 3 / 4, good.Length - 6 })
                {
                    char[] c = good.ToCharArray();
                    c[at] = c[at] == 'A' ? 'B' : 'A';
                    try { dpapi.Unprotect(new string(c)); return false; }
                    catch (System.Security.Cryptography.CryptographicException) { }
                    catch (FormatException) { }
                }
                return true;
            });
            Check("the config round-trips under DPAPI and holds no secret in the clear", () =>
            {
                string dir = Path.Combine(Path.GetTempPath(), "tallybook-selftest-" + Guid.NewGuid().ToString("N"));
                try
                {
                    string file = Path.Combine(dir, "config.json");
                    TrayConfig c = ConfigStore.ImportDownload("{\"api\":\"https://a.example.com\",\"ui\":\"https://b.example.com\",\"clientId\":\"id\",\"clientSecret\":\"selftest-secret\",\"uploadKey\":\"selftest-key\"}")!;
                    ConfigStore.Save(file, c, dpapi);
                    string text = File.ReadAllText(file);
                    TrayConfig? back = ConfigStore.Load(file, dpapi);
                    return back != null && back.ClientSecret == "selftest-secret" && back.UploadKey == "selftest-key" && !text.Contains("selftest-secret") && !text.Contains("selftest-key");
                }
                finally { try { Directory.Delete(dir, true); } catch (IOException) { } }
            });
            Check("the HTTP client loads and follows no redirects", () =>
            {
                using (var handler = ServerClient.CreateHandler())
                using (new ServerClient(new TrayConfig { Api = "https://a.example.com" }, handler)) return !handler.AllowAutoRedirect;
            });
            Check("gzip", () => Payload.Gzip(Encoding.UTF8.GetBytes(new string('x', 10000))).Length < 200);
            Check("the four tray icons draw", () =>
            {
                foreach (TrayState s in new[] { TrayState.Ok, TrayState.Retrying, TrayState.NeedsAttention, TrayState.Paused }) if (Icons.For(s).Width <= 0) return false;
                return true;
            });
            Check("the risk notice is inside", () => SetupForm.Notice().Contains("THE RISK") && SetupForm.Notice().Contains("not made, approved or supported by Blizzard"));

            lines.Add(ok ? "selftest ok" : "selftest FAILED");
            return Say(opts, ok ? 0 : 1, string.Join(Environment.NewLine, lines));
        }

        private static Dictionary<string, string> Options(string[] args)
        {
            var opts = new Dictionary<string, string>(StringComparer.Ordinal);
            for (int i = 0; i < args.Length; i++)
            {
                if (!args[i].StartsWith("--", StringComparison.Ordinal)) continue;
                bool hasValue = i + 1 < args.Length && !args[i + 1].StartsWith("--", StringComparison.Ordinal);
                opts[args[i]] = hasValue ? args[++i] : "";
            }
            return opts;
        }

        private static int Say(Dictionary<string, string> opts, int exitCode, string text)
        {
            Console.Out.WriteLine(text);
            if (opts.TryGetValue("--out", out string? file) && file.Length > 0)
            {
                try { File.WriteAllText(file, text + Environment.NewLine); }
                catch (Exception e) when (e is IOException || e is UnauthorizedAccessException) { return exitCode == 0 ? 1 : exitCode; }
            }
            return exitCode;
        }
    }
}
