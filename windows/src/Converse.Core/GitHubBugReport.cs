using System.Net;
using System.Text;
using System.Text.Json;

namespace Converse.Core;

public static class BugReportPrivacy
{
    // Only numeric counts and public version strings; no profile serialization.
    public static string Summary(string version, string os, bool grouped, int peers, int online, int sessions, int busy) =>
        $"\n\nDiagnostic summary (names and identifiers omitted):\nConverse: {version}\nOS: {os}\nIn a Group: {(grouped ? "yes" : "no")}\nKnown peers: {peers}; online: {online}\nLocal sessions: {sessions}; busy: {busy}";
    public static string Scrub(string text)
    {
        string[] patterns = [
            @"(?s)-----BEGIN [A-Z ]*PRIVATE KEY-----.*?-----END [A-Z ]*PRIVATE KEY-----",
            @"(?i)\b(?:gh[pousr]_[A-Za-z0-9_]+|github_pat_[A-Za-z0-9_]+|sk-[A-Za-z0-9_-]{8,})",
            "(?i)\\bBearer\\s+[^\\s\"',;]+",
            @"(?i)\b(?:api[_-]?key|token|password|secret)\s*[:=]\s*[^\r\n]+",
            @"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}",
            @"(?i)(?:/Users/|/home/|[A-Z]:\\Users\\)[^\r\n]+",
            @"\b(?:\d{1,3}\.){3}\d{1,3}\b"
        ];
        foreach (var pattern in patterns) text = System.Text.RegularExpressions.Regex.Replace(text, pattern, "[removed]", System.Text.RegularExpressions.RegexOptions.None, TimeSpan.FromSeconds(1));
        return text;
    }
}

public sealed record GitHubBugReport(string Title, string Body)
{
    public const string Repository = "richardkaufmann/converse";
    public const string NewIssueURL = "https://github.com/" + Repository + "/issues/new";
    public GitHubBugReport Validated()
    {
        var value = new GitHubBugReport(Title.Trim(), Body.Trim());
        if (value.Title.Length is 0 or > 200 || value.Body.Length is 0 or > 12000)
            throw new ArgumentException("Add a title (up to 200 characters) and description (up to 12,000 characters).");
        return value;
    }
    public Uri BrowserURL()
    {
        var value = Validated();
        var url = NewIssueURL + "?title=" + Uri.EscapeDataString(value.Title) + "&body=" + Uri.EscapeDataString(value.Body);
        if (Encoding.UTF8.GetByteCount(url) > 7500) throw new ArgumentException("This report is too long for a browser link. Shorten it, or copy the description and paste it into GitHub.");
        return new Uri(url);
    }
    public async Task<Uri> SubmitAsync(string token, HttpClient client)
    {
        var value = Validated();
        if (string.IsNullOrWhiteSpace(token)) throw new ArgumentException("Sign in on GitHub to submit this report.");
        using var request = new HttpRequestMessage(HttpMethod.Post, "https://api.github.com/repos/" + Repository + "/issues");
        request.Headers.Authorization = new("Bearer", token);
        request.Headers.UserAgent.ParseAdd("Converse/1");
        request.Headers.Accept.ParseAdd("application/vnd.github+json");
        request.Content = new StringContent(JsonSerializer.Serialize(new { title = value.Title, body = value.Body }), Encoding.UTF8, "application/json");
        HttpResponseMessage response;
        try { response = await client.SendAsync(request); }
        catch { throw new InvalidOperationException("GitHub did not confirm the result. Check the issue list before trying again; this report was not automatically retried."); }
        using (response)
        {
            if (response.StatusCode != HttpStatusCode.Created)
                throw new InvalidOperationException($"GitHub did not confirm creation (HTTP {(int)response.StatusCode}). Use GitHub in your browser to sign in and check access. Check the issue list before trying again.");
            try
            {
                var bytes = await response.Content.ReadAsByteArrayAsync();
                if (bytes.Length > 2_000_000) throw new InvalidOperationException();
                using var json = JsonDocument.Parse(bytes); var root = json.RootElement;
                var number = root.GetProperty("number").GetInt64();
                var expected = "https://github.com/" + Repository + "/issues/" + number;
                if (number <= 0 || root.TryGetProperty("pull_request", out _) || root.GetProperty("html_url").GetString() != expected) throw new InvalidOperationException();
                return new Uri(expected);
            }
            catch { throw new InvalidOperationException("GitHub accepted the request but returned an unexpected receipt. Check the issue list; do not submit it again."); }
        }
    }
}
