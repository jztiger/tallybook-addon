using System;

namespace Tallybook.Tray
{
    /// <summary>How long to leave the server alone after a failure: 5 s, doubling, never more than 10 minutes.</summary>
    public sealed class Backoff
    {
        private static readonly TimeSpan First = TimeSpan.FromSeconds(5);
        private static readonly TimeSpan Longest = TimeSpan.FromMinutes(10);
        private TimeSpan next = First;

        public TimeSpan Next()
        {
            TimeSpan wait = next;
            next = TimeSpan.FromSeconds(Math.Min(Longest.TotalSeconds, next.TotalSeconds * 2));
            return wait;
        }

        public void Reset() { next = First; }
    }
}
