using System;
using System.Collections.Generic;
using System.IO;
using System.Net.Http;
using System.Text;
using System.Threading.Tasks;

namespace Tallybook.Tray
{
    /// <summary>
    /// The addon as published for anyone to read (rule C1), fetched straight from GitHub. This is the way back when
    /// our own server has served something wrong: the person asks for it from the Settings menu, and what they get
    /// is the code in the public repository, not whatever the server is offering.
    ///
    /// It sends none of their credentials - GitHub is not our server - and it takes the file list from the addon's
    /// own .toc, so there is no archive to unpack. A name that is not a plain addon file name is never requested.
    /// </summary>
    public static class PublicAddon
    {
        public const string Base = "https://raw.githubusercontent.com/jztiger/tallybook-addon/main/Tallybook/";
        private const string Toc = "Tallybook.toc";
        private const int MaxBytes = AddonInstaller.MaxFileBytes;

        /// <summary>The published addon, or null when it cannot be had whole. Never a partial addon.</summary>
        public static async Task<AddonManifest?> FetchAsync(HttpMessageHandler handler)
        {
            using (var http = new HttpClient(handler, false) { Timeout = TimeSpan.FromSeconds(60) })
            {
                http.DefaultRequestHeaders.TryAddWithoutValidation("User-Agent", AppInfo.UserAgent);

                string? toc = await GetAsync(http, Toc).ConfigureAwait(false);
                if (toc == null) return null;
                string? version = AddonManifest.VersionOfToc(toc);
                if (version == null) return null;

                var names = new List<string> { Toc };
                foreach (string line in toc.Split('\n'))
                {
                    string listed = line.Trim();
                    if (listed.Length == 0 || listed.StartsWith("##", StringComparison.Ordinal)) continue;
                    // Somebody else's text becoming a path is exactly what must not happen: check, then fetch.
                    if (!AddonManifest.IsPlainName(listed)) return null;
                    if (!names.Contains(listed)) names.Add(listed);
                }
                if (names.Count > AddonInstaller.MaxFiles) return null;

                var files = new List<AddonFile> { new AddonFile { Name = Toc, Content = toc, Sha256 = AddonManifest.Hash(toc) } };
                foreach (string name in names)
                {
                    if (name == Toc) continue;
                    string? content = await GetAsync(http, name).ConfigureAwait(false);
                    if (content == null) return null; // whole, or nothing
                    files.Add(new AddonFile { Name = name, Content = content, Sha256 = AddonManifest.Hash(content) });
                }

                var manifest = new AddonManifest { Version = version, Files = files };
                return AddonManifest.Reject(manifest) == null ? manifest : null;
            }
        }

        private static async Task<string?> GetAsync(HttpClient http, string name)
        {
            try
            {
                using (HttpResponseMessage response = await http.GetAsync(Base + name, HttpCompletionOption.ResponseHeadersRead).ConfigureAwait(false))
                {
                    if ((int)response.StatusCode != 200) return null;
                    if (response.Content.Headers.ContentLength > MaxBytes) return null;
                    byte[] body = await response.Content.ReadAsByteArrayAsync().ConfigureAwait(false);
                    return body.Length > MaxBytes ? null : Encoding.UTF8.GetString(body);
                }
            }
            catch (Exception e) when (e is HttpRequestException || e is TaskCanceledException || e is IOException)
            {
                return null;
            }
        }
    }
}
