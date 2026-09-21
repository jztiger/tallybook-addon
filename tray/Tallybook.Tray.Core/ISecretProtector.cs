namespace Tallybook.Tray
{
    /// <summary>
    /// Seals the two credentials at rest. On Windows this is DPAPI for the current user (the shell supplies it);
    /// the core only knows the shape, so it stays free of Windows and of NuGet packages.
    /// </summary>
    public interface ISecretProtector
    {
        string Protect(string plain);

        /// <summary>Throws when the text was not made by <see cref="Protect"/> for this user, or was altered.</summary>
        string Unprotect(string sealedText);
    }
}
