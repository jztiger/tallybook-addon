using System;
using System.Collections.Generic;
using System.IO;

namespace Tallybook.Tray
{
    /// <summary>
    /// The only places this program ever looks, all below the folder the person picked, all by fixed shallow
    /// patterns - no search, no recursion, no other file name (C4). Looking never creates anything.
    /// </summary>
    public static class GameFolders
    {
        public const string SavedName = "Tallybook.lua";
        public const string SavedBackupName = "Tallybook.lua.bak";

        /// <summary>&lt;wow&gt;\_*_\WTF\Account\*\SavedVariables\Tallybook.lua and .lua.bak, where they exist.</summary>
        public static IReadOnlyList<string> SavedFiles(string wow)
        {
            var found = new List<string>();
            foreach (string product in Products(wow))
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

        /// <summary>&lt;wow&gt;\_*_\Interface\AddOns\Tallybook\Data.lua - only where that file already exists.</summary>
        public static IReadOnlyList<string> DataFiles(string wow)
        {
            var found = new List<string>();
            foreach (string product in Products(wow))
            {
                string file = Path.Combine(product, "Interface", "AddOns", "Tallybook", "Data.lua");
                if (File.Exists(file)) found.Add(file);
            }
            return found;
        }

        /// <summary>The picked folder holds at least one product folder such as _classic_beta_.</summary>
        public static bool LooksLikeWow(string wow) => Products(wow).Count > 0;

        private static List<string> Products(string wow)
        {
            var products = new List<string>();
            foreach (string dir in Children(wow))
            {
                string name = Path.GetFileName(dir);
                if (name.Length >= 3 && name[0] == '_' && name[name.Length - 1] == '_') products.Add(dir);
            }
            return products;
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
