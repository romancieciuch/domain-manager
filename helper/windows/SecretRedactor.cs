using System.Text.RegularExpressions;

namespace DomainManager.Helper;

internal static partial class SecretRedactor
{
    private const string Replacement = "[REDACTED]";

    public static string? Redact(string? value)
    {
        if (string.IsNullOrEmpty(value)) return value;

        string redacted = PrivateKeyRegex().Replace(value, Replacement);
        redacted = AuthorizationRegex().Replace(redacted, match => match.Groups["prefix"].Value + Replacement);
        redacted = UriPasswordRegex().Replace(redacted, match => match.Groups["prefix"].Value + Replacement + "@");
        redacted = JsonSecretRegex().Replace(redacted, match => match.Groups["prefix"].Value + Replacement + match.Groups["suffix"].Value);
        redacted = NamedSecretRegex().Replace(redacted, match => match.Groups["prefix"].Value + Replacement);
        return redacted;
    }

    public static bool SelfTest()
    {
        string sample = "postgres://user:p@ssword@localhost/db " +
            "password=hunter2; api_key='abc-123' token=xyz " +
            "Authorization: Bearer eyJ.secret.value " +
            "{\"client_secret\":\"json-secret\"}\n" +
            "-----BEGIN PRIVATE KEY-----\nprivate-material\n-----END PRIVATE KEY-----";
        string output = Redact(sample)!;

        return !output.Contains("p@ssword", StringComparison.Ordinal)
            && !output.Contains("hunter2", StringComparison.Ordinal)
            && !output.Contains("abc-123", StringComparison.Ordinal)
            && !output.Contains("xyz", StringComparison.Ordinal)
            && !output.Contains("eyJ.secret.value", StringComparison.Ordinal)
            && !output.Contains("json-secret", StringComparison.Ordinal)
            && !output.Contains("private-material", StringComparison.Ordinal)
            && output.Contains(Replacement, StringComparison.Ordinal);
    }

    [GeneratedRegex(@"-----BEGIN (?:[A-Z0-9 ]+ )?PRIVATE KEY-----[\s\S]*?-----END (?:[A-Z0-9 ]+ )?PRIVATE KEY-----", RegexOptions.IgnoreCase | RegexOptions.CultureInvariant)]
    private static partial Regex PrivateKeyRegex();

    [GeneratedRegex(@"(?<prefix>\bAuthorization\s*:\s*(?:Basic|Bearer)\s+)[^\s,;]+", RegexOptions.IgnoreCase | RegexOptions.CultureInvariant)]
    private static partial Regex AuthorizationRegex();

    [GeneratedRegex(@"(?<prefix>\b[a-z][a-z0-9+.-]*://[^\s/:@]+:)[^\s/@]+(?:@[^\s/]*)?(?=@)", RegexOptions.IgnoreCase | RegexOptions.CultureInvariant)]
    private static partial Regex UriPasswordRegex();

    [GeneratedRegex("(?<prefix>\\\"(?:password|passwd|pwd|secret|token|api[_-]?key|access[_-]?token|client[_-]?secret)\\\"\\s*:\\s*\\\")[^\\\"]*(?<suffix>\\\")", RegexOptions.IgnoreCase | RegexOptions.CultureInvariant)]
    private static partial Regex JsonSecretRegex();

    [GeneratedRegex("""(?<prefix>\b(?:password|passwd|pwd|secret|token|api[_-]?key|access[_-]?token|client[_-]?secret)\s*[=:]\s*['"]?)[^\s,;&'"]+""", RegexOptions.IgnoreCase | RegexOptions.CultureInvariant)]
    private static partial Regex NamedSecretRegex();
}
