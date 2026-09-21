using System;
using System.IO;
using System.Linq;
using System.Net.Http;
using System.Text;
using System.Threading.Tasks;
using Xunit;

namespace Tallybook.Tray.Tests
{
    /// <summary>A pretend World of Warcraft folder on disk, a pretend server, and a clock the test moves by hand.</summary>
    internal sealed class World : IDisposable
    {
        public readonly TempDir Dir = new TempDir();
        public readonly FakeServer Server = new FakeServer();
        public readonly TrayConfig Config = ServerClientTests.Config();
        public DateTime Now = new DateTime(2026, 9, 20, 12, 0, 0, DateTimeKind.Utc);
        public readonly string Wow;
        public readonly string Saved;
        public readonly string DataLua;
        public readonly string LogFile;
        public string Lua = ServerClientTests.GoodLua;
        public string AddonVersion = "0.9.0";
        public string AddonETag = "\"addon1\"";
        public int AddonStatus = 200;
        public int AddonRequests;
        public string ETag = "\"v1\"";
        public int IngestStatus = 200;
        public Cycle Cycle;

        /// <summary>A manifest in the shape the server sends: a .toc with that version, and one Lua file.</summary>
        public static string AddonJson(string version)
        {
            string toc = "## Interface: 16001\n## Title: Tallybook\n## Version: " + version + "\n\nLogic.lua\nData.lua\n";
            string logic = "local _, ns = ...\n-- " + version + "\n";
            string empty = "-- GENERATED\nns.baked = {\n}\n";
            string One(string n, string c) => "{\"name\":\"" + n + "\",\"sha256\":\"" + AddonManifest.Hash(c) + "\",\"content\":" + Quote(c) + "}";
            return "{\"version\":\"" + version + "\",\"files\":[" + One("Tallybook.toc", toc) + "," + One("Logic.lua", logic) + "," + One("Data.lua", empty) + "]}";
        }

        private static string Quote(string s) => "\"" + s.Replace("\\", "\\\\").Replace("\"", "\\\"").Replace("\n", "\\n") + "\"";

        public World(bool addonInstalled = true)
        {
            Wow = Path.Combine(Dir.Path, "World of Warcraft");
            Saved = Path.Combine(Wow, "_classic_beta_", "WTF", "Account", "ACCT#1", "SavedVariables", "Tallybook.lua");
            DataLua = Path.Combine(Wow, "_classic_beta_", "Interface", "AddOns", "Tallybook", "Data.lua");
            LogFile = Dir.File("log.txt");
            Directory.CreateDirectory(Path.GetDirectoryName(Saved)!);
            if (addonInstalled)
            {
                Directory.CreateDirectory(Path.GetDirectoryName(DataLua)!);
                File.WriteAllText(DataLua, "-- the empty one\nns.baked = {\n}\n");
                File.WriteAllText(Path.Combine(Path.GetDirectoryName(DataLua)!, "Tallybook.toc"), "## Version: 0.9.0\n\nLogic.lua\nData.lua\n");
            }
            else
            {
                Directory.CreateDirectory(Path.Combine(Wow, "_classic_beta_", "Interface", "AddOns"));
            }
            Config.WowFolder = Wow;
            Config.AcceptedNoticeVersion = 2;
            Server.Answer = r =>
            {
                if (r.Url.EndsWith("/api/v1/ingest", StringComparison.Ordinal)) return FakeServer.Status(IngestStatus, "{}", IngestStatus == 429 ? "120" : null);
                if (r.Url.EndsWith("/api/v1/addon", StringComparison.Ordinal))
                {
                    AddonRequests++;
                    if (AddonStatus != 200) return FakeServer.Status(AddonStatus, "{}");
                    if (r.Headers.TryGetValue("If-None-Match", out string? a) && a == AddonETag) return FakeServer.Status(304, "");
                    var m = FakeServer.Status(200, AddonJson(AddonVersion));
                    m.Headers.TryAddWithoutValidation("ETag", AddonETag);
                    return m;
                }
                if (r.Headers.TryGetValue("If-None-Match", out string? tag) && tag == ETag) return FakeServer.Status(304, "");
                var ok = FakeServer.Status(200, Lua);
                ok.Headers.TryAddWithoutValidation("ETag", ETag);
                return ok;
            };
            Cycle = NewCycle();
        }

        /// <summary>As after a restart: nothing in memory, the sent log and the files still there.</summary>
        public Cycle NewCycle() =>
            new Cycle(Config, new ServerClient(Config, Server), new SentLog(Dir.File("sent.txt")), new Stability(), new TrayLog(LogFile), () => Now);

        public void Save(string content) { File.WriteAllText(Saved, content); }

        /// <summary>Two looks, more than three seconds apart: the second one finds the file stable.</summary>
        public async Task<CycleReport> RunUntilStable(bool force = false)
        {
            await Cycle.RunAsync(force);
            Now = Now.AddSeconds(4);
            return await Cycle.RunAsync(force);
        }

        public int Count(string urlEnd) => Server.Requests.Count(r => r.Url.EndsWith(urlEnd, StringComparison.Ordinal));
        public void Dispose() { Dir.Dispose(); }
    }

    public class CycleTests
    {
        [Fact]
        public async Task A_new_saved_file_is_sent_once_it_is_quiet_and_the_data_file_comes_back()
        {
            using var w = new World();
            w.Save("TallybookDB = { one = 1 }");

            CycleReport first = await w.Cycle.RunAsync(false);
            Assert.Equal(0, first.Uploaded);
            Assert.Equal(0, w.Count("/ingest")); // seen for the first time: not yet known to be quiet

            w.Now = w.Now.AddSeconds(4);
            CycleReport second = await w.Cycle.RunAsync(false);
            Assert.Equal(1, second.Uploaded);
            Assert.Equal(TrayState.Ok, second.State);
            Assert.Equal(1, w.Count("/ingest"));
            Assert.Equal(ServerClientTests.GoodLua, File.ReadAllText(w.DataLua));
            Assert.Equal(w.Now, w.Cycle.LastUploadUtc);

            byte[] sent = w.Server.Requests.First(r => r.Url.EndsWith("/ingest", StringComparison.Ordinal)).Body;
            Assert.Equal(Payload.Gzip(File.ReadAllBytes(w.Saved)), sent);
        }

        [Fact]
        public async Task The_same_bytes_are_never_sent_twice_not_even_after_a_restart()
        {
            using var w = new World();
            w.Save("TallybookDB = { one = 1 }");
            await w.RunUntilStable();
            w.Now = w.Now.AddSeconds(10);
            await w.Cycle.RunAsync(false);
            Assert.Equal(1, w.Count("/ingest"));

            w.Cycle = w.NewCycle();
            await w.RunUntilStable();
            Assert.Equal(1, w.Count("/ingest"));

            w.Save("TallybookDB = { two = 2 }");
            await w.RunUntilStable();
            Assert.Equal(2, w.Count("/ingest"));
        }

        [Fact]
        public async Task The_bak_file_is_sent_too_when_its_bytes_are_new()
        {
            using var w = new World();
            w.Save("TallybookDB = { now = 1 }");
            File.WriteAllText(w.Saved + ".bak", "TallybookDB = { before = 1 }");
            CycleReport r = await w.RunUntilStable();
            Assert.Equal(2, r.Uploaded);
        }

        [Fact]
        public async Task A_rejected_file_is_not_sent_again()
        {
            using var w = new World { IngestStatus = 422 };
            w.Save("not a saved file");
            CycleReport r = await w.RunUntilStable();
            Assert.Equal(0, r.Uploaded);
            Assert.Equal(1, r.Rejected);
            Assert.Equal(TrayState.Ok, r.State);
            w.Now = w.Now.AddMinutes(5);
            await w.Cycle.RunAsync(false);
            Assert.Equal(1, w.Count("/ingest"));
        }

        [Fact]
        public async Task Refused_credentials_stop_everything_until_the_person_asks_again()
        {
            using var w = new World { IngestStatus = 403 };
            w.Save("TallybookDB = { one = 1 }");
            CycleReport r = await w.RunUntilStable();
            Assert.Equal(TrayState.NeedsAttention, r.State);
            Assert.Equal(1, w.Count("/ingest"));
            int requestsSoFar = w.Server.Requests.Count; // includes the fetch at start, before anything was refused

            w.Now = w.Now.AddHours(2);
            Assert.Equal(TrayState.NeedsAttention, (await w.Cycle.RunAsync(false)).State);
            Assert.Equal(requestsSoFar, w.Server.Requests.Count); // no retrying, and no fetching either

            w.IngestStatus = 200;
            CycleReport asked = await w.Cycle.RunAsync(true); // "Upload now"
            Assert.Equal(TrayState.Ok, asked.State);
            Assert.Equal(1, asked.Uploaded);
        }

        [Fact]
        public async Task A_failure_backs_off_and_a_429_waits_as_long_as_it_is_told()
        {
            using var w = new World { IngestStatus = 500 };
            w.Save("TallybookDB = { one = 1 }");
            Assert.Equal(TrayState.Retrying, (await w.RunUntilStable()).State);
            Assert.Equal(1, w.Count("/ingest"));

            w.Now = w.Now.AddSeconds(2);
            await w.Cycle.RunAsync(false);
            Assert.Equal(1, w.Count("/ingest")); // still inside the 5 s back-off

            w.Now = w.Now.AddSeconds(4);
            w.IngestStatus = 429;
            Assert.Equal(TrayState.Retrying, (await w.Cycle.RunAsync(false)).State);
            Assert.Equal(2, w.Count("/ingest"));

            w.IngestStatus = 200;
            w.Now = w.Now.AddSeconds(60);
            await w.Cycle.RunAsync(false);
            Assert.Equal(2, w.Count("/ingest")); // Retry-After: 120

            w.Now = w.Now.AddSeconds(61);
            CycleReport ok = await w.Cycle.RunAsync(false);
            Assert.Equal(3, w.Count("/ingest"));
            Assert.Equal(TrayState.Ok, ok.State);
        }

        [Fact]
        public async Task With_bring_data_back_off_nothing_is_fetched_or_written()
        {
            using var w = new World();
            w.Config.BringDataBack = false;
            string before = File.ReadAllText(w.DataLua);
            w.Save("TallybookDB = { one = 1 }");
            CycleReport r = await w.RunUntilStable(true);
            Assert.Equal(1, r.Uploaded);
            Assert.Equal(0, w.Count("/datafile"));
            Assert.Equal(before, File.ReadAllText(w.DataLua));
        }

        [Fact]
        public async Task Paused_does_nothing_at_all()
        {
            using var w = new World();
            w.Config.Paused = true;
            w.Save("TallybookDB = { one = 1 }");
            CycleReport r = await w.RunUntilStable();
            Assert.Equal(TrayState.Paused, r.State);
            Assert.Empty(w.Server.Requests);
        }

        [Fact]
        public async Task A_missing_game_folder_needs_attention_and_nothing_is_created()
        {
            using var w = new World();
            w.Config.WowFolder = Path.Combine(w.Dir.Path, "gone");
            CycleReport r = await w.Cycle.RunAsync(false);
            Assert.Equal(TrayState.NeedsAttention, r.State);
            Assert.False(Directory.Exists(w.Config.WowFolder));
            Assert.Empty(w.Server.Requests);
        }

        [Fact]
        public async Task The_data_file_is_fetched_at_start_then_at_most_every_thirty_minutes_with_the_etag()
        {
            using var w = new World();
            await w.Cycle.RunAsync(false);
            Assert.Equal(1, w.Count("/datafile"));
            w.Now = w.Now.AddMinutes(29);
            await w.Cycle.RunAsync(false);
            Assert.Equal(1, w.Count("/datafile"));
            w.Now = w.Now.AddMinutes(2);
            CycleReport r = await w.Cycle.RunAsync(false);
            Assert.Equal(2, w.Count("/datafile"));
            Assert.Equal("\"v1\"", w.Server.Requests.Last().Headers["If-None-Match"]);
            Assert.Equal(0, r.Wrote);
        }

        [Fact]
        public async Task An_addon_reinstall_that_put_the_empty_file_back_is_repaired_at_the_next_fetch()
        {
            using var w = new World();
            await w.Cycle.RunAsync(false);
            File.WriteAllText(w.DataLua, "-- the empty one again\nns.baked = {\n}\n");
            CycleReport r = await w.Cycle.RunAsync(true);
            Assert.Equal(1, r.Wrote);
            Assert.Equal(ServerClientTests.GoodLua, File.ReadAllText(w.DataLua));
        }

        [Fact]
        public async Task What_is_not_our_data_file_never_reaches_the_disk()
        {
            using var w = new World { Lua = "<!DOCTYPE html><html>Just a moment...</html>" };
            string before = File.ReadAllText(w.DataLua);
            CycleReport r = await w.Cycle.RunAsync(false);
            Assert.Equal(0, r.Wrote);
            Assert.Equal(TrayState.Retrying, r.State);
            Assert.Equal(before, File.ReadAllText(w.DataLua));
        }

        [Fact]
        public async Task It_writes_only_an_existing_data_lua_creates_nothing_and_leaves_no_temp_file()
        {
            using var w = new World();
            string otherProduct = Path.Combine(w.Wow, "_retail_", "Interface", "AddOns");
            Directory.CreateDirectory(otherProduct); // the addon is not installed there
            await w.Cycle.RunAsync(false);

            // A Forever addon has no business in somebody's retail game: a first install never guesses a product.
            Assert.False(Directory.Exists(Path.Combine(otherProduct, "Tallybook")));
            string addon = Path.GetDirectoryName(w.DataLua)!;
            string[] inAddon = Directory.GetFiles(addon).Select(Path.GetFileName).OrderBy(n => n, StringComparer.Ordinal).ToArray()!;
            Assert.Equal(new[] { "Data.lua", "Tallybook.toc" }, inAddon); // what was installed, and nothing more
            Assert.Empty(Directory.GetDirectories(addon));
            Assert.DoesNotContain(Directory.GetDirectories(Path.GetDirectoryName(addon)!), d => Path.GetFileName(d)!.Contains(".new-") || Path.GetFileName(d)!.Contains(".old-"));
        }

        [Fact]
        public async Task The_age_of_the_prices_is_read_from_the_file_for_the_tooltip()
        {
            using var w = new World { Lua = "-- GENERATED\nns.baked = {\n    pricesAt = 1790000000,\n    prices = {},\n}\n" };
            await w.Cycle.RunAsync(false);
            Assert.Equal(new DateTime(1970, 1, 1, 0, 0, 0, DateTimeKind.Utc).AddSeconds(1790000000), w.Cycle.PricesAtUtc);
        }

        [Fact]
        public async Task The_log_says_what_happened_and_never_a_credential_or_the_account_folder()
        {
            using var w = new World();
            w.Save("TallybookDB = { one = 1 }");
            await w.RunUntilStable();
            string log = File.ReadAllText(w.LogFile);
            Assert.Contains("sent", log);
            Assert.DoesNotContain(ServerClientTests.Secret, log);
            Assert.DoesNotContain(ServerClientTests.Key, log);
            Assert.DoesNotContain("ACCT#1", log);
        }
    }

    public class AddonCycleTests
    {
        [Fact]
        public async Task With_no_addon_installed_a_pass_installs_it_AND_THEN_fills_its_Data_lua()
        {
            using var w = new World(addonInstalled: false);
            string addon = Path.GetDirectoryName(w.DataLua)!;
            Assert.False(Directory.Exists(addon));

            CycleReport r = await w.Cycle.RunAsync(false);

            Assert.Equal("0.9.0", r.AddonInstalled);
            Assert.Equal("0.9.0", AddonInstaller.InstalledVersion(addon));
            // The order is what matters: an addon installed with the manifest's empty Data.lua would have no prices
            // until the next fetch. It is filled in the same pass.
            Assert.Equal(ServerClientTests.GoodLua, File.ReadAllText(w.DataLua));
            Assert.Equal(1, r.Wrote);
        }

        [Fact]
        public async Task A_half_there_addon_folder_is_repaired_and_the_prices_in_it_are_kept()
        {
            // Data.lua but no .toc: what a half-finished manual install, or a deleted file, leaves behind. The
            // rehearsal was set up this way before the tray app installed addons, and it must still come good.
            using var w = new World(addonInstalled: false);
            string addon = Path.GetDirectoryName(w.DataLua)!;
            Directory.CreateDirectory(addon);
            File.WriteAllText(w.DataLua, "-- mine\nns.baked = { prices = { [2589] = 160 } }\n");
            string mine = File.ReadAllText(w.DataLua);
            w.Save("TallybookDB = { one = 1 }");

            // The repair happens on the first pass - the saved file is not quiet enough to send yet.
            CycleReport first = await w.Cycle.RunAsync(false);
            Assert.Equal("0.9.0", first.AddonInstalled);
            w.Now = w.Now.AddSeconds(4);
            CycleReport then = await w.Cycle.RunAsync(false);

            Assert.Equal(TrayState.Ok, then.State);
            Assert.Equal(1, then.Uploaded);
            Assert.Equal("0.9.0", AddonInstaller.InstalledVersion(addon));
            Assert.Equal(ServerClientTests.GoodLua, File.ReadAllText(w.DataLua)); // the server's file, written after
            Assert.NotEqual(mine, File.ReadAllText(w.DataLua));
        }

        [Fact]
        public async Task The_version_already_installed_is_not_installed_again()
        {
            using var w = new World();
            CycleReport first = await w.Cycle.RunAsync(false);
            Assert.Null(first.AddonInstalled);
            int asked = w.AddonRequests;

            w.Now = w.Now.AddMinutes(5);
            await w.Cycle.RunAsync(false);
            Assert.Equal(asked, w.AddonRequests); // not asked again so soon
        }

        [Fact]
        public async Task A_newer_addon_is_installed_and_the_players_prices_come_across_it()
        {
            using var w = new World();
            await w.Cycle.RunAsync(false);
            File.WriteAllText(w.DataLua, "-- mine\nns.baked = { prices = { [2589] = 160 } }\n");
            string mine = File.ReadAllText(w.DataLua);

            w.AddonVersion = "1.0.0";
            w.AddonETag = "\"addon2\"";
            w.Lua = "-- GENERATED\nns.baked = {\n    pricesAt = 1790000000,\n}\n"; // nothing new to write back yet
            CycleReport r = await w.Cycle.RunAsync(true);

            Assert.Equal("1.0.0", r.AddonInstalled);
            Assert.Equal("1.0.0", AddonInstaller.InstalledVersion(Path.GetDirectoryName(w.DataLua)!));
            Assert.Contains("[2589] = 160", File.ReadAllText(w.DataLua) + mine); // the prices were not thrown away
        }

        [Fact]
        public async Task Switched_off_it_never_asks_for_the_addon_at_all()
        {
            using var w = new World();
            w.Config.KeepAddonUpToDate = false;
            await w.Cycle.RunAsync(true);
            Assert.Equal(0, w.AddonRequests);
        }

        [Fact]
        public async Task An_addon_the_server_cannot_offer_changes_nothing_and_the_upload_still_happens()
        {
            using var w = new World { AddonStatus = 503 };
            w.Save("TallybookDB = { one = 1 }");
            CycleReport r = await w.RunUntilStable();

            Assert.Equal(1, r.Uploaded);
            Assert.Null(r.AddonInstalled);
            Assert.Equal("0.9.0", AddonInstaller.InstalledVersion(Path.GetDirectoryName(w.DataLua)!)); // untouched
            Assert.Equal(TrayState.Ok, r.State);
        }
    }

    public class TrayLogTests
    {
        [Fact]
        public void It_rotates_and_hides_what_it_was_told_to_hide()
        {
            using var dir = new TempDir();
            string file = dir.File("log.txt");
            var log = new TrayLog(file, 2000);
            log.Hide("hunter2-secret", "");
            log.Write("the key is hunter2-secret, do not tell");
            Assert.DoesNotContain("hunter2", File.ReadAllText(file));
            Assert.Contains("[hidden]", File.ReadAllText(file));

            for (int i = 0; i < 100; i++) log.Write("line " + i + " " + new string('x', 50));
            Assert.True(new FileInfo(file).Length <= 2200);
            Assert.True(File.Exists(dir.File("log.1.txt")));
            Assert.Equal(2, Directory.GetFiles(dir.Path).Length);
        }

        [Fact]
        public void A_log_that_cannot_be_written_never_stops_the_program()
        {
            using var dir = new TempDir();
            var log = new TrayLog(Path.Combine(dir.Path, "no", "such", "\0bad", "log.txt"));
            log.Write("still fine");
        }
    }

    public class AtomicFileTests
    {
        [Fact]
        public void A_failed_write_leaves_the_old_file_and_no_temp_file()
        {
            using var dir = new TempDir();
            string target = Path.Combine(dir.Path, "folder-in-the-way");
            Directory.CreateDirectory(target); // a directory where the file should go: the swap must fail
            Assert.ThrowsAny<Exception>(() => AtomicFile.Write(target, Encoding.UTF8.GetBytes("new")));
            Assert.True(Directory.Exists(target));
            Assert.Empty(Directory.GetFiles(dir.Path));
        }

        [Fact]
        public void It_replaces_and_it_creates()
        {
            using var dir = new TempDir();
            string f = dir.File("a.txt");
            AtomicFile.Write(f, Encoding.UTF8.GetBytes("one"));
            AtomicFile.Write(f, Encoding.UTF8.GetBytes("two"));
            Assert.Equal("two", File.ReadAllText(f));
            Assert.Single(Directory.GetFiles(dir.Path));
        }
    }
}
