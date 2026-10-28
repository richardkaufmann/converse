using System.Text.Json;
using System.Text.Json.Nodes;

namespace Converse.Core;

// UI-neutral projection of a Muse approval/question request, local or
// remote, mirroring Mac RemoteRequestView/MuseRequestView semantics:
// approvals show tool + args + choice buttons; questions show each question
// with single/multi-select options plus free text, answered as an array of
// {questionId, selectedLabel?, selectedLabels?, freeText?}.
public sealed record RequestChoiceView(string Id, string Label, string? Detail);
public sealed record RequestOptionView(string Label, string? Description);
public sealed record RequestQuestionView(string Id, string Text, List<RequestOptionView> Options, bool Multiple);
public sealed record RequestView(string Id, string Kind, string? ToolName, string? RawArgs,
    List<RequestChoiceView> Choices, List<RequestQuestionView> Questions);

public static class RequestViews
{
    public static RequestView FromRemote(DeviceRequestDto dto) => new(dto.Id, dto.Kind, dto.ToolName, dto.RawArgs,
        dto.Choices.Select(c => new RequestChoiceView(c.Id, c.Label, c.Detail)).ToList(),
        ParseQuestions(dto.QuestionsJson is null ? null : System.Text.Encoding.UTF8.GetString(dto.QuestionsJson)));

    public static RequestView FromLocal(MuseRequest request)
    {
        var choices = (request.Params["availableChoices"] as JsonArray ?? new())
            .OfType<JsonObject>()
            .Where(c => c["choiceId"] is not null)
            .Select(c => new RequestChoiceView(
                c["choiceId"]!.GetValue<string>(),
                c["label"]?.GetValue<string>() ?? c["choiceId"]!.GetValue<string>(),
                c["rulePreview"]?.GetValue<string>() ?? c["scope"]?.GetValue<string>())).ToList();
        return new RequestView(request.Id, request.Kind,
            request.Params["toolName"]?.GetValue<string>(),
            request.Params["rawArgs"]?.GetValue<string>(),
            choices,
            ParseQuestions(request.Params["questions"]?.ToJsonString()));
    }

    public static List<RequestQuestionView> ParseQuestions(string? json)
    {
        var questions = new List<RequestQuestionView>();
        if (string.IsNullOrWhiteSpace(json)) return questions;
        JsonNode? node;
        try { node = JsonNode.Parse(json); }
        catch { return questions; }
        if (node is not JsonArray array) return questions;
        for (var i = 0; i < array.Count; i++)
        {
            if (array[i] is not JsonObject q) continue;
            var options = (q["options"] as JsonArray ?? new())
                .OfType<JsonObject>()
                .Select(o => new RequestOptionView(
                    o["label"]?.GetValue<string>() ?? "Option",
                    o["description"]?.GetValue<string>())).ToList();
            var multiple = (q["selection"] as JsonObject)?["mode"]?.GetValue<string>() == "multiple";
            questions.Add(new RequestQuestionView(
                q["id"]?.GetValue<string>() ?? i.ToString(),
                q["question"]?.GetValue<string>() ?? "Question",
                options, multiple));
        }
        return questions;
    }

    // Builds the answers array with Mac-identical keys. Selections hold
    // chosen option labels per question id; free text is trimmed and omitted
    // when empty.
    public static byte[] BuildAnswersJson(RequestView view,
        IReadOnlyDictionary<string, HashSet<string>> selections,
        IReadOnlyDictionary<string, string> freeText)
    {
        var answers = new JsonArray();
        foreach (var question in view.Questions)
        {
            var answer = new JsonObject { ["questionId"] = question.Id };
            var chosen = selections.TryGetValue(question.Id, out var set)
                ? set.Where(s => question.Options.Any(o => o.Label == s)).OrderBy(s => s).ToList()
                : new List<string>();
            if (question.Multiple)
            {
                if (chosen.Count > 0)
                {
                    var labels = new JsonArray();
                    foreach (var label in chosen) labels.Add(label);
                    answer["selectedLabels"] = labels;
                }
            }
            else if (chosen.Count > 0) answer["selectedLabel"] = chosen[0];
            if (freeText.TryGetValue(question.Id, out var text))
            {
                var trimmed = text.Trim();
                if (trimmed.Length > 0) answer["freeText"] = trimmed;
            }
            answers.Add(answer);
        }
        return System.Text.Encoding.UTF8.GetBytes(answers.ToJsonString());
    }
}
