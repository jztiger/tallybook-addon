using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading.Tasks;

namespace Tallybook.Tray
{
    public enum TrayState
    {
        /// <summary>Green: nothing waiting, nothing wrong.</summary>
        Ok,
        /// <summary>Yellow: the server could not be reached, or asked us to wait. It will try again by itself.</summary>
        Retrying,
        /// <summary>Red: it will not fix itself - the folder is gone, or the credentials are refused.</summary>
        NeedsAttention,
        /// <summary>Grey: the person paused it.</summary>
        Paused,
    }

    public sealed class CycleReport
    {
        public int Uploaded { get; set; }
        public int Rejected { get; set; }
        public int Wrote { get; set; }
        /// <summary>The addon version installed this pass, or null when nothing was installed.</summary>
        public string? AddonInstalled { get; set; }
        /// <summary>The server sent a different list of product folders; it is in the config now, to be saved.</summary>
        public bool ProductsChanged { get; set; }
        public TrayState State { get; set; } = TrayState.Ok;
        /// <summary>Plain words for the tooltip when the state is not Ok.</summary>
        public string Reason { get; set; } = "";
    }

    /// <summary>
    /// One pass: send every saved file that is quiet and new, then - when "Bring data back" is on - fetch the data
    /// file and put it where the addon's own Data.lua already is. The shell calls this every two seconds; it does
    /// nothing at all most of the time.
    /// </summary>
    public sealed class Cycle
    {
        public static readonly TimeSpan FetchEvery = TimeSpan.FromMinutes(30);
        /// <summary>An addon version comes out rarely; the check is cheap but there is no point being eager.</summary>
        public static readonly TimeSpan AddonEvery = TimeSpan.FromHours(6);
        /// <summary>The server's own cap on a saved file. A bigger one is not ours.</summary>
        private const long MaxSavedBytes = 64L * 1024 * 1024;
        private static readonly Regex PricesAt = new Regex(@"\bpricesAt = (\d{9,11}),", RegexOptions.CultureInvariant);

        private readonly TrayConfig config;
        private readonly ServerClient client;
        private readonly SentLog sent;
        private readonly Stability stability;
        private readonly TrayLog log;
        private readonly Func<DateTime> nowUtc;
        private readonly Backoff backoff = new Backoff();
        private readonly Dictionary<string, (long length, DateTime modified, string sha)> hashed =
            new Dictionary<string, (long, DateTime, string)>(StringComparer.OrdinalIgnoreCase);

        private DateTime notBeforeUtc = DateTime.MinValue;
        private bool refused;
        private string? etag;
        private byte[]? lastLua;
        private string? addonEtag;
        private DateTime? addonCheckedUtc;
        private bool addonUnsure;

        public DateTime? LastUploadUtc { get; private set; }
        public DateTime? LastFetchUtc { get; private set; }
        /// <summary>When the prices in the data file were scanned, for "prices from 3h ago".</summary>
        public DateTime? PricesAtUtc { get; private set; }

        public Cycle(TrayConfig config, ServerClient client, SentLog sent, Stability stability, TrayLog log, Func<DateTime> nowUtc)
        {
            this.config = config;
            this.client = client;
            this.sent = sent;
            this.stability = stability;
            this.log = log;
            this.nowUtc = nowUtc;
            log.Hide(config.ClientSecret, config.UploadKey);
        }

        /// <param name="force">The person asked ("Upload now"): forget a refusal and any waiting, and fetch whatever the clock says.</param>
        public async Task<CycleReport> RunAsync(bool force)
        {
            var report = new CycleReport();
            DateTime now = nowUtc();

            if (config.Paused) return Done(report, TrayState.Paused, "Paused");
            if (!GameFolders.LooksLikeWow(config.WowFolder))
                return Done(report, TrayState.NeedsAttention, "The World of Warcraft folder is not there");
            if (force)
            {
                refused = false;
                notBeforeUtc = DateTime.MinValue;
            }
            if (refused) return Done(report, TrayState.NeedsAttention, "The server refused this PC's credentials");
            if (now < notBeforeUtc) return Done(report, TrayState.Retrying, "Cannot reach the server - trying again soon");

            foreach (FileInfo file in QuietSavedFiles(now))
            {
                byte[] bytes;
                try { bytes = ReadShared(file.FullName); }
                catch (IOException) { continue; }
                catch (UnauthorizedAccessException) { continue; }
                string sha = HashOf(file, bytes);
                if (sent.Has(sha)) continue;

                (SendResult result, int retryAfter) = await client.SendAsync(Payload.Gzip(bytes)).ConfigureAwait(false);
                string what = file.Name + " (" + bytes.Length + " bytes, sha " + sha.Substring(0, 8) + ")";
                switch (result)
                {
                    case SendResult.Sent:
                        sent.Add(sha);
                        report.Uploaded++;
                        LastUploadUtc = now;
                        log.Write("sent " + what);
                        break;
                    case SendResult.Rejected:
                        sent.Add(sha);
                        report.Rejected++;
                        log.Write("the server would not take " + what + ": " + client.LastError + " - it will not be sent again");
                        break;
                    case SendResult.Refused:
                        refused = true;
                        log.Write("refused: " + client.LastError + " - stopped until asked again");
                        return Done(report, TrayState.NeedsAttention, "The server refused this PC's credentials");
                    case SendResult.Later:
                        return Wait(report, now, TimeSpan.FromSeconds(retryAfter), "asked to wait " + retryAfter + " s");
                    default:
                        return Wait(report, now, backoff.Next(), client.LastError);
                }
            }

            // Before the data file, so a fresh install's empty Data.lua is filled in this same pass. Also when updates
            // are switched off: the manifest is where the product folders come from (nothing is installed then).
            string? stop = await KeepAddonCurrent(report, now, force).ConfigureAwait(false);
            if (stop != null)
            {
                refused = true;
                log.Write("refused: " + stop + " - stopped until asked again");
                return Done(report, TrayState.NeedsAttention, "The server refused this PC's credentials");
            }

            bool due = LastFetchUtc == null || now - LastFetchUtc.Value >= FetchEvery;
            if (config.BringDataBack && (report.Uploaded > 0 || force || due))
            {
                (FetchResult result, byte[]? lua, string? tag) = await client.FetchDataFileAsync(etag).ConfigureAwait(false);
                switch (result)
                {
                    case FetchResult.Changed:
                        lastLua = lua;
                        etag = tag;
                        LastFetchUtc = now;
                        ReadPricesAt(lua!);
                        break;
                    case FetchResult.NotModified:
                        LastFetchUtc = now;
                        break;
                    case FetchResult.Refused:
                        refused = true;
                        log.Write("refused: " + client.LastError + " - stopped until asked again");
                        return Done(report, TrayState.NeedsAttention, "The server refused this PC's credentials");
                    default:
                        return Wait(report, now, backoff.Next(), client.LastError);
                }
                if (lastLua != null && !PutInPlace(lastLua, report)) return Wait(report, now, backoff.Next(), "Data.lua could not be written");
            }

            backoff.Reset();
            return report;
        }

        /// <summary>
        /// Learns the product folders from the manifest, and - when that is switched on - installs the addon when it
        /// is missing and replaces it when a newer version is published. Returns null normally, or the reason when
        /// the server refused this PC - anything else is logged and let go, because a server with no addon to offer
        /// must not stop the uploads.
        /// </summary>
        private async Task<string?> KeepAddonCurrent(CycleReport report, DateTime now, bool force)
        {
            bool install = config.KeepAddonUpToDate;
            // Where it already is - those get replaced. Only when it is nowhere does a first install pick a folder,
            // and then never on a guess: a Forever addon does not belong in somebody's retail game.
            IReadOnlyList<string> folders = GameFolders.AddonFolders(config.WowFolder, config.Products);
            bool missing = folders.Count == 0;
            bool canPlace = !missing || GameFolders.InstallTarget(config.WowFolder, config.Products) != null;
            bool due = force || addonCheckedUtc == null || now - addonCheckedUtc.Value >= AddonEvery;
            // A missing addon with somewhere to go is fetched at once. Everything else waits for the cadence - also a
            // PC where none of the listed folders is there, which asks only to learn whether the list has changed.
            if (!due && !(install && missing && canPlace)) return null;

            // A missing addon has to be fetched whole, whatever our etag says about the last one we saw.
            (FetchResult result, AddonManifest? manifest, string? tag) =
                await client.FetchAddonAsync(install && missing && canPlace ? null : addonEtag).ConfigureAwait(false);
            addonCheckedUtc = now;
            if (result == FetchResult.Refused) return client.LastError;
            if (result == FetchResult.NotModified) return null;
            if (result != FetchResult.Changed || manifest == null)
            {
                log.Write("no addon to install this time: " + client.LastError);
                return null;
            }

            IReadOnlyList<string> products = ForeverProducts.Choose(config.Products, manifest.Products);
            if (!ForeverProducts.Same(products, config.Products))
            {
                config.Products = products;
                report.ProductsChanged = true;
                addonUnsure = false;
                log.Write("the game's folders are now " + string.Join(", ", products)); // checked names: safe to log
            }
            // An etag stands for "acted on": with installing switched off, the next manifest must still be read whole
            // once it is switched back on.
            if (!install) return null;
            addonEtag = tag;

            folders = GameFolders.AddonFolders(config.WowFolder, config.Products);
            if (folders.Count == 0)
            {
                string? fresh = GameFolders.InstallTarget(config.WowFolder, config.Products);
                if (fresh == null)
                {
                    if (!addonUnsure)
                    {
                        addonUnsure = true;
                        log.Write("the addon is not installed and none of the game's folders (" + string.Join(", ", config.Products) + ") is here - install it once yourself");
                    }
                    return null;
                }
                folders = new[] { fresh };
            }

            foreach (string folder in folders)
            {
                if (AddonInstaller.InstalledVersion(folder) == manifest.Version) continue;
                try
                {
                    log.Write(AddonInstaller.Install(folder, manifest));
                    report.AddonInstalled = manifest.Version;
                }
                catch (Exception e) when (e is IOException || e is UnauthorizedAccessException || e is InvalidOperationException)
                {
                    log.Write("could not install the addon: " + e.Message);
                }
            }
            return null;
        }

        private IEnumerable<FileInfo> QuietSavedFiles(DateTime now)
        {
            var quiet = new List<FileInfo>();
            foreach (string path in GameFolders.SavedFiles(config.WowFolder, config.Products))
            {
                try
                {
                    var info = new FileInfo(path);
                    if (!info.Exists || info.Length == 0 || info.Length > MaxSavedBytes) continue;
                    if (stability.IsStable(path, info.Length, info.LastWriteTimeUtc, now)) quiet.Add(info);
                }
                catch (IOException) { }
                catch (UnauthorizedAccessException) { }
            }
            return quiet.OrderByDescending(f => f.LastWriteTimeUtc);
        }

        /// <summary>Hashed once per version of the file, not every two seconds.</summary>
        private string HashOf(FileInfo file, byte[] bytes)
        {
            if (hashed.TryGetValue(file.FullName, out var h) && h.length == file.Length && h.modified == file.LastWriteTimeUtc) return h.sha;
            string sha = Payload.Sha256Hex(bytes);
            hashed[file.FullName] = (file.Length, file.LastWriteTimeUtc, sha);
            return sha;
        }

        /// <summary>Every Data.lua that already exists and differs. False when one could not be written.</summary>
        private bool PutInPlace(byte[] lua, CycleReport report)
        {
            bool ok = true;
            foreach (string path in GameFolders.DataFiles(config.WowFolder, config.Products))
            {
                try
                {
                    if (ReadShared(path).SequenceEqual(lua)) continue;
                    AtomicFile.Write(path, lua);
                    report.Wrote++;
                    log.Write("wrote Data.lua (" + lua.Length + " bytes)");
                }
                catch (Exception e) when (e is IOException || e is UnauthorizedAccessException)
                {
                    ok = false;
                    log.Write("could not write Data.lua: " + e.GetType().Name);
                }
            }
            return ok;
        }

        private void ReadPricesAt(byte[] lua)
        {
            Match m = PricesAt.Match(Encoding.UTF8.GetString(lua));
            PricesAtUtc = m.Success && long.TryParse(m.Groups[1].Value, out long at)
                ? new DateTime(1970, 1, 1, 0, 0, 0, DateTimeKind.Utc).AddSeconds(at)
                : (DateTime?)null;
        }

        private static byte[] ReadShared(string path)
        {
            using (var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete))
            using (var buffer = new MemoryStream())
            {
                stream.CopyTo(buffer);
                return buffer.ToArray();
            }
        }

        private CycleReport Wait(CycleReport report, DateTime now, TimeSpan wait, string why)
        {
            notBeforeUtc = now + wait;
            log.Write("waiting " + (int)wait.TotalSeconds + " s: " + why);
            return Done(report, TrayState.Retrying, "Cannot reach the server - trying again soon");
        }

        private static CycleReport Done(CycleReport report, TrayState state, string reason)
        {
            report.State = state;
            report.Reason = reason;
            return report;
        }
    }
}
