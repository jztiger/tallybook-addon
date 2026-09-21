using System;
using System.Collections.Generic;

namespace Tallybook.Tray
{
    /// <summary>The game writes its saved file in one go at logout or /reload; a file is read only once it has
    /// kept the same size and time for three seconds, so a half-written one is never sent.</summary>
    public sealed class Stability
    {
        public static readonly TimeSpan Quiet = TimeSpan.FromSeconds(3);

        private sealed class Seen
        {
            public long Length;
            public DateTime ModifiedUtc;
            public DateTime SinceUtc;
        }

        private readonly Dictionary<string, Seen> seen = new Dictionary<string, Seen>(StringComparer.OrdinalIgnoreCase);

        public bool IsStable(string path, long length, DateTime modifiedUtc, DateTime nowUtc)
        {
            if (!seen.TryGetValue(path, out Seen? s) || s.Length != length || s.ModifiedUtc != modifiedUtc)
            {
                seen[path] = new Seen { Length = length, ModifiedUtc = modifiedUtc, SinceUtc = nowUtc };
                return false;
            }
            return nowUtc - s.SinceUtc >= Quiet;
        }
    }
}
