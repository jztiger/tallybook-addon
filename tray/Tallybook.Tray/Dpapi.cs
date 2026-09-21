using System;
using System.Security.Cryptography;
using System.Text;

namespace Tallybook.Tray
{
    /// <summary>Windows' per-user protection (DPAPI): what it seals, only this Windows user on this PC can open.</summary>
    internal sealed class Dpapi : ISecretProtector
    {
        private static readonly byte[] Entropy = Encoding.UTF8.GetBytes("Tallybook.Tray.v1");

        public string Protect(string plain) =>
            Convert.ToBase64String(ProtectedData.Protect(Encoding.UTF8.GetBytes(plain), Entropy, DataProtectionScope.CurrentUser));

        public string Unprotect(string sealedText) =>
            Encoding.UTF8.GetString(ProtectedData.Unprotect(Convert.FromBase64String(sealedText), Entropy, DataProtectionScope.CurrentUser));
    }
}
