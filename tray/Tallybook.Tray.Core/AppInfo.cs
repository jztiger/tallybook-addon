namespace Tallybook.Tray
{
    /// <summary>What this build is. The server compares Version with what it has on offer.</summary>
    public static class AppInfo
    {
        public const string Name = "Tallybook";
        public const string Version = "0.1.0";
        /// <summary>An ordinary User-Agent: Cloudflare challenges odd ones.</summary>
        public const string UserAgent = "Tallybook-Tray/" + Version;
    }
}
