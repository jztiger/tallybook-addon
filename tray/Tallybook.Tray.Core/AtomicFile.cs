using System;
using System.IO;

namespace Tallybook.Tray
{
    /// <summary>Writes a whole file or none of it: a temp file beside the target, flushed, then swapped in.</summary>
    public static class AtomicFile
    {
        public const string TempSuffix = ".tmp-tallybook";

        public static void Write(string path, byte[] bytes)
        {
            string temp = path + TempSuffix;
            try
            {
                using (var stream = new FileStream(temp, FileMode.Create, FileAccess.Write, FileShare.None))
                {
                    stream.Write(bytes, 0, bytes.Length);
                    stream.Flush(true);
                }
                if (File.Exists(path)) File.Replace(temp, path, null);
                else File.Move(temp, path);
            }
            catch
            {
                try { if (File.Exists(temp)) File.Delete(temp); } catch (IOException) { } catch (UnauthorizedAccessException) { }
                throw;
            }
        }
    }
}
