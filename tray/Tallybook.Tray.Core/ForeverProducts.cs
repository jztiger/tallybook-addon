using System;
using System.Collections.Generic;
using System.Text.RegularExpressions;

namespace Tallybook.Tray
{
    /// <summary>
    /// World of Warcraft: Forever's product folders (_classic_beta_ today). They come from the server - its
    /// FOREVER_PRODUCTS, carried in the addon manifest - because the folder is renamed at launch to a name nobody
    /// knows yet. Every name is somebody else's text and becomes a folder name here, so each one is checked first.
    /// </summary>
    public static class ForeverProducts
    {
        /// <summary>The most names taken from one list.</summary>
        public const int Max = 8;

        /// <summary>A plain product folder name. \z, not $: $ would let a trailing newline through.</summary>
        private static readonly Regex Name = new Regex(@"^_[a-z0-9_]+_\z", RegexOptions.CultureInvariant);

        /// <summary>What this program uses until the server has said otherwise: the beta's own folder.</summary>
        public static IReadOnlyList<string> Default { get; } = Array.AsReadOnly(new[] { "_classic_beta_" });

        /// <summary>
        /// A folder name such as _classic_beta_ and nothing else - no separator, no dot, no capital. Never retail's:
        /// a Forever addon does not belong in somebody's retail game, whatever a list says.
        /// </summary>
        public static bool IsProductName(string? name) =>
            name != null && Name.IsMatch(name) && !string.Equals(name, "_retail_", StringComparison.Ordinal);

        /// <summary>
        /// The list to use from now on: what was offered, in its order, without the entries that are not product
        /// names, without repeats, and at most <see cref="Max"/> of them. When nothing was offered (a server from
        /// before the list) or nothing usable was, the list already held is kept.
        /// </summary>
        public static IReadOnlyList<string> Choose(IReadOnlyList<string> held, IEnumerable<string?>? offered)
        {
            if (offered == null) return held;
            var chosen = new List<string>();
            foreach (string? name in offered)
            {
                if (chosen.Count == Max) break;
                if (IsProductName(name) && !chosen.Contains(name!)) chosen.Add(name!);
            }
            return chosen.Count == 0 ? held : chosen.AsReadOnly();
        }

        /// <summary>The same names in the same order.</summary>
        public static bool Same(IReadOnlyList<string> a, IReadOnlyList<string> b)
        {
            if (a.Count != b.Count) return false;
            for (int i = 0; i < a.Count; i++)
                if (!string.Equals(a[i], b[i], StringComparison.Ordinal)) return false;
            return true;
        }
    }
}
