using System.Text.Json;
using System.Text.Json.Serialization;

namespace Converse.Core;

/// <summary>
/// Offline Help document generated at build time from the tracked README by
/// scripts/build-help.py. One versioned artifact is shared by every platform;
/// each renders <see cref="HelpTopic.Markdown"/> natively and searches
/// <see cref="HelpTopic.PlainText"/>. No runtime network dependency.
/// </summary>
public sealed class HelpDocument
{
    public const int CurrentSchemaVersion = 1;

    [JsonPropertyName("schemaVersion")] public int SchemaVersion { get; set; }
    // Locked shared metadata (schema 1). Unknown fields are ignored on load.
    [JsonPropertyName("title")] public string Title { get; set; } = "";
    [JsonPropertyName("appVersion")] public string AppVersion { get; set; } = "unknown";
    [JsonPropertyName("appBuild")] public string AppBuild { get; set; } = "";
    [JsonPropertyName("sourceCommit")] public string SourceCommit { get; set; } = "unknown";
    [JsonPropertyName("sourceURL")] public string SourceURL { get; set; } = "";
    [JsonPropertyName("sourceSHA256")] public string SourceSHA256 { get; set; } = "";
    [JsonPropertyName("source")] public string Source { get; set; } = "README.md";
    [JsonPropertyName("topics")] public List<HelpTopic> Topics { get; set; } = new();

    public static HelpDocument Load(string json)
    {
        var document = JsonSerializer.Deserialize<HelpDocument>(json)
            ?? throw new InvalidDataException("Help artifact is empty.");
        if (document.SchemaVersion != CurrentSchemaVersion)
            throw new InvalidDataException(
                $"Unsupported Help schema {document.SchemaVersion}; regenerate with scripts/build-help.py.");
        document.Topics = document.Topics
            .Where(t => !string.IsNullOrWhiteSpace(t.Id) && !string.IsNullOrWhiteSpace(t.Title))
            .ToList();
        return document;
    }

    public static HelpDocument? TryLoadFile(string path)
    {
        try { return File.Exists(path) ? Load(File.ReadAllText(path)) : null; }
        catch { return null; }
    }

    /// <summary>
    /// Case-insensitive substring search over topic titles and plain text,
    /// with title hits ranked first (document order within each rank).
    /// </summary>
    public IReadOnlyList<HelpTopic> Search(string? query)
    {
        if (string.IsNullOrWhiteSpace(query)) return Topics;
        var needle = query.Trim();
        var titleHits = Topics.Where(t => t.Title.Contains(needle, StringComparison.OrdinalIgnoreCase));
        var bodyOnly = Topics.Where(t =>
            !t.Title.Contains(needle, StringComparison.OrdinalIgnoreCase) &&
            t.PlainText.Contains(needle, StringComparison.OrdinalIgnoreCase));
        return titleHits.Concat(bodyOnly).ToList();
    }

    public HelpTopic? Topic(string id) => Topics.FirstOrDefault(t => t.Id == id);
}

public sealed class HelpTopic
{
    [JsonPropertyName("id")] public string Id { get; set; } = "";
    [JsonPropertyName("title")] public string Title { get; set; } = "";
    [JsonPropertyName("markdown")] public string Markdown { get; set; } = "";
    [JsonPropertyName("plainText")] public string PlainText { get; set; } = "";
}
