using System.Text.Json;
using System.Text.RegularExpressions;

namespace DomainManager.Helper;

internal sealed class RuntimeSettings
{
    private const string ConfigurationPath = @"C:\ProgramData\DomainManager\config\runtime.json";
    private static readonly Lazy<RuntimeSettings> LazyCurrent = new(Load);

    public static RuntimeSettings Current => LazyCurrent.Value;

    public required string ApacheRoot { get; init; }
    public required string ApacheServiceName { get; init; }
    public required string AllowedProjectRoot { get; init; }
    public required string MkcertExecutable { get; init; }
    public required IReadOnlyDictionary<string, string> PhpRuntimes { get; init; }

    private static RuntimeSettings Load()
    {
        if (!File.Exists(ConfigurationPath))
            throw new InvalidOperationException($"Brakuje chronionej konfiguracji helpera: {ConfigurationPath}");

        using JsonDocument document = JsonDocument.Parse(File.ReadAllText(ConfigurationPath));
        JsonElement root = document.RootElement;
        if (root.GetProperty("schema_version").GetInt32() != 1 || root.GetProperty("platform").GetString() != "windows")
            throw new InvalidOperationException("Nieobsługiwana konfiguracja środowiska helpera.");

        JsonElement apache = root.GetProperty("apache");
        string apacheRoot = FullPath(apache.GetProperty("root").GetString(), "apache.root");
        string serviceName = apache.GetProperty("service_name").GetString() ?? string.Empty;
        if (!Regex.IsMatch(serviceName, "^[A-Za-z0-9._-]+$"))
            throw new InvalidOperationException("apache.service_name zawiera niedozwolone znaki.");
        if (!File.Exists(Path.Combine(apacheRoot, "bin", "httpd.exe")) || !File.Exists(Path.Combine(apacheRoot, "conf", "httpd.conf")))
            throw new InvalidOperationException("apache.root nie wskazuje prawidłowej instalacji Apache.");

        JsonElement allowedRoots = root.GetProperty("projects").GetProperty("allowed_roots");
        if (allowedRoots.GetArrayLength() != 1)
            throw new InvalidOperationException("Windows MVP wymaga dokładnie jednego projects.allowed_roots.");
        string allowedProjectRoot = FullPath(allowedRoots[0].GetString(), "projects.allowed_roots[0]");
        if (!Directory.Exists(allowedProjectRoot))
            throw new InvalidOperationException("Dozwolony katalog projektów nie istnieje.");

        var phpRuntimes = new Dictionary<string, string>(StringComparer.Ordinal);
        foreach (JsonProperty version in root.GetProperty("php").GetProperty("versions").EnumerateObject())
        {
            if (!Regex.IsMatch(version.Name, "^[0-9]+\\.[0-9]+\\.[0-9]+$"))
                throw new InvalidOperationException($"Nieprawidłowa wersja PHP: {version.Name}");
            string cgi = FullPath(version.Value.GetProperty("cgi").GetString(), $"php.versions.{version.Name}.cgi");
            if (!File.Exists(cgi) || !Path.GetFileName(cgi).Equals("php-cgi.exe", StringComparison.OrdinalIgnoreCase))
                throw new InvalidOperationException($"Runtime PHP {version.Name} nie zawiera php-cgi.exe.");
            phpRuntimes.Add(version.Name, cgi);
        }
        if (phpRuntimes.Count == 0)
            throw new InvalidOperationException("Konfiguracja nie zawiera żadnego runtime PHP.");

        string mkcert = FullPath(root.GetProperty("tools").GetProperty("mkcert").GetString(), "tools.mkcert");
        return new RuntimeSettings
        {
            ApacheRoot = apacheRoot,
            ApacheServiceName = serviceName,
            AllowedProjectRoot = allowedProjectRoot,
            MkcertExecutable = mkcert,
            PhpRuntimes = phpRuntimes,
        };
    }

    private static string FullPath(string? value, string field)
    {
        if (string.IsNullOrWhiteSpace(value) || !Path.IsPathFullyQualified(value) || value.IndexOfAny(['\r', '\n', '"']) >= 0)
            throw new InvalidOperationException($"{field} musi być bezpieczną ścieżką bezwzględną.");
        return Path.GetFullPath(value).TrimEnd(Path.DirectorySeparatorChar);
    }
}
