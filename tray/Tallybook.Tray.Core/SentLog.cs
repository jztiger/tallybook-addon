using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text;

namespace Tallybook.Tray
{
    /// <summary>The SHA-256 of every file already dealt with, so nothing is sent twice - across restarts too.
    /// Hashes only: no path, no time. The newest <c>keep</c> are kept.</summary>
    public sealed class SentLog
    {
        private readonly string file;
        private readonly int keep;
        private readonly List<string> order = new List<string>();
        private readonly HashSet<string> known = new HashSet<string>(StringComparer.Ordinal);

        public SentLog(string file, int keep = 200)
        {
            this.file = file;
            this.keep = Math.Max(1, keep);
            try
            {
                if (!File.Exists(file)) return;
                foreach (string line in File.ReadAllLines(file, Encoding.UTF8))
                {
                    string h = line.Trim();
                    if (h.Length > 0 && h.Length <= 128 && h.All(char.IsLetterOrDigit) && known.Add(h)) order.Add(h);
                }
            }
            catch (IOException) { }
            catch (UnauthorizedAccessException) { }
        }

        public bool Has(string sha256) => known.Contains(sha256);

        public void Add(string sha256)
        {
            if (!known.Add(sha256)) return;
            order.Add(sha256);
            while (order.Count > keep)
            {
                known.Remove(order[0]);
                order.RemoveAt(0);
            }
            string? dir = Path.GetDirectoryName(file);
            if (!string.IsNullOrEmpty(dir)) Directory.CreateDirectory(dir);
            AtomicFile.Write(file, Encoding.UTF8.GetBytes(string.Join("\n", order) + "\n"));
        }
    }
}
