using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Runtime.Serialization;
using System.Runtime.Serialization.Json;
using System.Text;
using System.Threading.Tasks;
using Xunit;

namespace Tallybook.Tray.Tests
{
    /// <summary>
    /// Forever's product folders come from the server (FOREVER_PRODUCTS, spec 2026-09-25 section 4): launch day renames
    /// _classic_beta_ to a name nobody knows yet, and that must be one server setting, not a new tray download.
    /// </summary>
    public class ForeverProductsTests
    {
        private static readonly string[] Beta = { "_classic_beta_" };

        [Fact]
        public void With_nothing_ever_received_it_is_the_betas_folder()
        {
            Assert.Equal(Beta, ForeverProducts.Default);
        }

        [Theory]
        [InlineData("_classic_beta_", true)]
        [InlineData("_classic_forever_", true)]
        [InlineData("_x1_", true)]
        [InlineData("_retail_", false)] // a Forever addon does not belong in somebody's retail game, whatever a list says
        [InlineData("classic_beta", false)]
        [InlineData("_Classic_", false)]
        [InlineData("__", false)]
        [InlineData("_a/b_", false)]
        [InlineData("_a\\b_", false)]
        [InlineData("_.._", false)]
        [InlineData("_classic_beta_\n", false)]
        [InlineData("", false)]
        [InlineData(null, false)]
        public void A_product_name_is_a_plain_folder_name_and_nothing_else(string? name, bool ok)
        {
            Assert.Equal(ok, ForeverProducts.IsProductName(name));
        }

        [Fact]
        public void The_servers_list_is_taken_in_its_order()
        {
            Assert.Equal(new[] { "_classic_forever_", "_classic_beta_" },
                ForeverProducts.Choose(Beta, new[] { "_classic_forever_", "_classic_beta_" }));
        }

        [Fact]
        public void An_entry_that_is_not_a_folder_name_is_dropped_and_the_rest_kept()
        {
            Assert.Equal(new[] { "_classic_forever_", "_era_" },
                ForeverProducts.Choose(Beta, new[] { "..\\..\\Windows", "_classic_forever_", null, "_Retail_", "_era_", "_classic_forever_" }));
        }

        [Fact]
        public void No_list_or_nothing_usable_keeps_the_list_already_held()
        {
            var held = new[] { "_classic_forever_" };
            Assert.Equal(held, ForeverProducts.Choose(held, null));
            Assert.Equal(held, ForeverProducts.Choose(held, new string[0]));
            Assert.Equal(held, ForeverProducts.Choose(held, new[] { "../x", "" }));
        }

        [Fact]
        public void At_most_eight_are_taken()
        {
            string[] ten = Enumerable.Range(0, 10).Select(i => "_p" + i + "_").ToArray();
            Assert.Equal(ten.Take(8).ToArray(), ForeverProducts.Choose(Beta, ten));
        }
    }

    public class ProductManifestTests
    {
        /// <summary>The manifest exactly as a tray app from before this change declares it: version and files only.</summary>
        [DataContract]
        private sealed class ManifestBeforeProducts
        {
            [DataMember(Name = "version")] public string Version { get; set; } = "";
            [DataMember(Name = "files")] public List<AddonFile> Files { get; set; } = new List<AddonFile>();
        }

        private static string WithProducts(string productsJson) =>
            World.AddonJson("0.9.0").TrimEnd('}') + ",\"products\":" + productsJson + "}";

        [Fact]
        public void A_tray_app_from_before_the_list_still_reads_the_new_manifest_and_would_install_it()
        {
            string json = WithProducts("[\"_classic_forever_\",\"_classic_beta_\"]");
            var settings = new DataContractJsonSerializerSettings { UseSimpleDictionaryFormat = true };
            ManifestBeforeProducts? old;
            using (var stream = new MemoryStream(Encoding.UTF8.GetBytes(json)))
            {
                old = new DataContractJsonSerializer(typeof(ManifestBeforeProducts), settings).ReadObject(stream) as ManifestBeforeProducts;
            }
            Assert.NotNull(old);
            Assert.Equal("0.9.0", old!.Version);
            Assert.Null(AddonManifest.Reject(new AddonManifest { Version = old.Version, Files = old.Files }));
        }

        [Fact]
        public async Task This_tray_app_reads_the_list_and_a_bad_list_never_refuses_the_addon()
        {
            async Task<AddonManifest?> Fetch(string json)
            {
                var server = new FakeServer { Answer = _ => FakeServer.Status(200, json) };
                var (_, manifest, _) = await new ServerClient(ServerClientTests.Config(), server).FetchAddonAsync(null);
                return manifest;
            }

            AddonManifest? m = await Fetch(WithProducts("[\"_classic_forever_\",\"_classic_beta_\"]"));
            Assert.Equal(new[] { "_classic_forever_", "_classic_beta_" }, m!.Products);

            Assert.Null((await Fetch(World.AddonJson("0.9.0")))!.Products); // a server from before the list
            Assert.NotNull(await Fetch(WithProducts("[\"../../x\"]")));      // the addon is still fine; the entry is dropped later
        }
    }

    public class ProductFoldersTests
    {
        private static readonly string[] Beta = { "_classic_beta_" };

        private static string Touch(string root, params string[] parts)
        {
            string path = Path.Combine(new[] { root }.Concat(parts).ToArray());
            Directory.CreateDirectory(Path.GetDirectoryName(path)!);
            File.WriteAllText(path, "x");
            return path;
        }

        private static string Addon(string root, string product) => Path.Combine(root, product, "Interface", "AddOns", "Tallybook");

        [Fact]
        public void A_first_install_goes_to_the_first_listed_product_that_is_there()
        {
            using var dir = new TempDir();
            foreach (string p in new[] { "_retail_", "_classic_beta_", "_classic_forever_" }) Directory.CreateDirectory(Path.Combine(dir.Path, p));

            Assert.Equal(Addon(dir.Path, "_classic_forever_"), GameFolders.InstallTarget(dir.Path, new[] { "_classic_forever_", "_classic_beta_" }));
            Assert.Equal(Addon(dir.Path, "_classic_beta_"), GameFolders.InstallTarget(dir.Path, new[] { "_classic_beta_", "_classic_forever_" }));
            // The first listed is not there: the next one is.
            Assert.Equal(Addon(dir.Path, "_classic_beta_"), GameFolders.InstallTarget(dir.Path, new[] { "_classic_era_", "_classic_beta_" }));
        }

        [Fact]
        public void Retail_or_any_unlisted_game_is_never_chosen_even_when_it_is_the_only_one()
        {
            using var dir = new TempDir();
            Directory.CreateDirectory(Path.Combine(dir.Path, "_retail_"));
            Directory.CreateDirectory(Path.Combine(dir.Path, "_classic_era_"));
            Assert.Null(GameFolders.InstallTarget(dir.Path, Beta));

            Directory.CreateDirectory(Path.Combine(dir.Path, "_ptr_"));
            Assert.Null(GameFolders.InstallTarget(dir.Path, new[] { "_classic_forever_" }));
            // Not even a list that names retail, or entries that are not folder names: the core checks each one itself.
            Assert.Null(GameFolders.InstallTarget(dir.Path, new[] { "_retail_", "_retail_/..", "..", "" }));
        }

        [Fact]
        public void Saved_files_Data_lua_and_the_installed_addon_are_looked_for_under_listed_products_only()
        {
            using var dir = new TempDir();
            string saved = Touch(dir.Path, "_classic_forever_", "WTF", "Account", "A", "SavedVariables", "Tallybook.lua");
            string data = Touch(dir.Path, "_classic_forever_", "Interface", "AddOns", "Tallybook", "Data.lua");
            Touch(dir.Path, "_classic_forever_", "Interface", "AddOns", "Tallybook", "Tallybook.toc");
            Touch(dir.Path, "_retail_", "WTF", "Account", "B", "SavedVariables", "Tallybook.lua");
            Touch(dir.Path, "_retail_", "Interface", "AddOns", "Tallybook", "Data.lua");
            Touch(dir.Path, "_retail_", "Interface", "AddOns", "Tallybook", "Tallybook.toc");

            string[] forever = { "_classic_forever_" };
            Assert.Equal(new[] { saved }, GameFolders.SavedFiles(dir.Path, forever));
            Assert.Equal(new[] { data }, GameFolders.DataFiles(dir.Path, forever));
            Assert.Equal(new[] { Addon(dir.Path, "_classic_forever_") }, GameFolders.AddonFolders(dir.Path, forever));

            // The stale list of before launch day finds nothing - and still, the folder is a game folder.
            Assert.Empty(GameFolders.SavedFiles(dir.Path, Beta));
            Assert.Empty(GameFolders.DataFiles(dir.Path, Beta));
            Assert.Empty(GameFolders.AddonFolders(dir.Path, Beta));
            Assert.True(GameFolders.LooksLikeWow(dir.Path));
        }
    }

    public class ProductPersistenceTests
    {
        private const string Download = "{\"api\":\"https://tally-api.example.com\",\"ui\":\"https://tally.example.com\","
            + "\"clientId\":\"abc123.access\",\"clientSecret\":\"s3cr3t-client-secret\",\"uploadKey\":\"upl0ad-key-43-chars\"}";

        [Fact]
        public void A_download_and_a_config_from_before_the_list_both_start_with_the_betas_folder()
        {
            using var dir = new TempDir();
            TrayConfig c = ConfigStore.ImportDownload(Download)!;
            Assert.Equal(new[] { "_classic_beta_" }, c.Products);
            string path = dir.File("config.json");
            ConfigStore.Save(path, c, new FakeProtector());
            Assert.Equal(new[] { "_classic_beta_" }, ConfigStore.Load(path, new FakeProtector())!.Products);
        }

        [Fact]
        public void The_last_list_received_survives_a_restart_and_a_bad_entry_in_the_file_is_dropped()
        {
            using var dir = new TempDir();
            string path = dir.File("config.json");
            TrayConfig c = ConfigStore.ImportDownload(Download)!;
            c.Products = new[] { "_classic_forever_", "_classic_beta_" };
            ConfigStore.Save(path, c, new FakeProtector());
            Assert.Equal(new[] { "_classic_forever_", "_classic_beta_" }, ConfigStore.Load(path, new FakeProtector())!.Products);

            // Somebody edits the file by hand: the entry that is not a folder name never becomes a path.
            File.WriteAllText(path, File.ReadAllText(path).Replace("\"_classic_beta_\"", "\"..\\\\..\\\\Windows\""));
            Assert.Equal(new[] { "_classic_forever_" }, ConfigStore.Load(path, new FakeProtector())!.Products);
        }

        [Fact]
        public void New_credentials_leave_the_list_alone()
        {
            TrayConfig held = ConfigStore.ImportDownload(Download)!;
            held.Products = new[] { "_classic_forever_" };
            ConfigStore.ApplyCredentials(held, ConfigStore.ImportDownload(Download)!);
            Assert.Equal(new[] { "_classic_forever_" }, held.Products);
        }
    }
}
