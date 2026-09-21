using System;
using System.Drawing;
using System.IO;
using System.Reflection;
using System.Windows.Forms;

namespace Tallybook.Tray
{
    /// <summary>
    /// First run and Settings are the same window: the notice, the folder the person picks (never detected, never
    /// guessed - C4), and the two switches. On first run nothing starts until "I understand" is ticked.
    /// </summary>
    internal sealed class SetupForm : Form
    {
        private readonly TextBox folder = new TextBox { ReadOnly = true, Anchor = AnchorStyles.Left | AnchorStyles.Right | AnchorStyles.Top };
        private readonly Label folderHint = new Label { AutoSize = true, ForeColor = Color.Firebrick };
        private readonly CheckBox understand = new CheckBox { AutoSize = true, Text = "I have read this and I understand the risk" };
        private readonly CheckBox startWithWindows = new CheckBox { AutoSize = true, Text = "Start with Windows" };
        private readonly CheckBox bringDataBack = new CheckBox { AutoSize = true, Text = "Bring data back (write the shared Data.lua into the Tallybook addon's folder)" };
        private readonly CheckBox keepAddon = new CheckBox { AutoSize = true, Text = "Keep the Tallybook addon installed and up to date" };
        private readonly Button ok = new Button { Text = "OK", DialogResult = DialogResult.OK, Width = 90 };

        /// <summary>Settings only: the credentials of a settings file the person loaded here; null when they did not.</summary>
        public TrayConfig? NewCredentials { get; private set; }

        public SetupForm(TrayConfig config, bool firstRun)
        {
            Text = firstRun ? "Tallybook - before you start" : "Tallybook - settings";
            StartPosition = FormStartPosition.CenterScreen;
            FormBorderStyle = FormBorderStyle.FixedDialog;
            MaximizeBox = false;
            MinimizeBox = false;
            ShowInTaskbar = true;
            ClientSize = new Size(640, 590);
            Font = SystemFonts.MessageBoxFont;

            var notice = new TextBox
            {
                Multiline = true, ReadOnly = true, ScrollBars = ScrollBars.Vertical, WordWrap = true,
                Text = NoticeText().Replace("\r\n", "\n").Replace("\n", "\r\n"),
                Location = new Point(12, 12), Size = new Size(616, 300), TabStop = false, BackColor = SystemColors.Window,
            };
            notice.Select(0, 0);

            var folderLabel = new Label { AutoSize = true, Text = "Your World of Warcraft folder (the one that holds _classic_beta_ or similar):", Location = new Point(12, 324) };
            folder.Location = new Point(12, 346);
            folder.Size = new Size(516, 24);
            folder.Text = config.WowFolder;
            var browse = new Button { Text = "Browse...", Location = new Point(538, 344), Width = 90 };
            browse.Click += (s, e) => Browse();
            folderHint.Location = new Point(12, 374);

            understand.Location = new Point(12, 404);
            understand.Checked = config.AcceptedNoticeVersion > 0;
            startWithWindows.Location = new Point(12, 436);
            startWithWindows.Checked = config.StartWithWindows;
            bringDataBack.Location = new Point(12, 464);
            bringDataBack.Checked = config.BringDataBack;
            keepAddon.Location = new Point(12, 492);
            keepAddon.Checked = config.KeepAddonUpToDate;

            if (!firstRun)
            {
                // After a new download on the website (each one retires the key before it) the running copy is refused
                // and turns red; this is how it is given the new file without hunting for the folder it lives in.
                var load = new Button { Text = "Load new settings file...", Location = new Point(12, 548), Width = 190 };
                var loaded = new Label { AutoSize = true, Location = new Point(210, 553), ForeColor = Color.SeaGreen };
                load.Click += (s, e) =>
                {
                    TrayConfig? fresh = SettingsFile.Pick(this, new TrayLog(Paths.Log));
                    if (fresh == null) return;
                    NewCredentials = fresh;
                    loaded.Text = "Loaded - press OK";
                };
                Controls.Add(load);
                Controls.Add(loaded);
            }

            ok.Location = new Point(442, 548);
            var cancel = new Button { Text = firstRun ? "Quit" : "Cancel", DialogResult = DialogResult.Cancel, Width = 90, Location = new Point(538, 548) };
            AcceptButton = ok;
            CancelButton = cancel;

            understand.CheckedChanged += (s, e) => Check();
            Controls.AddRange(new Control[] { notice, folderLabel, folder, browse, folderHint, understand, startWithWindows, bringDataBack, keepAddon, ok, cancel });
            Check();
        }

        /// <summary>Copies what the person chose into the config. Call after ShowDialog returned OK.</summary>
        public void ApplyTo(TrayConfig config)
        {
            config.WowFolder = folder.Text;
            config.AcceptedNoticeVersion = understand.Checked ? Notice.VersionOf(NoticeText()) : 0;
            config.StartWithWindows = startWithWindows.Checked;
            config.BringDataBack = bringDataBack.Checked;
            config.KeepAddonUpToDate = keepAddon.Checked;
        }

        public static string NoticeText()
        {
            using (Stream? s = Assembly.GetExecutingAssembly().GetManifestResourceStream("risk-notice.txt"))
            {
                if (s == null) return "";
                using (var reader = new StreamReader(s)) return reader.ReadToEnd();
            }
        }

        private void Browse()
        {
            using (var dialog = new FolderBrowserDialog { Description = "Pick your World of Warcraft folder", ShowNewFolderButton = false })
            {
                if (Directory.Exists(folder.Text)) dialog.SelectedPath = folder.Text;
                if (dialog.ShowDialog(this) == DialogResult.OK) folder.Text = dialog.SelectedPath;
            }
            Check();
        }

        private void Check()
        {
            bool looksRight = GameFolders.LooksLikeWow(folder.Text);
            folderHint.Text = folder.Text.Length == 0 ? "Pick the folder first."
                : looksRight ? ""
                : "That folder has no game inside it (no _classic_beta_ or similar). Pick the folder above it?";
            ok.Enabled = looksRight && understand.Checked;
        }
    }
}
