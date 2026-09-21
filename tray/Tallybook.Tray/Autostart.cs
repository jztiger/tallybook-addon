using Microsoft.Win32;

namespace Tallybook.Tray
{
    /// <summary>"Start with Windows": one value under the current user's Run key - visible in Task Manager's
    /// Startup tab, removed by switching it off. Nothing machine-wide, no service, no scheduled task.</summary>
    internal static class Autostart
    {
        private const string RunKey = @"Software\Microsoft\Windows\CurrentVersion\Run";
        private const string ValueName = "Tallybook";

        public static void Apply(bool on)
        {
            using (RegistryKey? key = Registry.CurrentUser.OpenSubKey(RunKey, true))
            {
                if (key == null) return;
                if (on) key.SetValue(ValueName, "\"" + Paths.Exe + "\"");
                else key.DeleteValue(ValueName, false);
            }
        }
    }
}
