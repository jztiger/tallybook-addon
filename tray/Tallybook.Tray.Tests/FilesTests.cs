using System;
using System.IO;
using System.IO.Compression;
using System.Linq;
using System.Text;
using Xunit;

namespace Tallybook.Tray.Tests
{
    public class GameFoldersTests
    {
        private static string Touch(string root, params string[] parts)
        {
            string path = Path.Combine(new[] { root }.Concat(parts).ToArray());
            Directory.CreateDirectory(Path.GetDirectoryName(path)!);
            File.WriteAllText(path, "x");
            return path;
        }

        [Fact]
        public void Saved_files_are_found_by_the_fixed_pattern_only()
        {
            using var dir = new TempDir();
            string a = Touch(dir.Path, "_classic_beta_", "WTF", "Account", "ACCT#1", "SavedVariables", "Tallybook.lua");
            string b = Touch(dir.Path, "_classic_beta_", "WTF", "Account", "ACCT#1", "SavedVariables", "Tallybook.lua.bak");
            string c = Touch(dir.Path, "_retail_", "WTF", "Account", "OTHER", "SavedVariables", "Tallybook.lua");
            // None of these may be picked up:
            Touch(dir.Path, "_classic_beta_", "WTF", "Account", "ACCT#1", "SavedVariables", "Auctionator.lua");
            Touch(dir.Path, "_classic_beta_", "WTF", "Account", "ACCT#1", "Server", "Char", "SavedVariables", "Tallybook.lua");
            Touch(dir.Path, "_classic_beta_", "WTF", "Tallybook.lua");
            Touch(dir.Path, "Tallybook.lua");
            Touch(dir.Path, "notagame", "WTF", "Account", "ACCT#1", "SavedVariables", "Tallybook.lua");
            Touch(dir.Path, "_classic_beta_", "_nested_", "WTF", "Account", "X", "SavedVariables", "Tallybook.lua");

            var found = GameFolders.SavedFiles(dir.Path).OrderBy(p => p, StringComparer.Ordinal).ToArray();
            Assert.Equal(new[] { a, b, c }.OrderBy(p => p, StringComparer.Ordinal).ToArray(), found);
        }

        [Fact]
        public void Data_files_are_only_ones_that_already_exist_in_the_addons_own_folder()
        {
            using var dir = new TempDir();
            string a = Touch(dir.Path, "_classic_beta_", "Interface", "AddOns", "Tallybook", "Data.lua");
            Directory.CreateDirectory(Path.Combine(dir.Path, "_retail_", "Interface", "AddOns", "Tallybook")); // installed, but no Data.lua
            Touch(dir.Path, "_classic_beta_", "Interface", "AddOns", "OtherAddon", "Data.lua");
            Touch(dir.Path, "_classic_beta_", "Interface", "AddOns", "Tallybook", "Sub", "Data.lua");

            Assert.Equal(new[] { a }, GameFolders.DataFiles(dir.Path).ToArray());
        }

        [Fact]
        public void Looking_creates_nothing_and_a_missing_or_wrong_folder_is_just_empty()
        {
            using var dir = new TempDir();
            string missing = Path.Combine(dir.Path, "nope");
            Assert.Empty(GameFolders.SavedFiles(missing));
            Assert.Empty(GameFolders.DataFiles(missing));
            Assert.Empty(GameFolders.SavedFiles(""));
            Assert.False(GameFolders.LooksLikeWow(missing));
            Assert.False(GameFolders.LooksLikeWow(dir.Path));
            Assert.False(Directory.Exists(missing));
            Assert.Empty(Directory.GetFileSystemEntries(dir.Path));

            Directory.CreateDirectory(Path.Combine(dir.Path, "_classic_beta_"));
            Assert.True(GameFolders.LooksLikeWow(dir.Path));
        }
    }

    public class StabilityTests
    {
        private static readonly DateTime T0 = new DateTime(2026, 9, 20, 12, 0, 0, DateTimeKind.Utc);

        [Fact]
        public void A_file_is_stable_after_three_seconds_without_change()
        {
            var s = new Stability();
            Assert.False(s.IsStable("a", 100, T0, T0));
            Assert.False(s.IsStable("a", 100, T0, T0.AddSeconds(2)));
            Assert.True(s.IsStable("a", 100, T0, T0.AddSeconds(3)));
            Assert.True(s.IsStable("a", 100, T0, T0.AddSeconds(60)));
        }

        [Fact]
        public void A_change_of_size_or_time_restarts_the_wait_and_files_do_not_affect_each_other()
        {
            var s = new Stability();
            s.IsStable("a", 100, T0, T0);
            s.IsStable("b", 5, T0, T0);
            Assert.False(s.IsStable("a", 200, T0, T0.AddSeconds(3)));           // grew
            Assert.True(s.IsStable("b", 5, T0, T0.AddSeconds(3)));
            Assert.False(s.IsStable("a", 200, T0.AddSeconds(4), T0.AddSeconds(5))); // rewritten, same size
            Assert.False(s.IsStable("a", 200, T0.AddSeconds(4), T0.AddSeconds(7)));
            Assert.True(s.IsStable("a", 200, T0.AddSeconds(4), T0.AddSeconds(8)));
        }
    }

    public class SentLogTests
    {
        [Fact]
        public void It_remembers_across_restarts_and_does_not_repeat_itself()
        {
            using var dir = new TempDir();
            string file = dir.File("sent.txt");
            var log = new SentLog(file);
            Assert.False(log.Has("aa"));
            log.Add("aa");
            log.Add("aa");
            log.Add("bb");
            Assert.True(log.Has("aa"));

            var again = new SentLog(file);
            Assert.True(again.Has("aa"));
            Assert.True(again.Has("bb"));
            Assert.False(again.Has("cc"));
            Assert.Equal(2, File.ReadAllLines(file).Length);
        }

        [Fact]
        public void It_keeps_the_newest_and_survives_a_damaged_file()
        {
            using var dir = new TempDir();
            string file = dir.File("sent.txt");
            var log = new SentLog(file, 3);
            foreach (string h in new[] { "h1", "h2", "h3", "h4", "h5" }) log.Add(h);
            var again = new SentLog(file, 3);
            Assert.False(again.Has("h1"));
            Assert.False(again.Has("h2"));
            Assert.True(again.Has("h3") && again.Has("h4") && again.Has("h5"));

            File.WriteAllBytes(file, new byte[] { 0, 255, 10, 13, 0 });
            Assert.False(new SentLog(file, 3).Has("h5"));
        }
    }

    public class PayloadTests
    {
        [Fact]
        public void Sha256_is_lowercase_hex()
        {
            Assert.Equal("ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", Payload.Sha256Hex(Encoding.ASCII.GetBytes("abc")));
        }

        [Fact]
        public void Gzip_round_trips_and_carries_no_file_name()
        {
            byte[] plain = Encoding.UTF8.GetBytes(string.Concat(Enumerable.Repeat("TallybookDB = { scans = {} }\n", 500)));
            byte[] gz = Payload.Gzip(plain);
            Assert.True(gz.Length < plain.Length / 4);
            Assert.Equal(0x1f, gz[0]);
            Assert.Equal(0x8b, gz[1]);
            Assert.Equal(0, gz[3] & 0x08); // FNAME flag not set: no file name travels with the bytes (C11)

            using var input = new GZipStream(new MemoryStream(gz), CompressionMode.Decompress);
            using var output = new MemoryStream();
            input.CopyTo(output);
            Assert.Equal(plain, output.ToArray());
        }
    }
}
