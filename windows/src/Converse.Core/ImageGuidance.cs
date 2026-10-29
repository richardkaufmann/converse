namespace Converse.Core;

// Picture-request delivery guidance: raw CLIs (claude/codex/muse exec)
// run with no Converse system prompt, so left alone they save SVGs and
// shell open a browser (the spinning-top/red-truck reports). When the
// user's prompt asks for a picture, the runner-bound prompt earns one
// appended instruction steering the agent to PNG-plus-markdown inside
// the session working directory, which ResponseImages.ImportAsync can
// capture. History keeps the original text: callers append only to the
// prompt handed to the runner, never to the stored user message.
public static class ImageGuidance
{
    private static readonly string[] Markers =
    {
        "picture of", "pictures of", "image of", "images of", "photo of", "photos of",
        "show me a picture", "show me an image", "show me a photo",
        "draw a", "draw me", "generate a picture", "generate an image", "generate a photo",
        "make a picture", "make an image", "make a photo",
    };

    public const string Instruction =
        "[Converse image delivery: save any picture for this request as a PNG file " +
        "inside the session working directory and reply with standard markdown " +
        "![caption](absolute path) pointing at that file so it renders inline. " +
        "Do not open a browser or any other app to display it.]";

    public static bool WantsPicture(string prompt)
    {
        if (string.IsNullOrWhiteSpace(prompt)) return false;
        // Already markdown-savvy: an image ref needs no steering.
        if (prompt.Contains("](", StringComparison.Ordinal)) return false;
        return Markers.Any(m => prompt.Contains(m, StringComparison.OrdinalIgnoreCase));
    }

    public static string WithGuidance(string prompt) =>
        WantsPicture(prompt) ? prompt + "\n\n" + Instruction : prompt;
}
