using System.Collections.Generic;

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
        /// <summary>Install the addon when it is missing, and replace it when a newer version is published.</summary>
        public bool KeepAddonUpToDate { get; set; } = true;
        public bool StartWithWindows { get; set; } = true;
        /// <summary>Which version of the notice they accepted. 0 means they have not seen one.</summary>
        public int AcceptedNoticeVersion { get; set; }
        public bool Paused { get; set; }
        /// <summary>
        /// Forever's product folders: the last list the server sent, so this works offline too. Replaced whole,
        /// never changed in place - a pass reads it on another thread.
        /// </summary>
        public IReadOnlyList<string> Products { get; set; } = ForeverProducts.Default;

        /// <summary>Safe to log: no credential, no folder.</summary>
        public override string ToString() =>
            "TrayConfig(api=" + Api + ", bringDataBack=" + BringDataBack + ", paused=" + Paused + ")";
    }
}
