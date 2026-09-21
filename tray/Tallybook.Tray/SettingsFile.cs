using System;
using System.IO;
using System.Text;
using System.Windows.Forms;

namespace Tallybook.Tray
{
    /// <summary>
    /// The person points at their tallybook.config.json (the website's second download). It is read, checked, and -
    /// once the caller has sealed it under %APPDATA% - the plain copy is removed, because it holds credentials in
    /// the clear. The program never looks for the file by itself.
    /// </summary>
    internal static class SettingsFile
    {
        /// <summary>Null when the person cancels. Keeps asking while what they pick is not a settings file.</summary>
        public static TrayConfig? Pick(IWin32Window? owner, TrayLog log)
        {
            using (var dialog = new OpenFileDialog
            {
                Title = "Pick your Tallybook settings file",
                Filter = "Tallybook settings (*.json)|*.json",
                CheckFileExists = true,
                Multiselect = false,
            })
            {
                while (dialog.ShowDialog(owner) == DialogResult.OK)
                {
                    TrayConfig? config = null;
                    try { config = ConfigStore.ImportDownload(File.ReadAllText(dialog.FileName, Encoding.UTF8)); }
                    catch (Exception e) when (e is IOException || e is UnauthorizedAccessException)
                    {
                        log.Write("could not read the picked settings file: " + e.GetType().Name);
                    }
                    if (config != null)
                    {
                        RemovePlainCopy(dialog.FileName, log);
                        return config;
                    }
                    MessageBox.Show(owner, "That is not a Tallybook settings file. It is the second download on the website, named tallybook.config.json.",
                        AppInfo.Name, MessageBoxButtons.OK, MessageBoxIcon.Warning);
                }
                return null;
            }
        }

        private static void RemovePlainCopy(string file, TrayLog log)
        {
            try
            {
                File.Delete(file);
                log.Write("took the credentials from the settings file and removed the plain file");
            }
            catch (Exception e) when (e is IOException || e is UnauthorizedAccessException)
            {
                log.Write("could not remove the plain settings file: " + e.GetType().Name);
            }
        }
    }
}
