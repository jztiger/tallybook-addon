using System;
using System.Collections.Generic;
using System.Linq;
using System.Net;
using System.Net.Http;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using Xunit;

namespace Tallybook.Tray.Tests
{
    /// <summary>The server, as far as the tray app can tell: records each request and answers from a script.</summary>
    internal sealed class FakeServer : HttpMessageHandler
    {
        public sealed class Seen
        {
            public HttpMethod Method = HttpMethod.Get;
            public string Url = "";
            public Dictionary<string, string> Headers = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
            public byte[] Body = new byte[0];
        }

        public readonly List<Seen> Requests = new List<Seen>();
        public Func<Seen, HttpResponseMessage> Answer = _ => new HttpResponseMessage(HttpStatusCode.OK) { Content = new StringContent("{}") };

        protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
        {
            var seen = new Seen { Method = request.Method, Url = request.RequestUri!.ToString() };
            foreach (var h in request.Headers) seen.Headers[h.Key] = string.Join(",", h.Value);
            if (request.Content != null)
            {
                foreach (var h in request.Content.Headers) seen.Headers[h.Key] = string.Join(",", h.Value);
                seen.Body = await request.Content.ReadAsByteArrayAsync();
            }
            Requests.Add(seen);
            return Answer(seen);
        }

        public static HttpResponseMessage Status(int code, string body = "{}", string? retryAfter = null)
        {
            var r = new HttpResponseMessage((HttpStatusCode)code) { Content = new StringContent(body) };
            if (retryAfter != null) r.Headers.TryAddWithoutValidation("Retry-After", retryAfter);
            return r;
        }
    }

    public class ServerClientTests
    {
        internal const string Secret = "s3cr3t-client-secret";
        internal const string Key = "upl0ad-key-43-chars";
        internal const string GoodLua = "-- GENERATED\nlocal _, ns = ...\n\nns.baked = {\n    builtAt = 5,\n}\n";

        internal static TrayConfig Config() => new TrayConfig
        {
            Api = "https://tally-api.example.com",
            Ui = "https://tally.example.com",
            ClientId = "abc123.access",
            ClientSecret = Secret,
            UploadKey = Key,
        };

        [Fact]
        public async Task An_upload_is_a_post_of_exactly_the_bytes_with_the_credentials_and_nothing_about_the_pc()
        {
            var server = new FakeServer();
            var client = new ServerClient(Config(), server);
            byte[] gz = Payload.Gzip(Encoding.UTF8.GetBytes("TallybookDB = {}"));

            var (result, _) = await client.SendAsync(gz);

            Assert.Equal(SendResult.Sent, result);
            FakeServer.Seen r = Assert.Single(server.Requests);
            Assert.Equal(HttpMethod.Post, r.Method);
            Assert.Equal("https://tally-api.example.com/api/v1/ingest", r.Url);
            Assert.Equal(gz, r.Body);
            Assert.Equal("abc123.access", r.Headers["CF-Access-Client-Id"]);
            Assert.Equal(Secret, r.Headers["CF-Access-Client-Secret"]);
            Assert.Equal("Bearer " + Key, r.Headers["Authorization"]);
            Assert.Equal(AppInfo.UserAgent, r.Headers["User-Agent"]);
            Assert.Equal("application/octet-stream", r.Headers["Content-Type"]);
            var allowed = new[] { "CF-Access-Client-Id", "CF-Access-Client-Secret", "Authorization", "User-Agent", "Content-Type", "Content-Length", "Accept" };
            Assert.DoesNotContain(r.Headers.Keys, k => !allowed.Contains(k, StringComparer.OrdinalIgnoreCase));
            string machine = Environment.MachineName, user = Environment.UserName;
            foreach (string v in r.Headers.Values)
            {
                if (machine.Length > 2) Assert.DoesNotContain(machine, v, StringComparison.OrdinalIgnoreCase);
                if (user.Length > 2) Assert.DoesNotContain(user, v, StringComparison.OrdinalIgnoreCase);
            }
        }

        [Theory]
        [InlineData(200, SendResult.Sent)]
        [InlineData(400, SendResult.Rejected)]
        [InlineData(413, SendResult.Rejected)]
        [InlineData(422, SendResult.Rejected)]
        [InlineData(429, SendResult.Later)]
        [InlineData(401, SendResult.Refused)]
        [InlineData(403, SendResult.Refused)]
        [InlineData(302, SendResult.Refused)]
        [InlineData(500, SendResult.Failed)]
        [InlineData(502, SendResult.Failed)]
        [InlineData(404, SendResult.Failed)]
        public async Task Each_answer_means_one_thing(int status, SendResult expected)
        {
            var server = new FakeServer { Answer = _ => FakeServer.Status(status) };
            var (result, _) = await new ServerClient(Config(), server).SendAsync(new byte[] { 1 });
            Assert.Equal(expected, result);
        }

        [Theory]
        [InlineData("120", 120)]
        [InlineData("999999", 86400)]
        [InlineData("-5", 60)]
        [InlineData("soon", 60)]
        [InlineData(null, 60)]
        public async Task Retry_after_is_honoured_within_reason(string? header, int expected)
        {
            var server = new FakeServer { Answer = _ => FakeServer.Status(429, "{}", header) };
            var (result, retryAfter) = await new ServerClient(Config(), server).SendAsync(new byte[] { 1 });
            Assert.Equal(SendResult.Later, result);
            Assert.Equal(expected, retryAfter);
        }

        [Fact]
        public async Task A_network_error_or_a_timeout_is_a_failure_and_says_nothing_secret()
        {
            var server = new FakeServer { Answer = _ => throw new HttpRequestException("connection refused " + Secret) };
            var client = new ServerClient(Config(), server);
            var (result, _) = await client.SendAsync(new byte[] { 1 });
            Assert.Equal(SendResult.Failed, result);
            Assert.DoesNotContain(Secret, client.LastError);
            Assert.DoesNotContain(Key, client.LastError);

            server.Answer = _ => throw new TaskCanceledException("timed out");
            Assert.Equal(SendResult.Failed, (await client.SendAsync(new byte[] { 1 })).result);
        }

        [Fact]
        public void The_real_handler_does_not_follow_redirects_or_keep_cookies()
        {
            HttpClientHandler h = ServerClient.CreateHandler();
            Assert.False(h.AllowAutoRedirect);
            Assert.False(h.UseCookies);
        }

        [Fact]
        public async Task The_data_file_comes_back_with_its_etag_and_a_304_means_nothing_new()
        {
            var server = new FakeServer
            {
                Answer = r =>
                {
                    if (r.Headers.TryGetValue("If-None-Match", out string? tag) && tag == "\"v1\"") return FakeServer.Status(304, "");
                    var ok = FakeServer.Status(200, GoodLua);
                    ok.Headers.TryAddWithoutValidation("ETag", "\"v1\"");
                    return ok;
                },
            };
            var client = new ServerClient(Config(), server);

            var first = await client.FetchDataFileAsync(null);
            Assert.Equal(FetchResult.Changed, first.result);
            Assert.Equal(GoodLua, Encoding.UTF8.GetString(first.lua!));
            Assert.Equal("\"v1\"", first.etag);
            Assert.Equal("https://tally-api.example.com/api/v1/datafile", server.Requests[0].Url);
            Assert.Equal(HttpMethod.Get, server.Requests[0].Method);
            Assert.False(server.Requests[0].Headers.ContainsKey("If-None-Match"));
            Assert.Equal("Bearer " + Key, server.Requests[0].Headers["Authorization"]);

            var second = await client.FetchDataFileAsync(first.etag);
            Assert.Equal(FetchResult.NotModified, second.result);
            Assert.Null(second.lua);
        }

        [Theory]
        [InlineData("<!DOCTYPE html><html><body>Just a moment...</body></html>")]
        [InlineData("")]
        [InlineData("-- a comment and nothing else\n")]
        [InlineData("ns.baked = {}  -- does not start with a comment header")]
        [InlineData("-- header\nns.baked = {\n\0}")]
        public async Task What_is_not_our_data_file_is_invalid_and_never_handed_on(string body)
        {
            var server = new FakeServer { Answer = _ => FakeServer.Status(200, body) };
            var got = await new ServerClient(Config(), server).FetchDataFileAsync(null);
            Assert.Equal(FetchResult.Invalid, got.result);
            Assert.Null(got.lua);
        }

        [Fact]
        public async Task An_oversize_data_file_is_invalid()
        {
            string big = "-- header\nns.baked = {\n" + new string('-', ServerClient.MaxDataFileBytes) + "\n}";
            var server = new FakeServer { Answer = _ => FakeServer.Status(200, big) };
            Assert.Equal(FetchResult.Invalid, (await new ServerClient(Config(), server).FetchDataFileAsync(null)).result);
        }

        [Theory]
        [InlineData(401, FetchResult.Refused)]
        [InlineData(403, FetchResult.Refused)]
        [InlineData(302, FetchResult.Refused)]
        [InlineData(500, FetchResult.Failed)]
        [InlineData(429, FetchResult.Failed)]
        public async Task Fetch_answers(int status, FetchResult expected)
        {
            var server = new FakeServer { Answer = _ => FakeServer.Status(status) };
            Assert.Equal(expected, (await new ServerClient(Config(), server).FetchDataFileAsync(null)).result);
        }

        [Theory]
        [InlineData("{\"version\":\"0.2.0\"}", "0.2.0")]
        [InlineData("{\"version\":null}", null)]
        [InlineData("{\"version\":\"<b>1</b>\"}", null)]
        [InlineData("nonsense", null)]
        public async Task The_version_on_offer(string body, string? expected)
        {
            var server = new FakeServer { Answer = _ => FakeServer.Status(200, body) };
            Assert.Equal(expected, await new ServerClient(Config(), server).LatestVersionAsync());
            Assert.Equal("https://tally-api.example.com/api/v1/tray/version", server.Requests[0].Url);
        }

        [Theory]
        [InlineData("0.1.0", "0.2.0", true)]
        [InlineData("0.1.0", "0.1.0", false)]
        [InlineData("0.10.0", "0.9.9", false)]
        [InlineData("0.1.0", null, false)]
        [InlineData("0.1.0", "junk", false)]
        public void Newer_means_newer(string mine, string? offered, bool expected)
        {
            Assert.Equal(expected, ServerClient.IsNewer(mine, offered));
        }
    }

    public class AddonFetchTests
    {
        private const string Manifest =
            "{\"version\":\"0.9.0\",\"files\":[{\"name\":\"Tallybook.toc\",\"sha256\":\"SHA\",\"content\":\"TOC\"}]}";

        private static string Body()
        {
            const string toc = "## Version: 0.9.0\n";
            return Manifest.Replace("SHA", AddonManifest.Hash(toc)).Replace("TOC", "## Version: 0.9.0\\n");
        }

        [Fact]
        public async Task The_addon_comes_back_parsed_with_its_etag_and_a_304_means_nothing_new()
        {
            var server = new FakeServer
            {
                Answer = r =>
                {
                    if (r.Headers.TryGetValue("If-None-Match", out string? tag) && tag == "\"a1\"") return FakeServer.Status(304, "");
                    var ok = FakeServer.Status(200, Body());
                    ok.Headers.TryAddWithoutValidation("ETag", "\"a1\"");
                    return ok;
                },
            };
            var client = new ServerClient(ServerClientTests.Config(), server);

            var first = await client.FetchAddonAsync(null);
            Assert.Equal(FetchResult.Changed, first.result);
            Assert.Equal("0.9.0", first.manifest!.Version);
            Assert.Equal("Tallybook.toc", Assert.Single(first.manifest.Files).Name);
            Assert.Null(AddonManifest.Reject(first.manifest));
            Assert.Equal("\"a1\"", first.etag);
            Assert.Equal("https://tally-api.example.com/api/v1/addon", server.Requests[0].Url);
            Assert.Equal("Bearer " + ServerClientTests.Key, server.Requests[0].Headers["Authorization"]);
            Assert.False(server.Requests[0].Headers.ContainsKey("If-None-Match"));

            var second = await client.FetchAddonAsync(first.etag);
            Assert.Equal(FetchResult.NotModified, second.result);
            Assert.Null(second.manifest);
        }

        [Theory]
        [InlineData("<!DOCTYPE html><html>Just a moment...</html>")]
        [InlineData("")]
        [InlineData("{\"version\":\"0.9.0\",\"files\":[]}")]
        [InlineData("{\"version\":\"0.9.0\",\"files\":[{\"name\":\"../evil.lua\",\"sha256\":\"x\",\"content\":\"y\"}]}")]
        public async Task What_is_not_an_addon_we_would_install_is_invalid_and_never_handed_on(string body)
        {
            var server = new FakeServer { Answer = _ => FakeServer.Status(200, body) };
            var got = await new ServerClient(ServerClientTests.Config(), server).FetchAddonAsync(null);
            Assert.Equal(FetchResult.Invalid, got.result);
            Assert.Null(got.manifest);
        }

        [Theory]
        [InlineData(401, FetchResult.Refused)]
        [InlineData(403, FetchResult.Refused)]
        [InlineData(302, FetchResult.Refused)]
        [InlineData(503, FetchResult.Failed)]
        [InlineData(500, FetchResult.Failed)]
        public async Task Answers(int status, FetchResult expected)
        {
            var server = new FakeServer { Answer = _ => FakeServer.Status(status) };
            var got = await new ServerClient(ServerClientTests.Config(), server).FetchAddonAsync(null);
            Assert.Equal(expected, got.result);
        }
    }

    public class BackoffTests
    {
        [Fact]
        public void Five_seconds_doubling_to_ten_minutes_and_back_to_the_start_on_success()
        {
            var b = new Backoff();
            var seen = Enumerable.Range(0, 9).Select(_ => (int)b.Next().TotalSeconds).ToArray();
            Assert.Equal(new[] { 5, 10, 20, 40, 80, 160, 320, 600, 600 }, seen);
            b.Reset();
            Assert.Equal(5, (int)b.Next().TotalSeconds);
        }
    }
}
