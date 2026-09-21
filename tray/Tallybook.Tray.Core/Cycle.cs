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

        private IEnumerable<FileInfo> QuietSavedFiles(DateTime now)
        {
            var quiet = new List<FileInfo>();
            foreach (string path in GameFolders.SavedFiles(config.WowFolder))
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
            foreach (string path in GameFolders.DataFiles(config.WowFolder))
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
