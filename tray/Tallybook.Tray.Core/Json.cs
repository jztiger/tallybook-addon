using System.IO;
using System.Runtime.Serialization;
using System.Runtime.Serialization.Json;
using System.Text;

namespace Tallybook.Tray
{
    /// <summary>JSON through what netstandard2.0 and the Framework both already have - no package to ship.</summary>
    internal static class Json
    {
        private static readonly DataContractJsonSerializerSettings Settings = new DataContractJsonSerializerSettings
        {
            UseSimpleDictionaryFormat = true,
        };

        /// <summary>Null when the text is not JSON of that shape. Unknown fields are ignored.</summary>
        public static T? Read<T>(string text) where T : class
        {
            if (string.IsNullOrWhiteSpace(text)) return null;
            try
            {
                using (var stream = new MemoryStream(Encoding.UTF8.GetBytes(text)))
                {
                    return new DataContractJsonSerializer(typeof(T), Settings).ReadObject(stream) as T;
                }
            }
            catch (SerializationException) { return null; }
            catch (System.Xml.XmlException) { return null; }
            catch (System.InvalidCastException) { return null; }
        }

        public static string Write<T>(T value) where T : class
        {
            using (var stream = new MemoryStream())
            {
                using (var writer = JsonReaderWriterFactory.CreateJsonWriter(stream, Encoding.UTF8, false, true, "  "))
                {
                    new DataContractJsonSerializer(typeof(T), Settings).WriteObject(writer, value);
                }
                return Encoding.UTF8.GetString(stream.ToArray()) + "\n";
            }
        }
    }
}
