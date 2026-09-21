using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Text;

namespace Tallybook.Tray
{
    /// <summary>
    /// A small text log the person can open from the menu. It rotates (one older file is kept), it blanks out
    /// anything it was told to hide, and a log that cannot be written never stops the program.
    /// </summary>
    public sealed class TrayLog
    {
        private readonly string file;
        private readonly long maxBytes;
        private readonly Func<DateTime> nowUtc;
        private readonly List<string> hidden = new List<string>();
        private readonly object gate = new object();

        public TrayLog(string file, long maxBytes = 512 * 1024, Func<DateTime>? nowUtc = null)
        {
            this.file = file;
            this.maxBytes = maxBytes;
            this.nowUtc = nowUtc ?? (() => DateTime.UtcNow);
        }

        public string FilePath => file;

        /// <summary>Text that must never appear in the log (the credentials), whatever a caller passes to Write.</summary>
        public void Hide(params string[] secrets)
        {
            lock (gate)
            {
                foreach (string s in secrets) if (!string.IsNullOrEmpty(s) && s.Length >= 4) hidden.Add(s);
            }
        }

        public void Write(string line)
        {
            lock (gate)
            {
                try
                {
                    foreach (string s in hidden) line = line.Replace(s, "[hidden]");
                    string text = nowUtc().ToString("yyyy-MM-dd HH:mm:ss'Z'", CultureInfo.InvariantCulture) + " " + line.Replace('\r', ' ').Replace('\n', ' ') + Environment.NewLine;
                    string? dir = Path.GetDirectoryName(file);
                    if (!string.IsNullOrEmpty(dir)) Directory.CreateDirectory(dir);
                    var info = new FileInfo(file);
                    if (info.Exists && info.Length + text.Length > maxBytes)
                    {
                        string older = Path.Combine(dir ?? "", Path.GetFileNameWithoutExtension(file) + ".1" + Path.GetExtension(file));
                        if (File.Exists(older)) File.Delete(older);
                        File.Move(file, older);
                    }
                    File.AppendAllText(file, text, new UTF8Encoding(false));
                }
                catch (Exception)
                {
                    // Deliberately everything: a full disk, a locked file or a bad path must never take the tray app down.
                }
            }
        }
    }
}
