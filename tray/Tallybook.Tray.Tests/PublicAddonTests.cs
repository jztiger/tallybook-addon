using System;
using System.Linq;
using System.Threading.Tasks;
using Xunit;

namespace Tallybook.Tray.Tests
{
    /// <summary>
    /// Putting the addon back WITHOUT the server. This is what keeps a bad Data.lua transient: if our own server
    /// ever served something wrong, the person can fetch the published code instead, from GitHub, by hand.
    /// </summary>
    public class PublicAddonTests
    {
        private const string Toc = "## Interface: 16001\n## Title: Tallybook\n## Version: 0.8.0\n\nLogic.lua\nData.lua\n";

        private static FakeServer Repo(string toc, Func<string, string?>? file = null) =>
            new FakeServer
            {
                Answer = r =>
                {
                    string name = r.Url.Substring(r.Url.LastIndexOf('/') + 1);
                    if (name == "Tallybook.toc") return FakeServer.Status(200, toc);
                    string? body = file == null ? "-- " + name + "\n" : file(name);
                    return body == null ? FakeServer.Status(404, "Not Found") : FakeServer.Status(200, body);
                },
            };

        [Fact]
        public async Task It_takes_the_file_list_from_the_toc_itself_and_fetches_exactly_those()
        {
            var repo = Repo(Toc);
            AddonManifest? m = await PublicAddon.FetchAsync(repo);

            Assert.NotNull(m);
            Assert.Equal("0.8.0", m!.Version);
            Assert.Equal(new[] { "Data.lua", "Logic.lua", "Tallybook.toc" }, m.Files.Select(f => f.Name).OrderBy(n => n, StringComparer.Ordinal).ToArray());
            Assert.Null(AddonManifest.Reject(m)); // it is installable as it stands
            foreach (AddonFile f in m.Files) Assert.Equal(AddonManifest.Hash(f.Content), f.Sha256);
            Assert.All(repo.Requests, r => Assert.StartsWith("https://raw.githubusercontent.com/jztiger/tallybook-addon/", r.Url, StringComparison.Ordinal));
        }

        [Fact]
        public async Task It_carries_none_of_our_credentials_to_github()
        {
            var repo = Repo(Toc);
            await PublicAddon.FetchAsync(repo);
            foreach (FakeServer.Seen r in repo.Requests)
            {
                Assert.False(r.Headers.ContainsKey("Authorization"));
                Assert.False(r.Headers.ContainsKey("CF-Access-Client-Id"));
                Assert.False(r.Headers.ContainsKey("CF-Access-Client-Secret"));
            }
        }

        [Theory]
        [InlineData("../evil.lua")]
        [InlineData("sub/Logic.lua")]
        [InlineData("C:\\windows\\evil.lua")]
        [InlineData("Logic.exe")]
        public async Task A_name_in_the_toc_that_is_not_a_plain_addon_file_is_never_even_requested(string listed)
        {
            var repo = Repo(Toc.Replace("Logic.lua", listed));
            Assert.Null(await PublicAddon.FetchAsync(repo));
            Assert.DoesNotContain(repo.Requests, r => r.Url.Contains("evil") || r.Url.Contains("windows") || r.Url.EndsWith(".exe", StringComparison.Ordinal));
        }

        [Fact]
        public async Task One_file_missing_gives_nothing_at_all_rather_than_half_an_addon()
        {
            Assert.Null(await PublicAddon.FetchAsync(Repo(Toc, name => name == "Data.lua" ? null : "-- ok\n")));
        }

        [Theory]
        [InlineData("<!DOCTYPE html><html>404</html>")]
        [InlineData("")]
        [InlineData("## Title: Tallybook\n\nLogic.lua\n")]
        public async Task A_toc_that_is_not_ours_gives_nothing(string toc)
        {
            Assert.Null(await PublicAddon.FetchAsync(Repo(toc)));
        }

        [Fact]
        public async Task A_toc_listing_more_files_than_an_addon_could_have_is_refused()
        {
            string many = "## Version: 0.8.0\n\n" + string.Join("\n", Enumerable.Range(0, 60).Select(i => "File" + i + ".lua"));
            Assert.Null(await PublicAddon.FetchAsync(Repo(many)));
        }
    }
}
