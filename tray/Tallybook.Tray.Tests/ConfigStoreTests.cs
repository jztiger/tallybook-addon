using System;
using System.IO;
using Xunit;

namespace Tallybook.Tray.Tests
{
    /// <summary>Stands in for Windows' DPAPI: reversible, recognisable, and it refuses what it did not make.</summary>
    internal sealed class FakeProtector : ISecretProtector
    {
        public string Protect(string plain)
        {
            char[] c = plain.ToCharArray();
            Array.Reverse(c);
            return "fake[" + Convert.ToBase64String(System.Text.Encoding.UTF8.GetBytes(new string(c))) + "]";
        }

        public string Unprotect(string sealedText)
        {
            if (!sealedText.StartsWith("fake[", StringComparison.Ordinal) || !sealedText.EndsWith("]", StringComparison.Ordinal))
                throw new InvalidOperationException("not mine");
            char[] c = System.Text.Encoding.UTF8.GetString(Convert.FromBase64String(sealedText.Substring(5, sealedText.Length - 6))).ToCharArray();
            Array.Reverse(c);
            return new string(c);
        }
    }

    internal sealed class TempDir : IDisposable
    {
        public string Path { get; } = System.IO.Path.Combine(System.IO.Path.GetTempPath(), "tallybook-test-" + Guid.NewGuid().ToString("N"));
        public TempDir() { Directory.CreateDirectory(Path); }
        public string File(string name) => System.IO.Path.Combine(Path, name);
        public void Dispose() { try { Directory.Delete(Path, true); } catch (IOException) { } }
    }

    public class ConfigStoreTests
    {
        private const string Download = "{\n  \"api\": \"https://tally-api.example.com\",\n  \"ui\": \"https://tally.example.com\",\n"
            + "  \"clientId\": \"abc123.access\",\n  \"clientSecret\": \"s3cr3t-client-secret\",\n  \"uploadKey\": \"upl0ad-key-43-chars\"\n}\n";

        [Fact]
        public void The_servers_download_imports()
        {
            TrayConfig? c = ConfigStore.ImportDownload(Download);
            Assert.NotNull(c);
            Assert.Equal("https://tally-api.example.com", c!.Api);
            Assert.Equal("https://tally.example.com", c.Ui);
            Assert.Equal("abc123.access", c.ClientId);
            Assert.Equal("s3cr3t-client-secret", c.ClientSecret);
            Assert.Equal("upl0ad-key-43-chars", c.UploadKey);
            Assert.True(ConfigStore.IsComplete(c));
        }

        [Theory]
        [InlineData("")]
        [InlineData("not json")]
        [InlineData("[]")]
        [InlineData("{\"api\":\"https://a.example.com\"}")]
        [InlineData("{\"api\":\"http://tally-api.example.com\",\"ui\":\"https://tally.example.com\",\"clientId\":\"a\",\"clientSecret\":\"b\",\"uploadKey\":\"c\"}")]
        [InlineData("{\"api\":\"https://tally-api.example.com/path\",\"ui\":\"https://tally.example.com\",\"clientId\":\"a\",\"clientSecret\":\"b\",\"uploadKey\":\"c\"}")]
        public void What_is_not_a_complete_https_download_does_not_import(string json)
        {
            Assert.Null(ConfigStore.ImportDownload(json));
        }

        private static string DownloadWithApi(string api) => Download.Replace("https://tally-api.example.com", api);

        [Theory]
        [InlineData("http://127.0.0.1:3102")]
        [InlineData("http://localhost:3102")]
        public void A_loopback_address_may_be_plain_http_for_the_rehearsal_on_one_pc(string api)
        {
            TrayConfig? c = ConfigStore.ImportDownload(DownloadWithApi(api));
            Assert.NotNull(c);
            Assert.Equal(api, c!.Api);
        }

        [Theory]
        [InlineData("http://10.0.0.5:3000")]  // any LAN address: the credentials must never cross a network in the clear
        [InlineData("http://tally.example.com")]
        [InlineData("http://127.0.0.1.evil.example")]
        [InlineData("http://localhost.evil.example:3102")]
        [InlineData("ftp://127.0.0.1")]
        public void Nothing_else_may_travel_in_the_clear(string api)
        {
            Assert.Null(ConfigStore.ImportDownload(DownloadWithApi(api)));
        }

        [Fact]
        public void Defaults_are_both_switches_on_and_the_notice_not_accepted()
        {
            TrayConfig c = ConfigStore.ImportDownload(Download)!;
            Assert.True(c.BringDataBack);
            Assert.True(c.StartWithWindows);
            Assert.False(c.AcceptedNotice);
            Assert.False(c.Paused);
            Assert.Equal("", c.WowFolder);
        }

        [Fact]
        public void Save_then_load_round_trips_and_no_secret_is_on_disk_in_the_clear()
        {
            using var dir = new TempDir();
            string path = dir.File("config.json");
            TrayConfig c = ConfigStore.ImportDownload(Download)!;
            c.WowFolder = @"D:\Games\World of Warcraft";
            c.AcceptedNotice = true;
            c.BringDataBack = false;
            ConfigStore.Save(path, c, new FakeProtector());

            string onDisk = File.ReadAllText(path);
            Assert.DoesNotContain("s3cr3t-client-secret", onDisk);
            Assert.DoesNotContain("upl0ad-key-43-chars", onDisk);
            Assert.Contains("p1:fake[", onDisk);
            Assert.Empty(Directory.GetFiles(dir.Path, "*.tmp*"));

            TrayConfig? back = ConfigStore.Load(path, new FakeProtector());
            Assert.NotNull(back);
            Assert.Equal("s3cr3t-client-secret", back!.ClientSecret);
            Assert.Equal("upl0ad-key-43-chars", back.UploadKey);
            Assert.Equal(@"D:\Games\World of Warcraft", back.WowFolder);
            Assert.True(back.AcceptedNotice);
            Assert.False(back.BringDataBack);
            Assert.True(back.StartWithWindows);
        }

        [Fact]
        public void No_file_is_no_config()
        {
            using var dir = new TempDir();
            Assert.Null(ConfigStore.Load(dir.File("config.json"), new FakeProtector()));
        }

        [Fact]
        public void A_tampered_or_foreign_secret_is_no_config_not_a_crash()
        {
            using var dir = new TempDir();
            string path = dir.File("config.json");
            ConfigStore.Save(path, ConfigStore.ImportDownload(Download)!, new FakeProtector());
            File.WriteAllText(path, File.ReadAllText(path).Replace("p1:fake[", "p1:other["));
            Assert.Null(ConfigStore.Load(path, new FakeProtector()));

            File.WriteAllText(path, "{ this is not json");
            Assert.Null(ConfigStore.Load(path, new FakeProtector()));
        }

        [Fact]
        public void A_new_settings_file_replaces_the_credentials_and_keeps_everything_the_person_chose()
        {
            TrayConfig mine = ConfigStore.ImportDownload(Download)!;
            mine.WowFolder = @"D:\Games\World of Warcraft";
            mine.AcceptedNotice = true;
            mine.BringDataBack = false;
            mine.StartWithWindows = false;
            mine.Paused = true;

            TrayConfig fresh = ConfigStore.ImportDownload(Download.Replace("upl0ad-key-43-chars", "a-brand-new-upload-key").Replace("s3cr3t-client-secret", "rotated-secret"))!;
            ConfigStore.ApplyCredentials(mine, fresh);

            Assert.Equal("a-brand-new-upload-key", mine.UploadKey);
            Assert.Equal("rotated-secret", mine.ClientSecret);
            Assert.Equal(fresh.Api, mine.Api);
            Assert.Equal(fresh.Ui, mine.Ui);
            Assert.Equal(fresh.ClientId, mine.ClientId);
            Assert.Equal(@"D:\Games\World of Warcraft", mine.WowFolder);
            Assert.True(mine.AcceptedNotice);
            Assert.False(mine.BringDataBack);
            Assert.False(mine.StartWithWindows);
            Assert.True(mine.Paused);
        }

        [Fact]
        public void Unknown_fields_are_ignored()
        {
            string json = Download.Replace("{\n", "{\n  \"somethingNew\": 5,\n");
            Assert.NotNull(ConfigStore.ImportDownload(json));
        }

        [Fact]
        public void A_config_never_prints_its_secrets()
        {
            TrayConfig c = ConfigStore.ImportDownload(Download)!;
            Assert.DoesNotContain("s3cr3t", c.ToString());
            Assert.DoesNotContain("upl0ad", c.ToString());
        }
    }
}
