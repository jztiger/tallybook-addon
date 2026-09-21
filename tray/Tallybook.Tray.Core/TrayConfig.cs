namespace Tallybook.Tray
{
    /// <summary>Everything the tray app is told or asked. The three credentials come from the member's own download.</summary>
    public sealed class TrayConfig
    {
        /// <summary>Where tray apps talk to the server (its own Cloudflare Access application).</summary>
        public string Api { get; set; } = "";
        /// <summary>The website, for "Open Tallybook". Never sent anything by this program.</summary>
        public string Ui { get; set; } = "";
        public string ClientId { get; set; } = "";
        public string ClientSecret { get; set; } = "";
        public string UploadKey { get; set; } = "";

        /// <summary>The folder the person picked. Never detected, never guessed (C4).</summary>
        public string WowFolder { get; set; } = "";
        public bool BringDataBack { get; set; } = true;
        public bool StartWithWindows { get; set; } = true;
        public bool AcceptedNotice { get; set; }
        public bool Paused { get; set; }

        /// <summary>Safe to log: no credential, no folder.</summary>
        public override string ToString() =>
            "TrayConfig(api=" + Api + ", bringDataBack=" + BringDataBack + ", paused=" + Paused + ")";
    }
}
