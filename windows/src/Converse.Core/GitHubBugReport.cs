using System.Net;
using System.Text;
using System.Text.Json;

namespace Converse.Core;

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
