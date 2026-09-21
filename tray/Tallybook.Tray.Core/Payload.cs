using System.IO;
using System.IO.Compression;
using System.Security.Cryptography;
using System.Text;

namespace Tallybook.Tray
{
    /// <summary>What travels: the saved file's bytes, gzipped. No name, no path, no time (C11).</summary>
    public static class Payload
    {
        public static string Sha256Hex(byte[] bytes)
        {
            using (SHA256 sha = SHA256.Create())
            {
                var hex = new StringBuilder(64);
                foreach (byte b in sha.ComputeHash(bytes)) hex.Append(b.ToString("x2"));
                return hex.ToString();
            }
        }

        public static byte[] Gzip(byte[] bytes)
        {
            using (var output = new MemoryStream())
            {
                using (var gzip = new GZipStream(output, CompressionLevel.Optimal, true))
                {
                    gzip.Write(bytes, 0, bytes.Length);
                }
                return output.ToArray();
            }
        }
    }
}
