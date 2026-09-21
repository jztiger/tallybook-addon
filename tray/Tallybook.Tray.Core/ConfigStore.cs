using System;
using System.IO;
using System.Runtime.Serialization;
using System.Text;

namespace Tallybook.Tray
{
    /// <summary>
    /// The config file: the member's download once (plain, beside the exe), then %APPDATA%\Tallybook\config.json
    /// for good, with the two credentials sealed by <see cref="ISecretProtector"/>.
    /// </summary>
    public static class ConfigStore
    {
        /// <summary>Marks a sealed value, so a plain one is never mistaken for it (and the other way round).</summary>
        private const string Sealed = "p1:";

        [DataContract]
        private sealed class Stored
        {
            [DataMember(Name = "api", Order = 1)] public string? Api { get; set; }
            [DataMember(Name = "ui", Order = 2)] public string? Ui { get; set; }
            [DataMember(Name = "clientId", Order = 3)] public string? ClientId { get; set; }
            [DataMember(Name = "clientSecret", Order = 4)] public string? ClientSecret { get; set; }
            [DataMember(Name = "uploadKey", Order = 5)] public string? UploadKey { get; set; }
            [DataMember(Name = "wowFolder", Order = 6, EmitDefaultValue = false)] public string? WowFolder { get; set; }
            [DataMember(Name = "bringDataBack", Order = 7, EmitDefaultValue = false)] public bool? BringDataBack { get; set; }
            [DataMember(Name = "keepAddonUpToDate", Order = 12, EmitDefaultValue = false)] public bool? KeepAddonUpToDate { get; set; }
            [DataMember(Name = "startWithWindows", Order = 8, EmitDefaultValue = false)] public bool? StartWithWindows { get; set; }
            [DataMember(Name = "acceptedNotice", Order = 9, EmitDefaultValue = false)] public bool? AcceptedNotice { get; set; }
            [DataMember(Name = "acceptedNoticeVersion", Order = 11, EmitDefaultValue = false)] public int? AcceptedNoticeVersion { get; set; }
            [DataMember(Name = "paused", Order = 10, EmitDefaultValue = false)] public bool? Paused { get; set; }
        }

        /// <summary>The server's tallybook.config.json. Null when it is not a complete one.</summary>
        public static TrayConfig? ImportDownload(string downloadJson)
        {
            Stored? s = Json.Read<Stored>(downloadJson);
            if (s == null) return null;
            TrayConfig c = FromStored(s, s.ClientSecret ?? "", s.UploadKey ?? "");
            return IsComplete(c) ? c : null;
        }

        /// <summary>Null when there is no file, it is damaged, or its secrets were not sealed by this user.</summary>
        public static TrayConfig? Load(string path, ISecretProtector protector)
        {
            string text;
            try
            {
                if (!File.Exists(path)) return null;
                text = File.ReadAllText(path, Encoding.UTF8);
            }
            catch (IOException) { return null; }
            catch (UnauthorizedAccessException) { return null; }

            Stored? s = Json.Read<Stored>(text);
            if (s == null) return null;
            string? secret = Open(s.ClientSecret, protector);
            string? key = Open(s.UploadKey, protector);
            if (secret == null || key == null) return null;
            TrayConfig c = FromStored(s, secret, key);
            return IsComplete(c) ? c : null;
        }

        public static void Save(string path, TrayConfig c, ISecretProtector protector)
        {
            var s = new Stored
            {
                Api = c.Api,
                Ui = c.Ui,
                ClientId = c.ClientId,
                ClientSecret = Sealed + protector.Protect(c.ClientSecret),
                UploadKey = Sealed + protector.Protect(c.UploadKey),
                WowFolder = c.WowFolder,
                BringDataBack = c.BringDataBack,
                KeepAddonUpToDate = c.KeepAddonUpToDate,
                StartWithWindows = c.StartWithWindows,
                AcceptedNoticeVersion = c.AcceptedNoticeVersion,
                Paused = c.Paused,
            };
            string? dir = Path.GetDirectoryName(path);
            if (!string.IsNullOrEmpty(dir)) Directory.CreateDirectory(dir);
            AtomicFile.Write(path, Encoding.UTF8.GetBytes(Json.Write(s)));
        }

        /// <summary>
        /// Takes the credentials of a newer settings file (each download retires the key before it) and keeps what the
        /// person chose: the folder, the switches, the notice they accepted. Changes <paramref name="target"/> in
        /// place, so whatever already holds it - the running client - uses the new credentials at its next request.
        /// </summary>
        public static void ApplyCredentials(TrayConfig target, TrayConfig from)
        {
            target.Api = from.Api;
            target.Ui = from.Ui;
            target.ClientId = from.ClientId;
            target.ClientSecret = from.ClientSecret;
            target.UploadKey = from.UploadKey;
        }

        /// <summary>Two origins the credentials may be sent to, and the three credentials.</summary>
        public static bool IsComplete(TrayConfig c) =>
            IsSafeOrigin(c.Api) && IsSafeOrigin(c.Ui) && c.ClientId.Length > 0 && c.ClientSecret.Length > 0 && c.UploadKey.Length > 0;

        private static TrayConfig FromStored(Stored s, string clientSecret, string uploadKey) => new TrayConfig
        {
            Api = (s.Api ?? "").TrimEnd('/'),
            Ui = (s.Ui ?? "").TrimEnd('/'),
            ClientId = s.ClientId ?? "",
            ClientSecret = clientSecret,
            UploadKey = uploadKey,
            WowFolder = s.WowFolder ?? "",
            BringDataBack = s.BringDataBack ?? true,
            KeepAddonUpToDate = s.KeepAddonUpToDate ?? true,
            StartWithWindows = s.StartWithWindows ?? true,
            // A config written before the notice had versions: what they accepted was version 1.
            AcceptedNoticeVersion = s.AcceptedNoticeVersion ?? ((s.AcceptedNotice ?? false) ? 1 : 0),
            Paused = s.Paused ?? false,
        };

        private static string? Open(string? stored, ISecretProtector protector)
        {
            if (stored == null || !stored.StartsWith(Sealed, StringComparison.Ordinal)) return null;
            try { return protector.Unprotect(stored.Substring(Sealed.Length)); }
            catch (Exception) { return null; } // whatever the protector throws, the answer is "not a config"
        }

        /// <summary>
        /// https anywhere; plain http only to this PC itself (the rehearsal, where a stand-in for Cloudflare runs on
        /// a loopback port) - so the credentials can never cross a network in the clear.
        /// </summary>
        private static bool IsSafeOrigin(string url)
        {
            if (!Uri.TryCreate(url, UriKind.Absolute, out Uri? u)) return false;
            if (u.AbsolutePath != "/" || u.Query.Length != 0 || u.Fragment.Length != 0 || u.UserInfo.Length != 0 || u.Host.Length == 0) return false;
            if (u.Scheme == Uri.UriSchemeHttps) return true;
            return u.Scheme == Uri.UriSchemeHttp && (u.Host == "127.0.0.1" || u.Host == "localhost");
        }
    }
}
