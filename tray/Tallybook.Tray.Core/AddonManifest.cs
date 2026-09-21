using System;
using System.Collections.Generic;
using System.Runtime.Serialization;
using System.Security.Cryptography;
using System.Text;
using System.Text.RegularExpressions;

namespace Tallybook.Tray
{
    /// <summary>
    /// The plain-words notice every member reads before installing. It carries its own version so that changing
    /// what the program does brings the notice back in front of the people who accepted an older one.
    /// </summary>
    public static class Notice
    {
        /// <summary>The version on the notice's first line, or 0 when it has none.</summary>
        public static int VersionOf(string? noticeText)
        {
            Match m = Regex.Match(noticeText ?? "", @"^Tallybook notice, version ([0-9]{1,4})\s*$", RegexOptions.Multiline | RegexOptions.CultureInvariant);
            return m.Success && int.TryParse(m.Groups[1].Value, out int v) ? v : 0;
        }
    }

/// <summary>One file of the addon, as the server sends it: a plain name, its SHA-256, and its text.</summary>
    [DataContract]
    public sealed class AddonFile
    {
        [DataMember(Name = "name")] public string Name { get; set; } = "";
        [DataMember(Name = "sha256")] public string Sha256 { get; set; } = "";
        [DataMember(Name = "content")] public string Content { get; set; } = "";
    }

    /// <summary>
    /// The addon as the server sends it (GET /api/v1/addon). This will be written into somebody's game folder, so
    /// <see cref="Reject"/> is the gate: nothing here is trusted because the server said it, and a manifest that
    /// does not add up is refused whole rather than installed in part.
    /// </summary>
    [DataContract]
    public sealed class AddonManifest
    {
        /// <summary>A plain file name and nothing else: no folder, no separator, no dots but the one.</summary>
        private static readonly Regex PlainName = new Regex(@"^[A-Za-z][A-Za-z0-9]*\.(lua|toc)$", RegexOptions.CultureInvariant);
        private static readonly Regex PlainVersion = new Regex(@"^[0-9]{1,4}(\.[0-9]{1,4}){0,3}$", RegexOptions.CultureInvariant);

        [DataMember(Name = "version")] public string Version { get; set; } = "";
        [DataMember(Name = "files")] public List<AddonFile> Files { get; set; } = new List<AddonFile>();

        /// <summary>A plain addon file name and nothing else. Checked before a name is ever used as a path.</summary>
        public static bool IsPlainName(string? name) => name != null && PlainName.IsMatch(name);

        /// <summary>The "## Version:" line of a .toc, or null.</summary>
        public static string? VersionOfToc(string toc)
        {
            Match m = Regex.Match(toc ?? "", @"^## Version:\s*(\S+)\s*$", RegexOptions.Multiline | RegexOptions.CultureInvariant);
            return m.Success && PlainVersion.IsMatch(m.Groups[1].Value) ? m.Groups[1].Value : null;
        }

        /// <summary>Null when it is safe to install; otherwise why it is not - plain words, safe to log.</summary>
        public static string? Reject(AddonManifest? m)
        {
            if (m == null) return "no manifest";
            if (!PlainVersion.IsMatch(m.Version ?? "")) return "the version is not a version";
            if (m.Files == null || m.Files.Count == 0) return "it holds no files";
            if (m.Files.Count > AddonInstaller.MaxFiles) return "it holds more than " + AddonInstaller.MaxFiles + " files";

            var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            int tocs = 0;
            long total = 0;
            foreach (AddonFile f in m.Files)
            {
                string name = f?.Name ?? "";
                // Whatever the server said, only a plain addon file name is ever written.
                if (!PlainName.IsMatch(name)) return "\"" + Safe(name) + "\" is not a plain addon file name";
                if (!seen.Add(name)) return "\"" + name + "\" is in it twice";
                if (name.EndsWith(".toc", StringComparison.OrdinalIgnoreCase)) tocs++;
                if (f!.Content == null) return "\"" + name + "\" has no content";
                int bytes = Encoding.UTF8.GetByteCount(f.Content);
                if (bytes > AddonInstaller.MaxFileBytes) return "\"" + name + "\" is larger than " + AddonInstaller.MaxFileBytes + " bytes";
                total += bytes;
                if (!string.Equals(Hash(f.Content), f.Sha256, StringComparison.OrdinalIgnoreCase)) return "\"" + name + "\" does not match its hash";
            }
            if (tocs != 1) return tocs == 0 ? "it has no .toc" : "it has more than one .toc";
            if (total > AddonInstaller.MaxTotalBytes) return "it is larger than " + AddonInstaller.MaxTotalBytes + " bytes in total";
            return null;
        }

        public static string Hash(string content)
        {
            using (SHA256 sha = SHA256.Create())
            {
                var hex = new StringBuilder(64);
                foreach (byte b in sha.ComputeHash(Encoding.UTF8.GetBytes(content))) hex.Append(b.ToString("x2"));
                return hex.ToString();
            }
        }

        /// <summary>A name is somebody else's text: it never reaches a log or a message with control characters in it.</summary>
        private static string Safe(string name)
        {
            var clean = new StringBuilder(Math.Min(name.Length, 40));
            foreach (char c in name.Substring(0, Math.Min(name.Length, 40))) clean.Append(c < 0x20 || c > 0x7e ? '?' : c);
            return clean.ToString();
        }
    }
}
