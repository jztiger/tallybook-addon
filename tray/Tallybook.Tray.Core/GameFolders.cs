using System;
using System.Collections.Generic;
using System.IO;

namespace Tallybook.Tray
{
    /// <summary>
    /// The only places this program ever looks, all below the folder the person picked, all by fixed shallow
    /// patterns - no search, no recursion, no other file name (C4). Looking never creates anything. Every lookup is
    /// limited to Forever's product folders, as the server listed them (<see cref="ForeverProducts"/>), and each
    /// listed name is checked again here before it becomes part of a path.
    /// </summary>
    public static class GameFolders
    {
        public const string SavedName = "Tallybook.lua";
        public const string SavedBackupName = "Tallybook.lua.bak";

        /// <summary>&lt;wow&gt;\&lt;product&gt;\WTF\Account\*\SavedVariables\Tallybook.lua and .lua.bak, where they exist.</summary>
        public static IReadOnlyList<string> SavedFiles(string wow, IReadOnlyList<string> products)
        {
            var found = new List<string>();
            foreach (string product in Products(wow, products))
            {
                foreach (string account in Children(Path.Combine(product, "WTF", "Account")))
                {
                    string saved = Path.Combine(account, "SavedVariables");
                    foreach (string name in new[] { SavedName, SavedBackupName })
                    {
                        string file = Path.Combine(saved, name);
                        if (File.Exists(file)) found.Add(file);
                    }
                }
            }
            return found;
        }

        /// <summary>&lt;wow&gt;\&lt;product&gt;\Interface\AddOns\Tallybook\Data.lua - only where that file already exists.</summary>
        public static IReadOnlyList<string> DataFiles(string wow, IReadOnlyList<string> products)
        {
            var found = new List<string>();
            foreach (string product in Products(wow, products))
            {
                string file = Path.Combine(product, "Interface", "AddOns", "Tallybook", "Data.lua");
                if (File.Exists(file)) found.Add(file);
            }
            return found;
        }

        /// <summary>Where the addon IS installed - a folder with our .toc in it. These are what an update replaces.</summary>
        public static IReadOnlyList<string> AddonFolders(string wow, IReadOnlyList<string> products)
        {
            var found = new List<string>();
            foreach (string product in Products(wow, products))
            {
                string folder = Path.Combine(product, "Interface", "AddOns", "Tallybook");
                if (File.Exists(Path.Combine(folder, "Tallybook.toc"))) found.Add(folder);
            }
            return found;
        }

        /// <summary>
        /// Where a FIRST install goes, or null. The addon is for one game, so it is never put into a product folder on
        /// a guess: it goes into the first listed product, in the list's order, that is there - never an unlisted
        /// one, never retail's. With none of them there, the person installs it themselves.
        /// </summary>
        public static string? InstallTarget(string wow, IReadOnlyList<string> products)
        {
            List<string> here = Products(wow, products);
            return here.Count == 0 ? null : Path.Combine(here[0], "Interface", "AddOns", "Tallybook");
        }

        /// <summary>
        /// The picked folder holds at least one product folder such as _classic_beta_ - ANY one, listed or not. This
        /// only asks "is this a World of Warcraft folder": on launch day the game's folder has a new name that this
        /// PC's list does not know yet, and the program must still run long enough to fetch the new list.
        /// </summary>
        public static bool LooksLikeWow(string wow)
        {
            foreach (string dir in Children(wow))
            {
                string name = Path.GetFileName(dir);
                if (name.Length >= 3 && name[0] == '_' && name[name.Length - 1] == '_') return true;
            }
            return false;
        }

        /// <summary>The listed products that are there, in the list's order. A name that is not a product name is skipped.</summary>
        private static List<string> Products(string wow, IReadOnlyList<string> products)
        {
            var here = new List<string>();
            if (string.IsNullOrEmpty(wow)) return here;
            foreach (string name in products)
            {
                if (!ForeverProducts.IsProductName(name)) continue;
                string dir = Path.Combine(wow, name);
                try
                {
                    if (Directory.Exists(dir) && !here.Contains(dir)) here.Add(dir);
                }
                catch (Exception e) when (e is IOException || e is UnauthorizedAccessException || e is ArgumentException) { }
            }
            return here;
        }

        private static string[] Children(string dir)
        {
            try
            {
                return string.IsNullOrEmpty(dir) || !Directory.Exists(dir) ? new string[0] : Directory.GetDirectories(dir);
            }
            catch (IOException) { return new string[0]; }
            catch (UnauthorizedAccessException) { return new string[0]; }
        }
    }
}
