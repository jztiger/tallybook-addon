using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Net.Http;
using System.Net.Http.Headers;
using System.Runtime.Serialization;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading.Tasks;

namespace Tallybook.Tray
{
    /// <summary>What the server's answer to an upload means for this file.</summary>
    public enum SendResult
    {
        /// <summary>200: stored (or already there). Done with this file.</summary>
        Sent,
        /// <summary>400, 413, 422: the server will never take these bytes. Done with this file; do not send it again.</summary>
        Rejected,
        /// <summary>429: over the rate or the daily quota. Try again after the time given.</summary>
        Later,
        /// <summary>401, 403, or a redirect to a login page: these credentials are not accepted. Stop and say so.</summary>
        Refused,
        /// <summary>Anything else - the network, a timeout, a server error. Back off and retry.</summary>
        Failed,
    }

    public enum FetchResult { Changed, NotModified, Refused, Failed, Invalid }

    /// <summary>
    /// The three requests this program makes, and no other: send a saved file, fetch the data file, ask which
    /// version is on offer. Each carries the member's Cloudflare service token, their upload key and an ordinary
    /// User-Agent - and nothing about the PC. Redirects are never followed.
    /// </summary>
    public sealed class ServerClient : IDisposable
    {
        /// <summary>A full market and every profession is about 0.4 MiB; anything near this is not our file.</summary>
        public const int MaxDataFileBytes = 8 * 1024 * 1024;
        private const int DefaultRetryAfter = 60;
        private const int LongestRetryAfter = 86400;

        private readonly TrayConfig config;
        private readonly HttpClient http;

        /// <summary>Why the last request failed, safe to log: a status or an exception's type, never its text.</summary>
        public string LastError { get; private set; } = "";

        public ServerClient(TrayConfig config, HttpMessageHandler handler)
        {
            this.config = config;
            http = new HttpClient(handler, true) { Timeout = TimeSpan.FromSeconds(90) };
        }

        /// <summary>The handler for real use: no redirects (a login page is a refusal, not a destination), no cookies.</summary>
        public static HttpClientHandler CreateHandler() => new HttpClientHandler { AllowAutoRedirect = false, UseCookies = false };

        public async Task<(SendResult result, int retryAfterSeconds)> SendAsync(byte[] gzipped)
        {
            using (var request = Request(HttpMethod.Post, "/api/v1/ingest"))
            {
                request.Content = new ByteArrayContent(gzipped);
                request.Content.Headers.ContentType = new MediaTypeHeaderValue("application/octet-stream");
                try
                {
                    using (HttpResponseMessage response = await http.SendAsync(request).ConfigureAwait(false))
                    {
                        int status = (int)response.StatusCode;
                        LastError = status == 200 ? "" : "upload answered " + status;
                        if (status == 200) return (SendResult.Sent, 0);
                        if (status == 400 || status == 413 || status == 422) return (SendResult.Rejected, 0);
                        if (status == 429) return (SendResult.Later, RetryAfter(response));
                        if (IsRefusal(status)) return (SendResult.Refused, 0);
                        return (SendResult.Failed, 0);
                    }
                }
                catch (Exception e) when (e is HttpRequestException || e is TaskCanceledException || e is IOException)
                {
                    LastError = "upload failed: " + e.GetType().Name;
                    return (SendResult.Failed, 0);
                }
            }
        }

        public async Task<(FetchResult result, byte[]? lua, string? etag)> FetchDataFileAsync(string? etag)
        {
            using (var request = Request(HttpMethod.Get, "/api/v1/datafile"))
            {
                if (!string.IsNullOrEmpty(etag)) request.Headers.TryAddWithoutValidation("If-None-Match", etag);
                try
                {
                    using (HttpResponseMessage response = await http.SendAsync(request, HttpCompletionOption.ResponseHeadersRead).ConfigureAwait(false))
                    {
                        int status = (int)response.StatusCode;
                        LastError = status == 200 || status == 304 ? "" : "data file answered " + status;
                        if (status == 304) return (FetchResult.NotModified, null, etag);
                        if (IsRefusal(status)) return (FetchResult.Refused, null, null);
                        if (status != 200) return (FetchResult.Failed, null, null);

                        byte[]? body = await ReadCapped(response.Content, MaxDataFileBytes).ConfigureAwait(false);
                        if (body == null || !LooksLikeDataFile(body))
                        {
                            LastError = "data file was not a Tallybook data file";
                            return (FetchResult.Invalid, null, null);
                        }
                        string? tag = response.Headers.TryGetValues("ETag", out IEnumerable<string>? tags) ? tags.FirstOrDefault() : null;
                        return (FetchResult.Changed, body, tag);
                    }
                }
                catch (Exception e) when (e is HttpRequestException || e is TaskCanceledException || e is IOException)
                {
                    LastError = "data file failed: " + e.GetType().Name;
                    return (FetchResult.Failed, null, null);
                }
            }
        }

        [DataContract]
        private sealed class VersionAnswer
        {
            [DataMember(Name = "version")] public string? Version { get; set; }
        }

        /// <summary>The tray app version the server has on offer, or null. Only ever shown; nothing is downloaded.</summary>
        public async Task<string?> LatestVersionAsync()
        {
            using (var request = Request(HttpMethod.Get, "/api/v1/tray/version"))
            {
                try
                {
                    using (HttpResponseMessage response = await http.SendAsync(request, HttpCompletionOption.ResponseHeadersRead).ConfigureAwait(false))
                    {
                        if ((int)response.StatusCode != 200) return null;
                        byte[]? body = await ReadCapped(response.Content, 4096).ConfigureAwait(false);
                        string? version = body == null ? null : Json.Read<VersionAnswer>(Encoding.UTF8.GetString(body))?.Version;
                        return version != null && Regex.IsMatch(version, @"^\d{1,4}\.\d{1,4}\.\d{1,4}$") ? version : null;
                    }
                }
                catch (Exception e) when (e is HttpRequestException || e is TaskCanceledException || e is IOException)
                {
                    return null;
                }
            }
        }

        public static bool IsNewer(string mine, string? offered) =>
            offered != null && Version.TryParse(mine, out Version? m) && Version.TryParse(offered, out Version? o) && o > m;

        /// <summary>It will be loaded by the game as code, so it must at least be ours: a comment header, the table, no NUL.</summary>
        public static bool LooksLikeDataFile(byte[] body)
        {
            if (body.Length < 16 || body.Length > MaxDataFileBytes || body[0] != (byte)'-' || body[1] != (byte)'-') return false;
            if (Array.IndexOf(body, (byte)0) >= 0) return false;
            return Encoding.UTF8.GetString(body).Contains("ns.baked = {");
        }

        public void Dispose() { http.Dispose(); }

        private HttpRequestMessage Request(HttpMethod method, string path)
        {
            var request = new HttpRequestMessage(method, config.Api + path);
            request.Headers.TryAddWithoutValidation("CF-Access-Client-Id", config.ClientId);
            request.Headers.TryAddWithoutValidation("CF-Access-Client-Secret", config.ClientSecret);
            request.Headers.TryAddWithoutValidation("Authorization", "Bearer " + config.UploadKey);
            request.Headers.TryAddWithoutValidation("User-Agent", AppInfo.UserAgent);
            return request;
        }

        /// <summary>401 / 403 from Cloudflare or the server, or Cloudflare redirecting to its login page.</summary>
        private static bool IsRefusal(int status) => status == 401 || status == 403 || (status >= 300 && status < 400 && status != 304);

        private static int RetryAfter(HttpResponseMessage response)
        {
            if (response.Headers.TryGetValues("Retry-After", out IEnumerable<string>? values)
                && int.TryParse(values.FirstOrDefault(), out int seconds) && seconds > 0)
            {
                return Math.Min(seconds, LongestRetryAfter);
            }
            return DefaultRetryAfter;
        }

        private static async Task<byte[]?> ReadCapped(HttpContent content, int max)
        {
            if (content.Headers.ContentLength > max) return null;
            using (Stream stream = await content.ReadAsStreamAsync().ConfigureAwait(false))
            using (var buffer = new MemoryStream())
            {
                var chunk = new byte[81920];
                int read;
                while ((read = await stream.ReadAsync(chunk, 0, chunk.Length).ConfigureAwait(false)) > 0)
                {
                    if (buffer.Length + read > max) return null;
                    buffer.Write(chunk, 0, read);
                }
                return buffer.ToArray();
            }
        }
    }
}
