using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Security.Cryptography;
using System.Text;
using Xunit;

namespace Tallybook.Tray.Tests
{
    /// <summary>
    /// The one place this program writes into somebody's game folder. Everything here is about what it REFUSES:
    /// a manifest is installed whole or not at all, and never a byte outside the addon's own folder.
    /// </summary>
    public class AddonInstallerTests
    {
        private static string Sha(string content)
        {
            using (SHA256 sha = SHA256.Create())
            {
                var hex = new StringBuilder(64);
                foreach (byte b in sha.ComputeHash(Encoding.UTF8.GetBytes(content))) hex.Append(b.ToString("x2"));
                return hex.ToString();
            }
        }

        private static AddonFile File_(string name, string content) =>
            new AddonFile { Name = name, Content = content, Sha256 = Sha(content) };

        private const string Toc = "## Interface: 16001\n## Title: Tallybook\n## Version: 0.9.0\n\nLogic.lua\nData.lua\n";

        private static AddonManifest Good(params AddonFile[] extra)
        {
            var files = new List<AddonFile> { File_("Tallybook.toc", Toc), File_("Logic.lua", "local _, ns = ...\nns.L = {}\n"), File_("Data.lua", "-- GENERATED\nns.baked = {\n}\n") };
            files.AddRange(extra);
            return new AddonManifest { Version = "0.9.0", Files = files };
        }

        /// <summary>An AddOns folder with another addon beside ours, so a stray write shows up.</summary>
        private static (string addons, string target) AddOns(TempDir dir, bool installed)
        {
            string addons = Path.Combine(dir.Path, "Interface", "AddOns");
            Directory.CreateDirectory(Path.Combine(addons, "SomeoneElse"));
            System.IO.File.WriteAllText(Path.Combine(addons, "SomeoneElse", "Other.lua"), "not ours");
            string target = Path.Combine(addons, "Tallybook");
            if (installed)
            {
                Directory.CreateDirectory(target);
                System.IO.File.WriteAllText(Path.Combine(target, "Tallybook.toc"), Toc.Replace("0.9.0", "0.8.0"));
                System.IO.File.WriteAllText(Path.Combine(target, "Logic.lua"), "old logic\n");
                System.IO.File.WriteAllText(Path.Combine(target, "Gone.lua"), "dropped by the new version\n");
                System.IO.File.WriteAllText(Path.Combine(target, "Data.lua"), "-- the player's own prices\nns.baked = { prices = { [2589] = 160 } }\n");
            }
            return (addons, target);
        }

        private static void NothingElseTouched(string addons)
        {
            Assert.Equal("not ours", System.IO.File.ReadAllText(Path.Combine(addons, "SomeoneElse", "Other.lua")));
            string[] left = Directory.GetDirectories(addons).Select(Path.GetFileName).OrderBy(n => n, StringComparer.Ordinal).ToArray()!;
            Assert.All(left, n => Assert.True(n == "SomeoneElse" || n == "Tallybook", "left behind: " + n));
        }

        [Fact]
        public void A_fresh_install_writes_every_file_and_creates_the_folder()
        {
            using var dir = new TempDir();
            var (addons, target) = AddOns(dir, installed: false);

            AddonInstaller.Install(target, Good());

            Assert.Equal(new[] { "Data.lua", "Logic.lua", "Tallybook.toc" }, Directory.GetFiles(target).Select(Path.GetFileName).OrderBy(n => n, StringComparer.Ordinal).ToArray());
            Assert.Equal(Toc, System.IO.File.ReadAllText(Path.Combine(target, "Tallybook.toc")));
            Assert.Equal("0.9.0", AddonInstaller.InstalledVersion(target));
            NothingElseTouched(addons);
        }

        [Fact]
        public void An_update_replaces_the_code_KEEPS_THE_PLAYERS_PRICES_and_drops_what_the_new_version_removed()
        {
            using var dir = new TempDir();
            var (addons, target) = AddOns(dir, installed: true);
            string prices = System.IO.File.ReadAllText(Path.Combine(target, "Data.lua"));

            AddonInstaller.Install(target, Good());

            Assert.Equal("local _, ns = ...\nns.L = {}\n", System.IO.File.ReadAllText(Path.Combine(target, "Logic.lua")));
            Assert.Equal(prices, System.IO.File.ReadAllText(Path.Combine(target, "Data.lua"))); // NOT the manifest's empty one
            Assert.False(System.IO.File.Exists(Path.Combine(target, "Gone.lua")));
            Assert.Equal("0.9.0", AddonInstaller.InstalledVersion(target));
            NothingElseTouched(addons);
        }

        [Theory]
        [InlineData("../evil.lua")]
        [InlineData("..\\evil.lua")]
        [InlineData("sub/Logic.lua")]
        [InlineData("sub\\Logic.lua")]
        [InlineData("C:\\windows\\evil.lua")]
        [InlineData("/etc/passwd")]
        [InlineData("Logic.exe")]
        [InlineData("Logic.lua.bak")]
        [InlineData(".hidden.lua")]
        [InlineData("")]
        [InlineData(".lua")]
        [InlineData("Logic .lua")]
        [InlineData("Logic\0.lua")]
        public void A_name_that_is_not_a_plain_addon_file_is_refused_whole(string name)
        {
            using var dir = new TempDir();
            var (addons, target) = AddOns(dir, installed: true);
            string before = System.IO.File.ReadAllText(Path.Combine(target, "Logic.lua"));

            AddonManifest m = Good(File_(name, "payload"));
            Assert.NotNull(AddonManifest.Reject(m));
            Assert.ThrowsAny<Exception>(() => AddonInstaller.Install(target, m));

            Assert.Equal(before, System.IO.File.ReadAllText(Path.Combine(target, "Logic.lua")));
            NothingElseTouched(addons);
        }

        [Fact]
        public void A_manifest_that_does_not_add_up_is_refused_whole()
        {
            using var dir = new TempDir();
            var (addons, target) = AddOns(dir, installed: true);
            string before = System.IO.File.ReadAllText(Path.Combine(target, "Logic.lua"));

            var bad = new List<AddonManifest>
            {
                new AddonManifest { Version = "0.9.0", Files = new List<AddonFile>() },                    // nothing in it
                new AddonManifest { Version = "0.9.0", Files = new List<AddonFile> { File_("Logic.lua", "x") } }, // no .toc
                Good(File_("Second.toc", Toc)),                                                            // two .toc files
                Good(File_("Logic.lua", "a different Logic")),                                             // a duplicate name
            };
            var tampered = Good();
            tampered.Files[1].Content = "swapped after the hash was taken";                                 // hash does not match
            bad.Add(tampered);
            var big = Good();
            big.Files[1].Content = new string('x', AddonInstaller.MaxFileBytes + 1);
            big.Files[1].Sha256 = Sha(big.Files[1].Content);
            bad.Add(big);                                                                                   // one file too large
            var many = Good();
            for (int i = 0; i < AddonInstaller.MaxFiles; i++) many.Files.Add(File_("Filler" + i + ".lua", "x"));
            bad.Add(many);                                                                                  // too many files
            bad.Add(new AddonManifest { Version = "", Files = Good().Files });                              // no version

            foreach (AddonManifest m in bad)
            {
                Assert.NotNull(AddonManifest.Reject(m));
                Assert.ThrowsAny<Exception>(() => AddonInstaller.Install(target, m));
            }
            Assert.NotNull(AddonManifest.Reject(null)); // no manifest at all is refused too

            Assert.Equal(before, System.IO.File.ReadAllText(Path.Combine(target, "Logic.lua")));
            Assert.Equal(4, Directory.GetFiles(target).Length); // still the four it had
            NothingElseTouched(addons);
        }

        [Fact]
        public void A_refusal_leaves_no_half_written_folder_behind()
        {
            using var dir = new TempDir();
            var (addons, target) = AddOns(dir, installed: true);
            try { AddonInstaller.Install(target, Good(File_("../evil.lua", "x"))); } catch (Exception) { }
            Assert.DoesNotContain(Directory.GetDirectories(addons), d => Path.GetFileName(d)!.Contains(".new-") || Path.GetFileName(d)!.Contains(".old-"));
            NothingElseTouched(addons);
        }

        [Fact]
        public void The_installed_version_is_read_from_the_toc_and_is_null_when_there_is_no_addon()
        {
            using var dir = new TempDir();
            var (_, target) = AddOns(dir, installed: true);
            Assert.Equal("0.8.0", AddonInstaller.InstalledVersion(target));
            Assert.Null(AddonInstaller.InstalledVersion(Path.Combine(dir.Path, "nowhere")));
            System.IO.File.WriteAllText(Path.Combine(target, "Tallybook.toc"), "## Title: Tallybook\n");
            Assert.Null(AddonInstaller.InstalledVersion(target));
        }

        [Fact]
        public void A_good_manifest_is_not_refused()
        {
            Assert.Null(AddonManifest.Reject(Good()));
        }
    }
}
