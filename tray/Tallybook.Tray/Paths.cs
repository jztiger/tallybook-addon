using System;
using System.IO;
using System.Reflection;

namespace Tallybook.Tray
{
    /// <summary>The only places outside the game folder this program reads or writes.</summary>
    internal static class Paths
    {
        /// <summary>%APPDATA%\Tallybook</summary>
        public static string Home => Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "Tallybook");
        public static string Config => Path.Combine(Home, "config.json");
        public static string Sent => Path.Combine(Home, "sent.txt");
        public static string Log => Path.Combine(Home, "log.txt");

        public static string Exe => Assembly.GetExecutingAssembly().Location;
        /// <summary>The member's download, as unzipped beside the exe. Imported once, then deleted.</summary>
        public static string Download => Path.Combine(Path.GetDirectoryName(Exe) ?? ".", "tallybook.config.json");
    }
}
