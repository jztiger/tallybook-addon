using System;
using System.IO;
using System.Text;
using System.Text.RegularExpressions;

namespace Tallybook.Tray
{
    /// <summary>
    /// The only writer into the game folder besides Data.lua. It writes a whole addon or none of it: everything goes
    /// into a temp folder beside the target, is read back and re-hashed there, and only then takes the target's
    /// place. A failure leaves exactly what was there before, and no temp folder.
    /// </summary>
    public static class AddonInstaller
    {
        public const int MaxFiles = 40;
        public const int MaxFileBytes = 1024 * 1024;
        public const int MaxTotalBytes = 8 * 1024 * 1024;

        /// <summary>The player's own prices live here; an update must never throw them away.</summary>
        private const string DataFile = "Data.lua";
        private static readonly Regex VersionLine = new Regex(@"^## Version:\s*(\S+)\s*$", RegexOptions.Multiline | RegexOptions.CultureInvariant);

        /// <summary>What is installed at <paramref name="addonFolder"/>, or null when there is no addon there.</summary>
        public static string? InstalledVersion(string addonFolder)
        {
            try
            {
                string toc = Path.Combine(addonFolder, "Tallybook.toc");
                if (!File.Exists(toc)) return null;
                Match m = VersionLine.Match(File.ReadAllText(toc, Encoding.UTF8));
                return m.Success ? m.Groups[1].Value : null;
            }
            catch (Exception e) when (e is IOException || e is UnauthorizedAccessException || e is ArgumentException)
            {
                return null;
            }
        }

        /// <summary>
        /// Installs <paramref name="manifest"/> at <paramref name="addonFolder"/>, whole or not at all. Throws with
        /// a plain reason when the manifest is refused or the swap cannot be made. Returns a line for the log.
        /// </summary>
        public static string Install(string addonFolder, AddonManifest manifest)
        {
            string? why = AddonManifest.Reject(manifest);
            if (why != null) throw new InvalidOperationException("the addon was refused: " + why);

            string parent = Path.GetDirectoryName(Path.GetFullPath(addonFolder))
                ?? throw new InvalidOperationException("the addon folder has no parent");
            string name = Path.GetFileName(Path.GetFullPath(addonFolder));
            string stamp = Guid.NewGuid().ToString("N").Substring(0, 8);
            string staged = Path.Combine(parent, name + ".new-" + stamp);
            string aside = Path.Combine(parent, name + ".old-" + stamp);
            bool had = Directory.Exists(addonFolder);

            try
            {
                Directory.CreateDirectory(staged);
                foreach (AddonFile f in manifest.Files)
                {
                    // Combine only ever sees a name Reject has already approved; this is the second lock.
                    string path = Path.Combine(staged, f.Name);
                    if (Path.GetDirectoryName(Path.GetFullPath(path)) != Path.GetFullPath(staged))
                        throw new InvalidOperationException("the addon was refused: \"" + f.Name + "\" would land outside the folder");
                    File.WriteAllText(path, f.Content, new UTF8Encoding(false));
                }
                // Read back what is actually on the disk, not what we meant to write.
                foreach (AddonFile f in manifest.Files)
                {
                    if (AddonManifest.Hash(File.ReadAllText(Path.Combine(staged, f.Name), Encoding.UTF8)) != f.Sha256.ToLowerInvariant())
                        throw new IOException("\"" + f.Name + "\" did not survive being written");
                }
                // The player's own prices come across an update; only a fresh install keeps the manifest's empty one.
                string installedData = Path.Combine(addonFolder, DataFile);
                if (had && File.Exists(installedData)) File.Copy(installedData, Path.Combine(staged, DataFile), true);
            }
            catch (Exception)
            {
                Discard(staged);
                throw;
            }

            if (had)
            {
                Directory.Move(addonFolder, aside);
                try
                {
                    Directory.Move(staged, addonFolder);
                }
                catch (Exception)
                {
                    Directory.Move(aside, addonFolder); // put back what was there
                    Discard(staged);
                    throw;
                }
                Discard(aside);
            }
            else
            {
                try
                {
                    Directory.Move(staged, addonFolder);
                }
                catch (Exception)
                {
                    Discard(staged);
                    throw;
                }
            }
            return (had ? "updated" : "installed") + " the addon, version " + manifest.Version + ", " + manifest.Files.Count + " files";
        }

        private static void Discard(string folder)
        {
            try { if (Directory.Exists(folder)) Directory.Delete(folder, true); }
            catch (IOException) { }
            catch (UnauthorizedAccessException) { }
        }
    }
}
