using System;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.Threading.Tasks;
using System.Windows.Forms;

namespace Tallybook.Tray
{
    /// <summary>
    /// The resident part: a tray icon that is always visible while this runs, a menu, and a two-second timer that
    /// asks the core for one pass. It never runs unseen: if the icon cannot be shown, it exits.
    /// </summary>
    internal sealed class TrayApp : ApplicationContext
    {
        private readonly TrayConfig config;
        private readonly ISecretProtector protector;
        private readonly TrayLog log;
        private readonly ServerClient client;
        private readonly Cycle cycle;
        private readonly NotifyIcon icon;
        private readonly ToolStripMenuItem pauseItem = new ToolStripMenuItem("Pause");
        private readonly ToolStripMenuItem updateItem = new ToolStripMenuItem("") { Visible = false };
        private readonly Timer timer = new Timer { Interval = 2000 };
        private bool busy;
        private bool forceNext;
        private DateTime versionCheckedUtc = DateTime.MinValue;
        private TrayState state = TrayState.Ok;
        private string reason = "";

        public TrayApp(TrayConfig config, ISecretProtector protector, TrayLog log)
        {
            this.config = config;
            this.protector = protector;
            this.log = log;
            client = new ServerClient(config, ServerClient.CreateHandler());
            cycle = new Cycle(config, client, new SentLog(Paths.Sent), new Stability(), log, () => DateTime.UtcNow);

            var menu = new ContextMenuStrip();
            menu.Items.Add("Open Tallybook", null, (s, e) => OpenWebsite());
            menu.Items.Add(updateItem);
            menu.Items.Add(new ToolStripSeparator());
            menu.Items.Add("Upload now", null, (s, e) => { forceNext = true; });
            menu.Items.Add(pauseItem);
            menu.Items.Add("Settings...", null, (s, e) => ShowSettings());
            menu.Items.Add("View log", null, (s, e) => OpenLog());
            menu.Items.Add(new ToolStripSeparator());
            menu.Items.Add("Quit", null, (s, e) => Quit());
            pauseItem.Click += (s, e) => TogglePause();
            updateItem.Click += (s, e) => OpenWebsite();

            icon = new NotifyIcon { ContextMenuStrip = menu, Icon = Icons.For(config.Paused ? TrayState.Paused : TrayState.Ok), Text = "Tallybook", Visible = true };
            icon.DoubleClick += (s, e) => OpenWebsite();
            if (!icon.Visible) throw new InvalidOperationException("the tray icon could not be shown");

            Show(config.Paused ? TrayState.Paused : TrayState.Ok, "");
            log.Write("started " + AppInfo.Name + " tray " + AppInfo.Version);
            timer.Tick += async (s, e) => await Tick();
            timer.Start();
            forceNext = true; // the first pass fetches whatever the clock says
        }

        private async Task Tick()
        {
            if (busy) return;
            busy = true;
            try
            {
                bool force = forceNext;
                forceNext = false;
                CycleReport report = await Task.Run(() => cycle.RunAsync(force));
                Show(report.State, report.Reason);

                if (!config.Paused && DateTime.UtcNow - versionCheckedUtc > TimeSpan.FromHours(24))
                {
                    versionCheckedUtc = DateTime.UtcNow;
                    string? offered = await Task.Run(() => client.LatestVersionAsync());
                    if (ServerClient.IsNewer(AppInfo.Version, offered))
                    {
                        // Shown, never fetched: the person downloads it from the website themselves.
                        updateItem.Text = "Version " + offered + " is available - open the website";
                        updateItem.Visible = true;
                    }
                }
            }
            catch (Exception e)
            {
                log.Write("a pass failed: " + e.GetType().Name);
                Show(TrayState.Retrying, "Something went wrong - see the log");
            }
            finally
            {
                busy = false;
            }
        }

        private void Show(TrayState newState, string newReason)
        {
            state = newState;
            reason = newReason;
            icon.Icon = Icons.For(state);
            pauseItem.Text = config.Paused ? "Resume" : "Pause";

            string text;
            if (state == TrayState.Ok)
            {
                text = "Tallybook - up to date";
                if (cycle.LastUploadUtc != null) text += ". Sent " + Ago(cycle.LastUploadUtc.Value);
                if (cycle.PricesAtUtc != null) text += "; prices " + Ago(cycle.PricesAtUtc.Value);
            }
            else
            {
                text = "Tallybook - " + reason;
            }
            icon.Text = text.Length > 63 ? text.Substring(0, 62) + "…" : text; // Windows allows 63 characters
        }

        private static string Ago(DateTime utc)
        {
            TimeSpan t = DateTime.UtcNow - utc;
            if (t.TotalMinutes < 1) return "just now";
            if (t.TotalHours < 1) return (int)t.TotalMinutes + "m ago";
            if (t.TotalDays < 1) return (int)t.TotalHours + "h ago";
            return (int)t.TotalDays + "d ago";
        }

        private void TogglePause()
        {
            config.Paused = !config.Paused;
            Save();
            log.Write(config.Paused ? "paused" : "resumed");
            forceNext = !config.Paused;
            Show(config.Paused ? TrayState.Paused : TrayState.Ok, config.Paused ? "Paused" : "");
        }

        private void ShowSettings()
        {
            using (var form = new SetupForm(config, false))
            {
                if (form.ShowDialog() != DialogResult.OK) return;
                form.ApplyTo(config);
                if (form.NewCredentials != null)
                {
                    // In place: the client and the pass read this object at their next request.
                    ConfigStore.ApplyCredentials(config, form.NewCredentials);
                    log.Hide(config.ClientSecret, config.UploadKey);
                    log.Write("new credentials loaded");
                }
            }
            Save();
            try { Autostart.Apply(config.StartWithWindows); }
            catch (Exception e) when (e is UnauthorizedAccessException || e is System.Security.SecurityException || e is IOException)
            {
                log.Write("could not change Start with Windows: " + e.GetType().Name);
            }
            forceNext = true;
        }

        private void Save()
        {
            try { ConfigStore.Save(Paths.Config, config, protector); }
            catch (Exception e) when (e is IOException || e is UnauthorizedAccessException)
            {
                log.Write("could not save the settings: " + e.GetType().Name);
            }
        }

        private void OpenWebsite() { Start(config.Ui); }

        private void OpenLog()
        {
            if (!File.Exists(log.FilePath)) log.Write("the log was opened");
            Start(log.FilePath);
        }

        /// <summary>Hands a website address or the log file to Windows to open. Nothing else is ever started.</summary>
        private void Start(string what)
        {
            try { Process.Start(new ProcessStartInfo(what) { UseShellExecute = true }); }
            catch (Exception e) when (e is System.ComponentModel.Win32Exception || e is InvalidOperationException || e is FileNotFoundException)
            {
                log.Write("could not open it: " + e.GetType().Name);
            }
        }

        private void Quit()
        {
            timer.Stop();
            icon.Visible = false;
            log.Write("quit");
            ExitThread();
        }

        protected override void Dispose(bool disposing)
        {
            if (disposing)
            {
                timer.Dispose();
                icon.Dispose();
                client.Dispose();
            }
            base.Dispose(disposing);
        }
    }
}
