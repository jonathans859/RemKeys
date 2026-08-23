using System.Reflection;

namespace RemKeysAgent;

/// <summary>
/// The agent's own build identity, read once from the attributes the csproj
/// stamps into the assembly.
///
/// The version number is <c>1.0.&lt;commit count&gt;</c>, produced by CI from
/// <c>git rev-list --count HEAD</c> — the same rule the iOS and macOS build
/// numbers already follow, so a build is monotonic on main and recomputable
/// from any checkout. That also makes two versions directly comparable with a
/// plain integer, which is what an updater would need. A local
/// <c>dotnet build</c> gets the csproj's fallback and says so.
/// </summary>
public static class AgentVersion
{
    /// <summary>e.g. "1.0.412", or "1.0.0-dev" for a build made outside CI.</summary>
    public static string Version { get; } = ReadVersion();

    /// <summary>Short commit hash the build came from, empty if it wasn't stamped.</summary>
    public static string Commit { get; } = ReadCommit();

    /// <summary>Build date as "yyyy-MM-dd", empty if it wasn't stamped.</summary>
    public static string BuildDate { get; } = ReadMetadata("BuildDate");

    /// <summary>
    /// One line for a log or a dialog: "1.0.412 (a3f9c21), built 2026-08-23".
    /// </summary>
    public static string Display
    {
        get
        {
            var text = Version;
            if (Commit.Length > 0) text += $" ({Commit})";
            if (BuildDate.Length > 0) text += $", built {BuildDate}";
            return text;
        }
    }

    private static string ReadVersion()
    {
        // InformationalVersion is the one that keeps a suffix like "-dev";
        // AssemblyVersion is forced to four numeric parts and would lose it.
        var informational = typeof(AgentVersion).Assembly
            .GetCustomAttribute<AssemblyInformationalVersionAttribute>()?.InformationalVersion;
        if (string.IsNullOrWhiteSpace(informational)) return "unknown";

        // The SDK appends "+<full sha>" of its own accord when the build has
        // repository information; the hash is reported separately.
        var plus = informational.IndexOf('+');
        return plus < 0 ? informational : informational[..plus];
    }

    private static string ReadCommit()
    {
        var informational = typeof(AgentVersion).Assembly
            .GetCustomAttribute<AssemblyInformationalVersionAttribute>()?.InformationalVersion;
        var plus = informational?.IndexOf('+') ?? -1;
        if (informational is null || plus < 0) return string.Empty;

        var sha = informational[(plus + 1)..];
        return sha.Length > 7 ? sha[..7] : sha;
    }

    private static string ReadMetadata(string key)
    {
        foreach (var attribute in typeof(AgentVersion).Assembly
            .GetCustomAttributes<AssemblyMetadataAttribute>())
        {
            if (attribute.Key == key) return attribute.Value ?? string.Empty;
        }
        return string.Empty;
    }
}
